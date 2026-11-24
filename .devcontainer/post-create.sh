#!/usr/bin/env bash
# Installs kubectl and kind (Kubernetes in Docker), then the Python packages.
set -euo pipefail

KUBECTL_VERSION=v1.31.2
KIND_VERSION=v0.24.0
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
sudo install -m 0755 /tmp/kind /usr/local/bin/kind

pip install --quiet -r services/requirements.txt

[ -f .env ] || cp .env.example .env

echo ""
echo "Ready. Run 'make up' to start the lab, or 'make help' to see every command."
