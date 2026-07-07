#!/usr/bin/env bash

# Per-component setup, run once by the session-start hook (remote sessions only),
# right after PROJECT.sh — but only when a component is configured (a non-empty
# AGENTS_COMPONENT_DIR in conf/.env); otherwise it's skipped and PROJECT.sh
# alone covers the repo. Runs with the component directory ($AGENTS_COMPONENT_DIR,
# i.e. AGENTS_REPO_DIR joined with the relative AGENTS_COMPONENT_DIR) as the
# working directory. Put component-scoped setup here (dependency installs,
# codegen, etc.).

set -euxo pipefail

# npm ci
