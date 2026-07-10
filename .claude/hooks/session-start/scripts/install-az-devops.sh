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
  # Install manually from Microsoft's apt repo rather than the one-liner
  # `curl https://aka.ms/InstallAzureCLIDeb | sudo bash`: the sandbox classifier
  # blocks piping remote code into a privileged shell, so that install fails
  # silently. These steps only curl a GPG *key* (data, not code) and then let
  # apt install the signed azure-cli package — the sandbox-friendly equivalent.
  # See https://learn.microsoft.com/cli/azure/install-azure-cli-linux (manual).
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg
  sudo mkdir -p /etc/apt/keyrings
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc -o /tmp/microsoft.asc
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg /tmp/microsoft.asc
  sudo chmod go+r /etc/apt/keyrings/microsoft.gpg
  rm -f /tmp/microsoft.asc
  az_dist=$(lsb_release -cs)
  echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${az_dist}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null
  sudo apt-get update
  sudo apt-get install -y azure-cli
fi

if az extension show --name azure-devops >/dev/null 2>&1; then
  echo "azure-devops extension already installed."
else
  echo "Installing azure-devops extension..."
  az extension add --name azure-devops
fi
