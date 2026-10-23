#!/usr/bin/env bash
# Ajoute à la VM pg20-info « la dernière fois où chaque poste a été vu en ligne » (à lancer avec sudo, depuis ce dossier).
#   - peers-presence.py + son service et son minuteur (toutes les 15 s) : écrivent /var/lib/pg20-peers/presence.json ;
#   - peers-feed.py (mis à jour) : sert ce fichier sur GET /presence, avec le même jeton que /peers.
# Ne touche NI à peers-export.py, NI à peers.json, NI à registrations.json, NI à hbbs, NI à Home Assistant.
# Les fichiers remplacés sont d'abord copiés dans /root/pg20-avant-presence-<date> (retour en arrière : voir la fin du message).
set -euo pipefail
cd "$(dirname "$0")"
IP_VM="<IP_VM>"   # adresse de la VM (la même que dans pg20-peers-presence.service)
case "$IP_VM" in *"<"*) echo "Renseignez IP_VM en tete de install-presence.sh (adresse de la VM)."; exit 1 ;; esac
if grep -q '<[A-Z_]*>' pg20-peers-presence.service; then
  echo "Renseignez <IP_VM> et <RESEAU_LOCAL> dans pg20-peers-presence.service avant l'installation."; exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Lancez ce script avec sudo."; exit 1; }
command -v python3 >/dev/null || { echo "python3 est requis."; exit 1; }
[ -f /var/lib/pg20-peers/peers.json ] || { echo "peers.json introuvable : installez d'abord le flux (install-feed.sh)."; exit 1; }
[ -f /usr/local/lib/pg20/peers-feed.py ] || { echo "peers-feed.py n'est pas installé : installez d'abord le flux (install-feed.sh)."; exit 1; }
for f in peers-presence.py peers-feed.py pg20-peers-presence.service pg20-peers-presence.timer; do
  [ -f "$f" ] || { echo "Fichier manquant dans ce dossier : $f"; exit 1; }
done

# 1. Syntaxe des deux scripts, avant de remplacer quoi que ce soit
for f in peers-presence.py peers-feed.py; do
  PYTHONDONTWRITEBYTECODE=1 python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
    || { echo "Erreur de syntaxe dans $f : rien n'a été modifié."; exit 1; }
done

# 2. Sauvegarde de ce qui va être remplacé
AVANT="/root/pg20-avant-presence-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$AVANT"
cp -a /usr/local/lib/pg20/peers-feed.py "$AVANT/"
for u in pg20-peers-presence.service pg20-peers-presence.timer; do
  [ -f "/etc/systemd/system/$u" ] && cp -a "/etc/systemd/system/$u" "$AVANT/" || true
done
echo "sauvegarde : $AVANT"

# 3. Installation
install -m 0755 peers-presence.py peers-feed.py /usr/local/lib/pg20/
install -m 0644 pg20-peers-presence.service pg20-peers-presence.timer /etc/systemd/system/
systemctl daemon-reload

# 4. Premier relevé immédiat, puis activation du minuteur et redémarrage du flux (quelques secondes sans réponse sur 8099)
systemctl start pg20-peers-presence.service || echo "(le premier relevé a échoué : voir journalctl -u pg20-peers-presence.service)"
systemctl enable --now pg20-peers-presence.timer
systemctl restart pg20-peers-feed.service
sleep 2

# 5. Contrôles (le jeton n'est jamais affiché)
echo "--- état ---"
systemctl is-active pg20-peers-presence.timer pg20-peers-feed.service
ls -l /var/lib/pg20-peers/presence.json
python3 - <<'PY'
import json
d = json.load(open("/var/lib/pg20-peers/presence.json"))
p = d.get("presence", {})
print("relevé : ok =", d.get("ok"), "| postes suivis :", len(p), "| en ligne :", sum(1 for v in p.values() if v.get("online")), "| depuis :", d.get("since"))
if not d.get("ok"):
    print("ATTENTION : hbbs n'a pas répondu depuis la VM (PG20_HBBS_HOST dans pg20-peers-presence.service ; hbbs doit répondre sur son adresse réseau, pas sur 127.0.0.1).")
PY
TOKEN="$(cat /etc/pg20/feed.token)"
CODE="000"
for url in "http://$IP_VM:8099/presence" "https://$IP_VM:8099/presence"; do
  CODE="$(curl -ksS --max-time 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null || true)"
  [ "$CODE" = "200" ] && { echo "GET /presence -> 200 ($url)"; break; }
done
unset TOKEN
[ "$CODE" = "200" ] || echo "ATTENTION : GET /presence n'a pas répondu 200 (dernier code : $CODE) : voir journalctl -u pg20-peers-feed.service"

cat <<EOF

Retour en arrière :
  systemctl disable --now pg20-peers-presence.timer
  rm -f /etc/systemd/system/pg20-peers-presence.service /etc/systemd/system/pg20-peers-presence.timer /usr/local/lib/pg20/peers-presence.py /var/lib/pg20-peers/presence.json
  cp -a $AVANT/peers-feed.py /usr/local/lib/pg20/peers-feed.py
  systemctl daemon-reload && systemctl restart pg20-peers-feed.service
EOF
