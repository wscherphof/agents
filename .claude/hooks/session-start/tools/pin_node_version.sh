#!/usr/bin/env bash

set -euo pipefail

NODE_VERSION=$1

# This script runs non-interactively, so login/profile scripts that define the
# `nvm` shell function are not sourced. Load nvm here.
echo "Loading nvm..."
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

echo "Installing and using Node.js version $NODE_VERSION..."
nvm install $NODE_VERSION
nvm use $NODE_VERSION
nvm alias default $NODE_VERSION

# `nvm use` only affects this hook's own shell. The non-interactive shells
# Claude Code spawns for Bash tool calls don't load nvm at all (~/.bashrc
# returns early when not interactive), so `node` would otherwise resolve to the
# system /opt/node22 that sits on PATH. Drop symlinks into ~/.local/bin (first
# entry on PATH) so every shell — interactive, login, or non-interactive — runs
# Node $NODE_VERSION.
echo "Symlinking Node.js binaries into ~/.local/bin..."
NODE_BIN_DIR="$(dirname "$(nvm which "$NODE_VERSION")")"
mkdir -p "$HOME/.local/bin"
for b in node npm npx corepack; do
    if [ -x "$NODE_BIN_DIR/$b" ]; then
        ln -sf "$NODE_BIN_DIR/$b" "$HOME/.local/bin/$b"
    fi
done
