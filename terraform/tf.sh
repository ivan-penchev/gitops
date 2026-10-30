#!/usr/bin/env bash
# Run Terraform in one stack, or in all of them in dependency order, with the
# credentials from secrets.sops.env.
#
#   terraform/tf.sh platform plan
#   terraform/tf.sh all init
#   terraform/tf.sh all apply
#
# `all` runs cloudflare, platform, then cluster. cluster reads the other two
# states, so on a fresh rebuild it can only plan after they are applied.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
stacks=(cloudflare platform cluster)

if [ $# -lt 2 ]; then
  echo "usage: $0 <cloudflare|platform|cluster|all> <terraform args...>" >&2
  exit 2
fi

target=$1
shift

case "$target" in
  all) selected=("${stacks[@]}") ;;
  cloudflare | platform | cluster) selected=("$target") ;;
  *)
    echo "unknown stack: $target" >&2
    exit 2
    ;;
esac

export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$root/age.key}
args=$(printf '%q ' "$@")

for stack in "${selected[@]}"; do
  echo "==> $stack" >&2
  sops exec-env "$root/secrets.sops.env" \
    "exec terraform -chdir=$(printf '%q' "$root/terraform/$stack") $args"
done
