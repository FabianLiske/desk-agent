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
# Voraussetzung: im Ziel-User-Kontext aufgerufen. -AddFirewallRule braucht
# eine erhoehte PowerShell, alle anderen Schritte nicht.
#
# Beispiel:
#   .\Install-DeskAgent.ps1 -BinaryPath .\desk-agent-windows-amd64.exe -EnvFile .\desk-agent.env -Start

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BinaryPath,
    [string]$Token,
    [string]$EnvFile,
    [string]$ConfigPath,
    [string]$TaskName = 'DeskAgent',
    [switch]$ForceConfig,
    [switch]$NoConfig,
    [switch]$Start,
    [switch]$AddFirewallRule
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-ScriptRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Kind not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function ConvertFrom-EnvValue {
    param([string]$Value)

    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
        return $v.Substring(1, $v.Length - 2).Replace("'\\''", "'")
    }
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        $inner = $v.Substring(1, $v.Length - 2)
        $inner = $inner -replace '\\n', "`n"
        $inner = $inner -replace '\\r', "`r"
        $inner = $inner -replace '\\t', "`t"
        $inner = $inner -replace '\\"', '"'
        $inner = $inner -replace '\\\\', '\'
        return $inner
    }

    return $v
}

function Read-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $vars = @{}
    $lineNo = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $lineNo++
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line.StartsWith('export ')) {
            $line = $line.Substring(7).TrimStart()
        }

        $match = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
        if (-not $match.Success) {
            throw "unsupported env file syntax in $Path line $lineNo`: $rawLine"
        }

        $name = $match.Groups[1].Value
        $value = ConvertFrom-EnvValue $match.Groups[2].Value
        $vars[$name] = $value
    }
    return $vars
}

function Set-UserEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-PowerShellLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Write-Launcher {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Binary,
        [Parameter(Mandatory = $true)][hashtable]$Variables
    )

    $lines = @(
        '$ErrorActionPreference = ''Stop''',
        'Set-StrictMode -Version Latest'
    )
    foreach ($name in ($Variables.Keys | Sort-Object)) {
        $value = ConvertTo-PowerShellLiteral ([string]$Variables[$name])
        $lines += "[Environment]::SetEnvironmentVariable('$name', $value, 'Process')"
    }
    $binaryLiteral = ConvertTo-PowerShellLiteral $Binary
    $lines += "& $binaryLiteral"
    $lines += 'exit $LASTEXITCODE'

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

if (-not (Test-Path $BinaryPath)) {
    throw "binary not found: $BinaryPath"
}

$scriptDir = Get-ScriptRoot
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)

$binarySource = Resolve-ExistingPath -Path $BinaryPath -Kind 'binary'
if ($EnvFile) {
    $EnvFile = Resolve-ExistingPath -Path $EnvFile -Kind 'env file'
}

if (-not $NoConfig -and -not $ConfigPath) {
    $candidate = Join-Path $repoRoot 'configs\windows-pc.yaml'
    if (Test-Path -LiteralPath $candidate) {
        $ConfigPath = $candidate
    }
}
if ($ConfigPath) {
    $ConfigPath = Resolve-ExistingPath -Path $ConfigPath -Kind 'config'
}

$installDir = Join-Path $env:LOCALAPPDATA 'desk-agent\bin'
$cfgDir     = Join-Path $env:APPDATA 'desk-agent'
$configFile = Join-Path $cfgDir 'config.yaml'
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
New-Item -ItemType Directory -Force -Path $cfgDir     | Out-Null

$installedBinary = Join-Path $installDir 'desk-agent.exe'
$launcherPath = Join-Path $installDir 'Start-DeskAgent.ps1'
Copy-Item -Force -LiteralPath $binarySource -Destination $installedBinary

Write-Host "installed binary -> $installedBinary"

$envVars = @{}
if ($EnvFile) {
    $envVars = Read-EnvFile -Path $EnvFile
}
if ($Token) {
    $envVars['DESK_AGENT_TOKEN'] = $Token
}
if (-not $envVars.ContainsKey('DESK_AGENT_TOKEN') -or [string]::IsNullOrWhiteSpace([string]$envVars['DESK_AGENT_TOKEN'])) {
    throw "DESK_AGENT_TOKEN missing: pass -Token or provide it in -EnvFile"
}
if ($envVars.ContainsKey('DISCORD_TOKEN_CACHE') -and ([string]$envVars['DISCORD_TOKEN_CACHE']) -match '^/') {
    $envVars.Remove('DISCORD_TOKEN_CACHE')
    Write-Warning "ignored Unix-style DISCORD_TOKEN_CACHE from env file; Windows will use its default token cache path"
}

foreach ($name in ($envVars.Keys | Sort-Object)) {
    Set-UserEnvironment -Name $name -Value ([string]$envVars[$name])
}
Write-Host "set $($envVars.Count) user environment variable(s)"

Write-Launcher -Path $launcherPath -Binary $installedBinary -Variables $envVars
Write-Host "installed launcher -> $launcherPath"

if (-not $NoConfig -and $ConfigPath) {
    if ((Test-Path -LiteralPath $configFile) -and -not $ForceConfig) {
        Write-Host "kept existing config -> $configFile"
    } else {
        Copy-Item -Force -LiteralPath $ConfigPath -Destination $configFile
        Write-Host "installed config -> $configFile"
    }
} elseif (-not (Test-Path -LiteralPath $configFile)) {
    Write-Warning "config missing: create $configFile or rerun without -NoConfig"
}

# Scheduled task: at logon of current user, in user context, hidden.
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskArgs  = "-NoProfile -ExecutionPolicy Bypass -File `"$launcherPath`""
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
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

if ($AddFirewallRule) {
    if (-not (Test-IsAdministrator)) {
        Write-Warning "firewall rule not added: rerun elevated with -AddFirewallRule, or add TCP 8765 manually"
    } else {
        $existingRule = Get-NetFirewallRule -DisplayName 'Desk Agent HTTP' -ErrorAction SilentlyContinue
        if ($existingRule) {
            Set-NetFirewallRule -DisplayName 'Desk Agent HTTP' -Enabled True | Out-Null
            Write-Host "enabled firewall rule 'Desk Agent HTTP'"
        } else {
            New-NetFirewallRule `
                -DisplayName 'Desk Agent HTTP' `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalPort 8765 `
                -Program $installedBinary `
                -Profile Private | Out-Null
            Write-Host "added firewall rule 'Desk Agent HTTP' for private networks"
        }
    }
}

if ($Start) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "started scheduled task '$TaskName'"
} else {
    Write-Host ""
    Write-Host "next steps:"
    Write-Host "  1. Log out / back in, or run: Start-ScheduledTask -TaskName $TaskName"
    Write-Host "  2. Test locally: curl.exe http://localhost:8765/healthz"
    Write-Host "  3. For LAN access, add a private firewall rule for TCP 8765 if needed"
}
