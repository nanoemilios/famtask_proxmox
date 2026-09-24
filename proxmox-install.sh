#!/bin/bash
# FamTask Proxmox Auto-Installer
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install.sh)
# Oder lokal: git clone https://github.com/nanoemilios/famtask_proxmox.git && cd famtask_proxmox && bash proxmox-install.sh

set -euo pipefail

# ========== KONFIGURATION ==========
DOCKER_REPO_URL="https://github.com/nanoemilios/famtask_docker.git"
APP_REPO_URL="https://github.com/nanoemilios/famtask.git"
BRANCH="main"
INSTALL_DIR="/opt/famtask_docker"
APP_PORT="8888"
PMA_PORT="8081"
DB_PORT="3307"
# ====================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Bitte als root ausführen (sudo bash proxmox-install.sh)"
        exit 1
    fi
}

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log "Docker & Docker Compose bereits installiert"
        return
    fi
    log "Installiere Docker & Docker Compose..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker installiert"
}

generate_password() {
    tr -dc 'A-Za-z0-9!#%&' </dev/urandom | head -c 24
}

clone_or_update_repo() {
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Docker-Repo existiert, aktualisiere..."
        cd "$INSTALL_DIR"
        git fetch origin
        git reset --hard "origin/$BRANCH"
    else
        log "Klone Docker-Repo von $DOCKER_REPO_URL..."
        git clone --branch "$BRANCH" "$DOCKER_REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi
}

create_env_file() {
    local db_pass=$(generate_password)
    local db_root_pass=$(generate_password)
    local env_file="$INSTALL_DIR/docker/.env"

    log "Erstelle .env mit sicheren Passwörtern..."
    cat > "$env_file" <<EOF
# FamTask Docker Konfiguration - automatisch generiert am $(date)
DB_NAME=famtask
DB_USER=famtask
DB_PASS=$db_pass
DB_ROOT_PASS=$db_root_pass
APP_PORT=$APP_PORT
PMA_PORT=$PMA_PORT
DB_PORT=$DB_PORT
EOF
    chmod 600 "$env_file"
    log "Passwörter gespeichert in $env_file"
}

start_containers() {
    log "Starte Container..."
    cd "$INSTALL_DIR/docker"
    docker compose pull
    docker compose up -d
    log "Container gestartet"
}

wait_for_db() {
    log "Warte auf Datenbank..."
    local max=60
    local count=0
    local db_root_pass=$(grep DB_ROOT_PASS "$INSTALL_DIR/docker/.env" | cut -d= -f2)
    until docker exec famtask-db mariadb -u root -p"$db_root_pass" -e "SELECT 1" &>/dev/null; do
        sleep 2
        ((count++))
        if [[ $count -ge $max ]]; then
            err "Datenbank startet nicht (Timeout)"
            exit 1
        fi
    done
    log "Datenbank bereit"
}

run_app_setup() {
    log "Führe App-Setup aus (klont famtask Repo, erstellt Config)..."
    cd "$INSTALL_DIR"
    bash scripts/setup.sh
}

print_summary() {
    local ip=$(hostname -I | awk '{print $1}')
    echo
    echo "=========================================="
    echo -e "${GREEN}FamTask erfolgreich installiert!${NC}"
    echo "=========================================="
    echo -e "App:        http://$ip:$APP_PORT"
    echo -e "Admin:      http://$ip:$APP_PORT/?action=admin"
    echo -e "phpMyAdmin: http://$ip:$PMA_PORT"
    echo
    echo "Config:     $INSTALL_DIR/docker/.env"
    echo "App-Config: $INSTALL_DIR/my/.famtask_cfg.php"
    echo
    echo "Logs:       docker compose -f $INSTALL_DIR/docker/docker-compose.yml logs -f"
    echo "Stop:       docker compose -f $INSTALL_DIR/docker/docker-compose.yml down"
    echo "Update:     cd $INSTALL_DIR && git pull && docker compose -f docker/docker-compose.yml up -d --build && bash scripts/setup.sh"
    echo "=========================================="
}

main() {
    check_root
    install_docker
    clone_or_update_repo
    create_env_file
    start_containers
    wait_for_db
    run_app_setup
    print_summary
}

main "$@"