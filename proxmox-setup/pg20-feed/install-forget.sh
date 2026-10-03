#!/usr/bin/env bash
# Installe la suppression de postes depuis Pg20-Clients sur la VM pg20-info (à lancer avec sudo, depuis ce dossier).
# Prérequis : install-feed.sh et install-inbox.sh déjà passés (groupe pg20-inbox, jeton du flux).
set -euo pipefail
cd "$(dirname "$0")"
if grep -q '<[A-Z_]*>' pg20-peers-feed.service; then
  echo "Renseignez <IP_VM>, <RESEAU_LOCAL> et <RESEAU_WIREGUARD> dans pg20-peers-feed.service avant l'installation."; exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script avec sudo."; exit 1; }
getent group pg20-inbox >/dev/null || { echo "Le groupe pg20-inbox est absent : lancez d'abord install-inbox.sh."; exit 1; }
[ -f /home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3 ] || { echo "Base hbbs introuvable."; exit 1; }

# Dossier des demandes : le flux (groupe pg20-inbox) y dépose, root les exécute
install -d -m 2770 -o root -g pg20-inbox /var/lib/pg20-forget
install -m 0755 peers-feed.py peers-forget.py /usr/local/lib/pg20/
install -m 0644 pg20-peers-feed.service pg20-forget.service pg20-forget.path /etc/systemd/system/
systemctl daemon-reload
systemctl restart pg20-peers-feed.service
systemctl enable --now pg20-forget.path

sleep 1
echo "--- état ---"
systemctl is-active pg20-peers-feed.service pg20-forget.path
ls -ld /var/lib/pg20-forget
