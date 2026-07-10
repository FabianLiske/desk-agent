#!/usr/bin/env bash
# gaming-mode.sh — Linux/Hyprland Gaming-Modus
#
# Setzt:
#   - Displayprofil "gaming" via `hyprctl keyword monitor` oder kanshictl
#   - Standard-Audiosink via wpctl
#   - startet Steam Big Picture wenn steam installiert ist
#
# Defaults sind ueber Umgebungsvariablen ueberschreibbar:
#   DESK_AGENT_HYPR_PROFILE   z.B. "gaming"      (kanshi profile name)
#   DESK_AGENT_AUDIO_SINK     wpctl id oder name (z.B. "alsa_output.pci-...HDMI...")

set -u
log() { printf '[gaming-mode] %s\n' "$*"; }
warn() { printf '[gaming-mode][warn] %s\n' "$*" >&2; }

hypr_profile=${DESK_AGENT_HYPR_PROFILE:-gaming}
audio_sink=${DESK_AGENT_AUDIO_SINK:-}

if command -v kanshictl >/dev/null 2>&1; then
    log "switching kanshi profile to $hypr_profile"
    kanshictl switch "$hypr_profile" || warn "kanshictl switch failed"
elif command -v hyprctl >/dev/null 2>&1; then
    log "kanshi missing — leaving monitors to hyprland.conf"
else
    warn "no hyprctl/kanshictl available — skipping display switch"
fi

if [[ -n $audio_sink ]] && command -v wpctl >/dev/null 2>&1; then
    log "setting default sink to $audio_sink"
    wpctl set-default "$audio_sink" || warn "wpctl set-default failed"
fi

if command -v steam >/dev/null 2>&1; then
    log "launching Steam Big Picture"
    steam steam://open/bigpicture >/dev/null 2>&1 &
else
    warn "steam not installed — skipping Big Picture"
fi
