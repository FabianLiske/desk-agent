# Uninstall-DeskAgent.ps1
#
# Entfernt die Scheduled-Task-Registrierung und (optional) das Binary.
# Belaesst die Konfiguration in %APPDATA%\desk-agent absichtlich.

[CmdletBinding()]
param(
    [string]$TaskName = 'DeskAgent',
    [string]$EnvFile,
    [switch]$RemoveBinary,
    [switch]$RemoveToken,
    [switch]$RemoveEnvironment
)

$ErrorActionPreference = 'Continue'

function Read-EnvNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    $names = @()
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) {
            $line = $line.Substring(7).TrimStart()
        }
        $match = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*)=')
        if ($match.Success) {
            $names += $match.Groups[1].Value
        }
    }
    return $names | Sort-Object -Unique
}

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

if ($RemoveEnvironment) {
    $names = @(
        'DESK_AGENT_TOKEN',
        'DESK_AGENT_AUDIO_TV',
        'DESK_AGENT_AUDIO_DESK',
        'DESK_AGENT_DISCORD_HOTKEY',
        'DESK_AGENT_MONITORS_TV_ENABLE',
        'DESK_AGENT_MONITORS_TV_DISABLE',
        'DESK_AGENT_MONITOR_TV_PRIMARY',
        'DESK_AGENT_MONITORS_DESK_ENABLE',
        'DESK_AGENT_MONITORS_DESK_DISABLE',
        'DESK_AGENT_MONITOR_DESK_PRIMARY',
        'DESK_AGENT_DESK120_PROFILE',
        'DISCORD_CLIENT_ID',
        'DISCORD_CLIENT_SECRET',
        'DISCORD_REDIRECT_URI',
        'DISCORD_TOKEN_CACHE'
    )
    if ($EnvFile -and (Test-Path -LiteralPath $EnvFile)) {
        $names = $names + (Read-EnvNames -Path $EnvFile)
    }
    foreach ($name in ($names | Sort-Object -Unique)) {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
    }
    Write-Host "removed desk-agent user environment variables"
}
