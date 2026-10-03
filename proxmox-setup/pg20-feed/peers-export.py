#!/usr/bin/python3
"""Exporte la liste des postes enregistrés par hbbs vers des fichiers JSON (lecture seule).

Exécuté par root toutes les 15 s (pg20-peers-export.timer). Seuls ces fichiers JSON sont
ensuite lus par des services sans privilèges :
  - peers.json          servi sur le réseau local par peers-feed.py (liste des postes, les 200 plus récents)
  - registrations.json  lu par inbox-receive.py : pour chaque poste, adresse vue et date de sa dernière (ré)inscription,
                        qui sert à vérifier qu'une fiche reçue d'Internet vient bien d'un poste qui vient de s'installer.
La date de dernière inscription n'existe pas dans la base de hbbs : elle est déduite ici, en gardant une empreinte
(uuid, clé, adresse) de chaque poste et en notant l'instant où elle change (état dans .state.json, lisible par root seul).
"""
import datetime
import hashlib
import json
import os
import sqlite3
import tempfile

DB = "/home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3"
OUT_DIR = os.environ.get("PG20_EXPORT_DIR", "/var/lib/pg20-peers")
OUT = os.path.join(OUT_DIR, "peers.json")
REG = os.path.join(OUT_DIR, "registrations.json")
STATE = os.path.join(OUT_DIR, ".state.json")
LIMIT = 200
REG_LIMIT = 5000


def clean_ip(raw):
    ip = raw or ""
    if ip.startswith("::ffff:"):
        ip = ip[len("::ffff:"):]
    return ip


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def write_json(path, payload, mode=0o644):
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=".peers-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def load_state():
    try:
        with open(STATE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def main():
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=5)
    try:
        total = con.execute("SELECT COUNT(*) FROM peer").fetchone()[0]
        rows = con.execute(
            "SELECT id, created_at, info, uuid, pk FROM peer ORDER BY created_at DESC, id LIMIT ?", (REG_LIMIT,)
        ).fetchall()
    finally:
        con.close()

    now = datetime.datetime.now(datetime.timezone.utc)
    old_state = load_state()
    first_run = old_state is None          # premier passage : on ne sait rien, aucun poste n'est considéré comme récent
    old_state = old_state or {}

    state, regs, peers = {}, [], []
    for pid, created, info, uuid, pk in rows:
        pid = str(pid)
        try:
            ip = clean_ip(json.loads(info or "{}").get("ip"))
        except (ValueError, AttributeError):
            ip = ""
        first_seen = (created or "").replace(" ", "T")
        first_seen = first_seen + "Z" if first_seen else ""

        h = hashlib.sha256()
        for part in (pid.encode(), bytes(uuid or b""), bytes(pk or b""), (info or "").encode()):
            h.update(part + b"\x00")
        fp = h.hexdigest()
        prev = old_state.get(pid)
        if prev and prev.get("fp") == fp:
            changed = prev.get("changed_at") or first_seen
        elif first_run:
            changed = first_seen or iso(now)
        else:
            changed = iso(now)             # poste nouveau ou ré-inscrit depuis le dernier passage
        state[pid] = {"fp": fp, "changed_at": changed}
        regs.append({"id": pid, "ip": ip, "updated_at": changed})
        if len(peers) < LIMIT:
            peers.append({"id": pid, "first_seen": first_seen, "ip": ip})

    generated = iso(now)
    write_json(OUT, {"generated_at": generated, "count": total, "peers": peers})
    write_json(REG, {"generated_at": generated, "peers": regs})
    write_json(STATE, state, 0o600)


if __name__ == "__main__":
    main()
