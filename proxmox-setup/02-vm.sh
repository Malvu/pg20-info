#!/usr/bin/env bash
# Crée la VM 102 "pg20-info" (Debian 12 cloud-init) sur le stockage pg20-info.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

VMID=102
NAME=pg20-info
STORAGE=pg20-info
IP="<IP_VM>/24"
GW="<IP_PASSERELLE>"
MAC="<MAC_DE_LA_VM>"   # ex. BC:24:11:xx:xx:xx
BASE=/root/pg20-setup
DL="/mnt/pve/$STORAGE/pg20-dl"
SNIP="/mnt/pve/$STORAGE/snippets"
IMG=debian-12-genericcloud-amd64.qcow2
URL=https://cloud.debian.org/images/cloud/bookworm/latest

# --- Garde-fous ---
case "$IP$GW$MAC" in *"<"*) echo "ERREUR : renseignez IP, GW et MAC en tete du script (valeurs entre < >)."; exit 1 ;; esac
qm status "$VMID" >/dev/null 2>&1 && { echo "ERREUR : la VM $VMID existe déjà."; exit 1; }
[ -d "/mnt/pve/$STORAGE" ] || { echo "ERREUR : stockage $STORAGE absent (lancez 01-storage.sh)."; exit 1; }
[ -s "$BASE/hash.txt" ] && [ -s "$BASE/ssh.pub" ] || { echo "ERREUR : $BASE/hash.txt ou ssh.pub manquant."; exit 1; }
if ping -c2 -W1 "${IP%/*}" >/dev/null 2>&1; then echo "ERREUR : ${IP%/*} répond déjà : adresse utilisée."; exit 1; fi

# --- Image Debian, vérifiée par SHA512 ---
mkdir -p "$DL" "$SNIP"
cd "$DL"
if [ ! -s "$IMG" ]; then
  echo "Téléchargement de $IMG..."
  wget -q -O "$IMG.part" "$URL/$IMG"
  wget -q -O SHA512SUMS "$URL/SHA512SUMS"
  expected="$(grep " $IMG\$" SHA512SUMS | awk '{print $1}')"
  actual="$(sha512sum "$IMG.part" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "ERREUR : SHA512 incorrect."; rm -f "$IMG.part"; exit 1; }
  mv "$IMG.part" "$IMG"
  echo "SHA512 conforme ($(du -h "$IMG" | cut -f1))."
fi

# --- user-data cloud-init ---
tpl="$(cat "$BASE/user-data.template.yaml")"
hash="$(tr -d '\r\n' < "$BASE/hash.txt")"
key="$(tr -d '\r\n' < "$BASE/ssh.pub")"
tpl="${tpl//__HASH__/$hash}"
tpl="${tpl//__SSHKEY__/$key}"
umask 077
printf '%s\n' "$tpl" > "$SNIP/pg20-user.yaml"

# --- VM ---
qm create "$VMID" --name "$NAME" --ostype l26 --memory 1024 --balloon 0 --cores 1 --cpu host \
  --net0 "virtio=$MAC,bridge=vmbr0" --scsihw virtio-scsi-single --agent enabled=1 --onboot 1 \
  --serial0 socket --vga serial0 \
  --description "Serveur RustDesk Pg20 Info (hbbs/hbbr) + Cockpit. Cree le $(date +%F)."
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$DL/$IMG,format=qcow2,discard=on"
qm resize "$VMID" scsi0 16G
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0
qm set "$VMID" --ipconfig0 "ip=$IP,gw=$GW" --nameserver "$GW" --cicustom "user=$STORAGE:snippets/pg20-user.yaml"
qm start "$VMID"
echo "--- VM $VMID démarrée ---"
qm status "$VMID"
