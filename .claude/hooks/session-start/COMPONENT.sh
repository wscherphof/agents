#!/usr/bin/env bash

set -euxo pipefail

NODE_VERSION=24.16.0
nvm install $NODE_VERSION
nvm use $NODE_VERSION

npm ci

# Install the correct version of Chromium Headless Shell for the current version
# of Playwright. Do this in the background so that it doesn't block the rest of
# the session start process.
npx playwright install chromium-headless-shell &
