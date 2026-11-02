#!/bin/bash
# FamTask Proxmox One-Liner Installer
# Führen Sie dies direkt auf Proxmox aus:
# bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-oneliner.sh)
# Eigener Port:  bash <(curl -fsSL .../proxmox-install-oneliner.sh) --port 80

set -euo pipefail

DOCKER_REPO_URL="https://github.com/nanoemilios/famtask_docker.git"
BRANCH="main"
INSTALL_DIR="/opt/famtask_docker"
APP_PORT="${APP_PORT:-}"
PMA_PORT="${PMA_PORT:-}"
DB_PORT="${DB_PORT:-}"
PORT_SET=0
PMA_SET=0
DB_SET=0
if [[ -n "$APP_PORT" ]]; then PORT_SET=1; fi
if [[ -n "$PMA_PORT" ]]; then PMA_SET=1; fi
if [[ -n "$DB_PORT" ]]; then DB_SET=1; fi
APP_PORT="${APP_PORT:-8888}"
PMA_PORT="${PMA_PORT:-8081}"
DB_PORT="${DB_PORT:-3307}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Optionen ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)     APP_PORT="$2"; PORT_SET=1; shift ;;
        --pma-port)    PMA_PORT="$2"; PMA_SET=1; shift ;;
        --db-port)     DB_PORT="$2"; DB_SET=1; shift ;;
        -y|--yes)      PORT_SET=1 ;;
        -h|--help)
            echo "Aufruf: bash proxmox-install-oneliner.sh [--port PORT] [--pma-port PORT] [--db-port PORT]"
            exit 0
            ;;
        *)             err "Unbekannte Option: $1"; exit 1 ;;
    esac
    shift
done

# Ohne --port und mit Terminal wird der App-Port abgefragt.
if [[ "$PORT_SET" == "0" && -t 0 ]]; then
    ANSWER=""
    while true; do
        read -r -p "Port für FamTask [${APP_PORT}]: " ANSWER || ANSWER=""
        if [[ -z "$ANSWER" ]]; then
            break
        fi
        if [[ "$ANSWER" =~ ^[0-9]+$ ]] && (( ANSWER >= 1 && ANSWER <= 65535 )); then
            APP_PORT="$ANSWER"
            PORT_SET=1
            break
        fi
        err "Bitte eine Zahl zwischen 1 und 65535 eingeben (Enter = ${APP_PORT})."
    done
fi

for PORT in "$APP_PORT" "$PMA_PORT" "$DB_PORT"; do
    [[ "$PORT" =~ ^[0-9]+$ ]] || { err "Ungültiger Port: '$PORT'"; exit 1; }
    (( PORT >= 1 && PORT <= 65535 )) || { err "Port ausserhalb von 1-65535: $PORT"; exit 1; }
done

[[ $EUID -ne 0 ]] && { err "Als root ausführen: sudo bash ..."; exit 1; }

log "Ports: App $APP_PORT, phpMyAdmin $PMA_PORT, DB $DB_PORT"
log "Installiere Docker..."
apt-get update -qq && apt-get install -y -qq ca-certificates curl gnupg lsb-release git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Docker bietet nicht für jedes Debian-Release sofort ein Repository an –
# unbekannte bzw. noch fehlende Codenamen fallen auf bookworm zurück.
CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-bookworm}")
case "$CODENAME" in bookworm|bullseye|trixie) ;; *) CODENAME=bookworm ;; esac
write_docker_repo() {
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $1 stable" \
        > /etc/apt/sources.list.d/docker.list
}
write_docker_repo "$CODENAME"
if ! apt-get update -qq; then
    warn "Docker-Repository für '$CODENAME' nicht verfügbar – nutze bookworm"
    write_docker_repo bookworm
    apt-get update -qq
fi
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

log "Klone Docker-Repo..."
[[ -d "$INSTALL_DIR/.git" ]] && { cd "$INSTALL_DIR" && git fetch origin && git reset --hard "origin/$BRANCH"; } || git clone --branch "$BRANCH" "$DOCKER_REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Generiere Passwörter..."
gen_pass() {
    # Kein "| head -c" am Ende (SIGPIPE + pipefail), siehe proxmox-install.sh.
    local raw
    raw=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    printf '%s' "${raw:0:24}"
}

# Bestehende .env niemals ueberschreiben: neue Passwoerter wuerden die
# Datenbank von einer bestehenden Installation abschneiden. Explizit
# gesetzte Ports werden aber uebernommen.
if [[ -f docker/.env ]]; then
  log ".env existiert bereits, Passwörter bleiben unverändert"
  if [[ "$PORT_SET" == "1" ]]; then
    sed -i "s|^APP_PORT=.*|APP_PORT=$APP_PORT|" docker/.env
  fi
  if [[ "$PMA_SET" == "1" ]]; then
    sed -i "s|^PMA_PORT=.*|PMA_PORT=$PMA_PORT|" docker/.env
  fi
  if [[ "$DB_SET" == "1" ]]; then
    sed -i "s|^DB_PORT=.*|DB_PORT=$DB_PORT|" docker/.env
  fi
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
for _ in {1..60}; do
    docker exec famtask-db mariadb -u root -p"$DB_ROOT_PASS" -e "SELECT 1" &>/dev/null && break
    sleep 2
done

log "Führe App-Setup aus (klont famtask Repo, erstellt Config)..."
bash scripts/setup.sh

IP=$(hostname -I | awk '{print $1}')
APP_SUFFIX=""
[[ "$APP_PORT" == "80" ]] || APP_SUFFIX=":$APP_PORT"
echo -e "\n${GREEN}✓ Fertig!${NC}"
echo "App:        http://$IP$APP_SUFFIX"
echo "Admin:      http://$IP$APP_SUFFIX/?action=admin"
echo "phpMyAdmin: http://$IP:$PMA_PORT"
echo "Config:     $INSTALL_DIR/docker/.env"