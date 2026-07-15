#!/usr/bin/env bash
# Mirror agent settings and instructions from the cloned source project repo
# (its root, plus an optional monorepo component dir layered on top) INTO the
# agents repo at $CLAUDE_PROJECT_DIR, then commit and push to the project's
# settings branch (derived from the project identity — see section 8).
#
# Invoked by session-start.sh with cwd = the source clone root. Environment
# provided by the parent:
#   AGENTS_REPO_DIR       source clone root          (READ FROM)
#   AGENTS_COMPONENT_DIR  optional component subdir   (READ FROM; == repo dir if none)
#   AGENTS_GIT_ACCOUNT    e.g. merkatordev
#   AGENTS_GIT_REPO       e.g. GeoWEP
#   CLAUDE_PROJECT_DIR    the agents repo            (WRITTEN TO / pushed)
#   AGENTS_REPO_URL       clone URL — CONTAINS A PAT; never echo it
#
# Merge mode is MIRROR: the source is authoritative each run (removals
# propagate), then the agents-repo SessionStart scaffolding is re-injected so
# regeneration keeps working. Idempotent: a second run with unchanged source
# produces no commit.

set -euo pipefail

set -x

# Recover a possibly-interrupted dpkg state before installing anything. Some
# base-image containers start with dpkg left mid-configure ("dpkg was
# interrupted, you must manually run 'dpkg --configure -a' to correct the
# problem"); the very next `apt install` then exits non-zero, and under `set -e`
# that aborts the whole merge before rsync is even installed — nothing gets
# mirrored, committed, or pushed. Reconfigure best-effort and carry on.
sudo dpkg --configure -a || true

# Install only the tools that are actually missing, and don't let a flaky apt
# abort the mirror when they are already present. Only hard-fail (below) if a
# required tool is still unavailable after the install attempt.
merge_deps_missing=()
for _t in rsync jq python3; do
  command -v "$_t" >/dev/null 2>&1 || merge_deps_missing+=("$_t")
done
if [ ${#merge_deps_missing[@]} -gt 0 ]; then
  # Only touch apt when something is actually missing — an already-provisioned
  # container needs no network round-trip here. Neither step is fatal: the
  # command -v gate below is the real check.
  #
  # --allow-releaseinfo-change: base-image apt repos (e.g. the ondrej/php PPA)
  # occasionally change their Release Label/Origin/Suite, which makes a plain
  # `apt update` exit non-zero. `|| true` keeps both apt steps from aborting the
  # whole merge (before anything is mirrored/committed) on a transient hiccup.
  sudo apt update --allow-releaseinfo-change || true
  sudo apt install -y "${merge_deps_missing[@]}" || true
fi
for _t in rsync jq python3; do
  command -v "$_t" >/dev/null 2>&1 || {
    printf 'merge-agent-settings: error: required tool %s is unavailable and could not be installed\n' "$_t" >&2
    exit 1
  }
done

# --- temp bookkeeping -------------------------------------------------------
TMPFILES=()
TMPDIRS=()
cleanup() {
  [ ${#TMPFILES[@]} -gt 0 ] && rm -f -- "${TMPFILES[@]}" 2>/dev/null || true
  [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf -- "${TMPDIRS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

log() { printf 'merge-agent-settings: %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

# --- 1. validate ------------------------------------------------------------
for v in AGENTS_REPO_DIR CLAUDE_PROJECT_DIR AGENTS_GIT_ACCOUNT AGENTS_GIT_REPO; do
  [ -n "${!v:-}" ] || die "$v is not set"
done
[ -d "$AGENTS_REPO_DIR" ] || die "AGENTS_REPO_DIR does not exist: $AGENTS_REPO_DIR"
[ -d "$CLAUDE_PROJECT_DIR" ] || die "CLAUDE_PROJECT_DIR does not exist: $CLAUDE_PROJECT_DIR"

DEST="$CLAUDE_PROJECT_DIR"
AGENTS_COMPONENT_DIR="${AGENTS_COMPONENT_DIR:-$AGENTS_REPO_DIR}"

repo_real="$(realpath "$AGENTS_REPO_DIR")"
comp_real="$(realpath "$AGENTS_COMPONENT_DIR")"

# --- 2. source layers (root, optionally + component) ------------------------
SRC_LAYERS=("$AGENTS_REPO_DIR")
SRC_LABELS=("root")
COMPONENT_REL=""
if [ "$comp_real" != "$repo_real" ]; then
  case "$comp_real/" in
  "$repo_real"/*) : ;;
  *) die "component dir escapes repo dir: $AGENTS_COMPONENT_DIR" ;;
  esac
  COMPONENT_REL="$(realpath --relative-to="$AGENTS_REPO_DIR" "$AGENTS_COMPONENT_DIR")"
  SRC_LAYERS+=("$AGENTS_COMPONENT_DIR")
  SRC_LABELS+=("component: $COMPONENT_REL")
fi

SRC_SHA="$(git -C "$AGENTS_REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# Recursive deep-merge: objects merge by key; arrays concat + dedupe
# (order-preserving); scalars / type-changes take the later layer; an explicit
# null in a later layer does not clobber the accumulator.
DEEPMERGE='
def deepmerge($a; $b):
  if   ($a|type) == "object" and ($b|type) == "object" then
       reduce ($b|keys_unsorted[]) as $k ($a; .[$k] = deepmerge($a[$k] // null; $b[$k]))
  elif ($a|type) == "array"  and ($b|type) == "array"  then
       reduce $b[] as $e ($a; if any(.[]; . == $e) then . else . + [$e] end)
  elif $b == null then $a
  else $b end;
reduce inputs as $o (null; deepmerge(.; $o))'

# Collect existing+valid JSON layer files for a given relative path.
json_inputs() { # json_inputs <relpath> -> prints one path per line
  local rel="$1" layer f
  for layer in "${SRC_LAYERS[@]}"; do
    f="$layer/$rel"
    [ -f "$f" ] || continue
    if jq -e . "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
    else
      log "warn: malformed JSON skipped: $f"
    fi
  done
}

# --- 3. .claude/settings.json (mirror + re-inject scaffolding) --------------
mirror_settings() {
  local rel=".claude/settings.json" out="$DEST/.claude/settings.json"
  local inputs=() merged scaffold
  mapfile -t inputs < <(json_inputs "$rel")

  merged="$(mktemp)"
  TMPFILES+=("$merged")
  if [ ${#inputs[@]} -gt 0 ]; then
    jq -n "$DEEPMERGE" "${inputs[@]}" >"$merged"
  else
    echo '{}' >"$merged"
  fi

  # Scaffolding = SessionStart entries that invoke session-start.sh, taken from
  # the committed base (deterministic; immune to a prior partial run).
  scaffold="$(git -C "$DEST" show "HEAD:$rel" 2>/dev/null |
    jq -c '[ .hooks.SessionStart[]?
               | select(any(.hooks[]?.command // ""; test("session-start\\.sh"))) ]' 2>/dev/null)"
  [ -n "$scaffold" ] || scaffold='[]'

  # MCP server definitions belong in .mcp.json (see mirror_mcp), never in the
  # mirrored settings.json — drop them from the output here.
  mkdir -p "$(dirname "$out")"
  jq --argjson scaffold "$scaffold" '
    del(.mcpServers)
    | .hooks = (.hooks // {})
    | .hooks.SessionStart = (
        ((.hooks.SessionStart // []) + $scaffold)
        | reduce .[] as $e ([]; if any(.[]; . == $e) then . else . + [$e] end)
      )
    | (if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end)
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  ' "$merged" >"$out"
}

# --- 4. .mcp.json (mirror; per-server last-layer-wins so args do not double) -
# Inputs per layer, in order: the mcpServers lifted out of that layer's
# settings.json (mirror_settings strips them there), then the layer's own
# .mcp.json (so an explicit .mcp.json wins over settings.json within a layer).
# Component layers come after root, so component wins across layers.
mirror_mcp() {
  local rel=".mcp.json" out="$DEST/.mcp.json"
  local layer s m tmp parts=()
  for layer in "${SRC_LAYERS[@]}"; do
    # mcpServers lifted out of this layer's settings.json
    s="$layer/.claude/settings.json"
    if [ -f "$s" ] && jq -e '.mcpServers | objects | length > 0' "$s" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      TMPFILES+=("$tmp")
      jq '{mcpServers: .mcpServers}' "$s" >"$tmp"
      parts+=("$tmp")
    fi
    # this layer's own .mcp.json (wins over its settings.json mcpServers)
    m="$layer/$rel"
    if [ -f "$m" ]; then
      if jq -e . "$m" >/dev/null 2>&1; then
        parts+=("$m")
      else
        log "warn: malformed JSON skipped: $m"
      fi
    fi
  done
  if [ ${#parts[@]} -eq 0 ]; then
    if [ -e "$out" ]; then rm -f "$out"; fi # mirror: source dropped it -> remove
    return 0
  fi
  jq -s 'reduce .[] as $o ({}; . * $o)' "${parts[@]}" >"$out"
}

# --- 5. relative-path referenced command / executable files -----------------
# Extract candidate path tokens from a layer's settings.json + .mcp.json,
# tokenizing shell-command strings with python3/shlex.
collect_refs() { # collect_refs <layer> -> prints one token per line
  local layer="$1" s="$1/.claude/settings.json" m="$1/.mcp.json"
  {
    if [ -f "$s" ]; then
      jq -r '
        [ (.hooks // {} | .[]? | .[]? | .hooks[]? | .command),
          (.statusLine?.command), (.fileSuggestion?.command) ]
        | map(select(type == "string")) | .[]' "$s" 2>/dev/null || true
    fi
    if [ -f "$m" ]; then
      jq -r '
        (.mcpServers // {}) | to_entries[]
        | (.value.command), (.value.args[]?)
        | select(type == "string")' "$m" 2>/dev/null || true
    fi
  } | python3 -c '
import sys, shlex
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    try:
        toks = shlex.split(line)
    except ValueError:
        toks = [line]
    for t in toks:
        print(t)
'
}

copy_referenced_files() {
  local i layer rel src dst tok
  for i in "${!SRC_LAYERS[@]}"; do
    layer="${SRC_LAYERS[$i]}"
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
      '$'*) continue ;;      # runtime variable (e.g. the scaffolding hook)
      /* | '~'*) continue ;; # absolute path — not portable
      */*) : ;;              # relative path with a slash — candidate
      *) continue ;;         # bare word / flag / PATH command
      esac
      rel="${tok#./}"
      case "$rel" in
      .claude/hooks/session-start.sh | .claude/settings.json | .mcp.json | \
        .claude/hooks/session-start/* | conf/* | tools/*)
        log "warn: refused to overwrite scaffolding via reference: $rel"
        continue
        ;;
      esac
      src="$layer/$rel"
      [ -f "$src" ] || continue
      dst="$DEST/$rel"
      mkdir -p "$(dirname "$dst")"
      rsync -a "$src" "$dst"
      chmod +x "$dst" 2>/dev/null || true
    done < <(collect_refs "$layer") # root then component: component wins
  done
}

# --- 6. directory mirror (union of layers, with deletions) ------------------
mirror_dir() { # mirror_dir <relpath>
  local rel="$1" layer staging out copied=false
  staging="$(mktemp -d)"
  TMPDIRS+=("$staging")
  for layer in "${SRC_LAYERS[@]}"; do
    if [ -d "$layer/$rel" ]; then
      rsync -a "$layer/$rel/" "$staging/" # component overlays root
      copied=true
    fi
  done
  out="$DEST/$rel"
  if [ "$copied" = true ]; then
    mkdir -p "$out"
    rsync -a --delete "$staging/" "$out/" # exact union; prune stale files
  else
    if [ -e "$out" ]; then rm -rf "$out"; fi # mirror: source dropped it
  fi
}

# --- 7. project CLAUDE.md -> separate imported file -------------------------
# Write the project repo's mirrored CLAUDE.md content (root layer, optionally
# + component layer) to its own file, .claude/merged-agent-instructions.md,
# which the agents repo's hand-maintained root CLAUDE.md @imports. The root
# CLAUDE.md is never read or written here. When no source layer has a
# CLAUDE.md, a marker-comment-only placeholder is written (never deleted) so
# the root CLAUDE.md's @import never dangles.
MERGED_MARKER='<!-- auto-generated by merge-agent-settings.sh; do not edit -->'

merge_claude_md() {
  local out="$DEST/.claude/merged-agent-instructions.md" body i layer label f
  body="$(mktemp)"
  TMPFILES+=("$body")
  : >"$body"
  for i in "${!SRC_LAYERS[@]}"; do
    layer="${SRC_LAYERS[$i]}"
    label="${SRC_LABELS[$i]}"
    f="$layer/CLAUDE.md"
    [ -s "$f" ] || continue
    {
      printf '## From %s/%s (%s)\n\n' "$AGENTS_GIT_ACCOUNT" "$AGENTS_GIT_REPO" "$label"
      cat "$f"
      printf '\n'
    } >>"$body"
  done

  mkdir -p "$(dirname "$out")"
  {
    printf '%s\n' "$MERGED_MARKER"
    if [ -s "$body" ]; then
      printf '\n'
      cat "$body"
    fi
  } >"$out"
}

# --- run filesystem mutations (git strictly last) ---------------------------
mirror_settings
mirror_mcp
copy_referenced_files
mirror_dir .claude/agents
mirror_dir .agents
mirror_dir .github
merge_claude_md

# --- 8. commit + push to the project's settings branch ----------------------
# The mirrored settings must land on a STABLE per-project branch so any future
# web session started from it picks them up. Do NOT push to whatever branch the
# session is currently checked out on: the web harness starts sessions on
# ephemeral claude/<id> branches, which are the wrong home for shared settings
# (and "the branch this session started from" is unrecoverable from git once
# that branch gets its own commits, e.g. on resume).
#
# Derive the target from the project identity (repo + optional component) so it
# is independent of the current checkout. The component is joined with a HYPHEN,
# not a slash, so a repo's project-level branch never collides with a component
# one: git refs cannot be both `geowep` and `geowep/ng` (a directory/file
# conflict that makes the project-level push fail whenever a component branch
# exists), but `geowep` and `geowep-ng` coexist fine.
#   GeoWEP              -> geowep
#   GeoWEP + docker/ng  -> geowep-ng
# The component part is the LAST path segment of the component dir, but with a
# redundant leading "<repo>-" stripped (case-insensitively): some layouts repeat
# the project name in the component dir so it is recognizable when a dev opens it
# as an IDE root (components/geowep-ng), and we want that to still yield geowep-ng,
# not geowep-geowep-ng.
#   GeoWEP + components/geowep-ng -> geowep-ng  (not geowep-geowep-ng)
# AGENTS_SETTINGS_BRANCH overrides the scheme when it does not fit.
target_branch="${AGENTS_SETTINGS_BRANCH:-}"
if [ -z "$target_branch" ]; then
  repo="${AGENTS_GIT_REPO,,}"
  target_branch="$repo"
  if [ -n "$COMPONENT_REL" ]; then
    seg="${COMPONENT_REL##*/}"
    case "${seg,,}" in "$repo"-*) seg="${seg:$((${#repo} + 1))}" ;; esac
    target_branch="$target_branch-$seg"
  fi
fi

# Remember where the session's checked-out branch started, so we can roll it
# back below (whether or not the push succeeds). Captured before any commit
# moves it.
session_head="$(git -C "$DEST" rev-parse HEAD)"

git -C "$DEST" add -A
if git -C "$DEST" diff --cached --quiet; then
  log "no changes to commit"
  exit 0
fi

msg="chore(agents): mirror agent settings from $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO"
if [ -n "$COMPONENT_REL" ]; then msg="$msg (component: $COMPONENT_REL)"; fi
msg="$msg @ $SRC_SHA"

# Author the mirror commit under the identity captured by session-start.sh
# before it set the Claude identity for the harness backstop commit — i.e. the
# identity the environment (the Claude Code Web harness) had configured at
# session start. Nothing is hardcoded to a person: with no captured identity
# (env configured none) this falls back to the Claude identity now in global
# config.
git -C "$DEST" \
  -c user.name="${AGENTS_ORIG_GIT_NAME:-Claude}" \
  -c user.email="${AGENTS_ORIG_GIT_EMAIL:-noreply@anthropic.com}" \
  commit -m "$msg" >&2
# Plain (non-forced) push: a fast-forward onto the settings branch succeeds; if
# the branch has diverged (or the name is invalid/colliding) it fails. We do NOT
# let a failure abort the script (it would skip the reset below and strand the
# commit) — we capture it and warn instead.
if git -C "$DEST" push origin "HEAD:$target_branch" >&2; then
  log "committed and pushed to $target_branch"
else
  log "WARNING: push to settings branch '$target_branch' FAILED — settings were"
  log "  not updated this session. The mirror is idempotent and will retry next"
  log "  session; if it keeps failing, check the branch name / push permissions"
  log "  or set AGENTS_SETTINGS_BRANCH to override. Discarding the local commit"
  log "  anyway (see below)."
fi

# Roll the session's checked-out branch back to where it started, discarding the
# local merge commit. UNCONDITIONAL — whether or not the push succeeded — so the
# ephemeral claude/<session> branch never carries a commit that Claude Code Web's
# end-of-session persistence would push as a redundant claude/<session> branch.
# There is no loss: on success the settings live on the settings branch (their
# permanent home, which future sessions clone from); on failure the mirror is
# idempotent and regenerates next session. Either way the current session keeps
# using the settings its own clone started with — it never consumes this commit.
git -C "$DEST" reset --hard "$session_head" >&2
log "reset session branch to $session_head"
