#!/usr/bin/env bash

# Starts the Docker daemon in the remote container so Claude can use Docker
# (dev containers, integration tests, docker-compose, ...). Gated by
# AGENTS_START_DOCKER=true in conf/.env. Assumes Docker is already installed in
# the image — this only starts the daemon, it does not install Docker.

set -uo pipefail

if docker info >/dev/null 2>&1; then
  echo "Docker daemon already running."
  exit 0
fi

if ! command -v dockerd >/dev/null 2>&1; then
  echo "dockerd not found — Docker does not appear to be installed in this image. Skipping."
  exit 0
fi

echo "Starting Docker daemon..."
# Containers here usually have no init system; prefer the service wrapper (it
# sets up iptables/storage from /etc/docker/daemon.json) and fall back to
# launching dockerd directly. The readiness poll below decides success.
if ! (command -v service >/dev/null 2>&1 && sudo service docker start >/dev/null 2>&1); then
  sudo dockerd >/dev/null 2>&1 &
fi

# Wait for the daemon to accept connections — the poll, not the start command,
# is the source of truth for readiness.
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    echo "Docker daemon is ready."
    exit 0
  fi
  sleep 1
done

echo "Docker daemon did not become ready within 30s."
exit 1
