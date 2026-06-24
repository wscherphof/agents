#!/usr/bin/env bash

set -uo pipefail

# Mandatory.
AGENTS_GIT_ACCOUNT=merkatordev
AGENTS_GIT_REPO=GeoWEP

# Optional (for a component in a monorepo).
AGENTS_COMPONENT_DIR="docker/ng"

# You should set either AZURE_DEVOPS_EXT_PAT or GITHUB_PERSONAL_ACCESS_TOKEN in
# your environment before starting the session. The script will use whichever is
# set to construct the repo URL for cloning.

[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] &&
AGENTS_REPO_URL=https://${GITHUB_PERSONAL_ACCESS_TOKEN:-}@github.com/$AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO.git

[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ] &&
AGENTS_REPO_URL=https://${AZURE_DEVOPS_EXT_PAT:-}@dev.azure.com/$AGENTS_GIT_ACCOUNT/_git/$AGENTS_GIT_REPO

# Child scripts are setup steps. Send their stdout to stderr so it stays out of
# Claude's context (SessionStart adds hook stdout to context) while remaining
# visible in the transcript and under --debug.
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
(
  session_start_dir=$dir/session-start
  src_dir="$CLAUDE_PROJECT_DIR/src"
  AGENTS_REPO_DIR=$src_dir/$AGENTS_GIT_REPO

  mkdir -p "$src_dir"
  if [ -d "$AGENTS_REPO_DIR/.git" ]; then
    git -C "$AGENTS_REPO_DIR" pull --ff-only
  else
    echo "Cloning $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO into $AGENTS_REPO_DIR"
    git clone "$AGENTS_REPO_URL" "$AGENTS_REPO_DIR"
  fi

  AGENTS_COMPONENT_DIR=$(realpath "$AGENTS_REPO_DIR/${AGENTS_COMPONENT_DIR:-.}")
  export AGENTS_COMPONENT_DIR
  export AGENTS_REPO_DIR
  export AGENTS_REPO_URL
  export AGENTS_GIT_ACCOUNT
  export AGENTS_GIT_REPO

  # This script runs non-interactively, so login/profile scripts that define the
  # `nvm` shell function are not sourced. Load nvm here.
  echo "Loading nvm..."
  export NVM_DIR="${NVM_DIR:-/opt/nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  echo "Running PROJECT.sh..."
  cd "$AGENTS_REPO_DIR" || exit
  bash "$session_start_dir/PROJECT.sh"

  echo "Running COMPONENT.sh..."
  cd "$AGENTS_COMPONENT_DIR" || exit
  bash "$session_start_dir/COMPONENT.sh"

  echo "Merging agent settings..."
  cd "$AGENTS_REPO_DIR" || exit
  bash "$session_start_dir/merge-agent-settings/merge-agent-settings.sh"
) &>"$dir/session-start.log"
