#!/usr/bin/env bash

set -euo pipefail

NODE_VERSION=$1

# Capture the PATH Claude Code launched this hook with, before nvm mutates it.
# This is (approximately) the PATH that Claude Code's own child processes — most
# importantly the MCP servers it spawns at startup — inherit. Used by the
# diagnostics block to reveal which Node those processes resolve.
CLAUDE_PATH="$PATH"

# --- Diagnostics ----------------------------------------------------------
# Prove which Node each context resolves, so a session where tooling still sees
# the system Node can be debugged from session-start.log. Registered as an EXIT
# trap so it runs even when a step below fails under `set -e` — i.e. in exactly
# the broken-pin case the diagnostics exist to explain. None of this affects the
# pin; failures here must not abort the hook.
node_pin_diagnostics() {
    {
        echo "=== node pin diagnostics ==="
        echo "expected: v$NODE_VERSION"
        # The Bash tool's shells: login (sources ~/.profile, adds ~/.local/bin) and
        # plain non-interactive. These are what `node -v` etc. run under.
        echo "login shell:        $(bash -lc 'command -v node && node -v' 2>&1 | tr '\n' ' ')"
        echo "non-interactive:    $(bash -c 'command -v node && node -v' 2>&1 | tr '\n' ' ')"
        # Claude Code's own child processes (MCP servers spawned at startup)
        # inherit roughly CLAUDE_PATH. If ~/.local/bin is absent here, those
        # processes fall through to the system Node regardless of the symlinks.
        echo "Claude/MCP PATH:    $(PATH="$CLAUDE_PATH" sh -c 'command -v node && node -v' 2>&1 | tr '\n' ' ')"
        case ":$CLAUDE_PATH:" in
        *":$HOME/.local/bin:"*)
            echo "$HOME/.local/bin on Claude PATH: yes"
            ;;
        *)
            echo "$HOME/.local/bin on Claude PATH: NO (MCP servers will use system Node)"
            ;;
        esac
        echo "symlinks:"
        ls -la "$HOME/.local/bin/node" "$HOME/.local/bin/npm" "$HOME/.local/bin/npx" 2>&1 || true
        echo "==========================="
    } >&2 || true
}
trap node_pin_diagnostics EXIT

# Retry a command with exponential backoff. Used to guard the `nvm install`,
# whose download can fail transiently when the hook runs concurrently with the
# proxy/apt warmup at session start — the failure mode that previously left the
# session on the system Node with no retry.
retry() {
    local attempts=$1 delay=$2
    shift 2
    local n=1
    until "$@"; do
        if [ "$n" -ge "$attempts" ]; then
            return 1
        fi
        echo "  attempt $n/$attempts failed; retrying in ${delay}s..." >&2
        sleep "$delay"
        n=$((n + 1))
        delay=$((delay * 2))
    done
}

# This script runs non-interactively, so login/profile scripts that define the
# `nvm` shell function are not sourced. Load nvm here.
#
# nvm.sh is a large script that is NOT safe to source under `set -euo pipefail`:
# it inspects the *sourcing* shell's positional parameters, so with our "$1"
# (the target version) set it runs `nvm_auto use` as a side effect, and in a
# fresh container that internal path can return non-zero and trip `set -e` —
# aborting this script before the install step ever runs (the original
# silent-pin-failure: the hook died right after "Loading nvm..." with the
# system Node still in place). Source it defensively: clear positional params
# so nvm doesn't treat "$1" as an `nvm use` request, and relax `set -eu` for the
# duration of the source only.
echo "Loading nvm..."
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
    set -- # hide our positional params from nvm's auto-use side effect
    set +eu
    # shellcheck disable=SC1091
    \. "$NVM_DIR/nvm.sh"
    set -eu
else
    echo "ERROR: nvm not found at $NVM_DIR/nvm.sh; cannot pin Node." >&2
    exit 1
fi

# A previous run of this script points npm's global prefix at ~/.local (see the
# end of this script). nvm refuses to `nvm use` while that config is set, which
# would abort a re-run here under `set -e` — clear it before touching nvm.
npm config delete prefix >/dev/null 2>&1 || true

echo "Installing and using Node.js version $NODE_VERSION..."
if ! retry 4 2 nvm install "$NODE_VERSION"; then
    echo "ERROR: 'nvm install $NODE_VERSION' failed after retries; leaving system Node in place." >&2
    exit 1
fi
nvm use "$NODE_VERSION"
nvm alias default "$NODE_VERSION"

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

# Global installs done after the pin (`npm install -g …`) would land in nvm's
# per-version prefix, whose bin dir is NOT on PATH for the shells Claude Code
# spawns (they never load nvm) — the package would install fine but its command
# would be unfindable. Point npm's global prefix at ~/.local instead, so global
# installs drop their launchers straight into ~/.local/bin, the same first-on-
# PATH directory the node symlinks above rely on. (nvm dislikes this setting;
# the `npm config delete prefix` before the install step above keeps re-runs of
# this script working.)
echo "Pointing npm's global prefix at ~/.local..."
"$NODE_BIN_DIR/npm" config set prefix "$HOME/.local"

# The symlinks only win if ~/.local/bin sits ahead of /opt/node22/bin on PATH.
# That holds for the non-interactive shells Claude Code spawns, but NOT for
# login shells: /etc/profile.d/nodejs.sh prepends /opt/node22/bin, shadowing the
# symlinks. Drop in a profile.d entry that sorts AFTER nodejs.sh and re-prepends
# ~/.local/bin, so login shells resolve the pinned Node too. (A duplicate PATH
# entry is harmless — the first match wins.)
echo "Ensuring login shells prefer ~/.local/bin..."
PROFILE_DROPIN=/etc/profile.d/zz-claude-node-pin.sh
if [ -d /etc/profile.d ] && { : >"$PROFILE_DROPIN"; } 2>/dev/null; then
    cat >"$PROFILE_DROPIN" <<'EOF'
# Auto-generated by pin_node_version.sh. /etc/profile.d/nodejs.sh prepends the
# system Node (/opt/node22/bin); re-prepend the Claude-pinned Node so login
# shells resolve ~/.local/bin first.
if [ -d "$HOME/.local/bin" ]; then
    PATH="$HOME/.local/bin:$PATH"
    export PATH
fi
EOF
else
    echo "  could not write $PROFILE_DROPIN; login shells may still prefer system Node." >&2
fi
