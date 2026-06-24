#!/usr/bin/env bash

set -x

NODE_VERSION=24.16.0
nvm install $NODE_VERSION
nvm use $NODE_VERSION

npm ci

npx playwright install \
    chromium \
    chromium-headless-shell \
    &
