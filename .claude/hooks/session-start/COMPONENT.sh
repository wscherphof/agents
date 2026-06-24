#!/usr/bin/env bash

set -euo pipefail

# This script runs non-interactively, so login/profile scripts that define the
# `nvm` shell function are not sourced. Load nvm here.
echo "Loading nvm..."
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

NODE_VERSION=24.16.0
echo "Installing and using Node.js version $NODE_VERSION..."
nvm install $NODE_VERSION
nvm use $NODE_VERSION

set -x

npm ci

# Install the correct version of Chromium Headless Shell for the current version
# of Playwright. Do this in the background so that it doesn't block the rest of
# the session start process.
npx playwright install chromium-headless-shell &
