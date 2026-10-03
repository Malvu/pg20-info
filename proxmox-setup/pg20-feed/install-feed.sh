#!/usr/bin/env bash
# Installe le service "liste des postes" sur la VM pg20-info (à lancer avec sudo, depuis ce dossier).
set -euo pipefail
cd "$(dirname "$0")"
if grep -q '<[A-Z_]*>' pg20-peers-feed.service; then
  echo "Renseignez <IP_VM>, <RESEAU_LOCAL> et <RESEAU_WIREGUARD> dans pg20-peers-feed.service avant l'installation."; exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script avec sudo."; exit 1; }
command -v python3 >/dev/null || { echo "python3 est requis."; exit 1; }
[ -f /home/pg20admin/serveur-pg20-info/data/db_v2.sqlite3 ] || { echo "Base hbbs introuvable."; exit 1; }

install -d -m 0755 /usr/local/lib/pg20 /var/lib/pg20-peers
install -d -m 0700 /etc/pg20
install -m 0755 peers-export.py peers-feed.py /usr/local/lib/pg20/

if [ ! -s /etc/pg20/feed.token ]; then
  umask 077
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /etc/pg20/feed.token
  echo "jeton généré (non affiché) : /etc/pg20/feed.token"
fi
chmod 600 /etc/pg20/feed.token

install -m 0644 pg20-peers-export.service pg20-peers-export.timer pg20-peers-feed.service /etc/systemd/system/
systemctl daemon-reload

# Premier export immédiat, puis activation
systemctl start pg20-peers-export.service
systemctl enable --now pg20-peers-export.timer
systemctl enable pg20-peers-feed.service
systemctl restart pg20-peers-feed.service
sleep 2

echo "--- état ---"
systemctl is-active pg20-peers-export.timer pg20-peers-feed.service
ls -l /var/lib/pg20-peers/peers.json
ss -lnt '( sport = :8099 )' | tail -n +2
