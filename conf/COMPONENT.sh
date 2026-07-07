#!/usr/bin/env bash

# Per-component setup, run once by the session-start hook (remote sessions only),
# right after PROJECT.sh — but only when a component is configured (a non-empty
# AGENTS_COMPONENT_DIR in conf/.env); otherwise it's skipped and PROJECT.sh
# alone covers the repo. Runs with the component directory ($AGENTS_COMPONENT_DIR,
# i.e. AGENTS_REPO_DIR joined with the relative AGENTS_COMPONENT_DIR) as the
# working directory. Put component-scoped setup here (dependency installs,
# codegen, etc.).

set -exuo pipefail

"$AGENTS_TOOLS_DIR/pin_node_version.sh" 24.16.0

npm ci

# Install the correct version of Chromium Headless Shell for the current version
# of Playwright. Do this in the background so that it doesn't block the rest of
# the session start process.
npx playwright install chromium-headless-shell &
