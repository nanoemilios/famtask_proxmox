#!/usr/bin/env bash
# ==========================================================================
# FamTask – Proxmox LXC-Installer
#
# Erstellt auf einem Proxmox-VE-Host einen Debian-LXC-Container und
# installiert darin FamTask inkl. System-Updates, Docker und App-Setup.
# Das Script läuft auf dem PROXMOX-HOST (nicht im Container) und wird dort
# als root ausgeführt – Docker wird also nicht auf dem Host installiert.
#
# Aufruf direkt auf der Proxmox-Shell:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-ct.sh)"
#
# Unbeaufsichtigt mit Standardwerten:
#   bash proxmox-install-ct.sh --default
#
# Mit eigenen Werten:
#   bash proxmox-install-ct.sh --ctid 120 --hostname famtask --memory 4096 \
#        --cores 4 --disk 20 --storage local-lvm --bridge vmbr0 --ip dhcp
#
# Alle Werte lassen sich auch als Umgebungsvariable setzen
# (CTID, CT_HOSTNAME, CT_MEMORY, CT_CORES, CT_DISK, CT_STORAGE, ...).
# ==========================================================================

set -euo pipefail

# ── Konfiguration (per Argument oder Umgebungsvariable überschreibbar) ─────
SCRIPT_REPO="${SCRIPT_REPO:-nanoemilios/famtask_proxmox}"
SCRIPT_BRANCH="${SCRIPT_BRANCH:-main}"
INSTALLER_URL="https://raw.githubusercontent.com/${SCRIPT_REPO}/${SCRIPT_BRANCH}/proxmox-install.sh"

CTID="${CTID:-}"
CT_HOSTNAME="${CT_HOSTNAME:-famtask}"
CT_CORES="${CT_CORES:-2}"
CT_MEMORY="${CT_MEMORY:-2048}"
CT_SWAP="${CT_SWAP:-512}"
CT_DISK="${CT_DISK:-16}"
CT_STORAGE="${CT_STORAGE:-}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_TEMPLATE="${CT_TEMPLATE:-}"
CT_PASSWORD="${CT_PASSWORD:-}"
CT_UNPRIVILEGED="${CT_UNPRIVILEGED:-1}"

NET_MODE="${NET_MODE:-dhcp}"       # dhcp | static
NET_IP="${NET_IP:-}"
NET_CIDR="${NET_CIDR:-24}"
NET_GW="${NET_GW:-}"
NET_DNS="${NET_DNS:-1.1.1.1 9.9.9.9}"

APP_PORT="${APP_PORT:-8888}"
PMA_PORT="${PMA_PORT:-8081}"
DB_PORT="${DB_PORT:-3307}"

INTERACTIVE="${INTERACTIVE:-1}"
ASSUME_YES="${ASSUME_YES:-0}"
LOG_DIR="${LOG_DIR:-/root}"
LOG_FILE=""
# ───────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
step() { echo -e "\n${BLUE}==>${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
FamTask Proxmox LXC-Installer

Erstellt einen Debian-LXC-Container auf dem Proxmox-Host und installiert
darin System-Updates, Docker und FamTask.

Aufruf:
  bash proxmox-install-ct.sh [Optionen]

Optionen:
  --default              Standardwerte verwenden, keine Dialoge
  -y, --yes              Rückfrage vor dem Erstellen überspringen
  --ctid <ID>            Container-ID (Standard: nächste freie)
  --hostname <NAME>      Hostname des Containers (Standard: famtask)
  --cores <N>            CPU-Kerne (Standard: 2)
  --memory <MB>          RAM in MB (Standard: 2048)
  --swap <MB>            Swap in MB (Standard: 512)
  --disk <GB>            Rootfs-Größe in GB (Standard: 16)
  --storage <NAME>       Storage für das Rootfs (Standard: automatisch)
  --template-storage <N> Storage für das Template (Standard: automatisch)
  --template <NAME>      Template-Datei oder Volid (Standard: Debian 13/12)
  --bridge <NAME>        Netzwerk-Bridge (Standard: vmbr0)
  --ip dhcp|static       Netzwerkkonfiguration (Standard: dhcp)
  --static-ip <IP>       IP-Adresse bei --ip static
  --cidr <N>             Präfixlänge bei --ip static (Standard: 24)
  --gw <IP>              Gateway bei --ip static
  --dns <IP[,IP]>        DNS-Server (Standard: 1.1.1.1 9.9.9.9)
  --password <PASS>      root-Passwort (Standard: zufällig generiert)
  --privileged           privilegierten Container erstellen
  --app-port <PORT>      Port der FamTask-App (Standard: 8888)
  --pma-port <PORT>      Port von phpMyAdmin (Standard: 8081)
  --db-port <PORT>       Port der MariaDB (Standard: 3307)
  -h, --help             Diese Hilfe anzeigen

Beispiele:
  bash proxmox-install-ct.sh --default
  bash proxmox-install-ct.sh --ctid 120 --memory 4096 --disk 20 --ip static \
       --static-ip 192.168.1.50 --gw 192.168.1.1
EOF
}

# ── Argumente ──────────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --default)
                INTERACTIVE=0
                ASSUME_YES=1
                ;;
            -y|--yes)
                ASSUME_YES=1
                ;;
            --ctid)             CTID="$2"; shift ;;
            --hostname)         CT_HOSTNAME="$2"; shift ;;
            --cores)            CT_CORES="$2"; shift ;;
            --memory)           CT_MEMORY="$2"; shift ;;
            --swap)             CT_SWAP="$2"; shift ;;
            --disk)             CT_DISK="$2"; shift ;;
            --storage)          CT_STORAGE="$2"; shift ;;
            --template-storage) CT_TEMPLATE_STORAGE="$2"; shift ;;
            --template)         CT_TEMPLATE="$2"; shift ;;
            --bridge)           CT_BRIDGE="$2"; shift ;;
            --ip)               NET_MODE="$2"; shift ;;
            --static-ip)        NET_IP="$2"; shift ;;
            --cidr)             NET_CIDR="$2"; shift ;;
            --gw)               NET_GW="$2"; shift ;;
            --dns)              NET_DNS="$2"; shift ;;
            --password)         CT_PASSWORD="$2"; shift ;;
            --privileged)       CT_UNPRIVILEGED=0 ;;
            --app-port)         APP_PORT="$2"; shift ;;
            --pma-port)         PMA_PORT="$2"; shift ;;
            --db-port)          DB_PORT="$2"; shift ;;
            -h|--help)          usage; exit 0 ;;
            *)                  die "Unbekannte Option: $1 (siehe --help)" ;;
        esac
        shift
    done
}

# ── Voraussetzungen prüfen ─────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
}

check_pve() {
    command -v pct &>/dev/null || die "'pct' nicht gefunden – das Script läuft auf dem Proxmox-Host, nicht im Container."
    command -v pveversion &>/dev/null || die "Kein Proxmox VE erkannt (pveversion fehlt)."
    local version
    version=$(pveversion 2>/dev/null | awk -F'/' 'NR==1 {print $2}')
    info "Proxmox VE ${version:-unbekannt} erkannt"
}

validate_args() {
    [[ "$CTID" =~ ^[0-9]+$ ]] || die "Ungültige Container-ID: '$CTID'"
    [[ "$CT_CORES" =~ ^[0-9]+$ ]] || die "--cores muss eine Zahl sein"
    [[ "$CT_MEMORY" =~ ^[0-9]+$ ]] || die "--memory muss eine Zahl sein"
    [[ "$CT_DISK" =~ ^[0-9]+$ ]] || die "--disk muss eine Zahl sein"
    [[ "$NET_MODE" == "dhcp" || "$NET_MODE" == "static" ]] || die "--ip muss 'dhcp' oder 'static' sein"
    if [[ "$NET_MODE" == "static" ]]; then
        [[ -n "$NET_IP" ]] || die "Bei --ip static wird --static-ip benötigt"
        [[ -n "$NET_GW" ]] || die "Bei --ip static wird --gw benötigt"
    fi
    for port in "$APP_PORT" "$PMA_PORT" "$DB_PORT"; do
        [[ "$port" =~ ^[0-9]+$ ]] || die "Ungültiger Port: '$port'"
        if (( port < 1 || port > 65535 )); then
            die "Port ausserhalb von 1-65535: $port"
        fi
    done
}

# ── Erkennung ──────────────────────────────────────────────────────────────
detect_storages() {
    pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'
}

detect_storage() {
    local -a storages=()
    mapfile -t storages < <(detect_storages)
    [[ ${#storages[@]} -gt 0 && -n "${storages[0]}" ]] \
        || die "Kein aktiver Storage mit Inhalt 'rootdir' gefunden."
    printf '%s\n' "${storages[0]}"
}

detect_template_storage() {
    local -a storages=()
    mapfile -t storages < <(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    if [[ ${#storages[@]} -gt 0 && -n "${storages[0]}" ]]; then
        printf '%s\n' "${storages[0]}"
    else
        echo "local"
    fi
}

detect_bridges() {
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 || true
}

next_ctid() {
    local id
    id=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '"[:space:]') || true
    if [[ -z "$id" || ! "$id" =~ ^[0-9]+$ ]]; then
        id=100
        while pct status "$id" &>/dev/null; do id=$((id + 1)); done
    fi
    echo "$id"
}

ct_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" 'NR>1 && $3==h {print $1; exit}'
}

# ── Template ───────────────────────────────────────────────────────────────
find_template() {
    local base="$1"
    pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null \
        | awk '{print $1}' \
        | grep -E ":vztmpl/${base}-standard_[0-9.]+-[0-9]+_amd64\.tar\.(zst|gz)$" \
        | sort -V | tail -n1 || true
}

ensure_template() {
    local base name

    if [[ -n "$CT_TEMPLATE" ]]; then
        if [[ "$CT_TEMPLATE" != *:* ]]; then
            CT_TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE}"
        fi
        local tpl_list
        tpl_list=$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null || true)
        grep -qF "${CT_TEMPLATE#*:vztmpl/}" <<<"$tpl_list" \
            || warn "Template ${CT_TEMPLATE} nicht im Storage ${CT_TEMPLATE_STORAGE} gefunden – pct create wird es prüfen"
        return 0
    fi

    info "Aktualisiere Template-Liste..."
    pveam update >/dev/null 2>&1 || warn "pveam update fehlgeschlagen – nutze vorhandene Liste"

    for base in debian-13 debian-12 debian-11; do
        CT_TEMPLATE=$(find_template "$base")
        if [[ -z "$CT_TEMPLATE" ]]; then
            name=$(pveam available --section system 2>/dev/null \
                | awk '{print $2}' \
                | grep -E "^${base}-standard_.*_amd64\.tar\.(zst|gz)$" \
                | sort -V | tail -n1 || true)
            if [[ -n "$name" ]]; then
                info "Lade Template $name ..."
                if pveam download "$CT_TEMPLATE_STORAGE" "$name" >/dev/null 2>&1; then
                    CT_TEMPLATE=$(find_template "$base")
                else
                    warn "Download von $name fehlgeschlagen"
                fi
            fi
        fi
        [[ -n "$CT_TEMPLATE" ]] && break
    done

    [[ -n "$CT_TEMPLATE" ]] || die "Kein Debian-Template gefunden. Bitte manuell laden: pveam available --section system | grep debian"
    info "Template: $CT_TEMPLATE"
}

# ── Dialoge (whiptail) ─────────────────────────────────────────────────────
can_dialog() {
    [[ "$INTERACTIVE" == "1" ]] && [[ -t 0 && -t 1 ]] && command -v whiptail &>/dev/null
}

wt_input() {
    local title="$1" prompt="$2" default="$3" value
    value=$(whiptail --title "$title" --inputbox "$prompt" 10 68 "$default" 3>&1 1>&2 2>&3) \
        || die "Abgebrochen."
    echo "$value"
}

wt_menu() {
    local title="$1" prompt="$2"
    shift 2
    local value
    value=$(whiptail --title "$title" --menu "$prompt" 20 68 10 "$@" 3>&1 1>&2 2>&3) \
        || die "Abgebrochen."
    echo "$value"
}

wt_yesno() {
    local title="$1" prompt="$2"
    whiptail --title "$title" --yesno "$prompt" 10 68
}

ask_settings() {
    if ! can_dialog; then
        if [[ "$INTERACTIVE" == "1" ]]; then
            warn "Kein interaktives Terminal – verwende Standardwerte (--default)."
        fi
        return 0
    fi

    CTID=$(wt_input "Container-ID" "CTID für den neuen Container:" "$CTID")
    CT_HOSTNAME=$(wt_input "Hostname" "Hostname des Containers:" "$CT_HOSTNAME")
    CT_MEMORY=$(wt_input "RAM" "Arbeitsspeicher in MB:" "$CT_MEMORY")
    CT_CORES=$(wt_input "CPU" "CPU-Kerne:" "$CT_CORES")
    CT_DISK=$(wt_input "Festplatte" "Rootfs-Größe in GB:" "$CT_DISK")

    local -a menu=()
    local storage
    while IFS= read -r storage; do
        [[ -n "$storage" ]] && menu+=("$storage" "")
    done < <(detect_storages)
    if [[ ${#menu[@]} -gt 0 ]]; then
        CT_STORAGE=$(wt_menu "Storage" "Storage für das Rootfs:" "${menu[@]}")
    fi

    menu=()
    local bridge
    while IFS= read -r bridge; do
        [[ -n "$bridge" ]] && menu+=("$bridge" "")
    done < <(detect_bridges)
    if [[ ${#menu[@]} -gt 0 ]]; then
        CT_BRIDGE=$(wt_menu "Netzwerk" "Bridge für den Container:" "${menu[@]}")
    fi

    local mode
    mode=$(wt_menu "IP-Adresse" "Netzwerkkonfiguration:" \
        "dhcp" "IP per DHCP beziehen" \
        "static" "Feste IP-Adresse vergeben")
    NET_MODE="$mode"
    if [[ "$NET_MODE" == "static" ]]; then
        NET_IP=$(wt_input "IP-Adresse" "IPv4-Adresse (z. B. 192.168.1.50):" "${NET_IP:-192.168.1.50}")
        NET_CIDR=$(wt_input "Präfix" "Präfixlänge (z. B. 24):" "$NET_CIDR")
        NET_GW=$(wt_input "Gateway" "Gateway (z. B. 192.168.1.1):" "${NET_GW:-192.168.1.1}")
        NET_DNS=$(wt_input "DNS" "DNS-Server (durch Leerzeichen getrennt):" "$NET_DNS")
    fi

    APP_PORT=$(wt_input "App-Port" "Port der FamTask-App (z. B. 8888 oder 80):" "$APP_PORT")
    if wt_yesno "Weitere Ports" "Auch die Ports für phpMyAdmin (${PMA_PORT}) und MariaDB (${DB_PORT}) anpassen?"; then
        PMA_PORT=$(wt_input "Port" "Port von phpMyAdmin:" "$PMA_PORT")
        DB_PORT=$(wt_input "Port" "Port der MariaDB:" "$DB_PORT")
    fi
}

# ── Plan anzeigen ──────────────────────────────────────────────────────────
show_plan() {
    local net
    if [[ "$NET_MODE" == "static" ]]; then
        net="${NET_IP}/${NET_CIDR}, Gateway ${NET_GW}, DNS ${NET_DNS}"
    else
        net="DHCP"
    fi

    cat <<EOF

  Container-ID : $CTID
  Hostname     : $CT_HOSTNAME
  Template     : $CT_TEMPLATE
  Storage      : $CT_STORAGE (${CT_DISK} GB)
  CPU / RAM    : ${CT_CORES} Kerne / ${CT_MEMORY} MB
  Netzwerk     : $CT_BRIDGE, $net
  Modus        : $([[ "$CT_UNPRIVILEGED" == "1" ]] && echo "unprivilegiert" || echo "privilegiert") (nesting=1, keyctl=1)
  Ports        : App $APP_PORT, phpMyAdmin $PMA_PORT, DB $DB_PORT

EOF
}

confirm() {
    [[ "$ASSUME_YES" == "1" ]] && return 0
    local answer
    read -r -p "Container jetzt erstellen und FamTask installieren? [J/n] " answer
    [[ "$answer" =~ ^([jJyY]|)$ ]]
}

# ── Container erstellen ────────────────────────────────────────────────────
create_ct() {
    local net="name=eth0,bridge=${CT_BRIDGE},firewall=1"
    if [[ "$NET_MODE" == "static" ]]; then
        net+=",ip=${NET_IP}/${NET_CIDR},gw=${NET_GW}"
    else
        net+=",ip=dhcp"
    fi

    local args=(
        "$CTID" "$CT_TEMPLATE"
        --hostname "$CT_HOSTNAME"
        --description "FamTask – erstellt $(date +%Y-%m-%d) mit famtask_proxmox"
        --cores "$CT_CORES"
        --memory "$CT_MEMORY"
        --swap "$CT_SWAP"
        --rootfs "${CT_STORAGE}:${CT_DISK}"
        --net0 "$net"
        --ostype debian
        --unprivileged "$CT_UNPRIVILEGED"
        --onboot 1
    )

    local out
    if out=$(pct create "${args[@]}" --features "nesting=1,keyctl=1,fuse=1" 2>&1); then
        :
    else
        # Ältere Proxmox-Versionen kennen das Feature "fuse" nicht.
        pct destroy "$CTID" --force >/dev/null 2>&1 || true
        if out=$(pct create "${args[@]}" --features "nesting=1,keyctl=1" 2>&1); then
            warn "Feature 'fuse' wird von diesem Proxmox nicht unterstützt – Container ohne fuse erstellt."
        else
            err "$out"
            die "Container $CTID konnte nicht erstellt werden."
        fi
    fi

    pct set "$CTID" --tags famtask >/dev/null 2>&1 || true
    info "Container $CTID erstellt"
}

start_ct() {
    info "Starte Container..."
    pct start "$CTID"

    for _ in $(seq 1 60); do
        pct exec "$CTID" -- true >/dev/null 2>&1 && break
        sleep 1
    done
    pct exec "$CTID" -- true >/dev/null 2>&1 || die "Container $CTID startet nicht."

    local ip=""
    for _ in $(seq 1 60); do
        ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}') || ip=""
        [[ -n "$ip" ]] && break
        sleep 2
    done
    [[ -n "$ip" ]] || die "Container $CTID hat keine IP-Adresse erhalten."

    # Warten, bis DNS/Internet im Container nutzbar ist (apt braucht das).
    for _ in $(seq 1 30); do
        pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
        sleep 2
    done

    info "Container läuft mit IP $ip"
}

generate_password() {
    local raw
    raw=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
    printf '%s' "${raw:0:20}"
}

set_root_password() {
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(generate_password)
    fi
    printf 'root:%s\n' "$CT_PASSWORD" | pct exec "$CTID" -- chpasswd
    info "root-Passwort gesetzt"
}

copy_ssh_keys() {
    local src="/root/.ssh/authorized_keys"
    [[ -f "$src" ]] || return 0
    pct exec "$CTID" -- mkdir -p /root/.ssh
    pct push "$CTID" "$src" /root/.ssh/authorized_keys --perms 600 >/dev/null
    info "SSH-Keys des Hosts übernommen"
}

# ── System aktualisieren ───────────────────────────────────────────────────
update_ct() {
    step "System-Updates im Container"
    pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive \
        apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade
    pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends \
        ca-certificates curl gnupg git lsb-release
    info "System aktuell"
}

# ── FamTask installieren ───────────────────────────────────────────────────
run_installer() {
    step "FamTask installieren"

    local dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    fi

    if [[ -n "$dir" && -f "$dir/proxmox-install.sh" ]]; then
        info "Übertrage lokales Installationsscript in den Container"
        pct push "$CTID" "$dir/proxmox-install.sh" /root/proxmox-install.sh --perms 755 >/dev/null
    else
        info "Lade Installationsscript aus GitHub"
        pct exec "$CTID" -- curl -fsSL "$INSTALLER_URL" -o /root/proxmox-install.sh
        pct exec "$CTID" -- chmod 755 /root/proxmox-install.sh
    fi

    LOG_FILE="${LOG_DIR}/famtask-install-${CTID}.log"
    info "Starte Installation im Container (Log: $LOG_FILE)"
    if ! pct exec "$CTID" -- env \
            APP_PORT="$APP_PORT" PMA_PORT="$PMA_PORT" DB_PORT="$DB_PORT" \
            bash /root/proxmox-install.sh --yes 2>&1 | tee "$LOG_FILE"; then
        err "Installation im Container fehlgeschlagen."
        err "Erneut versuchen mit: pct exec $CTID -- bash /root/proxmox-install.sh"
        err "Log: $LOG_FILE"
        exit 1
    fi
}

# ── Abschluss ──────────────────────────────────────────────────────────────
verify_app() {
    for _ in $(seq 1 15); do
        if pct exec "$CTID" -- curl -fsS -o /dev/null "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then
            info "App antwortet auf Port $APP_PORT"
            return 0
        fi
        sleep 2
    done
    warn "App antwortet noch nicht auf Port $APP_PORT."
    warn "Log prüfen: pct exec $CTID -- docker logs famtask-web"
}

print_summary() {
    local ip
    ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')

    local app_suffix=""
    [[ "$APP_PORT" == "80" ]] || app_suffix=":$APP_PORT"

    cat <<EOF

==========================================
 FamTask läuft im Container $CTID
==========================================
 App:        http://${ip}${app_suffix}
 Admin:      http://${ip}${app_suffix}/?action=admin
 phpMyAdmin: http://${ip}:${PMA_PORT}

 Container:  pct enter ${CTID}
 root-Passwort: ${CT_PASSWORD}
 Config:     /opt/famtask_docker/docker/.env
 Log:        ${LOG_FILE:-/root/famtask-install-${CTID}.log}

 Update im Container:
   pct exec ${CTID} -- bash /root/proxmox-install.sh

 Autostart:  aktiv (onboot=1)
==========================================
EOF
}

main() {
    parse_args "$@"
    check_root
    check_pve

    CT_STORAGE="${CT_STORAGE:-$(detect_storage)}"
    CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-$(detect_template_storage)}"
    CTID="${CTID:-$(next_ctid)}"
    validate_args

    ensure_template
    ask_settings
    validate_args

    local existing
    existing=$(ct_by_hostname)
    if [[ -n "$existing" && "$existing" != "$CTID" ]]; then
        die "Es gibt bereits einen Container mit Hostname '$CT_HOSTNAME' (ID $existing). Updates dort ausführen mit: pct exec $existing -- bash /root/proxmox-install.sh"
    fi
    if pct status "$CTID" &>/dev/null; then
        die "Container $CTID existiert bereits."
    fi

    show_plan
    confirm || { info "Abgebrochen."; exit 0; }

    create_ct
    start_ct
    set_root_password
    copy_ssh_keys
    update_ct
    run_installer
    verify_app
    print_summary
}

main "$@"
