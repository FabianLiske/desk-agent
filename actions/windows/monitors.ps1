# monitors.ps1
#
# Gemeinsame Monitorsteuerung über MultiMonitorTool.
# Die Action-Namen und festen Argumente stehen in configs/windows-pc.yaml;
# HTTP-Requests können keine freien Monitor-Argumente einschleusen.
#
# Env-Variablen:
#   DESK_AGENT_MONITOR_SAMSUNG1                  z.B. \\.\DISPLAY1
#   DESK_AGENT_MONITOR_SAMSUNG2                  z.B. \\.\DISPLAY2
#   DESK_AGENT_MONITOR_TV                        z.B. \\.\DISPLAY3
#   DESK_AGENT_MONITOR_SAMSUNG_DEFAULT_PRIMARY   samsung1|samsung2

param(
    [Parameter(Mandatory = $true)][string]$Command,
    [string]$Target,
    [string]$Arg1,
    [string]$Arg2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Get-MonitorAliases {
    $aliases = @{
        samsung1 = $env:DESK_AGENT_MONITOR_SAMSUNG1
        samsung2 = $env:DESK_AGENT_MONITOR_SAMSUNG2
        tv       = $env:DESK_AGENT_MONITOR_TV
    }
    foreach ($name in @($aliases.Keys)) {
        if ([string]::IsNullOrWhiteSpace($aliases[$name])) {
            throw "missing environment variable for monitor alias '$name'"
        }
        $aliases[$name] = $aliases[$name].Trim()
    }
    return $aliases
}

function Resolve-Monitor {
    param(
        [hashtable]$Aliases,
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "monitor alias is required"
    }
    $key = $Name.Trim().ToLowerInvariant()
    if (-not $Aliases.ContainsKey($key)) {
        throw "unknown monitor alias '$Name' (known: $($Aliases.Keys -join ', '))"
    }
    return $Aliases[$key]
}

function Get-Field {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    foreach ($name in $Names) {
        if ($Row.PSObject.Properties.Name -contains $name) {
            return [string]$Row.$name
        }
    }
    return $null
}

function Test-Truth {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value -match '^(1|true|yes|ja|y)$'
}

function Read-MonitorState {
    param([string]$Tool)

    $tmp = Join-Path $env:TEMP "desk-agent-monitors-$([Guid]::NewGuid()).csv"
    try {
        & $Tool /scomma $tmp | Out-Null
        Start-Sleep -Milliseconds 150
        if (-not (Test-Path $tmp)) {
            throw "MultiMonitorTool did not write state file: $tmp"
        }
        $rows = Import-Csv -Path $tmp
        $state = @{}
        foreach ($row in $rows) {
            $id = Get-Field $row @('Name', 'Short Monitor ID')
            if ([string]::IsNullOrWhiteSpace($id)) { continue }

            $activeRaw = Get-Field $row @('Active', 'Enabled')
            $primaryRaw = Get-Field $row @('Primary')
            $freqRaw = Get-Field $row @('Display Frequency', 'DisplayFrequency', 'Frequency')

            $freq = 0
            if (-not [string]::IsNullOrWhiteSpace($freqRaw)) {
                [void][int]::TryParse(($freqRaw -replace '[^\d]', ''), [ref]$freq)
            }

            $state[$id] = [pscustomobject]@{
                Id = $id
                Active = Test-Truth $activeRaw
                Primary = Test-Truth $primaryRaw
                Frequency = $freq
            }
        }
        return $state
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $tmp
    }
}

function Get-MonitorState {
    param(
        [hashtable]$State,
        [string]$MonitorId
    )
    if ($State.ContainsKey($MonitorId)) {
        return $State[$MonitorId]
    }
    throw "monitor '$MonitorId' not found in MultiMonitorTool state"
}

function Enable-Monitor {
    param([string]$Tool, [string]$MonitorId)
    Write-Host "[monitors] enabling $MonitorId"
    & $Tool /enable $MonitorId
}

function Disable-Monitor {
    param([string]$Tool, [string]$MonitorId)
    Write-Host "[monitors] disabling $MonitorId"
    & $Tool /disable $MonitorId
}

function Set-PrimaryMonitor {
    param([string]$Tool, [string]$MonitorId)
    Write-Host "[monitors] setting primary $MonitorId"
    & $Tool /SetPrimary $MonitorId
}

function Set-RefreshRate {
    param([string]$Tool, [string]$MonitorId, [int]$Hz)
    Write-Host "[monitors] setting $MonitorId to $Hz Hz"
    & $Tool /SetMonitors "Name=$MonitorId DisplayFrequency=$Hz"
}

$mmt = Resolve-Tool 'MultiMonitorTool.exe' @(
    (Join-Path $env:ProgramFiles       'MultiMonitorTool'),
    (Join-Path ${env:ProgramFiles(x86)} 'MultiMonitorTool')
)
if (-not $mmt) {
    Write-Error "[monitors] MultiMonitorTool.exe not found in PATH or Program Files"
    exit 1
}

$aliases = Get-MonitorAliases
$defaultSamsungPrimary = if ($env:DESK_AGENT_MONITOR_SAMSUNG_DEFAULT_PRIMARY) {
    $env:DESK_AGENT_MONITOR_SAMSUNG_DEFAULT_PRIMARY
} else {
    'samsung2'
}

switch ($Command) {
    'layout-tv' {
        $tv = Resolve-Monitor $aliases 'tv'
        $samsung1 = Resolve-Monitor $aliases 'samsung1'
        $samsung2 = Resolve-Monitor $aliases 'samsung2'

        Enable-Monitor $mmt $tv
        Start-Sleep -Milliseconds 500
        Set-PrimaryMonitor $mmt $tv
        Start-Sleep -Milliseconds 300
        Disable-Monitor $mmt $samsung1
        Disable-Monitor $mmt $samsung2
    }

    'layout-samsung' {
        $tv = Resolve-Monitor $aliases 'tv'
        $samsung1 = Resolve-Monitor $aliases 'samsung1'
        $samsung2 = Resolve-Monitor $aliases 'samsung2'
        $primary = Resolve-Monitor $aliases $defaultSamsungPrimary

        Enable-Monitor $mmt $samsung1
        Enable-Monitor $mmt $samsung2
        Start-Sleep -Milliseconds 700
        Set-PrimaryMonitor $mmt $primary
        Start-Sleep -Milliseconds 300
        Disable-Monitor $mmt $tv
    }

    'toggle-enabled' {
        $monitor = Resolve-Monitor $aliases $Target
        $state = Read-MonitorState $mmt
        $current = Get-MonitorState $state $monitor

        if ($current.Active) {
            if ($current.Primary) {
                $fallback = $null
                foreach ($alias in @('samsung1', 'samsung2', 'tv')) {
                    $candidate = Resolve-Monitor $aliases $alias
                    if ($candidate -eq $monitor) { continue }
                    if ($state.ContainsKey($candidate) -and $state[$candidate].Active) {
                        $fallback = $candidate
                        break
                    }
                }
                if (-not $fallback) {
                    throw "refusing to disable primary monitor '$monitor': no active fallback monitor found"
                }
                Set-PrimaryMonitor $mmt $fallback
                Start-Sleep -Milliseconds 300
            }
            Disable-Monitor $mmt $monitor
        } else {
            Enable-Monitor $mmt $monitor
        }
    }

    'set-primary' {
        $monitor = Resolve-Monitor $aliases $Target
        Enable-Monitor $mmt $monitor
        Start-Sleep -Milliseconds 300
        Set-PrimaryMonitor $mmt $monitor
    }

    'toggle-refresh' {
        $monitor = Resolve-Monitor $aliases $Target
        $lowHz = [int]$Arg1
        $highHz = [int]$Arg2
        if ($lowHz -le 0 -or $highHz -le 0 -or $lowHz -eq $highHz) {
            throw "toggle-refresh requires two different positive refresh rates"
        }

        $state = Read-MonitorState $mmt
        $current = Get-MonitorState $state $monitor
        if (-not $current.Active) {
            Enable-Monitor $mmt $monitor
            Start-Sleep -Milliseconds 500
        }

        $nextHz = if ($current.Frequency -eq $lowHz) { $highHz } else { $lowHz }
        Set-RefreshRate $mmt $monitor $nextHz
    }

    default {
        throw "unknown command '$Command'"
    }
}
