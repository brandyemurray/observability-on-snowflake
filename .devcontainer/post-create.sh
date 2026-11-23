#!/usr/bin/env bash
# Installs kind (Kubernetes in Docker) and the Python packages for local runs.
set -euo pipefail

KIND_VERSION=v0.24.0
curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
sudo install -m 0755 /tmp/kind /usr/local/bin/kind

pip install --quiet -r services/requirements.txt

[ -f .env ] || cp .env.example .env

echo ""
echo "Ready. Run 'make up' to start the lab, or 'make help' to see every command."
