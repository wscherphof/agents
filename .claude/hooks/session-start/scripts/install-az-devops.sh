#!/usr/bin/env bash

# Installs the Azure CLI and its azure-devops extension so Claude can push and
# open PRs against an Azure DevOps repo. Only meaningful when
# AZURE_DEVOPS_EXT_PAT is set — the az devops commands read that env var for
# non-interactive authentication.

set -uo pipefail

if command -v az >/dev/null 2>&1; then
  echo "Azure CLI already installed: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null)"
else
  echo "Installing Azure CLI..."
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

if az extension show --name azure-devops >/dev/null 2>&1; then
  echo "azure-devops extension already installed."
else
  echo "Installing azure-devops extension..."
  az extension add --name azure-devops
fi
