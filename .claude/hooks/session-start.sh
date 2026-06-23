#!/usr/bin/env bash

set -uo pipefail

# Mandatory.
AGENTS_GIT_ACCOUNT=merkatordev
AGENTS_GIT_REPO=GeoWEP

# Optional (for a component in a monorepo).
AGENTS_COMPONENT_DIR="docker/ng"
AGENTS_COMPONENT_DIR=""

# You should set either AZURE_DEVOPS_EXT_PAT or GITHUB_PERSONAL_ACCESS_TOKEN in
# your environment before starting the session. The script will use whichever is
# set to construct the repo URL for cloning.

[ -n "$AZURE_DEVOPS_EXT_PAT" ] &&
AGENTS_REPO_URL=https://$AZURE_DEVOPS_EXT_PAT@dev.azure.com/$AGENTS_GIT_ACCOUNT/_git/$AGENTS_GIT_REPO

[ -n "$GITHUB_PERSONAL_ACCESS_TOKEN" ] &&
AGENTS_REPO_URL=https://$GITHUB_PERSONAL_ACCESS_TOKEN@github.com/$AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO.git


# Child scripts are setup steps. Send their stdout to stderr so it stays out of
# Claude's context (SessionStart adds hook stdout to context) while remaining
# visible in the transcript and under --debug.
(
  session_start_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/session-start" && pwd)"
  src_dir="$CLAUDE_PROJECT_DIR/src"
  AGENTS_REPO_DIR=$src_dir/$AGENTS_GIT_REPO
  AGENTS_COMPONENT_DIR=$(realpath "$AGENTS_REPO_DIR/${AGENTS_COMPONENT_DIR:-.}")
  export AGENTS_COMPONENT_DIR
  export AGENTS_REPO_DIR
  export AGENTS_REPO_URL
  export AGENTS_GIT_ACCOUNT
  export AGENTS_GIT_REPO

  mkdir -p "$src_dir"
  if [ -d "$AGENTS_REPO_DIR/.git" ]; then
    git -C "$AGENTS_REPO_DIR" pull --ff-only
  else
    git clone "$AGENTS_REPO_URL" "$AGENTS_REPO_DIR"
  fi

  cd "$AGENTS_REPO_DIR" || exit
  bash "$session_start_dir/PROJECT.sh"

  cd "$AGENTS_COMPONENT_DIR" || exit
  bash "$session_start_dir/COMPONENT.sh"

  cd "$AGENTS_REPO_DIR" || exit
  bash "$session_start_dir/merge-agent-settings/merge-agent-settings.sh"
) 1>&2
