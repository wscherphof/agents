#!/usr/bin/env bash

set -euo pipefail

NODE_VERSION=$1

# Capture the PATH Claude Code launched this hook with, before nvm mutates it.
# This is (approximately) the PATH that Claude Code's own child processes — most
# importantly the MCP servers it spawns at startup — inherit. Used by the
# diagnostics block at the end to reveal which Node those processes resolve.
CLAUDE_PATH="$PATH"

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

# --- Diagnostics ----------------------------------------------------------
# Prove which Node each context resolves, so a session where tooling still
# sees the system Node can be debugged from session-start.log. None of this
# affects the pin; failures here must not abort the hook.
{
    echo "=== node pin diagnostics ==="
    echo "expected: v$NODE_VERSION"
    # The Bash tool's shells: login (sources ~/.profile, adds ~/.local/bin) and
    # plain non-interactive. These are what `node -v` etc. run under.
    echo "login shell:        $(bash -lc 'command -v node && node -v' 2>&1 | tr '\n' ' ')"
    echo "non-interactive:    $(bash -c  'command -v node && node -v' 2>&1 | tr '\n' ' ')"
    # Claude Code's own child processes (MCP servers spawned at startup)
    # inherit roughly CLAUDE_PATH. If ~/.local/bin is absent here, those
    # processes fall through to the system Node regardless of the symlinks.
    echo "Claude/MCP PATH:    $(PATH="$CLAUDE_PATH" sh -c 'command -v node && node -v' 2>&1 | tr '\n' ' ')"
    case ":$CLAUDE_PATH:" in
        *":$HOME/.local/bin:"*) echo "~/.local/bin on Claude PATH: yes" ;;
        *)                      echo "~/.local/bin on Claude PATH: NO (MCP servers will use system Node)" ;;
    esac
    echo "symlinks:"
    ls -la "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx" 2>&1 || true
    echo "==========================="
} >&2 || true
