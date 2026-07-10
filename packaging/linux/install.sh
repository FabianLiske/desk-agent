#!/usr/bin/env bash
# install.sh — deploy the Linux binary as a systemd --user service.
#
# Usage:
#   ./install.sh /path/to/desk-agent-linux-amd64 [options]
#
# Common:
#   ./install.sh ~/build/desk-agent/desk-agent-linux-amd64 --enable --start
#
# Fully scripted:
#   DESK_AGENT_TOKEN="$(openssl rand -hex 32)" \
#   DISCORD_CLIENT_ID="..." \
#   DISCORD_CLIENT_SECRET="..." \
#   ./install.sh ~/build/desk-agent/desk-agent-linux-amd64 --write-env --discord-auth --enable --start

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: install.sh <path-to-desk-agent-binary> [options]

options:
  --write-env       Write/update ~/.config/desk-agent/desk-agent.env from env vars.
                    Requires DESK_AGENT_TOKEN. Also writes DISCORD_* vars if set.
  --force-env       Allow --write-env to overwrite an existing env file.
  --discord-auth    Run desk-agent -discord-auth after installing.
                    Requires DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET.
  --enable          Run systemctl --user enable desk-agent.
  --start           Run systemctl --user restart desk-agent.
  --no-config       Do not install configs/linux-ws.yaml when config.yaml is missing.
  --help            Show this help.
EOF
}

if [[ $# -gt 0 && $1 == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

src=$1
shift

write_env=0
force_env=0
discord_auth=0
enable_service=0
start_service=0
install_config=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --write-env) write_env=1 ;;
        --force-env) force_env=1 ;;
        --discord-auth) discord_auth=1 ;;
        --enable) enable_service=1 ;;
        --start) start_service=1 ;;
        --no-config) install_config=0 ;;
        --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

if [[ ! -f $src ]]; then
    echo "binary not found: $src" >&2
    exit 1
fi
if [[ ! -x $src ]]; then
    chmod +x "$src"
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)

bin_dir="$HOME/.local/bin"
unit_dir="$HOME/.config/systemd/user"
cfg_dir="$HOME/.config/desk-agent"
env_file="$cfg_dir/desk-agent.env"
config_file="$cfg_dir/config.yaml"

mkdir -p "$bin_dir" "$unit_dir" "$cfg_dir"

install -m 0755 "$src" "$bin_dir/desk-agent"
install -m 0644 "$script_dir/desk-agent.service" "$unit_dir/desk-agent.service"

if [[ $install_config -eq 1 && ! -e $config_file ]]; then
    install -m 0644 "$repo_root/configs/linux-ws.yaml" "$config_file"
fi

if [[ $write_env -eq 1 ]]; then
    if [[ -e $env_file && $force_env -ne 1 ]]; then
        echo "env file already exists: $env_file (use --force-env to overwrite)" >&2
        exit 1
    fi
    if [[ -z ${DESK_AGENT_TOKEN:-} ]]; then
        echo "--write-env requires DESK_AGENT_TOKEN in the environment" >&2
        exit 1
    fi
    tmp="$env_file.tmp"
    {
        printf 'DESK_AGENT_TOKEN=%q\n' "$DESK_AGENT_TOKEN"
        [[ -n ${DISCORD_CLIENT_ID:-} ]] && printf 'DISCORD_CLIENT_ID=%q\n' "$DISCORD_CLIENT_ID"
        [[ -n ${DISCORD_CLIENT_SECRET:-} ]] && printf 'DISCORD_CLIENT_SECRET=%q\n' "$DISCORD_CLIENT_SECRET"
        [[ -n ${DISCORD_REDIRECT_URI:-} ]] && printf 'DISCORD_REDIRECT_URI=%q\n' "$DISCORD_REDIRECT_URI"
        [[ -n ${DISCORD_TOKEN_CACHE:-} ]] && printf 'DISCORD_TOKEN_CACHE=%q\n' "$DISCORD_TOKEN_CACHE"
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$env_file"
fi

if [[ $discord_auth -eq 1 ]]; then
    if [[ ! -f $env_file ]]; then
        echo "--discord-auth requires $env_file (use --write-env first or create it manually)" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    "$bin_dir/desk-agent" -discord-auth
fi

systemctl --user daemon-reload
if [[ $enable_service -eq 1 ]]; then
    systemctl --user enable desk-agent
fi
if [[ $start_service -eq 1 ]]; then
    systemctl --user restart desk-agent
fi

echo "installed:"
echo "  binary: $bin_dir/desk-agent"
echo "  unit:   $unit_dir/desk-agent.service"
echo "  config: $config_file"
echo "  env:    $env_file"

if [[ $write_env -ne 1 && ! -f $env_file ]]; then
    cat <<EOF

next steps:
  1. Create $env_file with DESK_AGENT_TOKEN, DISCORD_CLIENT_ID and DISCORD_CLIENT_SECRET.
  2. chmod 600 $env_file
  3. source $env_file && $bin_dir/desk-agent -discord-auth
  4. systemctl --user enable --now desk-agent
EOF
fi
