#!/usr/bin/python3
"""Retire de la base de hbbs (liste des postes du serveur) les postes dont le technicien a demandé la suppression.

Lancé en root par systemd (pg20-forget.path -> pg20-forget.service) dès qu'un fichier apparaît dans /var/lib/pg20-forget.
Ces fichiers sont déposés par le flux (peers-feed.py, POST /peers/forget, jeton obligatoire, réseau local / WireGuard) après un clic
du technicien dans Pg20-Clients. Ce programme ne FAIT CONFIANCE À RIEN dans ces fichiers :
  - il ne lit que de petits fichiers ordinaires (pas de lien symbolique, 1 Ko maximum) ;
  - il n'accepte qu'un ID numérique de 6 à 12 chiffres ;
  - il traite 10 postes au plus par passage ;
  - il copie la base AVANT toute suppression (data/sauvegardes-base/) ;
  - il redémarre hbbs UNE fois, seulement si au moins une ligne a été supprimée (hbbs garde les postes en mémoire).
Tout fichier lu est effacé, même invalide, pour que le déclencheur ne boucle pas. Un poste encore installé et allumé se réenregistre
tout seul : il réapparaît alors dans Pg20-Clients comme « A valider ».
"""
import datetime
import json
import os
import re
import sqlite3
import stat
import subprocess
import sys
import time

SPOOL = os.environ.get("PG20_FORGET_SPOOL", "/var/lib/pg20-forget")
DB = os.environ.get("PG20_DB", "/home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3")
BACKUP_DIR = os.environ.get("PG20_BACKUP_DIR", "/home/pg20admin/serveur-pg20-info/data/sauvegardes-base")
CONTAINER = os.environ.get("PG20_HBBS_CONTAINER", "pg20-info-hbbs")
NO_RESTART = os.environ.get("PG20_NO_RESTART", "0") == "1"
MAX_IDS = 10
ID_RE = re.compile(r"^[0-9]{6,12}$")


def log(msg):
    sys.stdout.write("%s\n" % msg)
    sys.stdout.flush()


def read_request(path):
    """Renvoie l'ID demandé, ou None si le fichier est invalide (le fichier sera effacé quand même)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > 1024:
            return None
        data = json.loads(os.read(fd, 1024).decode("utf-8"))
        pid = data.get("id") if isinstance(data, dict) else None
        return pid if isinstance(pid, str) and ID_RE.match(pid) else None
    except (ValueError, UnicodeDecodeError, OSError):
        return None
    finally:
        os.close(fd)


def main():
    try:
        entries = sorted(os.listdir(SPOOL))
    except OSError as e:
        log("dossier d'attente illisible: %s" % e)
        return 1

    ids, to_remove, young_tmp = [], [], False
    for name in entries:
        path = os.path.join(SPOOL, name)
        if name.startswith("."):                       # fichier temporaire du flux : on laisse finir son écriture, sauf s'il est resté là
            try:
                if time.time() - os.lstat(path).st_mtime > 60:
                    to_remove.append(path)
                else:
                    young_tmp = True
            except OSError:
                pass
            continue
        if len(ids) >= MAX_IDS:
            break                                      # le reste sera traité au passage suivant
        pid = read_request(path)
        to_remove.append(path)
        if pid is None:
            log("demande invalide ignorée: %r" % name[:40])
        elif pid not in ids:
            ids.append(pid)

    deleted_total, error = 0, None
    if ids:
        try:
            os.makedirs(BACKUP_DIR, mode=0o700, exist_ok=True)
            backup = os.path.join(BACKUP_DIR, "db_v2-%s.sqlite3" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
            src = sqlite3.connect(DB, timeout=30)
            dst = sqlite3.connect(backup)
            src.backup(dst)                            # copie cohérente de la base, faite AVANT la suppression
            dst.close()
            for pid in ids:
                n = src.execute("DELETE FROM peer WHERE id = ?", (pid,)).rowcount
                deleted_total += n
                log("retiré: id=%s (%d ligne(s))%s" % (pid, n, "" if n else " : inconnu du serveur, rien à faire"))
            src.commit()
            src.close()
            log("copie de la base: %s" % backup)
        except (sqlite3.Error, OSError) as e:
            error = e
            log("ERREUR base: %s" % e)

    for path in to_remove:                             # toujours effacer ce qui a été lu, même en cas d'erreur : pas de boucle
        try:
            os.unlink(path)
        except OSError as e:
            log("fichier non effacé (%s): %s" % (os.path.basename(path)[:40], e))

    if deleted_total and not NO_RESTART:
        try:
            r = subprocess.run(["docker", "restart", CONTAINER], timeout=90, capture_output=True, text=True)
            log("hbbs redémarré (code %d)" % r.returncode)
        except (OSError, subprocess.SubprocessError) as e:
            log("redémarrage de hbbs impossible: %s" % e)

    if young_tmp:
        time.sleep(2)                                  # évite que le déclencheur ne relance aussitôt ce programme en boucle
    return 1 if error else 0


if __name__ == "__main__":
    sys.exit(main())
