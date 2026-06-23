#!/usr/bin/env bash

# This script runs non-interactively (bash COMPONENT.sh), so login/profile
# scripts that define the `nvm` shell function are not sourced. Load nvm here.
export NVM_DIR="${NVM_DIR:-/opt/nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

echo "Installing Node.js 24.16.0..."
nvm install 24.16.0
nvm use 24.16.0

echo "Installing Chromium for Playwright..."
npx playwright install chromium

echo "Installing npm dependencies..."
npm ci
