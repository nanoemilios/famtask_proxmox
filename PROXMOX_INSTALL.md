# FamTask Proxmox Installer

Automatische Installationsscripts für FamTask auf Proxmox VE (VM oder LXC Container).

**Dieses Repo enthält nur die Installer-Scripts.** Die eigentliche Installation klont das **famtask_docker** Repo und führt dort das Setup aus.

---

## ⚠️ Bekannter Fehler in den Scripts

Die Scripts in diesem Repo rufen `docker/docker-compose.yml` auf.
**Diese Datei existiert nicht** – die Compose-Datei liegt im Repository-Stamm von
`famtask_docker`, also `docker-compose.yml` ohne `docker/` davor.

Zusätzlich liest `famtask_docker/scripts/setup.sh` die `.env` aus `docker/.env`,
während Docker Compose standardmässig `.env` aus dem Arbeitsverzeichnis erwartet.

**Die Befehle in dieser Datei wurden am 2026-10-15 auf die korrekte Form
gebracht** (`docker compose …` statt `docker compose -f docker/docker-compose.yml …`).
Die Scripts `proxmox-install.sh` und `proxmox-install-oneliner.sh` selbst sind
**noch nicht** angepasst. Wer sie benutzt, muss den Compose-Aufruf korrigieren
oder den Container von Hand starten:

```bash
cd /opt/famtask_docker
cp docker/.env.example docker/.env
docker compose up -d --build
bash scripts/setup.sh
```

Details in
[WORKSPACE_COMPARISON.md](https://github.com/nanoemilios/famtask_docs/blob/main/WORKSPACE_COMPARISON.md).

---

## Variante 1: One-Liner (schnellste Methode)

Direkt auf der Proxmox-Shell (oder in einer VM/CT) ausführen:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nanoemilios/famtask_proxmox/main/proxmox-install-oneliner.sh)
```

---

## Variante 2: Manuell (mehr Kontrolle)

```bash
# 1. Installer-Repo klonen
git clone https://github.com/nanoemilios/famtask_proxmox.git /opt/famtask_proxmox
cd /opt/famtask_proxmox

# 2. Installationsscript ausführen
bash proxmox-install.sh
```

---

## Was das Script tut

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

Editieren Sie `proxmox-install.sh` oder `proxmox-install-oneliner.sh`:

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

## LXC Container (Alternative zur VM)

Für bessere Performance können Sie FamTask in einem **unprivilegierten LXC Container** laufen lassen:

1. **CT erstellen:** Debian 12, 2 GB RAM, 2 CPU, 10 GB Disk
2. **Features aktivieren:** Nesting=1, Keyctl=1
3. **In CT:** One-Liner ausführen

```bash
# Auf Proxmox-Host:
pct set <CTID> -features nesting=1,keyctl=1
```

---

## Repository-Struktur (gesamt)

```
famtask_proxmox/         # Dieses Repo (nur Installer)
├── proxmox-install.sh
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