#!/usr/bin/env bash
#
# Propagate a source branch's scaffolding commits onto downstream settings
# branches, one commit at a time. Implements step 5 of the commit-push-propagate
# skill. Run from the agents-repo root.
#
#   propagate.sh <SRC> <branch> [<branch> ...]
#
# For each target branch it aligns the local branch to origin, then replays
# every commit the branch is missing (computed by patch identity with
# `git cherry`, oldest-first). Each commit is handled on its own so clean picks
# bank individually instead of a whole batch rolling back on one conflict:
#
#   * applies cleanly            -> keep it (real new content on files the
#                                   branch does not customize)
#   * conflicts on shared        -> the conflicted file is agents-repo
#     scaffolding                   scaffolding the branch must NOT customize
#                                   (.claude/hooks/**, .claude/skills/**,
#                                   tools/**). The source is
#                                   authoritative for these, so resolve toward
#                                   THEIRS and commit — this catches up a branch
#                                   that got an earlier iteration of the change
#                                   under a different patch-id (which `git
#                                   cherry` still lists, but which keeping-ours
#                                   would silently leave stale as "superseded").
#   * conflicts, superseded      -> the branch already has this change via a
#                                   different commit (patch-id differs, so
#                                   `git cherry` still lists it); keeping the
#                                   branch's (customized) version of the
#                                   conflicted files leaves no net change ->
#                                   skip it, don't create an empty commit
#   * conflicts, genuine         -> a customized file diverged, keeping the
#                                   branch's version still leaves a net change
#                                   (the commit also brings content the branch
#                                   lacks) -> DON'T guess: abort that commit,
#                                   stop this branch, and report it for a human
#                                   hand-merge. Commits already banked are kept
#                                   and pushed; the remaining ones flow on a
#                                   re-run once the blocker is resolved.
#
# Conflicts here are normal, not exceptional: settings branches customize files
# like conf/.env, README.md and conf/COMPONENT.sh, so scaffolding commits that
# touch those routinely collide. Keeping the branch's version is the safe
# default for a customized file. Shared scaffolding (the hooks and tools that
# must be identical on every branch — see the merge hook's own refuse-list) is
# the exception: there the source wins, so an older iteration on a branch is
# synced up instead of being mistaken for a superseded change and left stale.

set -uo pipefail

SRC="${1:?usage: propagate.sh <SRC> <branch>...}"; shift
BRANCHES=("$@")
[ "${#BRANCHES[@]}" -gt 0 ] || { echo "no target branches given — nothing to propagate"; exit 0; }

git fetch origin --prune --quiet

blocked_any=0
declare -A SUMMARY

for b in "${BRANCHES[@]}"; do
  echo "==================== $b ===================="
  git checkout -q -B "$b" "origin/$b" || { echo "  cannot check out $b"; SUMMARY[$b]="error: checkout failed"; blocked_any=1; continue; }

  picks=$(git cherry "origin/$b" "$SRC" | awk '/^\+/ {print $2}')   # oldest-first SHAs missing on $b
  if [ -z "$picks" ]; then
    echo "  already up to date"; SUMMARY[$b]="up to date"; continue
  fi

  applied=0 skipped=0 blocker=""
  for s in $picks; do
    subj=$(git show -s --format='%h %s' "$s")
    if git cherry-pick "$s" >/dev/null 2>&1; then
      echo "  pick $subj"; applied=$((applied+1)); continue
    fi
    # cherry-pick did not complete: either a merge conflict or an empty result.
    uf=$(git diff --name-only --diff-filter=U)
    # Resolve each conflicted file by its role. Shared scaffolding
    # (.claude/hooks/**, .claude/skills/**, tools/**) must be identical on every
    # branch — none of it is mirrored from the project, and the merge hook forbids
    # projects from overwriting the hooks/tools — so the source is authoritative:
    # take THEIRS, which syncs up a branch carrying an earlier iteration. Any
    # other file may be a legitimate per-branch customization (conf/.env, mirrored
    # settings under .claude/agents|.agents|.github, .mcp.json, …): keep OURS, the
    # safe default.
    customized_conflict=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
      .claude/hooks/* | .claude/skills/* | tools/*) git checkout --theirs -- "$f" ;;
      *) git checkout --ours -- "$f"; customized_conflict=1 ;;
      esac
      git add -- "$f"
    done <<<"$uf"
    if git diff --cached --quiet HEAD; then
      # nothing left to add once the branch keeps its own version -> superseded
      git cherry-pick --skip >/dev/null 2>&1 || { git cherry-pick --abort >/dev/null 2>&1; git reset -q --hard HEAD; }
      echo "  skip $subj   [superseded — already present via another commit]"
      skipped=$((skipped+1))
    elif [ "$customized_conflict" -eq 0 ]; then
      # the only net change is shared scaffolding taken from the source (and/or
      # cleanly-merged files) — safe to apply automatically, no human needed.
      git -c core.editor=true cherry-pick --continue >/dev/null 2>&1
      echo "  pick $subj   [scaffolding synced to source]"
      applied=$((applied+1))
    else
      # a customized file diverged and keeping the branch's version still leaves
      # net change (the commit brings content the branch lacks) — a genuine
      # divergence. Do not decide; leave it for a human.
      git cherry-pick --abort >/dev/null 2>&1
      echo "  STOP $subj"
      echo "       conflicts on: $(echo $uf | tr '\n' ' ')— needs hand-merge; stopping $b here"
      blocker="$subj on: $(echo $uf | tr '\n' ' ')"
      break
    fi
  done

  if [ "$applied" -gt 0 ]; then
    git push origin "$b" 2>&1 | tail -1
  else
    echo "  (nothing applied — nothing to push)"
  fi
  msg="applied=$applied skipped=$skipped"
  [ -n "$blocker" ] && { msg="$msg BLOCKED at $blocker"; blocked_any=1; }
  SUMMARY[$b]="$msg"
done

git checkout -q "$SRC"

echo
echo "=========== SUMMARY (source: $SRC) ==========="
for b in "${BRANCHES[@]}"; do printf "  %-14s %s\n" "$b" "${SUMMARY[$b]:-?}"; done
echo "back on: $(git rev-parse --abbrev-ref HEAD)"

exit "$blocked_any"
