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

sudo apt update
sudo apt install -y rsync jq python3

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
# is independent of the current checkout: GeoWEP + docker/ng -> geowep/ng.
# AGENTS_SETTINGS_BRANCH overrides it when the convention does not fit.
target_branch="${AGENTS_SETTINGS_BRANCH:-}"
if [ -z "$target_branch" ]; then
  target_branch="${AGENTS_GIT_REPO,,}"
  [ -n "$COMPONENT_REL" ] && target_branch="$target_branch/${COMPONENT_REL##*/}"
fi

git -C "$DEST" add -A
if git -C "$DEST" diff --cached --quiet; then
  log "no changes to commit"
  exit 0
fi

msg="chore(agents): mirror agent settings from $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO"
if [ -n "$COMPONENT_REL" ]; then msg="$msg (component: $COMPONENT_REL)"; fi
msg="$msg @ $SRC_SHA"

git -C "$DEST" \
  -c user.name="agents session-start" \
  -c user.email="wouter.scherphof@merkator.com" \
  commit -m "$msg" >&2
# Plain (non-forced) push: a fast-forward onto the settings branch succeeds; if
# that branch has diverged it fails loudly rather than clobbering other work.
git -C "$DEST" push origin "HEAD:$target_branch" >&2
log "committed and pushed to $target_branch"
