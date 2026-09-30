#!/usr/bin/env bash
# Render cilium.yaml from values.yaml for a given Cilium chart version.
#
# helm template generates fresh TLS material (cilium-ca, hubble-server-certs) on
# every run. To avoid rotating certs on each upgrade, any Secret that already
# exists in the current cilium.yaml is carried forward unchanged.
#
# Usage: ./render.sh <version>    e.g. ./render.sh 1.17.18
set -euo pipefail
cd "$(dirname "$0")"

version="${1:?usage: $0 <cilium chart version>}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helm template cilium cilium \
  --repo https://helm.cilium.io \
  --version "$version" \
  --namespace kube-system \
  -f values.yaml > "$tmp/new.yaml"

if [[ -f cilium.yaml ]]; then
  yq 'select(.kind == "Secret")' cilium.yaml > "$tmp/old-secrets.yaml"
  keep="$(yq -N '.metadata.name' "$tmp/old-secrets.yaml" | paste -sd, -)"
  # Drop rendered Secrets that we already have, then prepend the existing ones.
  KEEP="$keep" yq 'select(.kind != "Secret" or (.metadata.name as $n | strenv(KEEP) | split(",") | contains([$n]) | not))' \
    "$tmp/new.yaml" > "$tmp/rest.yaml"
  { cat "$tmp/old-secrets.yaml"; echo "---"; cat "$tmp/rest.yaml"; } > cilium.yaml
else
  mv "$tmp/new.yaml" cilium.yaml
fi

echo "rendered cilium $version -> $(pwd)/cilium.yaml"
