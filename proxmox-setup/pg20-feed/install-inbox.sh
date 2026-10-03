#!/usr/bin/env bash
# Installe (ou met à jour) la réception des fiches d'installation sur la VM pg20-info : à lancer avec sudo, depuis ce dossier.
# Ne touche PAS au pare-feu (voir proxmox-setup/pg20-firewall.nft, appliqué à part avec retour arrière automatique).
set -euo pipefail
cd "$(dirname "$0")"
if grep -q '<[A-Z_]*>' pg20-peers-feed.service; then
  echo "Renseignez <IP_VM>, <RESEAU_LOCAL> et <RESEAU_WIREGUARD> dans pg20-peers-feed.service avant l'installation."; exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script avec sudo."; exit 1; }
command -v python3 >/dev/null || { echo "python3 est requis."; exit 1; }
command -v openssl >/dev/null || { echo "openssl est requis."; exit 1; }
[ -s /etc/pg20/feed.token ] || { echo "Le service « liste des postes » doit être installé d'abord (install-feed.sh)."; exit 1; }

# Utilisateur dédié, sans shell ni dossier personnel
getent group pg20-inbox >/dev/null || groupadd --system pg20-inbox
id pg20-inbox >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid pg20-inbox pg20-inbox

install -d -m 0755 /usr/local/lib/pg20 /var/lib/pg20-peers
install -d -m 0770 -o pg20-inbox -g pg20-inbox /var/lib/pg20-inbox
install -m 0755 peers-export.py peers-feed.py inbox-receive.py /usr/local/lib/pg20/

# Certificat TLS auto-signé (valable 10 ans). L'exe d'installation ne fait confiance qu'à CE certificat (empreinte figée dans l'exe).
if [ ! -s /etc/pg20/inbox.crt ] || [ ! -s /etc/pg20/inbox.key ]; then
  umask 077
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -subj "/CN=pg20-info" \
    -keyout /etc/pg20/inbox.key -out /etc/pg20/inbox.crt 2>/dev/null
  echo "certificat TLS généré : /etc/pg20/inbox.crt"
fi
chmod 600 /etc/pg20/inbox.key; chmod 644 /etc/pg20/inbox.crt

install -m 0644 pg20-peers-export.service pg20-peers-export.timer pg20-peers-feed.service pg20-inbox.service /etc/systemd/system/
systemctl daemon-reload

# Un premier export crée registrations.json, dont le service de réception a besoin
systemctl start pg20-peers-export.service
systemctl restart pg20-peers-feed.service
systemctl enable pg20-inbox.service >/dev/null 2>&1
systemctl restart pg20-inbox.service
sleep 2

echo "--- état ---"
systemctl is-active pg20-peers-export.timer pg20-peers-feed.service pg20-inbox.service
ls -l /var/lib/pg20-peers/registrations.json
ss -lnt '( sport = :21120 or sport = :8099 )' | tail -n +2
echo "--- empreinte SHA-256 du certificat (à figer dans l'exe : -InboxPin) ---"
openssl x509 -in /etc/pg20/inbox.crt -outform DER | sha256sum | cut -d' ' -f1
