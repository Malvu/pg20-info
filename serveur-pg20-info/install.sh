#!/usr/bin/env bash
# Installe / met à jour le serveur RustDesk "Pg20 Info" (hbbs + hbbr) avec Docker.
# À lancer sur la machine qui hébergera le serveur (NAS, Raspberry, mini-PC Linux...).
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "Docker n'est pas installé (https://docs.docker.com/engine/install/)."
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else die "Docker Compose est introuvable."; fi

# --- Adresse publique des clients (IP fixe ou nom de domaine) ---------------------------------
touch .env
RD_HOST="$(grep -E '^RD_HOST=' .env | head -n1 | cut -d= -f2- || true)"
if [ -z "$RD_HOST" ]; then
  read -r -p "Adresse publique du serveur Pg20 Info (IP fixe ou nom de domaine) : " RD_HOST
fi
RD_HOST="$(printf '%s' "$RD_HOST" | tr -d '[:space:]')"
[ -n "$RD_HOST" ] || die "L'adresse est obligatoire."
case "$RD_HOST" in
  *:*|*/*) die "Saisissez uniquement l'IP ou le nom de domaine (sans http://, sans port)." ;;
esac
printf 'COMPOSE_PROJECT_NAME=pg20-info\nRD_HOST=%s\n' "$RD_HOST" > .env

# --- Démarrage --------------------------------------------------------------------------------
say "Téléchargement des images RustDesk Server..."
$DC pull
say "Démarrage de hbbs et hbbr..."
$DC up -d

say "Attente de la génération de la clé du serveur..."
for _ in $(seq 1 30); do
  [ -s data/id_ed25519.pub ] && break
  sleep 1
done
[ -s data/id_ed25519.pub ] || die "Clé introuvable dans ./data : consultez '$DC logs hbbs'."
KEY="$(tr -d '\r\n' < data/id_ed25519.pub)"

$DC ps

# --- Récapitulatif pour les clients -----------------------------------------------------------
cat > client-settings.txt <<EOF
Serveur RustDesk "Pg20 Info"
Adresse (serveur d'ID / relais) : ${RD_HOST}
Clé publique                    : ${KEY}

Construire l'exe Windows (sur votre PC) :
  .\\Build-Installer.ps1 -InstallerFile .\\redist\\rustdesk-1.5.0-x86_64.exe -Server ${RD_HOST} -Key "${KEY}" -Output .\\dist\\Pg20-Info-Support.exe
EOF

echo
ok "Serveur Pg20 Info démarré."
echo "    Adresse : ${RD_HOST}"
echo "    Clé     : ${KEY}"
echo "    (enregistrés dans client-settings.txt)"
echo
echo "Reste à faire sur votre box : rediriger vers cette machine"
echo "    TCP 21115, 21116, 21117   et   UDP 21116"
echo "Et sauvegarder ./data/id_ed25519 (clé privée) : sans elle, tous les clients seraient à reconfigurer."
