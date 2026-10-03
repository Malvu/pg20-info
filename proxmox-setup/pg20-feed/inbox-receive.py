#!/usr/bin/python3
"""Reçoit les fiches d'installation envoyées par l'exe Pg20 Info (service exposé à Internet : TCP 21120, TLS).

POST /v1/record   {"v":1, "id":"<ID RustDesk>", "label":"<nom affiché>", "blob":"<fiche chiffrée, base64>"}
GET  /v1/ping     {"ok": true}

Une fiche n'est acceptée que si :
  - le poste (ID) est enregistré sur le serveur RustDesk, avec la MÊME adresse publique que la requête,
    et son enregistrement date de moins de 30 minutes (voir registrations.json, produit par peers-export.py) ;
  - le format est strict et la taille limitée ; le nombre de requêtes par adresse est limité.
La réponse 200 contient le code de contrôle à 4 chiffres, tiré ici : {"ok": true, "code": "4827"}.
Le mot de passe du client est dans "blob", chiffré avec la clé publique du technicien : ce service ne peut pas le lire.
Il ne fait que déposer la fiche dans le dossier d'attente ; le technicien la récupère par le flux (peers-feed.py),
qui l'efface ensuite. Ce service n'a accès ni à la base de hbbs ni à la clé privée du serveur.
"""
import base64
import binascii
import collections
import datetime
import http.server
import json
import os
import re
import secrets
import socketserver
import ssl
import sys
import tempfile
import threading
import time

BIND = os.environ.get("PG20_INBOX_BIND", "0.0.0.0")
PORT = int(os.environ.get("PG20_INBOX_PORT", "21120"))
SPOOL = os.environ.get("PG20_INBOX_SPOOL", "/var/lib/pg20-inbox")
REG_FILE = os.environ.get("PG20_INBOX_REG", "/var/lib/pg20-peers/registrations.json")
WINDOW = int(os.environ.get("PG20_INBOX_WINDOW", "1800"))        # un poste doit s'être enregistré depuis moins de 30 min
TTL = int(os.environ.get("PG20_INBOX_TTL", str(14 * 86400)))     # une fiche jamais récupérée est effacée après 14 jours
MAX_PENDING = int(os.environ.get("PG20_INBOX_MAX_PENDING", "50"))
MAX_BODY = 4096
MAX_CONNECTIONS = 16

ID_RE = re.compile(r"^[0-9]{6,12}$")
B64_RE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
KEYS_OK = {"v", "id", "label", "blob"}


def log(msg):
    sys.stderr.write("%s\n" % msg)
    sys.stderr.flush()


def clean_text(value, limit):
    """Texte affichable seulement : lettres (accents compris), chiffres, espace et ponctuation courante."""
    value = re.sub(r"[^\w .,'&()+/@:-]", "", str(value), flags=re.UNICODE)
    return re.sub(r"\s+", " ", value).strip()[:limit]


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def parse_utc(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


class Limiter:
    """Limite le nombre de requêtes : par adresse et au total (les tentatives refusées comptent aussi)."""

    def __init__(self, per_ip, per_ip_window, total, total_window):
        self.per_ip, self.per_ip_window = per_ip, per_ip_window
        self.total, self.total_window = total, total_window
        self.hits = collections.defaultdict(collections.deque)
        self.all_hits = collections.deque()
        self.lock = threading.Lock()

    def allow(self, ip):
        now = time.monotonic()
        with self.lock:
            while self.all_hits and now - self.all_hits[0] > self.total_window:
                self.all_hits.popleft()
            q = self.hits[ip]
            while q and now - q[0] > self.per_ip_window:
                q.popleft()
            if len(self.hits) > 5000:
                for k in [k for k, v in self.hits.items() if not v or now - v[-1] > self.per_ip_window]:
                    del self.hits[k]
            if len(q) >= self.per_ip or len(self.all_hits) >= self.total:
                return False
            q.append(now)
            self.all_hits.append(now)
            return True


LIMITER = Limiter(per_ip=int(os.environ.get("PG20_INBOX_RATE_IP", "12")), per_ip_window=600,
                  total=int(os.environ.get("PG20_INBOX_RATE_TOTAL", "100")), total_window=3600)
SLOTS = threading.BoundedSemaphore(MAX_CONNECTIONS)
SPOOL_LOCK = threading.Lock()


def registration_state(pid, ip):
    """'ok' | 'unknown' (poste non reconnu : réessayer plus tard) | 'unavailable' (liste des postes périmée)."""
    try:
        with open(REG_FILE, "rb") as f:
            data = json.loads(f.read(2_000_000))
        if (utc_now() - parse_utc(data["generated_at"])).total_seconds() > 180:
            return "unavailable"
        for p in data["peers"]:
            if p.get("id") == pid:
                age = (utc_now() - parse_utc(p["updated_at"])).total_seconds()
                if p.get("ip") == ip and -60 <= age <= WINDOW:
                    return "ok"
                return "unknown"
        return "unknown"
    except (OSError, ValueError, KeyError, TypeError):
        return "unavailable"


def store_record(pid, label, blob, ip, code):
    """Dépose la fiche (écriture atomique, une seule fiche en attente par ID). Renvoie False si le dossier est plein."""
    path = os.path.join(SPOOL, pid + ".json")
    with SPOOL_LOCK:
        pending = [n for n in os.listdir(SPOOL) if n.endswith(".json")]
        if len(pending) >= MAX_PENDING and (pid + ".json") not in pending:
            return False
        rec = {"id": pid, "label": label, "blob": blob, "src_ip": ip, "code": code,
               "received_at": utc_now().strftime("%Y-%m-%dT%H:%M:%S.%fZ")}
        fd, tmp = tempfile.mkstemp(dir=SPOOL, prefix=".rec-")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False)
        os.chmod(tmp, 0o660)
        os.replace(tmp, path)
    return True


def purge_loop():
    while True:
        try:
            now = time.time()
            for n in os.listdir(SPOOL):
                p = os.path.join(SPOOL, n)
                limit = 3600 if n.startswith(".rec-") else TTL
                if os.path.isfile(p) and now - os.path.getmtime(p) > limit:
                    os.unlink(p)
                    log("purge: %s (plus de %d s)" % (n, limit))
        except OSError as e:
            log("purge: %s" % e)
        time.sleep(600)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "pg20-inbox"
    sys_version = ""
    protocol_version = "HTTP/1.0"      # une requête par connexion
    timeout = 8

    def log_message(self, fmt, *args):
        pass                            # journal volontairement sobre : rien de ce que l'appelant envoie n'est recopié

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        try:
            self._send(code, {"ok": False})
        except OSError:
            pass

    def do_GET(self):
        ip = self.client_address[0]
        if self.path == "/v1/ping" and LIMITER.allow(ip):
            return self._send(200, {"ok": True})
        return self._send(404 if self.path != "/v1/ping" else 429, {"ok": False})

    def do_POST(self):
        ip = self.client_address[0]
        if self.path != "/v1/record":
            return self._send(404, {"ok": False})
        if not LIMITER.allow(ip):
            log("refus: trop de requêtes depuis %s" % ip)
            return self._send(429, {"ok": False, "error": "rate"})
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._send(411, {"ok": False})
        if length <= 0 or length > MAX_BODY:
            return self._send(413, {"ok": False})
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError, OSError):
            return self._send(400, {"ok": False})

        if not (isinstance(data, dict) and set(data) <= KEYS_OK and {"v", "id", "blob"} <= set(data)):
            return self._send(400, {"ok": False})
        pid, blob = data["id"], data["blob"]
        if data["v"] != 1 or not isinstance(pid, str) or not ID_RE.match(pid):
            return self._send(400, {"ok": False})
        if not (isinstance(blob, str) and 100 <= len(blob) <= 3000 and B64_RE.match(blob)):
            return self._send(400, {"ok": False})
        try:
            base64.b64decode(blob, validate=True)
        except (binascii.Error, ValueError):
            return self._send(400, {"ok": False})
        label = clean_text(data.get("label", ""), 60) or "(sans nom)"

        state = registration_state(pid, ip)
        if state == "unavailable":
            log("refus: liste des postes indisponible")
            return self._send(503, {"ok": False, "error": "unavailable"})
        if state != "ok":
            # réponse volontairement uniforme : elle ne dit pas si l'ID existe
            return self._send(409, {"ok": False, "error": "retry"})
        # Code de contrôle choisi ICI (pas par l'exe) : l'exe l'affiche chez le client, le technicien le retrouve sur son
        # téléphone. Une fausse fiche reçoit un autre code, qui ne s'affiche sur l'écran d'aucun vrai client.
        code = "%04d" % secrets.randbelow(10000)
        try:
            stored = store_record(pid, label, blob, ip, code)
        except OSError as e:
            log("erreur d'écriture: %s" % e)
            return self._send(500, {"ok": False})
        if not stored:
            log("refus: dossier d'attente plein")
            return self._send(503, {"ok": False, "error": "full"})
        log("fiche acceptée: id=%s depuis %s" % (pid, ip))
        return self._send(200, {"ok": True, "code": code})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def process_request(self, request, client_address):
        if not SLOTS.acquire(blocking=False):      # trop de connexions simultanées : on coupe sans répondre
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            try:
                request.settimeout(8)
                tls = CONTEXT.wrap_socket(request, server_side=True)    # la poignée de main TLS se fait ICI, dans le thread, avec délai
            except (ssl.SSLError, OSError):
                self.shutdown_request(request)
                return
            super().process_request_thread(tls, client_address)
        finally:
            SLOTS.release()


def make_context():
    cred = os.environ.get("CREDENTIALS_DIRECTORY")
    cert = os.path.join(cred, "cert") if cred else "/etc/pg20/inbox.crt"
    key = os.path.join(cred, "key") if cred else "/etc/pg20/inbox.key"
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert, key)
    return ctx


CONTEXT = make_context()

if __name__ == "__main__":
    os.makedirs(SPOOL, mode=0o770, exist_ok=True)
    threading.Thread(target=purge_loop, daemon=True).start()
    log("pg20-inbox : écoute sur %s:%d (TLS)" % (BIND, PORT))
    Server((BIND, PORT), Handler).serve_forever()
