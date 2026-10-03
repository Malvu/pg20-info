#!/usr/bin/env bash
# Retire DÉFINITIVEMENT un poste de la base du serveur RustDesk Pg20 Info (la liste des postes enregistrés).
# Usage : sudo pg20-forget-peer <ID>        (chiffres seulement, sans espaces, ex. 12345678)
# - Affiche le poste trouvé et demande de taper « oui ».
# - Fait une copie cohérente de la base AVANT toute suppression (dans data/sauvegardes-base/).
# - Redémarre hbbs quelques secondes pour qu'il oublie le poste (les autres se réenregistrent seuls).
# Si le poste est encore installé et allumé, il se réenregistrera tout seul : désinstallez RustDesk chez le client d'abord.
set -euo pipefail

ID="${1:-}"
DB="${PG20_DB:-/home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3}"
BK="${PG20_BACKUP_DIR:-/home/pg20admin/serveur-pg20-info/data/sauvegardes-base}"

[[ "$ID" =~ ^[0-9]{6,12}$ ]] || { echo "Usage : sudo $0 <ID du poste, chiffres seulement, ex. 12345678>" >&2; exit 1; }
if [ "${PG20_SKIP_ROOT_CHECK:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then echo "Lancez ce script avec sudo." >&2; exit 1; fi
[ -f "$DB" ] || { echo "Base introuvable : $DB" >&2; exit 1; }

python3 - "$DB" "$ID" <<'PY'
import sqlite3, sys
db, pid = sys.argv[1], sys.argv[2]
c = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=10)
rows = c.execute("SELECT id, created_at, info FROM peer WHERE id = ?", (pid,)).fetchall()
total = c.execute("SELECT COUNT(*) FROM peer").fetchone()[0]
if not rows:
    print("Aucun poste d'ID %s dans la base (%d poste(s) enregistré(s))." % (pid, total))
    sys.exit(2)
print("Poste trouvé :")
for r in rows:
    print("  ID %s | première vue %s UTC | %s" % r)
print("Postes enregistrés : %d  ->  %d après suppression" % (total, total - len(rows)))
PY

echo
read -r -p "Supprimer DEFINITIVEMENT ce poste ? Tapez oui pour confirmer : " ANSWER
[ "$ANSWER" = "oui" ] || { echo "Annulé : rien n'a été modifié."; exit 0; }

mkdir -p "$BK"; chmod 700 "$BK"
STAMP="$(date +%Y%m%d-%H%M%S)"
python3 - "$DB" "$BK/db_v2-$STAMP.sqlite3" "$ID" <<'PY'
import sqlite3, sys
db, backup, pid = sys.argv[1:4]
src = sqlite3.connect(db, timeout=30)
dst = sqlite3.connect(backup)
src.backup(dst)          # copie cohérente de la base, faite AVANT la suppression
dst.close()
cur = src.execute("DELETE FROM peer WHERE id = ?", (pid,))
src.commit()
src.close()
print("Sauvegarde de la base : %s" % backup)
print("Supprimé : %d ligne(s)." % cur.rowcount)
PY

if [ "${PG20_NO_RESTART:-0}" != "1" ] && command -v docker >/dev/null 2>&1; then
  echo "Redémarrage de hbbs (quelques secondes)..."
  docker restart pg20-info-hbbs >/dev/null
  echo "hbbs redémarré. La liste publiée (et le capteur Home Assistant) se mettent à jour en moins d'une minute."
fi
