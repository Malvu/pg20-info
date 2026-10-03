#!/usr/bin/env bash
# Crée le stockage Proxmox "pg20-info" sur un disque dédié, repéré par son modèle et son numéro de série (voir : ls -l /dev/disk/by-id/).
# Équivalent de : interface web > Nœud > Disques > Directory > Créer.
set -euo pipefail

STORAGE=pg20-info
DEV="<PERIPHERIQUE>"   # ex. /dev/sdb
MODEL="<MODELE_DU_DISQUE>"   # ex. Samsung_SSD_870_EVO_500GB, tel que dans /dev/disk/by-id
SERIAL="<NUMERO_DE_SERIE>"
NODE="$(hostname)"

case "$DEV$MODEL$SERIAL" in *"<"*) echo "ERREUR : renseignez DEV, MODEL et SERIAL en tete du script."; exit 1 ;; esac

if pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  echo "Le stockage $STORAGE existe déjà : rien à faire."
  exit 0
fi

# --- Garde-fous : on ne touche qu'au bon disque, et seulement s'il est vide et libre ---
byid="$(ls /dev/disk/by-id/ | grep -E "${MODEL}_${SERIAL}\$" | head -n1 || true)"
[ -n "$byid" ] || { echo "ERREUR : disque de série $SERIAL introuvable."; exit 1; }
real="$(readlink -f "/dev/disk/by-id/$byid")"
[ "$real" = "$DEV" ] || { echo "ERREUR : le disque $SERIAL est $real et non $DEV : abandon."; exit 1; }
[ "$(lsblk -n -o NAME "$DEV" | wc -l)" -eq 1 ] || { echo "ERREUR : $DEV contient des partitions : abandon."; lsblk "$DEV"; exit 1; }
[ -z "$(wipefs "$DEV")" ] || { echo "ERREUR : $DEV contient encore une signature : abandon."; wipefs "$DEV"; exit 1; }
if grep -q "^$DEV" /proc/mounts; then echo "ERREUR : $DEV est monté."; exit 1; fi
echo "Disque vérifié : $byid -> $DEV, vide et libre."

# --- Création (même API que l'interface web) ---
# pvesh attend la fin de la tâche et affiche son journal ; un code retour non nul signale l'échec
pvesh create "/nodes/$NODE/disks/directory" --name "$STORAGE" --device "$DEV" --filesystem ext4 --add_storage 1

pvesm set "$STORAGE" --content images,rootdir,snippets,iso
echo "--- Résultat ---"
pvesm status | awk -v s="$STORAGE" 'NR==1 || $1==s'
df -h "/mnt/pve/$STORAGE"
