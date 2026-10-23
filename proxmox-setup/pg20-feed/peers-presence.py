#!/usr/bin/python3
"""Note, pour chaque poste connu, la dernière fois où hbbs l'a vu EN LIGNE (« a été connecté le ... »).

Exécuté toutes les 15 s (pg20-peers-presence.timer). hbbs ne garde pas cette information : il sait seulement, sur demande,
quels postes sont inscrits depuis moins de 30 s. On lui pose donc la même question que l'application RustDesk et la fenêtre
« Se connecter » (message OnlineRequest, TCP 21115), et on retient l'instant de chaque réponse « en ligne ».

Écrit presence.json (lu par peers-feed.py : GET /presence) :
  {"generated_at": "...", "checked_at": "...", "ok": true, "since": "...",
   "presence": {"<id>": {"online": true|false|null, "last_online": "2026-10-22T17:12:03Z" ou ""}}}
  - since       : premier passage de ce script ; avant cette date, on ne sait rien (last_online vide = jamais vu en ligne DEPUIS since) ;
  - ok = false  : hbbs n'a pas répondu comme prévu ; on garde les dates déjà notées et online vaut null (inconnu), rien n'est inventé ;
  - un poste disparu de peers.json (supprimé du serveur) disparaît aussi de presence.json.

Indépendant de peers-export.py : peers.json et registrations.json ne sont ni lus en écriture ni retardés (inbox-receive.py refuse les fiches
quand registrations.json a plus de 180 s). Ce script ne modifie pas peers.json : Home Assistant lit peers.json, et y mettre une date qui change
toutes les 15 s relancerait son automatisation à chaque passage. Seuls des identifiants et des dates sont écrits : aucun secret.
"""
import datetime
import json
import os
import socket
import sys
import tempfile
import time

DIR = os.environ.get("PG20_PRESENCE_DIR", "/var/lib/pg20-peers")
PEERS = os.path.join(DIR, "peers.json")
OUT = os.path.join(DIR, "presence.json")
HOST = os.environ.get("PG20_HBBS_HOST", "<IP_VM>")      # adresse du serveur, pas 127.0.0.1 : hbbs ne répond pas aux connexions de la machine elle-même
PORT = int(os.environ.get("PG20_HBBS_PORT", "21115"))
TIMEOUT = float(os.environ.get("PG20_HBBS_TIMEOUT", "2"))    # secondes, par étape (connexion, lecture) ; la durée totale reste inférieure à 3 × TIMEOUT
LIMIT = 200                                                  # une seule question : les 200 postes les plus récents


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def build_request(ids):
    """OnlineRequest.peers (champ 2, répété) dans RendezvousMessage.online_request (champ 23), précédé de l'en-tête de longueur de hbbs."""
    inner = b"".join(b"\x12" + varint(len(i.encode())) + i.encode() for i in ids)
    msg = b"\xba\x01" + varint(len(inner)) + inner
    n = len(msg)
    if n <= 0x3F:
        head = bytes([n << 2])
    elif n <= 0x3FFF:
        head = ((n << 2) | 1).to_bytes(2, "little")
    elif n <= 0x3FFFFF:
        head = ((n << 2) | 2).to_bytes(3, "little")
    else:
        raise ValueError("trop de postes")
    return head + msg


def read_varint(b, pos):
    v, shift = 0, 0
    while True:
        if pos >= len(b):
            raise ValueError("réponse tronquée")
        x = b[pos]
        pos += 1
        v |= (x & 0x7F) << shift
        if not x & 0x80:
            return v, pos
        shift += 7
        if shift > 35:
            raise ValueError("nombre trop long")


def find_field(b, wanted):
    """Contenu du premier champ « longueur » de numéro wanted d'un message protobuf, ou None."""
    pos = 0
    while pos < len(b):
        tag, pos = read_varint(b, pos)
        no, wt = tag >> 3, tag & 7
        if wt == 0:
            _, pos = read_varint(b, pos)
        elif wt == 1:
            pos += 8
        elif wt == 5:
            pos += 4
        elif wt == 2:
            ln, pos = read_varint(b, pos)
            if pos + ln > len(b):
                raise ValueError("champ tronqué")
            if no == wanted:
                return b[pos:pos + ln]
            pos += ln
        else:
            raise ValueError("type de champ inconnu")
    return None


def read_exact(sock, count, deadline):
    buf = b""
    while len(buf) < count:
        if time.monotonic() > deadline:
            raise TimeoutError("trop long")
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise ConnectionError("connexion fermée")
        buf += chunk
    return buf


def parse_states(frame_payload, count):
    """Liste de booléens (un par poste, dans l'ordre de la question) ; None si la réponse n'est pas celle attendue."""
    outer = find_field(frame_payload, 24)                # RendezvousMessage.online_response
    if outer is None:
        return None
    states = find_field(outer, 1)                        # OnlineResponse.states : un bit par poste, bit de poids fort d'abord
    if states is None or len(states) == 0:
        return [False] * count                           # aucun bit posé : personne n'est en ligne
    if len(states) < (count + 7) // 8:
        return None
    return [bool(states[i // 8] & (0x80 >> (i % 8))) for i in range(count)]


def query_hbbs(ids, host=None, port=None, timeout=None):
    """Liste de booléens, ou None si hbbs ne répond pas comme prévu (jamais d'exception)."""
    host, port, timeout = host or HOST, port or PORT, timeout or TIMEOUT
    if not ids:
        return []
    try:
        request = build_request(ids)
        deadline = time.monotonic() + 3 * timeout
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(request)
            b0 = read_exact(s, 1, deadline)[0]
            head = (b0 & 3) + 1
            val = b0
            if head > 1:
                rest = read_exact(s, head - 1, deadline)
                for k, x in enumerate(rest):
                    val |= x << (8 * (k + 1))
            length = val >> 2
            if length < 1 or length > 4096:
                return None
            payload = read_exact(s, length, deadline)
        return parse_states(payload, len(ids))
    except (OSError, ValueError, TimeoutError):
        return None


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def write_json(path, payload):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".presence-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def compute(ids, previous, states, now):
    """Nouveau contenu de presence.json à partir de l'ancien, de la liste actuelle des postes et de la réponse de hbbs (None = pas de réponse)."""
    prev = (previous or {}).get("presence") if isinstance((previous or {}).get("presence"), dict) else {}
    since = (previous or {}).get("since") or iso(now)
    stamp = iso(now)
    presence = {}
    for k, pid in enumerate(ids):
        last = ""
        old = prev.get(pid)
        if isinstance(old, dict) and isinstance(old.get("last_online"), str):
            last = old["last_online"]
        if states is None:
            presence[pid] = {"online": None, "last_online": last}
        else:
            if states[k]:
                last = stamp
            presence[pid] = {"online": bool(states[k]), "last_online": last}
    return {"generated_at": stamp, "checked_at": stamp, "ok": states is not None, "since": since, "presence": presence}


def main():
    data = load_json(PEERS)
    if not data or not isinstance(data.get("peers"), list):
        print("peers.json absent ou illisible : rien à faire", file=sys.stderr)
        return 1
    ids = []
    for p in data["peers"][:LIMIT]:
        pid = str(p.get("id", "")) if isinstance(p, dict) else ""
        if pid.isdigit() and 6 <= len(pid) <= 12 and pid not in ids:
            ids.append(pid)
    states = query_hbbs(ids)
    write_json(OUT, compute(ids, load_json(OUT), states, datetime.datetime.now(datetime.timezone.utc)))
    if states is None:
        print("hbbs n'a pas répondu comme prévu (%s:%d) : dates conservées, état inconnu" % (HOST, PORT), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
