#!/usr/bin/env bash
set -euo pipefail
umask 077

base_url=https://raw.githubusercontent.com/Seba-T/slurm-utils/main
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

# Download everything before changing an existing installation.
curl -sfL "$base_url/slurm-utils" -o "$stage/slurm-utils"
curl -sfL "$base_url/config.example.sh" -o "$stage/config.example.sh"
bash -n "$stage/slurm-utils" "$stage/config.example.sh"

mkdir -p -- "$HOME/.local/bin" "$HOME/.config/slurm-utils"
install -m 755 "$stage/slurm-utils" "$HOME/.local/bin/slurm-utils"
if [[ ! -e $HOME/.config/slurm-utils/config.sh && ! -L $HOME/.config/slurm-utils/config.sh ]]; then
    install -m 600 "$stage/config.example.sh" "$HOME/.config/slurm-utils/config.sh"
fi
printf 'Installed %s\nConfigure %s before scheduling.\n' \
    "$HOME/.local/bin/slurm-utils" "$HOME/.config/slurm-utils/config.sh"
