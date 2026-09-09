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
#
# Why mirror at all, instead of just instructing Claude to read the project's
# settings out of src/? Because this hook runs AFTER the harness has already
# loaded settings.json/.mcp.json/agents/skills/commands for this session — the
# mirror's payoff is the push to the settings branch, which configures the NEXT
# session. Most of what is mirrored is consumed by the harness, not the model,
# and no instruction can substitute for startup configuration. Decided
# 2026-08-24 to keep the mirror whole; see
# docs/decisions/2026-08-24-keep-the-settings-mirror.md.

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
# mirror_dir <relpath> [rsync-exclude ...]
# Optional trailing args are rsync --exclude patterns (relative to <relpath>)
# applied to BOTH the staging copy and the --delete sync, so matched entries in
# the destination are never overwritten NOR pruned. This is how the agents repo
# protects its OWN content that happens to live under a mirrored dir — notably
# its scaffolding skills under .claude/skills/ (see the call site), which the
# project source doesn't have and must not be deleted from the settings branch.
mirror_dir() {
  local rel="$1"
  shift
  local rsync_excl=() e
  for e in "$@"; do rsync_excl+=(--exclude="$e"); done
  local layer staging out copied=false
  staging="$(mktemp -d)"
  TMPDIRS+=("$staging")
  for layer in "${SRC_LAYERS[@]}"; do
    if [ -d "$layer/$rel" ]; then
      rsync -a "${rsync_excl[@]}" "$layer/$rel/" "$staging/" # component overlays root
      copied=true
    fi
  done
  out="$DEST/$rel"
  if [ "$copied" = true ]; then
    mkdir -p "$out"
    rsync -a --delete "${rsync_excl[@]}" "$staging/" "$out/" # exact union; prune stale (except excludes)
  elif [ ${#rsync_excl[@]} -gt 0 ] && [ -d "$out" ]; then
    # Source dropped the dir, but excludes protect content living here: prune
    # everything except the protected entries rather than removing the dir.
    rsync -a --delete "${rsync_excl[@]}" "$staging/" "$out/"
  elif [ -e "$out" ]; then
    rm -rf "$out" # mirror: source dropped it (nothing protected here)
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
# Grouped into a function because section 9 may run it twice: if the push loses
# a race to a concurrent session for the same project, the mirror is rebuilt on
# the new tip of the settings branch and pushed again. Every step recomputes its
# output from the project's checked-in files, so re-running is both safe and
# cheap — filesystem only, no network.
run_mirror() {
  mirror_settings
  mirror_mcp
  copy_referenced_files
  mirror_dir .claude/agents
  # .claude/skills is shared: the agents repo keeps its OWN scaffolding skills
  # here (commit-push-propagate, integration-pr) alongside any the project
  # ships. Exclude them so the project mirror never prunes them off the settings
  # branch — integration-pr in particular is used by remote sessions. Keep this
  # list in sync with propagate.sh's scaffolding-skills case.
  mirror_dir .claude/skills commit-push-propagate/ integration-pr/
  mirror_dir .claude/commands
  mirror_dir .agents
  mirror_dir .github
  merge_claude_md
}

# --- 8. settings branch: derive the target, sync the local checkout ---------
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

# Bring the checked-out branch up to date with the settings branch BEFORE
# mirroring onto it. Fast-forward only: never a rebase, reset or force-push.
#
# Two things go wrong without this, and both did:
#
#  * The push in section 9 is a plain fast-forward push, so a checkout that is
#    BEHIND the settings branch can never publish its mirror. Nothing else ever
#    advances a container's local settings branch either — the project clone
#    under src/ gets `pull --ff-only` from session-start.sh, the agents repo at
#    the workspace root got nothing, and on resume the harness re-checks-out the
#    same local ref. So a container that started seconds before a concurrent
#    session's mirror landed stayed stuck behind that commit for its whole life:
#    re-mirroring, failing to push and discarding the result on every hook run.
#  * The mirror is computed against whatever the tree holds, so an out-of-date
#    checkout also means the session itself runs on settings older than the ones
#    already published on its own settings branch.
#
# A non-fast-forward here is NOT an error: the checkout may legitimately be
# ahead (its own commits are not pushed yet), or be an ephemeral claude/<id>
# branch the session has already committed to, or the tree may be dirty on a
# resume. Log it and mirror onto the checkout as-is; the push decides.
#
# Also records whether the branch exists on origin at all, which the commit step
# needs: with no branch to fetch there is nothing to fast-forward to, and the
# push has to happen even when the mirror produces no diff.
settings_branch_on_origin=
sync_settings_branch() {
  if ! git -C "$DEST" fetch origin "$target_branch" >&2; then
    settings_branch_on_origin=
    log "no '$target_branch' branch on origin yet — this is its first mirror"
    return 0
  fi
  settings_branch_on_origin=1
  if git -C "$DEST" merge --ff-only FETCH_HEAD >&2; then
    log "checkout is in sync with origin/$target_branch"
  else
    log "checkout is not a fast-forward of origin/$target_branch — mirroring onto it as-is"
  fi
}

# --- 9. commit + push to the project's settings branch ----------------------
# Which branch the session is on decides what happens to the mirror commit
# after a successful push — see the rollback at the end.
current_branch="$(git -C "$DEST" rev-parse --abbrev-ref HEAD)"

# Up to two attempts. A concurrent session for the same project can push its own
# mirror in the window between our fetch and our push; that is not hypothetical,
# two containers starting ~25 s apart have collided exactly there. On a lost
# race, drop our commit, sync to the new tip, rebuild the mirror and push once
# more. A second failure is reported and left alone — the next session now
# fetches the branch first, so it retries from an up-to-date base.
pushed=
mirror_committed=
for attempt in 1 2; do
  sync_settings_branch

  # The commit the mirror is built on, and where the checked-out branch is
  # rolled back to. Captured AFTER the sync, so a fast-forward is KEPT — that is
  # how this session picks up settings pushed by earlier sessions — and only our
  # own mirror commit is ever discarded.
  base_head="$(git -C "$DEST" rev-parse HEAD)"

  run_mirror

  git -C "$DEST" add -A
  if git -C "$DEST" diff --cached --quiet; then
    log "no changes to commit"
    # There may still be nothing on origin to start the NEXT session from: the
    # first mirror for a project, or a freshly pointed AGENTS_SETTINGS_BRANCH,
    # where the mirror happens to produce no diff against this checkout. Create
    # the branch from HEAD in that case — with the branch already on origin,
    # "no diff" genuinely means it is already up to date.
    if [ -z "$settings_branch_on_origin" ]; then
      if git -C "$DEST" push origin "HEAD:$target_branch" >&2; then
        log "created settings branch '$target_branch' at HEAD (no mirror diff)"
      else
        log "failed to create settings branch '$target_branch'"
        break
      fi
    fi
    pushed=1
    break
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

  # Plain (non-forced) push: a fast-forward onto the settings branch succeeds;
  # if the branch has moved on (or the name is invalid/colliding) it fails. We
  # do NOT let a failure abort the script — it would skip the rollback below and
  # strand the commit — we capture it and retry/warn instead.
  if git -C "$DEST" push origin "HEAD:$target_branch" >&2; then
    log "committed and pushed to $target_branch"
    pushed=1
    mirror_committed=1
    break
  fi

  log "push to settings branch '$target_branch' was rejected (attempt $attempt/2)"
  git -C "$DEST" reset --hard "$base_head" >&2
done

if [ -z "$pushed" ]; then
  warning="the freshly merged agent settings could NOT be pushed to settings branch '$target_branch', so this session (and the next, until a push succeeds) runs on whatever settings that branch already carried"
  log "WARNING: $warning"
  log "  The mirror is idempotent and the next session fetches '$target_branch'"
  log "  before mirroring, so it retries from an up-to-date base. If it keeps"
  log "  failing, check the branch name / push permissions, or set"
  log "  AGENTS_SETTINGS_BRANCH to override."
  # Also surface it in the hook's single context line: a silently stale mirror
  # is exactly the kind of degraded session the status line exists to report.
  if [ -n "${AGENTS_MERGE_WARNING_FILE:-}" ]; then
    printf '%s\n' "$warning" >"$AGENTS_MERGE_WARNING_FILE"
  fi
fi

# Roll the session's checked-out branch back, discarding the local mirror
# commit — but NOT when the session is checked out on the settings branch
# itself.
#
# The reason to roll back at all is the ephemeral claude/<id> branch the web
# harness may start a session on: a mirror commit left there would be pushed as
# a redundant claude/<session> branch by end-of-session persistence. That does
# not apply when the checkout IS the settings branch (the harness does this when
# it is the session's designated branch): the commit has just been pushed to
# exactly that branch, so keeping it is what makes the working tree agree with
# the remote. Resetting it away would put the session back on settings it had
# already superseded — the bug this section used to have.
#
# On the failure path the loop has already reset to $base_head, so the reset
# below is a no-op there; on success without a commit ("no changes") $base_head
# is still HEAD and it is a no-op too.
if [ -n "$pushed" ] && [ "$current_branch" = "$target_branch" ]; then
  if [ -n "$mirror_committed" ]; then
    log "keeping the mirror commit: checked out on settings branch '$target_branch'"
  fi
else
  git -C "$DEST" reset --hard "$base_head" >&2
  log "reset session branch to $base_head"
fi
