#!/usr/bin/env bash

# Per-project setup, run once by the session-start hook (remote sessions only),
# with the cloned project repo root ($AGENTS_REPO_DIR, i.e. src/<AGENTS_GIT_REPO>)
# as the working directory. Runs before COMPONENT.sh. Put repo-wide setup here
# (dependency installs, codegen, etc.).

set -euxo pipefail

# Install the repo-root dependencies. Currently just @fission-ai/openspec, whose
# `openspec` CLI the .claude/commands/opsx/* commands drive — without this the
# commands are present but every `openspec …` call fails, and the guardrails
# forbid hand-creating change directories, so the whole workflow is unusable in a
# remote session.
npm ci

# Install the docker4gis CLI globally, which is required for Docker-related
# operations in the project.
npm install -g docker4gis
