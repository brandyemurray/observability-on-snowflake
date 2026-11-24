#!/usr/bin/env bash
# The Codespaces universal image already has Docker and Python.
# This adds kubectl (if missing) and kind (Kubernetes in Docker).
set -euo pipefail

KUBECTL_VERSION=v1.31.2
KIND_VERSION=v0.24.0
if ! command -v kubectl >/dev/null; then
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi
if ! command -v kind >/dev/null; then
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
fi

[ -f .env ] || cp .env.example .env

echo ""
echo "Ready. Run 'make up' to start the lab, or 'make help' to see every command."
