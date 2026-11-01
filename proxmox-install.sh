#!/bin/bash
# FamTask Proxmox Auto-Installer
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install.sh)
# Oder lokal: git clone https://github.com/nanoemilios/famtask_proxmox.git && cd famtask_proxmox && bash proxmox-install.sh
# Mit eigener Port-Wahl: bash proxmox-install.sh --port 80

set -euo pipefail

# ========== KONFIGURATION ==========
# Alle Werte lassen sich per Umgebungsvariable oder Argument überschreiben –
# der LXC-Installer (proxmox-install-ct.sh) reicht die Ports durch.
DOCKER_REPO_URL="${DOCKER_REPO_URL:-https://github.com/nanoemilios/famtask_docker.git}"
APP_REPO_URL="${APP_REPO_URL:-https://github.com/nanoemilios/famtask.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/famtask_docker}"
APP_PORT="${APP_PORT:-8888}"
PMA_PORT="${PMA_PORT:-8081}"
DB_PORT="${DB_PORT:-3307}"
# ====================================

# Wurde ein Port explizit gesetzt? Dann wird auch eine bestehende .env
# angepasst, statt den Wert stillschweigend zu ignorieren.
PORT_SET=0
PMA_SET=0
DB_SET=0
ASSUME_YES=0

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Compose aufrufen ──────────────────────────────────────────────────────
# Die Compose-Datei liegt im Repository-Stamm (nicht in docker/), und die
# .env wird bewusst unter docker/ abgelegt - deshalb wird sie hier
# explizit ueber --env-file uebergeben. Ohne das findet Compose weder
# die Datei noch die Zugangsdaten.
dc() {
    cd "$INSTALL_DIR"
    docker compose --env-file docker/.env "$@"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Bitte als root ausführen (sudo bash proxmox-install.sh)"
        exit 1
    fi
}

# Liefert das Debian-Codename, für das Docker ein Repository anbietet.
# Neue Debian-Versionen (z. B. trixie direkt nach dem Release) fehlen dort
# gelegentlich noch – dann wird auf bookworm zurückgefallen.
docker_codename() {
    local codename
    codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")
    case "$codename" in
        bookworm|bullseye|trixie) echo "$codename" ;;
        *) echo "bookworm" ;;
    esac
}

write_docker_repo() {
    local codename="$1"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $codename stable" \
        > /etc/apt/sources.list.d/docker.list
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

    local codename
    codename=$(docker_codename)
    write_docker_repo "$codename"

    if ! apt-get update -qq; then
        if [[ "$codename" != "bookworm" ]]; then
            warn "Docker-Repository für '$codename' nicht verfügbar – nutze bookworm"
            write_docker_repo "bookworm"
            apt-get update -qq
        else
            err "Docker-Repository konnte nicht geladen werden"
            exit 1
        fi
    fi

    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker installiert"
}

generate_password() {
    # Kein "| head -c" am Ende: head schliesst die Pipe, tr bekommt SIGPIPE
    # und das Script wuerde unter "set -o pipefail" abbrechen.
    local raw
    raw=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    printf '%s' "${raw:0:24}"
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
    local env_file="$INSTALL_DIR/docker/.env"

    # Bestehende .env niemals ueberschreiben: neue Passwoerter wuerden die
    # Datenbank von einer bestehenden Installation abschneiden. Explizit
    # gesetzte Ports werden aber uebernommen.
    if [[ -f "$env_file" ]]; then
        log ".env existiert bereits, Passwörter bleiben unverändert"
        if [[ "$PORT_SET" == "1" ]]; then
            update_env_value "$env_file" APP_PORT "$APP_PORT"
        fi
        if [[ "$PMA_SET" == "1" ]]; then
            update_env_value "$env_file" PMA_PORT "$PMA_PORT"
        fi
        if [[ "$DB_SET" == "1" ]]; then
            update_env_value "$env_file" DB_PORT "$DB_PORT"
        fi
        chmod 600 "$env_file" || true
        return
    fi

    local db_pass db_root_pass
    db_pass=$(generate_password)
    db_root_pass=$(generate_password)

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
    dc pull
    dc up -d
    log "Container gestartet"
}

wait_for_db() {
    log "Warte auf Datenbank..."
    local max=60
    local count=0
    local db_root_pass
    db_root_pass=$(grep DB_ROOT_PASS "$INSTALL_DIR/docker/.env" | cut -d= -f2)
    until docker exec famtask-db mariadb -u root -p"$db_root_pass" -e "SELECT 1" &>/dev/null; do
        sleep 2
        count=$((count + 1))
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
    local ip
    ip=$(hostname -I | awk '{print $1}')
    # Ports aus der .env lesen, damit die Angaben auch nach einer Anpassung stimmen
    local env_file="$INSTALL_DIR/docker/.env"
    local app_port pma_port
    app_port=$(grep -E '^APP_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || true)
    pma_port=$(grep -E '^PMA_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || true)
    app_port=${app_port:-$APP_PORT}
    pma_port=${pma_port:-$PMA_PORT}

    echo
    echo "=========================================="
    echo -e "${GREEN}FamTask erfolgreich installiert!${NC}"
    echo "=========================================="
    echo -e "App:        http://$ip:$app_port"
    echo -e "Admin:      http://$ip:$app_port/?action=admin"
    echo -e "phpMyAdmin: http://$ip:$pma_port"
    echo
    echo "Config:     $env_file"
    echo "App-Config: $INSTALL_DIR/my/.famtask_cfg.php"
    echo
    echo "Logs:       cd $INSTALL_DIR && docker compose --env-file docker/.env logs -f"
    echo "Stop:       cd $INSTALL_DIR && docker compose --env-file docker/.env down"
    echo "Update:     cd $INSTALL_DIR && git pull && docker compose --env-file docker/.env up -d --build && bash scripts/setup.sh"
    echo "=========================================="
}

# ── Argumente & Port-Auswahl ──────────────────────────────────────────────
usage() {
    cat <<'EOF'
FamTask Installer (Docker/Proxmox)

Aufruf:
  bash proxmox-install.sh [Optionen]

Optionen:
  -p, --port <PORT>       Port der FamTask-App (Standard: 8888)
      --pma-port <PORT>   Port von phpMyAdmin (Standard: 8081)
      --db-port <PORT>    Port der MariaDB (Standard: 3307)
  -y, --yes               Ohne Rückfrage installieren
  -h, --help              Diese Hilfe anzeigen

Ohne --port wird der App-Port beim Start interaktiv abgefragt
(Enter = Standardwert). Bei einer bestehenden Installation werden
explizit gesetzte Ports in docker/.env aktualisiert.
EOF
}

validate_ports() {
    local name value
    for name in APP_PORT PMA_PORT DB_PORT; do
        value="${!name}"
        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
            err "$name ist keine Zahl: '$value'"
            exit 1
        fi
        if (( value < 1 || value > 65535 )); then
            err "$name liegt ausserhalb von 1-65535: $value"
            exit 1
        fi
    done
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--port)      APP_PORT="$2"; PORT_SET=1; shift ;;
            --pma-port)     PMA_PORT="$2"; PMA_SET=1; shift ;;
            --db-port)      DB_PORT="$2"; DB_SET=1; shift ;;
            -y|--yes)       ASSUME_YES=1 ;;
            -h|--help)      usage; exit 0 ;;
            *)              err "Unbekannte Option: $1 (siehe --help)"; exit 1 ;;
        esac
        shift
    done
}

prompt_ports() {
    # Kein Prompt bei --yes, ohne Terminal (z. B. pct exec) oder wenn der
    # Port bereits per --port gesetzt wurde.
    if [[ "$ASSUME_YES" == "1" || "$PORT_SET" == "1" || ! -t 0 ]]; then
        return 0
    fi

    local answer=""
    read -r -p "Port für FamTask [${APP_PORT}]: " answer || answer=""
    if [[ -n "$answer" ]]; then
        APP_PORT="$answer"
    fi
}

update_env_value() {
    local file="$1" key="$2" value="$3"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
    log "$key in $(basename "$file") auf $value gesetzt"
}

main() {
    parse_args "$@"
    check_root
    validate_ports
    prompt_ports
    validate_ports
    log "Ports: App $APP_PORT, phpMyAdmin $PMA_PORT, DB $DB_PORT"
    install_docker
    clone_or_update_repo
    create_env_file
    start_containers
    wait_for_db
    run_app_setup
    print_summary
}

main "$@"