#!/bin/bash
# FamTask Proxmox One-Liner Installer
# Führen Sie dies direkt auf Proxmox aus:
# bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-oneliner.sh)

set -euo pipefail

DOCKER_REPO_URL="https://github.com/nanoemilios/famtask_docker.git"
BRANCH="main"
INSTALL_DIR="/opt/famtask_docker"
APP_PORT="8888"
PMA_PORT="8081"
DB_PORT="3307"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { err "Als root ausführen: sudo bash ..."; exit 1; }

log "Installiere Docker..."
apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg lsb-release git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

log "Klone Docker-Repo..."
[[ -d "$INSTALL_DIR/.git" ]] && { cd "$INSTALL_DIR" && git fetch origin && git reset --hard "origin/$BRANCH"; } || git clone --branch "$BRANCH" "$DOCKER_REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Generiere Passwörter..."
gen_pass() { tr -dc 'A-Za-z0-9!#%&' </dev/urandom | head -c 24; }

# Bestehende .env niemals ueberschreiben: neue Passwoerter wuerden die
# Datenbank von einer bestehenden Installation abschneiden.
if [[ -f docker/.env ]]; then
  log ".env existiert bereits, Passwörter bleiben unverändert"
  chmod 600 docker/.env || true
else
  DB_PASS=$(gen_pass)
  DB_ROOT_PASS=$(gen_pass)
  cat > docker/.env <<EOF
# FamTask Docker Konfiguration - automatisch generiert am $(date)
DB_NAME=famtask
DB_USER=famtask
DB_PASS=$DB_PASS
DB_ROOT_PASS=$DB_ROOT_PASS
APP_PORT=$APP_PORT
PMA_PORT=$PMA_PORT
DB_PORT=$DB_PORT
EOF
  chmod 600 docker/.env
fi

# Ports und DB-Passwort aus der .env lesen, damit die Angaben auch nach
# einer Anpassung stimmen. Die Datei liegt unter docker/, nicht im Stamm.
set -a
. ./docker/.env
set +a
DB_ROOT_PASS=${DB_ROOT_PASS:-$(gen_pass)}

# Die Compose-Datei liegt im Repository-Stamm, die .env unter docker/.
# Deshalb wird sie explizit ueber --env-file uebergeben.
log "Starte Container..."
docker compose --env-file docker/.env pull
docker compose --env-file docker/.env up -d

log "Warte auf DB..."
for i in {1..60}; do
    docker exec famtask-db mariadb -u root -p"$DB_ROOT_PASS" -e "SELECT 1" &>/dev/null && break
    sleep 2
done

log "Führe App-Setup aus (klont famtask Repo, erstellt Config)..."
bash scripts/setup.sh

IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}✓ Fertig!${NC}"
echo "App:        http://$IP:$APP_PORT"
echo "Admin:      http://$IP:$APP_PORT/?action=admin"
echo "phpMyAdmin: http://$IP:$PMA_PORT"
echo "Config:     $INSTALL_DIR/docker/.env"