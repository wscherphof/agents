#!/usr/bin/env bash

# Per-project setup, run once by the session-start hook (remote sessions only),
# with the cloned project repo root ($AGENTS_REPO_DIR, i.e. src/<AGENTS_GIT_REPO>)
# as the working directory. Runs before COMPONENT.sh. Put repo-wide setup here
# (dependency installs, codegen, etc.).

set -euxo pipefail

# npm ci
