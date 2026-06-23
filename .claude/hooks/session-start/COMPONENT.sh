#!/usr/bin/env bash

set -x

nvm install 24.16.0
nvm use 24.16.0

npx playwright install chromium

nvm install 24.16.0
nvm use 24.16.0

npx playwright install chromium

npm ci
