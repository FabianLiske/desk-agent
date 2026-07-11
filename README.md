# desk-agent

Kleiner lokaler Automationsdienst für Windows- und Linux-Systeme. Wird per HTTP
angesprochen (z.B. von Bitfocus Companion auf einem Raspberry Pi), führt
allow-gelistete Skripte im aktiven Benutzerkontext aus und bietet stateful
Discord-Steuerung per lokaler RPC.

## Aufbau

```
cmd/desk-agent/          Main-Entry
internal/api/            HTTP-Server mit Token-Auth
internal/config/         YAML-Config-Loader
internal/embedded/       Extrahiert eingebettete Actions in ein Datenverzeichnis
internal/runner/         Führt Actions per PowerShell / /bin/sh aus
internal/discordrpc/     Lokale Discord-RPC-Steuerung für Mute/Deafen/State
assets.go                //go:embed all:actions  (im Modul-Root, damit embed die actions/ sieht)
actions/windows/         PowerShell-Skripte
configs/                 Beispiel-YAML-Konfigurationen und Display-Profile
packaging/               systemd-Unit und Windows-Scheduled-Task-Skripte
.github/workflows/       CI (build) und Release
Makefile                 lokale Entwicklungskommandos
```

Warum liegt `assets.go` (die `//go:embed`-Datei) im Modul-Root und nicht unter
`internal/embedded/`? Weil `//go:embed`-Patterns keine Pfade oberhalb der eigenen
Datei sehen dürfen. `actions/` soll aber top-level bleiben (Design-Doc). Das
Root-Package `assets` exportiert nur eingebettete Dateien als `embed.FS` — es
macht sonst nichts.

## HTTP-API

| Methode | Pfad              | Auth  | Beschreibung                                                     |
| ------- | ----------------- | ----- | ---------------------------------------------------------------- |
| GET     | `/healthz`        | keine | `ok`                                                             |
| GET     | `/actions`        | Token | Liste der konfigurierten Actions inkl. Version                    |
| POST    | `/action/{name}`  | Token | Führt die Action `name` aus. Antwortet mit `exit_code` und Log. |
| GET     | `/discord/state`  | Token | Discord `mute`/`deaf` State per lokaler RPC                       |
| POST    | `/discord/mute/toggle`   | Token | Discord Mute togglen und `before`/`after` zurückgeben    |
| POST    | `/discord/deafen/toggle` | Token | Discord Deafen togglen und `before`/`after` zurückgeben  |
| POST    | `/discord/mute` / `/discord/unmute` | Token | Discord Mute explizit setzen/löschen         |
| POST    | `/discord/deafen` / `/discord/undeafen` | Token | Discord Deafen explizit setzen/löschen   |

Der Token muss im Header stehen — entweder `Authorization: Bearer <token>` oder
`X-Desk-Agent-Token: <token>`. Es gibt bewusst kein Query-Parameter-Fallback.

Beispiel:

```bash
curl -X POST http://windows-pc:8765/action/displays_tv \
     -H "Authorization: Bearer $DESK_AGENT_TOKEN"
```

## Konfiguration

Default-Pfade:

- Windows: `%APPDATA%\desk-agent\config.yaml`
- Linux:   `~/.config/desk-agent/config.yaml`

Beispiele: `configs/windows-pc.yaml`, `configs/linux-ws.yaml`.

Der Token wird nicht in die YAML geschrieben. Setze `token_env: DESK_AGENT_TOKEN`
und übergib den Wert über die Umgebung (Scheduled Task auf Windows, systemd
EnvironmentFile auf Linux).

### Windows-Displayprofile

MultiMonitorTool-Profile gehören ins Repo unter `configs/displays/*.cfg`.
Beim Start extrahiert der Windows-Agent diese Profile nach
`%APPDATA%\desk-agent\displays`, wo die PowerShell-Actions sie laden.

Für zustandsbasierte Windows-Monitoraktionen nutzt `monitors.ps1`
MultiMonitorTool direkt. Die Monitor-Aliase werden über die Umgebung gesetzt:
`DESK_AGENT_MONITOR_SAMSUNG1`, `DESK_AGENT_MONITOR_SAMSUNG2`,
`DESK_AGENT_MONITOR_TV` und optional
`DESK_AGENT_MONITOR_SAMSUNG_DEFAULT_PRIMARY`.

Beispiel für das aktuell aktive Monitor-Setup:

```powershell
New-Item -ItemType Directory -Force .\configs\displays
MultiMonitorTool.exe /SaveConfig .\configs\displays\desk-120hz.cfg
```

## Lokaler Entwicklungs-Workflow

```bash
make run            # aus Source starten
make test           # tests
make build          # native Binary in ~/build/desk-agent
make build-all      # windows-amd64 + linux-amd64
```

Ohne Task:

```bash
go run  ./cmd/desk-agent
go test ./...
go build -o dist/desk-agent ./cmd/desk-agent
```

## Discord RPC

Für stateful Discord-Steuerung ohne Fensterfokus kann der Agent Discords
lokalen RPC/IPC-Socket verwenden. Setze `DISCORD_CLIENT_ID` und
`DISCORD_CLIENT_SECRET` in der Umgebung des Agent-Prozesses. Die Discord-App
braucht als OAuth-Redirect `http://localhost`.

Einmalig am Desktop autorisieren:

```bash
desk-agent -discord-auth
```

Danach liegen Access-/Refresh-Token lokal unter
`~/.config/desk-agent/discord-rpc-token.json` (oder `DISCORD_TOKEN_CACHE`) und
die HTTP-Endpunkte liefern direkt maschinenlesbaren State:

```json
{"ok":true,"discord":{"mute":false,"deaf":false}}
```

## Deployment

### Windows

```powershell
.\packaging\windows\Install-DeskAgent.ps1 `
    -BinaryPath .\desk-agent-windows-amd64.exe `
    -EnvFile .\desk-agent.env `
    -Start
```

Legt die Binary unter `%LOCALAPPDATA%\desk-agent\bin\desk-agent.exe` ab und
registriert einen Login-Task in der Windows-Aufgabenplanung, der im User-Kontext
läuft (Session 1, nicht 0). Der Installer kopiert, wenn vorhanden,
`configs\windows-pc.yaml` nach `%APPDATA%\desk-agent\config.yaml`, setzt alle
Variablen aus `desk-agent.env` in der User-Umgebung und erzeugt einen lokalen
Task-Launcher unter `%LOCALAPPDATA%\desk-agent\bin\Start-DeskAgent.ps1`, damit
`-Start` ohne Ab-/Anmelden bereits die neuen Variablen sieht.

Die `desk-agent.env` darf dieselbe Datei sein, die auch unter Linux in
`~/.config/desk-agent/desk-agent.env` liegt. Unterstützt werden einfache
Shell-Env-Zeilen wie `NAME=value`, `NAME="value"`, `NAME='value'` und
`export NAME=value`. `DESK_AGENT_TOKEN` muss entweder in dieser Datei stehen
oder per `-Token` übergeben werden. Ein Linux-Pfad in `DISCORD_TOKEN_CACHE`
wird unter Windows ignoriert, damit der Agent dort seinen Windows-lokalen Cache
verwenden kann.

Nützliche Optionen:

```powershell
# Bestehende config.yaml überschreiben
.\packaging\windows\Install-DeskAgent.ps1 `
    -BinaryPath .\desk-agent-windows-amd64.exe `
    -EnvFile .\desk-agent.env `
    -ForceConfig `
    -Start

# Private Windows-Firewall-Regel für TCP 8765 anlegen (PowerShell als Admin)
.\packaging\windows\Install-DeskAgent.ps1 `
    -BinaryPath .\desk-agent-windows-amd64.exe `
    -EnvFile .\desk-agent.env `
    -AddFirewallRule
```

### Linux

```bash
./packaging/linux/install.sh ./desk-agent-linux-amd64
# dann:
#   ~/.config/desk-agent/desk-agent.env    → DESK_AGENT_TOKEN=..., DISCORD_CLIENT_ID=...
#   ~/.config/desk-agent/config.yaml       → aus configs/linux-ws.yaml adaptieren
source ~/.config/desk-agent/desk-agent.env
~/.local/bin/desk-agent -discord-auth
systemctl --user daemon-reload
systemctl --user enable --now desk-agent
```

Skriptbar mit Env-Datei und einmaliger Discord-Autorisierung:

```bash
DESK_AGENT_TOKEN="$(openssl rand -hex 32)" \
DISCORD_CLIENT_ID="..." \
DISCORD_CLIENT_SECRET="..." \
./packaging/linux/install.sh ./desk-agent-linux-amd64 \
  --write-env --discord-auth --enable --start
```

Secrets und Tokens:

- `~/.config/desk-agent/desk-agent.env` enthält statische Secrets wie
  `DESK_AGENT_TOKEN`, `DISCORD_CLIENT_ID` und `DISCORD_CLIENT_SECRET`; setze
  `chmod 600`.
- `~/.config/desk-agent/discord-rpc-token.json` wird von `-discord-auth`
  erzeugt und enthält Discord Access-/Refresh-Token; die Datei wird mit
  `0600` geschrieben.
- Beide Dateien bleiben lokal auf der Workstation und gehören nicht ins Repo.

## Sicherheit

- Nur die Actions aus der Config und die festen Discord-RPC-Endpunkte sind
  ausführbar. Es gibt keinen freien Kommando-Endpoint.
- Argumente aus HTTP-Requests werden nicht an die Skripte durchgereicht.
  Skripte lesen ihre Parameter aus Environment-Variablen.
- Token-Vergleich in konstanter Zeit (`crypto/subtle`).
- Betrieb ausschließlich im LAN; auf Windows den Zugriff per Firewall auf den
  Raspberry Pi begrenzen.

## Actions

| Action         | Windows-Skript        | Linux-Skript         | Zweck                                                     |
| -------------- | --------------------- | -------------------- | --------------------------------------------------------- |
| `displays_tv`  | `monitors.ps1`        | —                    | TV aktivieren, als Hauptanzeige setzen, Samsungs aus      |
| `displays_samsung` | `monitors.ps1`    | —                    | Samsung-Monitore aktivieren, TV aus                       |
| `samsung1_toggle` / `samsung2_toggle` | `monitors.ps1` | —      | Einzelne Samsung-Monitore aktivieren/deaktivieren         |
| `samsung1_primary` / `samsung2_primary` | `monitors.ps1` | —    | Samsung-Monitor als Hauptanzeige setzen                   |
| `samsung1_hz_toggle` / `samsung2_hz_toggle` | `monitors.ps1` | — | Samsung-Refresh-Rate umschalten                           |

Voraussetzungen pro Action sind im Skript-Header dokumentiert.

## Releases

Bei einem Tag `vX.Y.Z` erzeugt die Action `release.yml` ein GitHub Release mit
Windows- und Linux-Binaries sowie einer `checksums.txt`.

```
desk-agent-windows-amd64.exe
desk-agent-linux-amd64
checksums.txt
```

Update auf einem Zielsystem: neues Binary herunterladen, altes ersetzen, Agent
neu starten.
