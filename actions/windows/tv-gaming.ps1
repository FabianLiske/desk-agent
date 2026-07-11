# tv-gaming.ps1
#
# TV-Gaming-Modus einschalten:
#   1. TV-Monitor(e) via MultiMonitorTool aktivieren
#   2. Desktop-Monitor(e) deaktivieren
#   3. Wenn gesetzt: primären Monitor auf TV wechseln
#   4. Aktuelles Windows-Default-Audiogerät in eine State-Datei sichern,
#      dann TV als Standard-Audiogerät setzen
#   5. Steam Big Picture starten
#
# Monitor-Referenzen sind die kurzen IDs, mit denen MultiMonitorTool
# arbeitet — z.B. "\\.\DISPLAY1", "\\.\DISPLAY2". Die IDs findest du mit
#     MultiMonitorTool.exe /scomma out.csv
# in der Spalte "Short Monitor ID" (alternativ funktioniert auch die
# Spalte "Name", z.B. "Monitor #1").
#
# Env-Variablen (siehe .env.example):
#   DESK_AGENT_MONITORS_TV_ENABLE    Kommaliste zu aktivierender Monitor-IDs
#   DESK_AGENT_MONITORS_TV_DISABLE   Kommaliste zu deaktivierender Monitor-IDs
#   DESK_AGENT_MONITOR_TV_PRIMARY    einzelne ID für den primären Monitor (optional)
#   DESK_AGENT_AUDIO_TV              Audiogerät-Name (SoundVolumeView "Name")

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

function Get-IdList {
    param([string]$Raw)
    if (-not $Raw) { return @() }
    return $Raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Resolve-Tool {
    param([string]$Name, [string[]]$FallbackDirs = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in $FallbackDirs) {
        $candidate = Join-Path $dir $Name
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

$monitorsEnable  = Get-IdList $env:DESK_AGENT_MONITORS_TV_ENABLE
$monitorsDisable = Get-IdList $env:DESK_AGENT_MONITORS_TV_DISABLE
$monitorPrimary  = if ($env:DESK_AGENT_MONITOR_TV_PRIMARY) { $env:DESK_AGENT_MONITOR_TV_PRIMARY.Trim() } else { $null }
$audioDevice     = if ($env:DESK_AGENT_AUDIO_TV) { $env:DESK_AGENT_AUDIO_TV } else { 'TV' }

$mmt = Resolve-Tool 'MultiMonitorTool.exe' @(
    (Join-Path $env:ProgramFiles       'MultiMonitorTool'),
    (Join-Path ${env:ProgramFiles(x86)} 'MultiMonitorTool')
)
$svv = Resolve-Tool 'SoundVolumeView.exe' @(
    (Join-Path $env:ProgramFiles       'SoundVolumeView'),
    (Join-Path ${env:ProgramFiles(x86)} 'SoundVolumeView')
)

if ($mmt) {
    foreach ($id in $monitorsEnable) {
        Write-Host "[tv-gaming] enabling monitor '$id'"
        & $mmt /enable $id
    }
    if ($monitorPrimary) {
        Write-Host "[tv-gaming] setting primary monitor '$monitorPrimary'"
        & $mmt /SetPrimary $monitorPrimary
    }
    foreach ($id in $monitorsDisable) {
        Write-Host "[tv-gaming] disabling monitor '$id'"
        & $mmt /disable $id
    }
} else {
    Write-Warning "[tv-gaming] MultiMonitorTool.exe not found — skipping display switch"
}

$stateDir  = Join-Path $env:LOCALAPPDATA 'desk-agent\state'
$stateFile = Join-Path $stateDir 'audio-default.txt'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

if ($svv) {
    # Merken, welches Gerät aktuell als Windows-Default-Render markiert ist,
    # damit desk.ps1 es zurückdrehen kann. Bricht der Snapshot fehl, wird
    # der Wechsel trotzdem durchgezogen — nur die Rückstellung fällt später aus.
    $tmp = Join-Path $env:TEMP "desk-agent-audio-$([Guid]::NewGuid()).csv"
    try {
        & $svv /scomma $tmp | Out-Null
        Start-Sleep -Milliseconds 300
        if (Test-Path $tmp) {
            $current = Import-Csv -Path $tmp | Where-Object {
                $_.Direction -eq 'Render' -and $_.Default -match 'Render'
            } | Select-Object -First 1
            if ($current -and $current.Name) {
                Set-Content -Path $stateFile -Value $current.Name -Encoding UTF8
                Write-Host "[tv-gaming] saved previous default audio device: $($current.Name)"
            } else {
                Write-Warning "[tv-gaming] could not detect current default render device"
            }
        }
    } catch {
        Write-Warning "[tv-gaming] failed to snapshot current audio default: $_"
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmp
    }

    Write-Host "[tv-gaming] switching default audio to '$audioDevice'"
    & $svv /SetDefault $audioDevice all
} else {
    Write-Warning "[tv-gaming] SoundVolumeView.exe not found — skipping audio switch"
}

Write-Host "[tv-gaming] launching Steam Big Picture"
Start-Process 'steam://open/bigpicture' | Out-Null
