#!/usr/bin/env bash
# install.sh — deploy the Linux binary as a systemd --user service.
#
# Usage:
#   ./install.sh /path/to/desk-agent-linux-amd64
#
# Steps performed:
#   - Copy binary to ~/.local/bin/desk-agent
#   - Install the systemd user unit
#   - Reload the user daemon
# It does NOT enable/start the unit — do that manually so you know when
# it happens:
#   systemctl --user enable --now desk-agent

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <path-to-desk-agent-binary>" >&2
    exit 1
fi
src=$1
if [[ ! -x $src ]]; then
    chmod +x "$src"
fi

bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
cfg_dir="$HOME/.config/desk-agent"

mkdir -p "$bin_dir" "$unit_dir" "$cfg_dir"

install -m 0755 "$src" "$bin_dir/desk-agent"
install -m 0644 "$(dirname "$0")/desk-agent.service" "$unit_dir/desk-agent.service"

echo "installed:"
echo "  binary: $bin_dir/desk-agent"
echo "  unit:   $unit_dir/desk-agent.service"
echo
echo "next steps:"
echo "  1. Put DESK_AGENT_TOKEN=... into $cfg_dir/desk-agent.env (chmod 600)."
echo "  2. Copy configs/linux-ws.yaml to $cfg_dir/config.yaml and adjust."
echo "  3. systemctl --user daemon-reload"
echo "  4. systemctl --user enable --now desk-agent"
