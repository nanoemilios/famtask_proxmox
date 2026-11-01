# FamTask Proxmox Installer

Automatische Installationsscripts für FamTask auf Proxmox VE (VM oder LXC Container).

**Dieses Repo enthält nur die Installer-Scripts.** Die eigentliche Installation klont das **famtask_docker** Repo und führt dort das Setup aus.

---

## 🆕 Neu am 2026-11-01

- **`proxmox-install-ct.sh`** erstellt den LXC-Container direkt auf dem
  Proxmox-Host (Debian, unprivilegiert, `nesting=1`, `keyctl=1`), spielt alle
  System-Updates ein und installiert FamTask im Container – siehe Variante 0.
- **Passwort-Generierung** brach unter `set -o pipefail` ab (`tr … | head -c`
  → SIGPIPE); jetzt ohne `head` am Pipeline-Ende.
- **`((count++))`** in `wait_for_db` beendete das Script unter `set -e` beim
  ersten Durchlauf – jetzt `count=$((count + 1))`.
- **Docker-Repository** fällt bei fehlendem Codename automatisch auf
  `bookworm` zurück.
- **Port-Auswahl:** `proxmox-install.sh` fragt den App-Port ab (Enter = 8888)
  und akzeptiert `--port` / `--pma-port` / `--db-port`; der One-Liner ebenso.
  Explizit gesetzte Ports werden auch in einer bestehenden `docker/.env`
  aktualisiert.

---

## ✅ Behobener Fehler in den Scripts

Die Scripts riefen `docker/docker-compose.yml` auf. **Diese Datei existiert
nicht** – die Compose-Datei liegt im Repository-Stamm von `famtask_docker`,
also `docker-compose.yml` ohne `docker/` davor. Ausserdem las
`famtask_docker/scripts/setup.sh` die `.env` aus `docker/.env`, während Compose
standardmässig `.env` aus dem Arbeitsverzeichnis erwartet; die Passwörter wären
stillschweigend ignoriert worden.

**Behoben am 2026-10-15:**

- `proxmox-install.sh` und `proxmox-install-oneliner.sh` rufen Compose aus dem
  Repository-Stamm auf und übergeben die `.env` über `--env-file docker/.env`
- `docker-compose.yml` wertet `APP_PORT`, `PMA_PORT` und `DB_PORT` jetzt
  tatsächlich aus – vorher waren die Ports hart codiert
- Vorhandene `.env` wird nicht mehr überschrieben, damit ein Update nicht die
  Datenbankpasswörter zerstört
- Die Befehle in diesem Dokument wurden ebenfalls auf `--env-file` umgestellt

Die Korrektur wurde gegen das Dateisystem und mit `bash -n` geprüft, **nicht** auf
einem echten Proxmox-Host.

Wer die Scripts manuell nutzt:

```bash
cd /opt/famtask_docker
cp docker/.env.example docker/.env
docker compose --env-file docker/.env up -d --build
bash scripts/setup.sh
```

---

## Variante 0: LXC-Container automatisch erstellen (empfohlen)

`proxmox-install-ct.sh` läuft auf dem **Proxmox-Host** und erstellt dort einen
Debian-LXC-Container, aktualisiert das System im Container und installiert
FamTask inkl. Docker. Docker läuft damit im Container – nicht auf dem Host.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-ct.sh)"
```

Ohne Rückfragen mit Standardwerten:

```bash
curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-ct.sh -o /root/famtask-ct.sh
bash /root/famtask-ct.sh --default
```

Mit eigenen Werten (alle Optionen: `bash proxmox-install-ct.sh --help`):

```bash
bash /root/famtask-ct.sh --ctid 120 --hostname famtask --memory 4096 \
     --cores 4 --disk 20 --storage local-lvm --bridge vmbr0 --ip dhcp
```

**Standardwerte:** Debian 13 (Fallback 12), 2 Kerne, 2048 MB RAM, 16 GB Disk,
unprivilegiert, `nesting=1`, `keyctl=1`, DHCP, nächste freie CTID. Storage und
Template-Storage werden automatisch erkannt, das Template bei Bedarf
nachgeladen. Bei `--ip static` werden `--static-ip`, `--gw`, optional `--cidr`
und `--dns` gesetzt. Das root-Passwort wird generiert und am Ende angezeigt;
SSH-Keys des Hosts werden übernommen.

Im Container läuft danach `proxmox-install.sh` (Docker, `.env`, Container,
App-Setup). Update später:

```bash
pct exec <CTID> -- bash /root/proxmox-install.sh
```

---

## Variante 1: One-Liner (schnellste Methode)

Direkt auf der Proxmox-Shell (oder in einer VM/CT) ausführen:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-oneliner.sh)
```

Anderer Port (ohne Angabe wird der Port abgefragt, Enter = 8888):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-oneliner.sh) --port 80
```

---

## Variante 2: Manuell (mehr Kontrolle)

```bash
# 1. Installer-Repo klonen
git clone https://github.com/nanoemilios/famtask_proxmox.git /opt/famtask_proxmox
cd /opt/famtask_proxmox

# 2. Installationsscript ausführen (fragt nach dem Port, Enter = 8888)
bash proxmox-install.sh

# oder ohne Rückfrage mit festem Port
bash proxmox-install.sh --port 80 --yes
```

---

## Was das Script tut

0. **Port abfragt** (Standard 8888; `--port <PORT>` überspringt die Frage und
   aktualisiert bei einer bestehenden Installation auch `docker/.env`)
1. **Docker & Docker Compose** installiert (falls nicht vorhanden)
2. **Docker-Repo** (famtask_docker) klont/aktualisiert nach `/opt/famtask_docker`
3. **Sichere Passwörter** generiert (24 Zeichen)
4. **`.env` Datei** erstellt mit allen Zugangsdaten
5. **Container baut & startet** (Web, MariaDB, phpMyAdmin)
6. **Wartet auf DB** und führt `scripts/setup.sh` aus (im famtask_docker Repo):
   - Klont **App-Repo** (famtask) nach `./my/`
   - Erstellt App-Konfiguration (`.famtask_cfg.php`)

---

## Nach der Installation

| Dienst | URL |
|--------|-----|
| **FamTask App** | `http://<PROXMOX-IP>:8888` |
| **Admin-Panel** | `http://<PROXMOX-IP>:8888/?action=admin` |
| **phpMyAdmin** | `http://<PROXMOX-IP>:8081` |

**Wichtige Dateien (in `/opt/famtask_docker/`):**
- `docker/.env` – Docker-Umgebungsvariablen (Passwörter!)
- `my/.famtask_cfg.php` – App-DB-Konfiguration (wird von setup.sh erstellt)

---

## Updates

```bash
cd /opt/famtask_docker
git pull                                    # Docker-Repo aktualisieren
docker compose up -d --build  # Container neu bauen
bash scripts/setup.sh                       # App-Repo aktualisieren & Config neu erstellen
```

---

## Deinstallation

```bash
cd /opt/famtask_docker
docker compose down -v
rm -rf /opt/famtask_docker
# Optional: rm -rf /opt/famtask_proxmox
```

---

## Anpassung (vor Installation)

Die Ports müssen nicht mehr im Script geändert werden:

```bash
bash proxmox-install.sh --port 80 --pma-port 8081 --db-port 3307
bash proxmox-install.sh            # fragt den App-Port ab
```

Alle Werte lassen sich auch als Umgebungsvariable setzen. Feste Vorgaben im
Script (`proxmox-install.sh` / `proxmox-install-oneliner.sh`):

```bash
DOCKER_REPO_URL="https://github.com/nanoemilios/famtask_docker.git"
APP_REPO_URL="https://github.com/nanoemilios/famtask.git"
BRANCH="main"
INSTALL_DIR="/opt/famtask_docker"
APP_PORT="8888"
PMA_PORT="8081"
DB_PORT="3307"
```

---

## Firewall / Ports

Falls Proxmox-Firewall aktiv, Ports freigeben:

```bash
# Auf Proxmox-Host:
pve-firewall add rule --port 8888 --proto tcp --action accept
pve-firewall add rule --port 8081 --proto tcp --action accept
pve-firewall add rule --port 3307 --proto tcp --action accept
```

Oder in der Web-GUI: **Datacenter → Firewall → Regeln hinzufügen**.

---

## Troubleshooting

**Container starten nicht?**
```bash
cd /opt/famtask_docker
docker compose logs -f
```

**Passwort vergessen?**
```bash
cat /opt/famtask_docker/docker/.env
```

**Datenbank zurücksetzen (ACHTUNG: Datenverlust!):**
```bash
cd /opt/famtask_docker
docker compose down -v
docker compose up -d
bash scripts/setup.sh
```

**App-Repo manuell aktualisieren:**
```bash
cd /opt/famtask_docker/my
git pull
```

---

## LXC Container (manuell)

Normalerweise übernimmt das `proxmox-install-ct.sh` (siehe Variante 0).
Wer den Container lieber selbst anlegt:

1. **CT erstellen:** Debian 13 (oder 12), 2 GB RAM, 2 CPU, 16 GB Disk
2. **Features aktivieren:** Nesting=1, Keyctl=1, Fuse=1
3. **In CT:** One-Liner ausführen

```bash
# Auf Proxmox-Host:
pct set <CTID> -features nesting=1,keyctl=1,fuse=1
```

`nesting` und `keyctl` sind für Docker nötig, `fuse` für Storage-Treiber wie
`fuse-overlayfs` (z. B. wenn der Container auf ZFS liegt).

---

## Repository-Struktur (gesamt)

```
famtask_proxmox/         # Dieses Repo (nur Installer)
├── proxmox-install-ct.sh      # Erstellt den LXC-Container (auf dem Host)
├── proxmox-install.sh         # Installation im Container/VM
├── proxmox-install-oneliner.sh
└── PROXMOX_INSTALL.md

famtask_docker/          # Wird vom Installer geklont (Docker-Setup)
├── docker/
│   ├── docker-compose.yml
│   ├── .env             # Wird vom Installer erstellt
│   ├── php/Dockerfile
│   ├── php/php.ini
│   ├── db/init.sql
│   └── scripts/setup.sh # Klont famtask Repo, erstellt Config
├── README.md
└── ...

/opt/famtask_docker/my/  # Wird von setup.sh erstellt (famtask Repo)
├── api.php
├── index.html
├── ...
```

**Vier separate Repositories:**
- **famtask** – Hauptanwendung (PHP/HTML/JS)
- **famtask_installer** – Web-Installer für Shared Hosting
- **famtask_docker** – Docker Compose Setup
- **famtask_proxmox** – Proxmox Installer Scripts (dieses Repo)