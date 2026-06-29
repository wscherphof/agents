#!/usr/bin/env bash

set -uo pipefail

# Project configuration (which repo/component this branch targets, plus the
# PROJECT.sh/COMPONENT.sh setup steps) lives in conf/ — committed per
# project/component branch. Edit it there.
conf_dir="$CLAUDE_PROJECT_DIR/conf"
# shellcheck source=/dev/null
[ -f "$conf_dir/.env" ] && . "$conf_dir/.env"
: "${AGENTS_GIT_ACCOUNT:=}" "${AGENTS_GIT_REPO:=}" "${AGENTS_COMPONENT_DIR:=}" "${AGENTS_START_DOCKER:=}"

# You should set either AZURE_DEVOPS_EXT_PAT or GITHUB_PERSONAL_ACCESS_TOKEN in
# your environment before starting the session. The script will use whichever is
# set to construct the repo URL for cloning.

# Don't touch anything below this line.

[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ] &&
  repo_url=https://${GITHUB_PERSONAL_ACCESS_TOKEN:-}@github.com/$AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO.git

[ -n "${AZURE_DEVOPS_EXT_PAT:-}" ] &&
  repo_url=https://${AZURE_DEVOPS_EXT_PAT:-}@dev.azure.com/$AGENTS_GIT_ACCOUNT/_git/$AGENTS_GIT_REPO

# Child scripts are setup steps. Send their stdout to stderr so it stays out of
# Claude's context (SessionStart adds hook stdout to context) while remaining
# visible in the transcript and under --debug.
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
(
  echo "• Setting up Claude git user..."
  git config --global user.email noreply@anthropic.com
  git config --global user.name Claude

  src_dir="$CLAUDE_PROJECT_DIR/src"
  AGENTS_REPO_DIR=$src_dir/$AGENTS_GIT_REPO

  echo "Cloning $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO into $AGENTS_REPO_DIR..."
  mkdir -p "$src_dir"
  if [ -d "$AGENTS_REPO_DIR/.git" ]; then
    git -C "$AGENTS_REPO_DIR" pull --ff-only
  else
    git clone "$repo_url" "$AGENTS_REPO_DIR"
  fi

  AGENTS_COMPONENT_DIR=$(realpath "$AGENTS_REPO_DIR/${AGENTS_COMPONENT_DIR:-.}")
  export AGENTS_COMPONENT_DIR

  AGENTS_TOOLS_DIR=$CLAUDE_PROJECT_DIR/tools
  export AGENTS_TOOLS_DIR

  # Put `srclink` on PATH so Claude can turn a project source path into a web
  # link to the project repo's host (instead of a broken workspace-relative
  # one). ~/.local/bin is ahead of the Bash tool's login-shell PATH.
  echo "• Linking srclink onto PATH..."
  mkdir -p "$HOME/.local/bin"
  ln -sf "$AGENTS_TOOLS_DIR/srclink.sh" "$HOME/.local/bin/srclink"

  export AGENTS_REPO_DIR
  export AGENTS_GIT_ACCOUNT
  export AGENTS_GIT_REPO

  session_start_dir=$dir/session-start
  scripts_dir=$session_start_dir/scripts

  # With an Azure DevOps PAT set, install the az CLI + devops extension so
  # Claude can push and open PRs. The az devops commands authenticate via the
  # AZURE_DEVOPS_EXT_PAT env var, so no extra login step is needed.
  if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
    echo "• Installing Azure CLI and devops extension..."
    bash "$scripts_dir/install-az-devops.sh" &
  fi &>"$scripts_dir/install-az-devops.log"

  # When AGENTS_START_DOCKER=true, bring up the Docker daemon in the background
  # (the image must already have Docker installed).
  if [ "${AGENTS_START_DOCKER:-}" = "true" ]; then
    echo "• Starting Docker daemon..."
    bash "$scripts_dir/start-docker.sh" &
  fi &>"$scripts_dir/start-docker.log"

  echo "• Running PROJECT.sh..."
  cd "$AGENTS_REPO_DIR" || exit
  bash "$conf_dir/PROJECT.sh"

  echo "• Running COMPONENT.sh..."
  cd "$AGENTS_COMPONENT_DIR" || exit
  bash "$conf_dir/COMPONENT.sh"

  echo "• Merging agent settings..."
  cd "$AGENTS_REPO_DIR" || exit
  bash "$scripts_dir/merge-agent-settings.sh"

) &>"$dir/session-start.log"
