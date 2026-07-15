#!/usr/bin/env bash

set -uo pipefail

# This hook only does anything in a Claude Code on the web (remote) session,
# where it clones the project and mirrors its agent settings. Locally it must be
# inert — in particular it must NOT override the dev's global git identity (see
# the Claude identity set below) when they open a local session on a settings
# branch. Claude Code on the web sets CLAUDE_CODE_REMOTE=true; bail out otherwise.
# https://code.claude.com/docs/en/claude-code-on-the-web#install-dependencies-with-a-sessionstart-hook
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

# Project configuration (which repo/component this branch targets, plus the
# PROJECT.sh/COMPONENT.sh setup steps) lives in conf/ — committed per
# project/component branch. Edit it there.
conf_dir="$CLAUDE_PROJECT_DIR/conf"
# shellcheck source=/dev/null
[ -f "$conf_dir/.env" ] && . "$conf_dir/.env"
: "${AGENTS_GIT_ACCOUNT:=}" "${AGENTS_GIT_REPO:=}" "${AGENTS_COMPONENT_DIR:=}" "${AGENTS_START_DOCKER:=}" "${AGENTS_INTEGRATION_BRANCH:=}" "${AGENTS_SETTINGS_BRANCH:=}"

# On the scaffolding template branch (main), no project is configured
# (AGENTS_GIT_ACCOUNT blank): none of the project clone/merge setup below
# applies, so bail out before it runs. In particular, skip the Claude git
# identity the subshell sets only for project sessions (needed there for the
# harness's Stop-hook backstop commit) — leaving the dev's own pre-configured
# git identity in place, so scaffolding commits are authored under their name.
if [ -z "$AGENTS_GIT_ACCOUNT" ]; then
  exit 0
fi

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
# visible in the transcript and under --debug. The ONE thing we do feed into
# context is a single status line, emitted after the subshell below, saying
# whether setup succeeded — so Claude can report the hook outcome up front (see
# the "session-start hook outcome" instruction in CLAUDE.md).
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The current setup step, recorded before each one runs, so a failure can name
# the step that died. Read back after the subshell only on failure.
phase_file="$dir/.session-start-phase"
(
  # Abort the whole setup on the first failing step, so its exit status reflects
  # whether setup actually completed (background installs excepted — they are
  # fire-and-forget and reported separately).
  set -e

  # Record + announce the current setup step. The marker file lets the status
  # line after the subshell name the step that failed.
  phase() {
    printf '%s\n' "$1" >"$phase_file"
    echo "• $1..."
  }

  # Give git a valid identity so Claude Code on the web's harness Stop hook can
  # commit the freshly merged agent settings to the agents repo's settings
  # branch — without a configured user.name/email that commit (and thus the Stop
  # hook) would fail. Use the Claude identity here; project code commits made by
  # the session get the Co-Authored-By trailer either way.
  phase "Setting up Claude git user"
  git config --global user.email noreply@anthropic.com
  git config --global user.name Claude

  src_dir="$CLAUDE_PROJECT_DIR/src"
  AGENTS_REPO_DIR=$src_dir/$AGENTS_GIT_REPO

  phase "Cloning $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO into $AGENTS_REPO_DIR"
  mkdir -p "$src_dir"
  if [ -d "$AGENTS_REPO_DIR/.git" ]; then
    git -C "$AGENTS_REPO_DIR" pull --ff-only
  else
    git clone "$repo_url" "$AGENTS_REPO_DIR"
  fi

  # Resolve to an absolute path only when a component is actually configured;
  # leave it empty otherwise (merge-agent-settings.sh falls back to the repo
  # root, and COMPONENT.sh is skipped below).
  [ -n "$AGENTS_COMPONENT_DIR" ] &&
    AGENTS_COMPONENT_DIR=$(realpath "$AGENTS_REPO_DIR/$AGENTS_COMPONENT_DIR")
  export AGENTS_COMPONENT_DIR

  AGENTS_TOOLS_DIR=$CLAUDE_PROJECT_DIR/tools
  export AGENTS_TOOLS_DIR

  # Put `srclink` on PATH so Claude can turn a project source path — or an
  # issue/work-item/PR reference — into a web link to the project repo's host
  # (instead of a broken workspace-relative one). ~/.local/bin is ahead of the
  # Bash tool's login-shell PATH.
  phase "Linking srclink onto PATH"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$AGENTS_TOOLS_DIR/srclink.sh" "$HOME/.local/bin/srclink"

  export AGENTS_REPO_DIR
  export AGENTS_GIT_ACCOUNT
  export AGENTS_GIT_REPO
  # The remaining conf/.env knobs, exported so PROJECT.sh/COMPONENT.sh see them
  # as env vars.
  export AGENTS_START_DOCKER
  export AGENTS_INTEGRATION_BRANCH

  # Exported so merge-agent-settings.sh (a child process) picks up the override
  # from conf/.env; without this the AGENTS_SETTINGS_BRANCH knob is silently
  # ignored and the merge always targets the derived branch name.
  export AGENTS_SETTINGS_BRANCH

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

  phase "Running PROJECT.sh"
  cd "$AGENTS_REPO_DIR" || exit
  bash "$conf_dir/PROJECT.sh"

  # Only when a component was configured; otherwise its dir is just the repo
  # root and PROJECT.sh already covered that.
  if [ -n "$AGENTS_COMPONENT_DIR" ]; then
    phase "Running COMPONENT.sh"
    cd "$AGENTS_COMPONENT_DIR" || exit
    bash "$conf_dir/COMPONENT.sh"
  fi

  phase "Merging agent settings"
  cd "$AGENTS_REPO_DIR" || exit
  bash "$scripts_dir/merge-agent-settings.sh"

) &>"$dir/session-start.log"
hook_status=$?

# Feed a single status line into the session context (SessionStart adds hook
# stdout to context). CLAUDE.md instructs Claude to relay this up front, so a
# degraded session — clone or settings merge that silently failed — is surfaced
# instead of worked on obliviously. Absence of this line in a remote project
# session is itself a signal that setup did not reach this point.
if [ "$hook_status" -eq 0 ]; then
  echo "session-start-hook: OK — cloned $AGENTS_GIT_ACCOUNT/$AGENTS_GIT_REPO and merged agent settings into src/. Any background installs (az CLI / Docker) may still be finishing; see their logs under .claude/hooks/session-start/scripts/."
else
  echo "session-start-hook: FAILED during \"$(cat "$phase_file" 2>/dev/null || echo 'unknown step')\" (exit $hook_status). See .claude/hooks/session-start.log — the project clone under src/ and/or the merged agent settings may be missing or incomplete; do not assume the project is set up."
fi

# The hook itself always succeeds: a setup failure is reported in-band via the
# status line above (which must reach context), not via a non-zero hook exit.
exit 0
