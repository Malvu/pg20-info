#!/usr/bin/env bash
# Installe l'ARCHIVE des fiches sur la VM pg20-info (à lancer avec sudo, depuis ce dossier).
# Prérequis : install-feed.sh, install-inbox.sh et install-forget.sh déjà passés.
# Chaque fiche accusée par le PC du technicien est copiée dans /var/lib/pg20-archive TELLE QUELLE (chiffrée avec la clé publique du technicien : le serveur
# ne peut pas la lire). Elle sert à reconstruire le carnet si le PC du technicien est perdu ; elle est effacée avec le client (« Supprimer »).
# Retour arrière : voir la commande donnée à la fin (ancien peers-feed.py et ancien service sauvegardés).
set -euo pipefail
cd "$(dirname "$0")"
if grep -q '<[A-Z_]*>' pg20-peers-feed.service; then
  echo "Renseignez <IP_VM>, <RESEAU_LOCAL> et <RESEAU_WIREGUARD> dans pg20-peers-feed.service avant l'installation."; exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script avec sudo."; exit 1; }
[ -f /usr/local/lib/pg20/peers-feed.py ] || { echo "Le flux n'est pas installé : lancez d'abord install-feed.sh."; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BK="/root/pg20-avant-archive-$STAMP"
install -d -m 0700 "$BK"
cp -a /usr/local/lib/pg20/peers-feed.py /etc/systemd/system/pg20-peers-feed.service "$BK/"

# Le flux tourne sous « nobody » : lui seul lit et écrit l'archive (0700) ; les fichiers y sont en 0600
install -d -m 0700 -o nobody -g nogroup /var/lib/pg20-archive
install -m 0755 peers-feed.py /usr/local/lib/pg20/
install -m 0644 pg20-peers-feed.service /etc/systemd/system/
systemctl daemon-reload
systemctl restart pg20-peers-feed.service

sleep 2
echo "--- état ---"
systemctl is-active pg20-peers-feed.service
ls -ld /var/lib/pg20-archive
echo "Sauvegarde de l'ancienne version : $BK"
echo "Retour arrière : sudo cp -a $BK/peers-feed.py /usr/local/lib/pg20/ && sudo cp -a $BK/pg20-peers-feed.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl restart pg20-peers-feed.service"
