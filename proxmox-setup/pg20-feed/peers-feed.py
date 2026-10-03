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
POST /records/ack          -> {"items":[{"id":"...","received_at":"..."}], "validated":[{"id":"...","received_at":"..."}]} :
                              efface les fiches (et les validations) que le PC du technicien a bien enregistrées, seulement si
                              received_at correspond : une fiche plus récente est conservée
POST /peers/forget         -> {"id":"..."} : le technicien supprime ce client ; la demande est déposée dans /var/lib/pg20-forget, où un
                              service root (peers-forget.py) retire le poste de la base de hbbs, après en avoir fait une copie
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
BIND = os.environ.get("PG20_FEED_BIND", "127.0.0.1")
PORT = int(os.environ.get("PG20_FEED_PORT", "8099"))
RECENT_TTL = int(os.environ.get("PG20_FEED_RECENT_TTL", "1800"))    # annonce gardée après le relevé de la fiche par le PC (ou jusqu'à sa validation)
FORGET = os.environ.get("PG20_FORGET_SPOOL", "/var/lib/pg20-forget")
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
        if path in ("/peers", "/records"):
            if not self._authorized():
                return self._send(401, b'{"error": "unauthorized"}')
            query = parse_qs(parts.query)
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
        if path not in ("/records/ack", "/records/validate", "/peers/forget"):
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

        if path == "/peers/forget":
            try:
                queued = store_forget(body["id"])
            except OSError as e:
                sys.stderr.write("suppression non déposée: %s\n" % e)
                return self._send(500, b'{"error": "write failed"}')
            if not queued:
                return self._send(503, b'{"error": "full"}')
            sys.stderr.write("suppression demandée: id=%s\n" % body["id"])
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
            sys.stderr.write("validation reçue: id=%s\n" % body["id"])
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
