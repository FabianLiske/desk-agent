# desk.ps1
#
# Zurueck in den normalen Desktop-Modus:
#   1. Desktop-Monitor(e) via MultiMonitorTool aktivieren
#   2. TV-Monitor(e) deaktivieren
#   3. Wenn gesetzt: primaeren Monitor zuruecksetzen
#   4. Vorheriges Windows-Default-Audiogeraet aus State-Datei
#      wiederherstellen. Existiert die Datei nicht (z.B. weil tv-gaming
#      nie lief), wird Audio bewusst NICHT angeruehrt — Windows behaelt
#      dann sein aktuelles Default-Geraet.
#
# Monitor-Referenzen sind die kurzen MultiMonitorTool-IDs (siehe
# tv-gaming.ps1).
#
# Env-Variablen:
#   DESK_AGENT_MONITORS_DESK_ENABLE   Kommaliste
#   DESK_AGENT_MONITORS_DESK_DISABLE  Kommaliste
#   DESK_AGENT_MONITOR_DESK_PRIMARY   einzelne ID (optional)

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

$monitorsEnable  = Get-IdList $env:DESK_AGENT_MONITORS_DESK_ENABLE
$monitorsDisable = Get-IdList $env:DESK_AGENT_MONITORS_DESK_DISABLE
$monitorPrimary  = if ($env:DESK_AGENT_MONITOR_DESK_PRIMARY) { $env:DESK_AGENT_MONITOR_DESK_PRIMARY.Trim() } else { $null }

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
        Write-Host "[desk] enabling monitor '$id'"
        & $mmt /enable $id
    }
    if ($monitorPrimary) {
        Write-Host "[desk] setting primary monitor '$monitorPrimary'"
        & $mmt /SetPrimary $monitorPrimary
    }
    foreach ($id in $monitorsDisable) {
        Write-Host "[desk] disabling monitor '$id'"
        & $mmt /disable $id
    }
} else {
    Write-Warning "[desk] MultiMonitorTool.exe not found — skipping display switch"
}

$stateFile = Join-Path $env:LOCALAPPDATA 'desk-agent\state\audio-default.txt'
if (Test-Path $stateFile) {
    $previous = (Get-Content -Path $stateFile -Encoding UTF8 -Raw).Trim()
    if (-not $previous) {
        Write-Warning "[desk] saved audio state file is empty — skipping audio restore"
    } elseif (-not $svv) {
        Write-Warning "[desk] SoundVolumeView.exe not found — cannot restore audio to '$previous'"
    } else {
        Write-Host "[desk] restoring previous default audio device: $previous"
        & $svv /SetDefault $previous all
        Remove-Item -Force -ErrorAction SilentlyContinue $stateFile
    }
} else {
    Write-Host "[desk] no saved default audio — leaving Windows default untouched"
}
