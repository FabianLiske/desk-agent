# discord-mute.ps1
#
# Toggle des Discord-eigenen Mikrofon-Mutes. Es wird KEIN systemweiter
# Mute-Toggle ausgelöst — statt dessen wird das Discord-Fenster kurz
# in den Fokus geholt und der eingestellte Discord-Hotkey gesendet
# (Default: Ctrl+Shift+M). Nach dem Toggle wird der vorherige Fokus
# nicht wiederhergestellt (Discord-Overlay/Popout ist ohnehin häufig).
#
# Voraussetzung:
#   - Discord läuft
#   - In Discord unter User Settings > Keybinds ist "Toggle Mute" auf
#     Ctrl+Shift+M gesetzt (oder ENV DESK_AGENT_DISCORD_HOTKEY entsprechend
#     angepasst, siehe unten).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$hotkey = if ($env:DESK_AGENT_DISCORD_HOTKEY) { $env:DESK_AGENT_DISCORD_HOTKEY } else { '^+m' }

$discord = Get-Process -Name 'Discord' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1

if (-not $discord) {
    Write-Error "[discord-mute] Discord process with a main window not found"
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DeskAgentWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    public const int SW_RESTORE = 9;
}
"@

[void][DeskAgentWin]::ShowWindowAsync($discord.MainWindowHandle, [DeskAgentWin]::SW_RESTORE)
[void][DeskAgentWin]::SetForegroundWindow($discord.MainWindowHandle)
Start-Sleep -Milliseconds 120
[System.Windows.Forms.SendKeys]::SendWait($hotkey)

Write-Host "[discord-mute] sent mute-toggle hotkey '$hotkey' to Discord (pid=$($discord.Id))"
