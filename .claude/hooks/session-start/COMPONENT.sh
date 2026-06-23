#!/usr/bin/env bash

set -x

# This script runs non-interactively (bash COMPONENT.sh), so login/profile
# scripts that define the `nvm` shell function are not sourced. Load nvm here.
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install 24.16.0
nvm use 24.16.0

npx playwright install chromium

nvm install 24.16.0
nvm use 24.16.0

npx playwright install chromium

npm ci
