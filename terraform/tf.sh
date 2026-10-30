#!/usr/bin/env bash
# Run Terraform in one root with the credentials from secrets.sops.env.
#
#   terraform/tf.sh shared plan          # terraform/shared
#   terraform/tf.sh homelab-prd plan     # terraform/clusters/homelab-prd
#   terraform/tf.sh all apply            # shared, then every cluster
#
# Cluster roots read the shared state, so on a fresh rebuild apply shared
# first.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

usage() {
  echo "usage: $0 <shared|all|CLUSTER> <terraform args...>" >&2
  echo "clusters: $(ls "$root/terraform/clusters" | tr '\n' ' ')" >&2
  exit 2
}

[ $# -ge 2 ] || usage
target=$1
shift

dir_of() {
  if [ "$1" = shared ]; then
    echo "$root/terraform/shared"
  elif [ -d "$root/terraform/clusters/$1" ]; then
    echo "$root/terraform/clusters/$1"
  else
    echo "unknown root: $1" >&2
    usage
  fi
}

if [ "$target" = all ]; then
  selected=(shared)
  for d in "$root"/terraform/clusters/*/; do
    selected+=("$(basename "$d")")
  done
else
  selected=("$target")
fi

export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$root/age.key}
args=$(printf '%q ' "$@")

for name in "${selected[@]}"; do
  dir=$(dir_of "$name")
  echo "==> $name" >&2
  sops exec-env "$root/secrets.sops.env" \
    "exec terraform -chdir=$(printf '%q' "$dir") $args"
done
