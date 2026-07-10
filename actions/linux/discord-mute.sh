#!/usr/bin/env bash
# discord-mute.sh — Discord-eigenen Mute togglen.
#
# Sendet den Discord-Hotkey (Default Ctrl+Shift+M) an das Discord-Fenster.
# Der Hotkey muss in Discord unter User Settings > Keybinds fuer
# "Toggle Mute" gebunden sein.
#
# Unterstuetzt:
#   - Wayland/Hyprland via ydotool (benoetigt ydotoold-Daemon)
#   - X11 via xdotool
#
# Env:
#   DESK_AGENT_DISCORD_HOTKEY  z.B. "ctrl+shift+m" (default)

set -u
log() { printf '[discord-mute] %s\n' "$*"; }
warn() { printf '[discord-mute][warn] %s\n' "$*" >&2; }

hotkey=${DESK_AGENT_DISCORD_HOTKEY:-ctrl+shift+m}

if [[ ${XDG_SESSION_TYPE:-} == wayland ]] || [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    if ! command -v ydotool >/dev/null 2>&1; then
        warn "wayland session but ydotool not installed"
        exit 1
    fi
    # ydotool key expects Linux keycodes (KEY_LEFTCTRL=29, KEY_LEFTSHIFT=42, KEY_M=50).
    # We use key names via ydotool >= 1.0.
    IFS='+' read -r -a parts <<<"$hotkey"
    down=(); up=()
    declare -A map=(
        [ctrl]=29 [shift]=42 [alt]=56 [super]=125
        [a]=30 [b]=48 [c]=46 [d]=32 [e]=18 [f]=33 [g]=34 [h]=35
        [i]=23 [j]=36 [k]=37 [l]=38 [m]=50 [n]=49 [o]=24 [p]=25
        [q]=16 [r]=19 [s]=31 [t]=20 [u]=22 [v]=47 [w]=17 [x]=45 [y]=21 [z]=44
    )
    for p in "${parts[@]}"; do
        code=${map[${p,,}]:-}
        if [[ -z $code ]]; then
            warn "unknown key '$p' in hotkey — aborting"
            exit 1
        fi
        down+=("$code:1")
        up=("$code:0" "${up[@]}")
    done
    log "sending hotkey $hotkey via ydotool"
    ydotool key "${down[@]}" "${up[@]}"
    exit 0
fi

if command -v xdotool >/dev/null 2>&1; then
    win=$(xdotool search --name '^Discord' | head -n1 || true)
    if [[ -n $win ]]; then
        xdotool windowactivate --sync "$win"
    fi
    xdotool_hotkey=${hotkey//+/+}
    xdotool_hotkey=${xdotool_hotkey//ctrl/ctrl}
    log "sending hotkey $xdotool_hotkey via xdotool"
    xdotool key --clearmodifiers "$xdotool_hotkey"
    exit 0
fi

warn "neither ydotool nor xdotool available"
exit 1
