#!/usr/bin/python3
"""Sert, avec un jeton, sur le réseau local : la liste des postes RustDesk, les fiches d'installation en attente et leurs validations.

GET  /health               -> {"ok": true}                          (sans jeton)
GET  /peers[?limit=N]      -> contenu de peers.json                  (en-tête  Authorization: Bearer <jeton>)
                              + pending_label / pending_code / pending_since pour les postes dont une fiche attend d'être relevée
                              (ou l'a été il y a moins de 30 minutes sans avoir été validée : Home Assistant, qui lit toutes les 30 s,
                              affiche ainsi la fiche à valider même quand le PC du technicien l'a déjà relevée)
GET  /records[?brief=1]    -> fiches reçues d'Internet par inbox-receive.py, en attente d'être récupérées, et validations reçues
                              du téléphone (brief=1 : sans la fiche chiffrée ni les validations, pour Home Assistant)
POST /records/validate     -> {"id":"...","received_at":"..."} : le technicien a validé cette fiche depuis son téléphone
                              (appelé par Home Assistant ; le PC du technicien applique la décision à sa prochaine synchronisation)
                              dépose aussi <suivi>.ok pour l'exe d'installation qui attend cette validation (voir inbox-receive.py)
POST /records/ack          -> {"items":[{"id":"...","received_at":"..."}], "validated":[{"id":"...","received_at":"..."}]} :
                              efface les fiches (et les validations) que le PC du technicien a bien enregistrées, seulement si
                              received_at correspond : une fiche plus récente est conservée
POST /peers/forget         -> {"id":"..."} : le technicien supprime ce client ; la demande est déposée dans /var/lib/pg20-forget, où un
                              service root (peers-forget.py) retire le poste de la base de hbbs, après en avoir fait une copie ;
                              les fiches ARCHIVÉES de ce client (voir ci-dessous) sont effacées en même temps
GET  /archive[?offset=N&limit=N] -> ARCHIVE des fiches : à chaque accusé de réception (POST /records/ack), la fiche reçue est gardée dans
                              /var/lib/pg20-archive (une copie par fiche, 10 par client au plus), TELLE QUELLE c'est-à-dire chiffrée avec la clé
                              publique du technicien : ce service ne peut pas la lire. Sert à reconstruire le carnet du technicien si son PC est
                              perdu (Pg20-Clients-Carnet.ps1 -RestoreFromServer, avec la clé privée sauvegardée). Les plus anciennes d'abord.
GET  /orders               -> ordres de désinstallation déposés et leur état (done = le poste a signalé l'exécution)
POST /orders               -> {"order": {...}, "sig": "..."} : dépose un ordre de désinstallation SIGNÉ par le technicien (un poste équipé de la tâche de
                              maintenance l'interroge toutes les 30 min auprès du receveur et en vérifie la signature)
POST /orders/ack           -> {"id":"...","nonce":"..."} : efface l'ordre (traité ou annulé) et son accusé
Tout le reste est refusé. Ce service n'a accès ni à la base de hbbs ni à la clé privée du serveur, et ne peut
pas lire les mots de passe des clients (ils sont chiffrés avec la clé publique du technicien).
"""
import datetime
import hmac
import http.server
import json
import os
import re
import socketserver
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

DATA = os.environ.get("PG20_FEED_DATA", "/var/lib/pg20-peers/peers.json")
SPOOL = os.environ.get("PG20_INBOX_SPOOL", "/var/lib/pg20-inbox")
VALIDATED = os.path.join(SPOOL, "validated")
TRACK = os.path.join(SPOOL, "track")                      # suivis créés par inbox-receive.py : <suivi>.json ; on y dépose <suivi>.ok
TRACK_FILE_RE = re.compile(r"^[0-9a-f]{32}\.json$")
BIND = os.environ.get("PG20_FEED_BIND", "127.0.0.1")
PORT = int(os.environ.get("PG20_FEED_PORT", "8099"))
RECENT_TTL = int(os.environ.get("PG20_FEED_RECENT_TTL", "1800"))    # annonce gardée après le relevé de la fiche par le PC (ou jusqu'à sa validation)
FORGET = os.environ.get("PG20_FORGET_SPOOL", "/var/lib/pg20-forget")
ARCHIVE = os.environ.get("PG20_ARCHIVE", "/var/lib/pg20-archive")      # copie des fiches (chiffrées pour le technicien) ; dossier créé par install-archive.sh
ARCHIVE_PER_ID = int(os.environ.get("PG20_ARCHIVE_PER_ID", "10"))      # fiches gardées par client (les plus récentes)
ARCHIVE_LOCK = threading.Lock()
MAX_FORGET = 20                # demandes de suppression en attente d'être exécutées
FORGET_LOCK = threading.Lock()
VALID_TTL = 14 * 86400
MAX_VALIDATIONS = 50
ID_RE = re.compile(r"^[0-9]{6,12}$")
STAMP_RE = re.compile(r"^[0-9T:.\-]{10,32}Z$")
CODE_RE = re.compile(r"^[0-9]{4}$")

RECENT = {}                    # fiches relevées il y a moins de RECENT_TTL s : id -> annonce (en mémoire seulement)
RECENT_LOCK = threading.Lock()
VALID_LOCK = threading.Lock()


def load_token():
    cred_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    path = os.path.join(cred_dir, "token") if cred_dir else "/etc/pg20/feed.token"
    with open(path, "r", encoding="utf-8") as f:
        token = f.read().strip()
    if len(token) < 32:
        sys.exit("jeton trop court")
    return token


TOKEN = load_token()


def utc_stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def public_item(rec, brief):
    """Seules les clés connues sont relayées (jamais de contenu inattendu venu du dossier d'attente)."""
    code = str(rec.get("code", ""))
    item = {"id": str(rec["id"]), "label": str(rec.get("label", ""))[:60], "code": code if CODE_RE.match(code) else "",
            "received_at": str(rec["received_at"]), "src_ip": str(rec.get("src_ip", ""))}
    if not brief:
        item["blob"] = str(rec["blob"])
    return item


def list_records(brief):
    """Fiches en attente, les plus anciennes d'abord."""
    out = []
    try:
        names = sorted(n for n in os.listdir(SPOOL) if n.endswith(".json") and not n.startswith("."))
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(SPOOL, n), "r", encoding="utf-8") as f:
                item = public_item(json.load(f), brief)
            if ID_RE.match(item["id"]):
                out.append(item)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    out.sort(key=lambda r: r["received_at"])
    return out


def remember(rec):
    item = public_item(rec, True)
    with RECENT_LOCK:
        RECENT[item["id"]] = dict(item, until=time.monotonic() + RECENT_TTL)


def forget_recent(pid, stamp):
    """La fiche est validée : on cesse de l'annoncer comme « à valider »."""
    with RECENT_LOCK:
        r = RECENT.get(pid)
        if r and r["received_at"] == stamp:
            del RECENT[pid]


def recent_items():
    now = time.monotonic()
    with RECENT_LOCK:
        for k in [k for k, v in RECENT.items() if v["until"] < now]:
            del RECENT[k]
        return dict(RECENT)


def list_validations():
    """Validations faites depuis le téléphone, pas encore appliquées par le PC. Les plus vieilles que 14 jours sont purgées."""
    out = []
    try:
        names = sorted(n for n in os.listdir(VALIDATED) if n.endswith(".json"))
    except OSError:
        return out
    for n in names:
        p = os.path.join(VALIDATED, n)
        try:
            if time.time() - os.path.getmtime(p) > VALID_TTL:
                os.unlink(p)
                continue
            with open(p, "r", encoding="utf-8") as f:
                v = json.load(f)
            if ID_RE.match(str(v["id"])) and STAMP_RE.match(str(v["received_at"])):
                out.append({"id": str(v["id"]), "received_at": str(v["received_at"]), "validated_at": str(v.get("validated_at", ""))})
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return out


def store_validation(pid, stamp):
    with VALID_LOCK:
        os.makedirs(VALIDATED, mode=0o770, exist_ok=True)
        if len(list_validations()) >= MAX_VALIDATIONS and not os.path.exists(os.path.join(VALIDATED, pid + ".json")):
            return False
        fd, tmp = tempfile.mkstemp(dir=VALIDATED, prefix=".val-")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"id": pid, "received_at": stamp, "validated_at": utc_stamp()}, f)
        os.chmod(tmp, 0o660)
        os.replace(tmp, os.path.join(VALIDATED, pid + ".json"))
    return True


def mark_followed(pid, stamp):
    """Prévient l'exe d'installation qui attend cette validation : dépose <suivi>.ok à côté de <suivi>.json (fiche de même ID et même
    heure de réception). Au mieux : un échec ici ne doit jamais empêcher la validation. Renvoie le nombre de suivis marqués."""
    marked = 0
    try:
        names = [n for n in os.listdir(TRACK) if TRACK_FILE_RE.match(n)]
    except OSError:
        return 0
    for n in names[:500]:
        try:
            with open(os.path.join(TRACK, n), "r", encoding="utf-8") as f:
                t = json.load(f)
            if t.get("id") == pid and t.get("received_at") == stamp:
                os.close(os.open(os.path.join(TRACK, n[:-5] + ".ok"), os.O_WRONLY | os.O_CREAT, 0o660))
                marked += 1
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    return marked


def archive_files(pid):
    """Noms des fiches archivées pour cet ID, de la plus ancienne à la plus récente."""
    try:
        return sorted(n for n in os.listdir(ARCHIVE) if n.startswith(pid + "_") and n.endswith(".json"))
    except OSError:
        return []


def archive_record(rec):
    """Garde une copie de la fiche (déjà chiffrée avec la clé publique du technicien) au moment où le PC l'a bien enregistrée.
    Un échec d'écriture est consigné mais ne bloque jamais l'accusé de réception."""
    try:
        item = public_item(rec, False)
        stamp = re.sub(r"[^0-9A-Za-z]", "", item["received_at"])
        with ARCHIVE_LOCK:
            os.makedirs(ARCHIVE, mode=0o700, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=ARCHIVE, prefix=".arc-")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(item, f, ensure_ascii=False)
            os.chmod(tmp, 0o600)
            os.replace(tmp, os.path.join(ARCHIVE, "%s_%s.json" % (item["id"], stamp)))
            for old in archive_files(item["id"])[:-ARCHIVE_PER_ID]:
                try:
                    os.unlink(os.path.join(ARCHIVE, old))
                except OSError:
                    pass
        return True
    except (OSError, KeyError, TypeError, ValueError) as e:
        sys.stderr.write("archive non écrite: %s\n" % e)
        return False


def list_archive(offset, limit):
    """(total, fiches) : de la plus ancienne à la plus récente, `limit` au plus à partir de `offset`."""
    try:
        names = sorted(n for n in os.listdir(ARCHIVE) if n.endswith(".json") and not n.startswith("."))
    except OSError:
        return 0, []
    out = []
    for n in names:
        try:
            with open(os.path.join(ARCHIVE, n), "r", encoding="utf-8") as f:
                item = public_item(json.load(f), False)
            if ID_RE.match(item["id"]):
                out.append(item)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    out.sort(key=lambda r: r["received_at"])
    return len(out), out[offset:offset + limit]


def erase_archive(pid):
    """Le client est supprimé : ses fiches archivées aussi (« il n'a plus jamais existé »)."""
    n = 0
    with ARCHIVE_LOCK:
        for name in archive_files(pid):
            try:
                os.unlink(os.path.join(ARCHIVE, name))
                n += 1
            except OSError:
                pass
    return n


def store_forget(pid):
    """Dépose une demande de suppression (écriture atomique). Renvoie False si trop de demandes attendent déjà."""
    with FORGET_LOCK:
        names = [n for n in os.listdir(FORGET) if not n.startswith(".")]
        if len(names) >= MAX_FORGET and (pid + ".json") not in names:
            return False
        fd, tmp = tempfile.mkstemp(dir=FORGET, prefix=".fgt-")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"id": pid, "requested_at": utc_stamp()}, f)
        os.chmod(tmp, 0o660)
        os.replace(tmp, os.path.join(FORGET, pid + ".json"))
    return True


ORDER_STAMP_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
SIG_RE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
ORDERS = os.path.join(SPOOL, "orders")      # créé par inbox-receive.py (groupe pg20-inbox) ; on y dépose <ID>.json, le receveur y écrit <ID>.done.json
MAX_ORDERS = 50
ORDER_LOCK = threading.Lock()


def valid_order_body(b):
    """Forme stricte d'un ordre signé : {"order": {v, action, id, nonce, iat, exp}, "sig": <base64>}. La signature elle-même est vérifiée par le poste."""
    if not (isinstance(b, dict) and set(b) == {"order", "sig"}):
        return False
    o, sig = b["order"], b["sig"]
    if not (isinstance(o, dict) and set(o) == {"v", "action", "id", "nonce", "iat", "exp"}):
        return False
    return bool(o["v"] == 1 and o["action"] == "uninstall"
                and isinstance(o["id"], str) and ID_RE.match(o["id"])
                and isinstance(o["nonce"], str) and NONCE_RE.match(o["nonce"])
                and isinstance(o["iat"], str) and ORDER_STAMP_RE.match(o["iat"])
                and isinstance(o["exp"], str) and ORDER_STAMP_RE.match(o["exp"])
                and isinstance(sig, str) and 100 <= len(sig) <= 1000 and SIG_RE.match(sig))


def store_order(order, sig):
    """Dépose l'ordre (écriture atomique, un seul ordre par ID : un nouveau remplace l'ancien et son accusé). Faux si trop d'ordres attendent."""
    with ORDER_LOCK:
        os.makedirs(ORDERS, mode=0o770, exist_ok=True)
        pid = order["id"]
        names = [n for n in os.listdir(ORDERS) if n.endswith(".json") and not n.endswith(".done.json") and not n.startswith(".")]
        if len(names) >= MAX_ORDERS and (pid + ".json") not in names:
            return False
        try:
            os.unlink(os.path.join(ORDERS, pid + ".done.json"))
        except OSError:
            pass
        fd, tmp = tempfile.mkstemp(dir=ORDERS, prefix=".ord-")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"order": order, "sig": sig}, f)
        os.chmod(tmp, 0o644)                  # lisible par le receveur (autre utilisateur) : l'ordre n'a rien de secret
        os.replace(tmp, os.path.join(ORDERS, pid + ".json"))
    return True


def list_orders():
    """Ordres déposés et leur état : done = le poste a signalé les avoir exécutés (accusé écrit par le receveur)."""
    out = []
    try:
        names = sorted(n for n in os.listdir(ORDERS) if n.endswith(".json") and not n.endswith(".done.json") and not n.startswith("."))
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(ORDERS, n), "r", encoding="utf-8") as f:
                o = json.load(f)["order"]
            item = {"id": str(o["id"]), "nonce": str(o["nonce"]), "iat": str(o["iat"]), "exp": str(o["exp"]), "done": False, "done_at": ""}
            if not (ID_RE.match(item["id"]) and NONCE_RE.match(item["nonce"])):
                continue
            dp = os.path.join(ORDERS, item["id"] + ".done.json")
            if os.path.exists(dp):
                with open(dp, "r", encoding="utf-8") as f:
                    dd = json.load(f)
                if dd.get("nonce") == item["nonce"]:
                    item["done"] = True
                    item["done_at"] = str(dd.get("at", ""))
            out.append(item)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return out


def ack_order(pid, nonce):
    """Le technicien a traité (ou annule) cet ordre : effacé avec son accusé, seulement si le numéro correspond. Renvoie le nombre de fichiers effacés."""
    with ORDER_LOCK:
        try:
            with open(os.path.join(ORDERS, pid + ".json"), "r", encoding="utf-8") as f:
                if json.load(f)["order"]["nonce"] != nonce:
                    return 0
        except (OSError, ValueError, KeyError, TypeError):
            return 0
        n = 0
        for name in (pid + ".json", pid + ".done.json"):
            try:
                os.unlink(os.path.join(ORDERS, name))
                n += 1
            except OSError:
                pass
        return n


def read_json_body(handler, limit=4096):
    length = int(handler.headers.get("Content-Length", ""))
    if not 0 < length <= limit:
        raise ValueError("taille")
    return json.loads(handler.rfile.read(length).decode("utf-8"))


def valid_item(it):
    pid, stamp = it["id"], it["received_at"]
    return isinstance(pid, str) and ID_RE.match(pid) and isinstance(stamp, str) and STAMP_RE.match(stamp)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "pg20-feed"
    sys_version = ""
    timeout = 10

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def _authorized(self):
        sent = self.headers.get("Authorization", "").encode("utf-8", "replace")
        return hmac.compare_digest(sent, ("Bearer " + TOKEN).encode("utf-8"))

    def do_GET(self):
        parts = urlsplit(self.path)
        path = parts.path
        if path == "/health":
            return self._send(200, b'{"ok": true}')
        if path in ("/peers", "/records", "/orders", "/archive"):
            if not self._authorized():
                return self._send(401, b'{"error": "unauthorized"}')
            query = parse_qs(parts.query)
            if path == "/archive":
                try:
                    offset = max(0, int(query.get("offset", ["0"])[0]))
                    limit = max(1, min(int(query.get("limit", ["100"])[0]), 200))
                except (ValueError, TypeError):
                    return self._send(400, b'{"error": "bad request"}')
                total, recs = list_archive(offset, limit)
                return self._json(200, {"count": total, "offset": offset, "records": recs})
            if path == "/orders":
                found = list_orders()
                return self._json(200, {"count": len(found), "orders": found})
            if path == "/records":
                brief = query.get("brief", ["0"])[0] == "1"
                recs = list_records(brief)
                body = {"count": len(recs), "records": recs}
                if not brief:
                    body["validations"] = list_validations()
                return self._json(200, body)
            try:
                with open(DATA, "rb") as f:
                    data = json.loads(f.read())
                peers = data["peers"]
            except OSError:
                return self._send(503, b'{"error": "no data yet"}')
            except (ValueError, KeyError, TypeError):
                return self._send(503, b'{"error": "bad data"}')
            limit = query.get("limit", [None])[0]
            if limit is not None:
                # ?limit=N : seulement les N postes les plus récents (Home Assistant limite la taille des attributs)
                try:
                    peers = peers[:max(1, min(int(limit), 1000))]
                except (ValueError, TypeError):
                    return self._send(400, b'{"error": "bad request"}')
            # Poste dont la fiche d'installation attend d'être relevée (ou vient de l'être) : nom, code et heure d'arrivée
            # (jamais de blob ni de mot de passe). Home Assistant lit ces champs dans le capteur existant pour notifier
            # « <nom> vient de s'installer » avec un bouton « Valider ».
            pending = recent_items()
            pending.update({r["id"]: r for r in list_records(True)})
            for p in peers:
                r = pending.get(p.get("id")) if isinstance(p, dict) else None
                if r:
                    p["pending_label"] = r["label"]
                    p["pending_code"] = r["code"]
                    p["pending_since"] = r["received_at"]
            data["peers"] = peers
            return self._json(200, data)
        return self._send(404, b'{"error": "not found"}')

    def do_POST(self):
        path = urlsplit(self.path).path
        if path not in ("/records/ack", "/records/validate", "/peers/forget", "/orders", "/orders/ack"):
            return self._send(404, b'{"error": "not found"}')
        if not self._authorized():
            return self._send(401, b'{"error": "unauthorized"}')
        try:
            body = read_json_body(self)
            if not isinstance(body, dict):
                raise ValueError("forme")
            if path == "/records/validate":
                if not valid_item(body):
                    raise ValueError("id ou date")
            elif path == "/orders":
                if not valid_order_body(body):
                    raise ValueError("ordre")
            elif path == "/orders/ack":
                if not (isinstance(body.get("id"), str) and ID_RE.match(body["id"]) and isinstance(body.get("nonce"), str) and NONCE_RE.match(body["nonce"])):
                    raise ValueError("accusé")
            elif path == "/peers/forget":
                if not (isinstance(body.get("id"), str) and ID_RE.match(body["id"])):
                    raise ValueError("id")
            else:
                if "items" not in body and "validated" not in body:
                    raise ValueError("aucune liste")
                items, validated = body.get("items", []), body.get("validated", [])
                if not (isinstance(items, list) and isinstance(validated, list) and len(items) <= 50 and len(validated) <= 50):
                    raise ValueError("listes")
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            return self._send(400, b'{"error": "bad request"}')

        if path == "/orders":
            try:
                stored = store_order(body["order"], body["sig"])
            except OSError as e:
                sys.stderr.write("ordre non déposé: %s\n" % e)
                return self._send(500, b'{"error": "write failed"}')
            if not stored:
                return self._send(503, b'{"error": "full"}')
            sys.stderr.write("ordre de désinstallation déposé: id=%s\n" % body["order"]["id"])
            return self._send(200, b'{"ok": true}')

        if path == "/orders/ack":
            n = ack_order(body["id"], body["nonce"])
            sys.stderr.write("ordre traité ou annulé: id=%s (%d fichier(s))\n" % (body["id"], n))
            return self._json(200, {"ok": True, "deleted": n})

        if path == "/peers/forget":
            try:
                queued = store_forget(body["id"])
            except OSError as e:
                sys.stderr.write("suppression non déposée: %s\n" % e)
                return self._send(500, b'{"error": "write failed"}')
            if not queued:
                return self._send(503, b'{"error": "full"}')
            erased = erase_archive(body["id"])
            sys.stderr.write("suppression demandée: id=%s (%d fiche(s) archivée(s) effacée(s))\n" % (body["id"], erased))
            return self._send(200, b'{"ok": true}')

        if path == "/records/validate":
            try:
                stored = store_validation(body["id"], body["received_at"])
            except OSError as e:
                sys.stderr.write("validation non enregistrée: %s\n" % e)
                return self._send(500, b'{"error": "write failed"}')
            if not stored:
                return self._send(503, b'{"error": "full"}')
            forget_recent(body["id"], body["received_at"])
            followed = mark_followed(body["id"], body["received_at"])
            sys.stderr.write("validation reçue: id=%s%s\n" % (body["id"], " (exe en attente prévenu)" if followed else ""))
            return self._send(200, b'{"ok": true}')

        deleted = 0
        for it in items:
            try:
                if not valid_item(it):
                    continue
                path_rec = os.path.join(SPOOL, it["id"] + ".json")
                with open(path_rec, "r", encoding="utf-8") as f:
                    rec = json.load(f)
                if rec.get("received_at") != it["received_at"]:
                    continue                # une fiche plus récente a remplacé celle-ci : on la garde
                remember(rec)               # annonce gardée RECENT_TTL s pour Home Assistant
                archive_record(rec)         # copie chiffrée gardée (reconstruction du carnet si le PC du technicien est perdu)
                os.unlink(path_rec)
                deleted += 1
            except (OSError, ValueError, KeyError, TypeError):
                continue
        cleared = 0
        for it in validated:
            try:
                if not valid_item(it):
                    continue
                p = os.path.join(VALIDATED, it["id"] + ".json")
                with VALID_LOCK:
                    with open(p, "r", encoding="utf-8") as f:
                        if json.load(f).get("received_at") != it["received_at"]:
                            continue
                    os.unlink(p)
                cleared += 1
            except (OSError, ValueError, KeyError, TypeError):
                continue
        return self._json(200, {"ok": True, "deleted": deleted, "validations_cleared": cleared})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    Server((BIND, PORT), Handler).serve_forever()
