# desk-120hz.ps1
#
# 120-Hz-Sparmodus. Laedt ein MultiMonitorTool-Profil, in dem alle
# Monitore auf 120 Hz gesetzt sind, damit die GPU im Desktopbetrieb
# besser heruntertaktet.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$displayProfile = if ($env:DESK_AGENT_DESK120_PROFILE) { $env:DESK_AGENT_DESK120_PROFILE } else { 'desk-120hz.cfg' }
$displayDir     = Join-Path $env:APPDATA 'desk-agent\displays'
$profilePath    = Join-Path $displayDir $displayProfile

$mmt = Get-Command 'MultiMonitorTool.exe' -ErrorAction SilentlyContinue
if (-not $mmt) {
    foreach ($dir in @((Join-Path $env:ProgramFiles 'MultiMonitorTool'), (Join-Path ${env:ProgramFiles(x86)} 'MultiMonitorTool'))) {
        $candidate = Join-Path $dir 'MultiMonitorTool.exe'
        if (Test-Path $candidate) { $mmt = @{ Source = $candidate }; break }
    }
}

if (-not $mmt) {
    Write-Error "[desk-120hz] MultiMonitorTool.exe not found in PATH or Program Files"
    exit 1
}
if (-not (Test-Path $profilePath)) {
    Write-Error "[desk-120hz] display profile missing: $profilePath"
    exit 1
}

Write-Host "[desk-120hz] loading display profile $profilePath"
& $mmt.Source /LoadConfig $profilePath
