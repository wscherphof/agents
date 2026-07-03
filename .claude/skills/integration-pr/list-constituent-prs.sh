#!/usr/bin/env bash
# list-constituent-prs.sh — list the PRs merged into the integration branch but
# not yet in the target branch, oldest first, one per line, each already
# prefixed for the host (#<n> on GitHub, !<n> on Azure DevOps) so it renders as
# a full PR link when dropped verbatim into the integration PR's description.
#
# Usage (paths/branches of the CLONED PROJECT repo, not the agents workspace):
#   list-constituent-prs.sh <project-dir> <target-branch> <integration-branch>
#
# It reads the merge/squash commit messages in
# origin/<target>..origin/<integration> (fetch first!) and pulls PR numbers out
# of them. Host — and therefore both the commit-message pattern and the output
# prefix — is taken from the env the session-start hook sets:
#   AZURE_DEVOPS_EXT_PAT set          -> Azure DevOps
#       commit: "Merged PR <n>: <title>"           ref: !<n>
#   GITHUB_PERSONAL_ACCESS_TOKEN set  -> GitHub
#       merge:  "Merge pull request #<n> from …"    ref: #<n>
#       squash: "<title> (#<n>)"                     ref: #<n>
#
# Prints nothing (exit 0) when the range holds no recognizable PR merges — the
# caller should then fall back to the platform CLI (see SKILL.md).

set -euo pipefail

die() { echo "list-constituent-prs: $*" >&2; exit 1; }

[ $# -eq 3 ] || die "usage: list-constituent-prs.sh <project-dir> <target-branch> <integration-branch>"
proj=$1
target=$2
integration=$3

git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git work tree: $proj"
git -C "$proj" rev-parse --verify --quiet "origin/$target" >/dev/null \
  || die "origin/$target not found in $proj (fetch first?)"
git -C "$proj" rev-parse --verify --quiet "origin/$integration" >/dev/null \
  || die "origin/$integration not found in $proj (fetch first?)"

range="origin/$target..origin/$integration"

if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
  # Azure DevOps completed-PR merge commits: "Merged PR 1234: <title>".
  git -C "$proj" log --format='%s' --reverse "$range" \
    | sed -nE 's/^Merged PR ([0-9]+):.*/!\1/p' \
    | awk '!seen[$0]++'
elif [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
  # GitHub: merge-commit PRs ("Merge pull request #<n>") and squash/rebase PRs
  # (number trailing the subject as "(#<n>)"). One pass so chronological order
  # survives even if the repo mixes merge strategies; awk dedupes, keeping the
  # first occurrence.
  git -C "$proj" log --format='%s' --reverse "$range" \
    | sed -nE 's/.*Merge pull request #([0-9]+).*/#\1/p; s/.*\(#([0-9]+)\)[[:space:]]*$/#\1/p' \
    | awk '!seen[$0]++'
else
  die "neither AZURE_DEVOPS_EXT_PAT nor GITHUB_PERSONAL_ACCESS_TOKEN is set — cannot determine host"
fi
