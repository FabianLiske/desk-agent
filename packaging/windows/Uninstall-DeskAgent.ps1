# Uninstall-DeskAgent.ps1
#
# Entfernt die Scheduled-Task-Registrierung und (optional) das Binary.
# Belaesst die Konfiguration in %APPDATA%\desk-agent absichtlich.

[CmdletBinding()]
param(
    [string]$TaskName = 'DeskAgent',
    [switch]$RemoveBinary,
    [switch]$RemoveToken
)

$ErrorActionPreference = 'Continue'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "removed scheduled task '$TaskName'"
} else {
    Write-Warning "scheduled task '$TaskName' not found"
}

if ($RemoveBinary) {
    $installDir = Join-Path $env:LOCALAPPDATA 'desk-agent\bin'
    if (Test-Path $installDir) {
        Remove-Item -Recurse -Force $installDir
        Write-Host "removed $installDir"
    }
}

if ($RemoveToken) {
    [Environment]::SetEnvironmentVariable('DESK_AGENT_TOKEN', $null, 'User')
    Write-Host "removed DESK_AGENT_TOKEN user env var"
}
