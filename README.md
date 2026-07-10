# desk-agent

Kleiner lokaler Automationsdienst fuer Windows- und Linux-Systeme. Wird per HTTP
angesprochen (z.B. von Bitfocus Companion auf einem Raspberry Pi) und fuehrt
allow-gelistete Skripte im aktiven Benutzerkontext aus.

Detaillierte Motivation und Zielarchitektur: siehe `designidee.md`.

## Aufbau

```
cmd/desk-agent/          Main-Entry
internal/api/            HTTP-Server mit Token-Auth
internal/config/         YAML-Config-Loader
internal/embedded/       Extrahiert eingebettete Actions in ein Datenverzeichnis
internal/runner/         Fuehrt Actions per PowerShell / /bin/sh aus
assets.go                //go:embed all:actions  (im Modul-Root, damit embed die actions/ sieht)
actions/windows/         PowerShell-Skripte
actions/linux/           Shell-Skripte
configs/                 Beispiel-YAML-Konfigurationen
packaging/               systemd-Unit und Windows-Scheduled-Task-Skripte
.github/workflows/       CI (build) und Release
Taskfile.yml             lokale Entwicklungskommandos
```

Warum liegt `assets.go` (die `//go:embed`-Datei) im Modul-Root und nicht unter
`internal/embedded/`? Weil `//go:embed`-Patterns keine Pfade oberhalb der eigenen
Datei sehen duerfen. `actions/` soll aber top-level bleiben (Design-Doc). Das
Root-Package `assets` exportiert nur `assets.Actions` als `embed.FS` — es macht
sonst nichts.

## HTTP-API

| Methode | Pfad              | Auth  | Beschreibung                                                     |
| ------- | ----------------- | ----- | ---------------------------------------------------------------- |
| GET     | `/healthz`        | keine | `ok`                                                             |
| GET     | `/actions`        | Token | Liste der konfigurierten Actions inkl. Version                    |
| POST    | `/action/{name}`  | Token | Fuehrt die Action `name` aus. Antwortet mit `exit_code` und Log. |

Der Token muss im Header stehen — entweder `Authorization: Bearer <token>` oder
`X-Desk-Agent-Token: <token>`. Es gibt bewusst kein Query-Parameter-Fallback.

Beispiel:

```bash
curl -X POST http://windows-pc:8765/action/tv_gaming \
     -H "Authorization: Bearer $DESK_AGENT_TOKEN"
```

## Konfiguration

Default-Pfade:

- Windows: `%APPDATA%\desk-agent\config.yaml`
- Linux:   `~/.config/desk-agent/config.yaml`

Beispiele: `configs/windows-pc.yaml`, `configs/linux-ws.yaml`.

Der Token wird nicht in die YAML geschrieben. Setze `token_env: DESK_AGENT_TOKEN`
und uebergib den Wert ueber die Umgebung (Scheduled Task auf Windows, systemd
EnvironmentFile auf Linux).

## Lokaler Entwicklungs-Workflow

```bash
task run            # aus Source starten
task test           # tests
task build          # native Binary in ./dist
task build:all      # windows-amd64 + linux-amd64
```

Ohne Task:

```bash
go run  ./cmd/desk-agent
go test ./...
go build -o dist/desk-agent ./cmd/desk-agent
```

## Deployment

### Windows

```powershell
.\packaging\windows\Install-DeskAgent.ps1 `
    -BinaryPath .\desk-agent-windows-amd64.exe `
    -Token (openssl rand -hex 32)
```

Legt die Binary unter `%LOCALAPPDATA%\desk-agent\bin\desk-agent.exe` ab und
registriert einen Login-Task in der Windows-Aufgabenplanung, der im User-Kontext
laeuft (Session 1, nicht 0). Der Token wird in der User-Umgebung gespeichert.

### Linux

```bash
./packaging/linux/install.sh ./desk-agent-linux-amd64
# dann:
#   ~/.config/desk-agent/desk-agent.env    → DESK_AGENT_TOKEN=...
#   ~/.config/desk-agent/config.yaml       → aus configs/linux-ws.yaml adaptieren
systemctl --user daemon-reload
systemctl --user enable --now desk-agent
```

## Sicherheit

- Nur die Actions aus der Config sind ausfuehrbar. Es gibt keinen freien
  Kommando-Endpoint.
- Argumente aus HTTP-Requests werden nicht an die Skripte durchgereicht.
  Skripte lesen ihre Parameter aus Environment-Variablen.
- Token-Vergleich in konstanter Zeit (`crypto/subtle`).
- Betrieb ausschliesslich im LAN; auf Windows den Zugriff per Firewall auf den
  Raspberry Pi begrenzen.

## Actions

| Action         | Windows-Skript        | Linux-Skript         | Zweck                                                     |
| -------------- | --------------------- | -------------------- | --------------------------------------------------------- |
| `tv_gaming`    | `tv-gaming.ps1`       | —                    | TV-Monitorprofil, TV-Audio, Steam Big Picture             |
| `desk`         | `desk.ps1`            | —                    | Rueck in Desktop-Modus                                    |
| `desk_120hz`   | `desk-120hz.ps1`      | `desk-120hz.sh`      | Alle Monitore auf 120 Hz                                  |
| `discord_mute` | `discord-mute.ps1`    | `discord-mute.sh`    | Discord-eigenen Mute per Hotkey togglen (kein System-Mute) |
| `gaming_mode`  | —                     | `gaming-mode.sh`     | Hyprland/kanshi-Profil, Audio-Sink, Steam Big Picture     |

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
