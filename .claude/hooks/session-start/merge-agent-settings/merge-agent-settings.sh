#!/usr/bin/env bash
# Mirror agent settings and instructions from the cloned source project repo
# (its root, plus an optional monorepo component dir layered on top) INTO the
# agents repo at $CLAUDE_PROJECT_DIR, then commit and push to the current branch.
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

# --- temp bookkeeping -------------------------------------------------------
TMPFILES=()
TMPDIRS=()
cleanup() {
  [ ${#TMPFILES[@]} -gt 0 ] && rm -f -- "${TMPFILES[@]}" 2>/dev/null || true
  [ ${#TMPDIRS[@]} -gt 0 ] && rm -rf -- "${TMPDIRS[@]}" 2>/dev/null || true
}
trap cleanup EXIT

log() { printf 'merge-agent-settings: %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# --- 1. validate ------------------------------------------------------------
for v in AGENTS_REPO_DIR CLAUDE_PROJECT_DIR AGENTS_GIT_ACCOUNT AGENTS_GIT_REPO; do
  [ -n "${!v:-}" ] || die "$v is not set"
done
[ -d "$AGENTS_REPO_DIR" ]    || die "AGENTS_REPO_DIR does not exist: $AGENTS_REPO_DIR"
[ -d "$CLAUDE_PROJECT_DIR" ] || die "CLAUDE_PROJECT_DIR does not exist: $CLAUDE_PROJECT_DIR"

DEST="$CLAUDE_PROJECT_DIR"
AGENTS_COMPONENT_DIR="${AGENTS_COMPONENT_DIR:-$AGENTS_REPO_DIR}"

repo_real="$(realpath "$AGENTS_REPO_DIR")"
comp_real="$(realpath "$AGENTS_COMPONENT_DIR")"

# --- 2. source layers (root, optionally + component) ------------------------
SRC_LAYERS=( "$AGENTS_REPO_DIR" )
SRC_LABELS=( "root" )
COMPONENT_REL=""
if [ "$comp_real" != "$repo_real" ]; then
  case "$comp_real/" in
    "$repo_real"/*) : ;;
    *) die "component dir escapes repo dir: $AGENTS_COMPONENT_DIR" ;;
  esac
  COMPONENT_REL="$(realpath --relative-to="$AGENTS_REPO_DIR" "$AGENTS_COMPONENT_DIR")"
  SRC_LAYERS+=( "$AGENTS_COMPONENT_DIR" )
  SRC_LABELS+=( "component: $COMPONENT_REL" )
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

  merged="$(mktemp)"; TMPFILES+=("$merged")
  if [ ${#inputs[@]} -gt 0 ]; then
    jq -n "$DEEPMERGE" "${inputs[@]}" > "$merged"
  else
    echo '{}' > "$merged"
  fi

  # Scaffolding = SessionStart entries that invoke session-start.sh, taken from
  # the committed base (deterministic; immune to a prior partial run).
  scaffold="$(git -C "$DEST" show "HEAD:$rel" 2>/dev/null \
    | jq -c '[ .hooks.SessionStart[]?
               | select(any(.hooks[]?.command // ""; test("session-start\\.sh"))) ]' 2>/dev/null)"
  [ -n "$scaffold" ] || scaffold='[]'

  mkdir -p "$(dirname "$out")"
  jq --argjson scaffold "$scaffold" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = (
        ((.hooks.SessionStart // []) + $scaffold)
        | reduce .[] as $e ([]; if any(.[]; . == $e) then . else . + [$e] end)
      )
    | (if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end)
    | (if (.hooks | length) == 0 then del(.hooks) else . end)
  ' "$merged" > "$out"
}

# --- 4. .mcp.json (mirror; per-server last-layer-wins so args do not double) -
mirror_mcp() {
  local rel=".mcp.json" out="$DEST/.mcp.json"
  local inputs=()
  mapfile -t inputs < <(json_inputs "$rel")
  if [ ${#inputs[@]} -eq 0 ]; then
    [ -e "$out" ] && rm -f "$out"   # mirror: source dropped it -> remove
    return 0
  fi
  jq -s 'reduce .[] as $o ({}; . * $o)' "${inputs[@]}" > "$out"
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
        '$'*)       continue ;;   # runtime variable (e.g. the scaffolding hook)
        /*|'~'*)    continue ;;   # absolute path — not portable
        */*)        : ;;          # relative path with a slash — candidate
        *)          continue ;;   # bare word / flag / PATH command
      esac
      rel="${tok#./}"
      case "$rel" in
        .claude/hooks/session-start.sh|.claude/settings.json|.mcp.json \
          | .claude/hooks/session-start/*)
          log "warn: refused to overwrite scaffolding via reference: $rel"
          continue ;;
      esac
      src="$layer/$rel"
      [ -f "$src" ] || continue
      dst="$DEST/$rel"
      mkdir -p "$(dirname "$dst")"
      rsync -a "$src" "$dst"
      chmod +x "$dst" 2>/dev/null || true
    done < <(collect_refs "$layer")   # root then component: component wins
  done
}

# --- 6. directory mirror (union of layers, with deletions) ------------------
mirror_dir() { # mirror_dir <relpath>
  local rel="$1" layer staging out copied=false
  staging="$(mktemp -d)"; TMPDIRS+=("$staging")
  for layer in "${SRC_LAYERS[@]}"; do
    if [ -d "$layer/$rel" ]; then
      rsync -a "$layer/$rel/" "$staging/"   # component overlays root
      copied=true
    fi
  done
  out="$DEST/$rel"
  if [ "$copied" = true ]; then
    mkdir -p "$out"
    rsync -a --delete "$staging/" "$out/"   # exact union; prune stale files
  else
    [ -e "$out" ] && rm -rf "$out"          # mirror: source dropped it
  fi
}

# --- 7. CLAUDE.md (managed auto-generated block) ----------------------------
CLAUDE_BEGIN='<!-- BEGIN MERGED AGENT INSTRUCTIONS (auto-generated, do not edit) -->'
CLAUDE_END='<!-- END MERGED AGENT INSTRUCTIONS -->'

merge_claude_md() {
  local out="$DEST/CLAUDE.md" base body i layer label f
  base="$(mktemp)"; TMPFILES+=("$base")
  : > "$base"
  if [ -f "$out" ]; then
    CLAUDE_BEGIN="$CLAUDE_BEGIN" CLAUDE_END="$CLAUDE_END" \
      python3 - "$out" > "$base" <<'PY'
import os, sys
begin, end = os.environ["CLAUDE_BEGIN"], os.environ["CLAUDE_END"]
text = open(sys.argv[1], encoding="utf-8").read()
i = text.find(begin)
if i != -1:
    j = text.find(end, i)
    if j != -1:
        pre = text[:i].rstrip("\n")
        post = text[j + len(end):].lstrip("\n")
        text = pre + ("\n" + post if post else "")
sys.stdout.write(text)
PY
  fi

  body="$(mktemp)"; TMPFILES+=("$body")
  : > "$body"
  for i in "${!SRC_LAYERS[@]}"; do
    layer="${SRC_LAYERS[$i]}"; label="${SRC_LABELS[$i]}"
    f="$layer/CLAUDE.md"
    [ -s "$f" ] || continue
    { printf '## From %s/%s (%s)\n\n' "$AGENTS_GIT_ACCOUNT" "$AGENTS_GIT_REPO" "$label"
      cat "$f"; printf '\n'; } >> "$body"
  done

  if [ -s "$body" ]; then
    { if [ -s "$base" ]; then cat "$base"; printf '\n'; fi
      printf '%s\n\n' "$CLAUDE_BEGIN"
      cat "$body"
      printf '%s\n' "$CLAUDE_END"; } > "$out"
  elif [ -s "$base" ]; then
    cat "$base" > "$out"
  else
    [ -e "$out" ] && rm -f "$out"
  fi
}

# --- run filesystem mutations (git strictly last) ---------------------------
mirror_settings
mirror_mcp
copy_referenced_files
mirror_dir .claude/agents
mirror_dir .agents
mirror_dir .github
merge_claude_md

# --- 8. commit + push to the current branch of the agents repo --------------
branch="$(git -C "$DEST" rev-parse --abbrev-ref HEAD)"
git -C "$DEST" add -A
if git -C "$DEST" diff --cached --quiet; then
  log "no changes to commit"
  exit 0
fi

msg="chore(agents): mirror agent settings from $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO"
[ -n "$COMPONENT_REL" ] && msg="$msg (component: $COMPONENT_REL)"
msg="$msg @ $SRC_SHA"

git -C "$DEST" \
  -c user.name="agents session-start" \
  -c user.email="wouter.scherphof@merkator.com" \
  commit -m "$msg" >&2
git -C "$DEST" push origin "HEAD:$branch" >&2
log "committed and pushed to $branch"
