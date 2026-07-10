#!/usr/bin/env bash
# desk-120hz.sh — alle Monitore auf 120 Hz stellen (Hyprland).
#
# Nutzt hyprctl. Die konkreten Monitor-Namen werden ueber
# DESK_AGENT_MONITORS bereitgestellt, kommagetrennt in der Form
#   NAME@RES@RATE@POSITION,SCALE
# wobei RATE fest durch 120 ersetzt wird.
#
# Beispiel:
#   DESK_AGENT_MONITORS="DP-1@2560x1440@120@0x0,1;DP-2@1920x1080@120@2560x0,1"
#
# Ohne die ENV wird versucht, alle aktiven Monitore auf 120 Hz zu setzen,
# indem die aktuelle Aufloesung beibehalten wird.

set -u
log() { printf '[desk-120hz] %s\n' "$*"; }
warn() { printf '[desk-120hz][warn] %s\n' "$*" >&2; }

if ! command -v hyprctl >/dev/null 2>&1; then
    warn "hyprctl not found — is Hyprland running?"
    exit 1
fi

if [[ -n ${DESK_AGENT_MONITORS:-} ]]; then
    IFS=';' read -r -a monitors <<<"$DESK_AGENT_MONITORS"
    for m in "${monitors[@]}"; do
        [[ -z $m ]] && continue
        log "applying monitor: $m"
        hyprctl keyword monitor "$m" || warn "hyprctl failed for $m"
    done
    exit 0
fi

# Fallback: read current monitors, force 120 Hz.
mapfile -t names < <(hyprctl -j monitors 2>/dev/null | \
    awk -F\" '/"name":/ {print $4}')
if (( ${#names[@]} == 0 )); then
    warn "no monitors reported by hyprctl"
    exit 1
fi

for name in "${names[@]}"; do
    line=$(hyprctl -j monitors | awk -v n="\"$name\"" '
        $0 ~ n {found=1}
        found && /"width":/ {w=$2}
        found && /"height":/ {h=$2}
        found && /"x":/ {x=$2}
        found && /"y":/ {y=$2}
        found && /"scale":/ {s=$2; found=0; printf "%s|%s|%s|%s|%s\n", w, h, x, y, s}
    ' | tr -d ' ,')
    IFS='|' read -r w h x y s <<<"$line"
    if [[ -z $w || -z $h ]]; then
        warn "could not read geometry for $name — skipping"
        continue
    fi
    spec="$name,${w}x${h}@120,${x}x${y},${s:-1}"
    log "applying $spec"
    hyprctl keyword monitor "$spec" || warn "hyprctl failed for $spec"
done
