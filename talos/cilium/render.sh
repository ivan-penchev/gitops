#!/usr/bin/env bash
# Render cilium.yaml from values.yaml for a given Cilium chart version.
#
# Hubble TLS uses the certgen CronJob (values.yaml), so the render holds no
# Secrets. Keep it that way: this repo is public.
#
# Usage: ./render.sh <version>    e.g. ./render.sh 1.20.2
set -euo pipefail
cd "$(dirname "$0")"

version="${1:?usage: $0 <cilium chart version>}"

helm template cilium cilium \
  --repo https://helm.cilium.io \
  --version "$version" \
  --namespace kube-system \
  -f values.yaml > cilium.yaml.new

if [[ -n "$(yq 'select(.kind == "Secret") | .metadata.name' cilium.yaml.new)" ]]; then
  rm -f cilium.yaml.new
  echo "render contains a Secret, refusing to write it to a public repo" >&2
  exit 1
fi
mv cilium.yaml.new cilium.yaml

echo "rendered cilium $version -> $(pwd)/cilium.yaml"
