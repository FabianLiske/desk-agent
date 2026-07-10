# Install-DeskAgent.ps1
#
# Installiert das Desk-Agent-Binary in %LOCALAPPDATA%\desk-agent\bin
# und registriert eine Aufgabe in der Windows-Aufgabenplanung, die beim
# Benutzer-Login startet. Der Task laeuft explizit im User-Kontext
# (Session-1), NICHT in Session 0, damit Displayprofile / Discord /
# Steam funktionieren.
#
# Der Auth-Token wird als Umgebungsvariable auf User-Ebene gesetzt
# (nicht als Task-Argument), damit er nicht in Klartext in der
# Taskdefinition landet.
#
# Voraussetzung: aufgerufen im User-Kontext (kein "Als Administrator").
#
# Beispiel:
#   .\Install-DeskAgent.ps1 -BinaryPath .\desk-agent-windows-amd64.exe -Token (openssl rand -hex 32)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BinaryPath,
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$TaskName = 'DeskAgent'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $BinaryPath)) {
    throw "binary not found: $BinaryPath"
}

$installDir = Join-Path $env:LOCALAPPDATA 'desk-agent\bin'
$cfgDir     = Join-Path $env:APPDATA 'desk-agent'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
New-Item -ItemType Directory -Force -Path $cfgDir     | Out-Null

$installedBinary = Join-Path $installDir 'desk-agent.exe'
Copy-Item -Force -Path $BinaryPath -Destination $installedBinary

Write-Host "installed binary -> $installedBinary"

# Token als user-scoped env var setzen. Wirksam ab neuer Session.
[Environment]::SetEnvironmentVariable('DESK_AGENT_TOKEN', $Token, 'User')
Write-Host "set DESK_AGENT_TOKEN in user environment"

# Scheduled task: at logon of current user, in user context, hidden.
$action    = New-ScheduledTaskAction -Execute $installedBinary
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:UserName
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:UserName" -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -Hidden `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Write-Host "registered scheduled task '$TaskName'"
Write-Host ""
Write-Host "next steps:"
Write-Host "  1. Copy configs\windows-pc.yaml to $cfgDir\config.yaml"
Write-Host "  2. Log out / back in so the DESK_AGENT_TOKEN env var is available"
Write-Host "  3. Or start it now:  Start-ScheduledTask -TaskName $TaskName"
