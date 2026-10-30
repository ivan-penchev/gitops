#!/usr/bin/env bash
# Run Terraform with the credentials from secrets.sops.env.
#
#   terraform/tf.sh shared plan          # terraform/shared
#   terraform/tf.sh homelab-prd plan     # terraform/cluster with clusters/homelab-prd
#   terraform/tf.sh all apply            # shared, then every cluster
#
# Every cluster uses the one root in terraform/cluster. A cluster is a
# directory under terraform/clusters/ with its *.tfvars files. This script
# passes those as -var-file and points the backend at
# homelab/clusters/<name>.tfstate, switching the backend when the last run
# used another cluster. Cluster roots read the shared state, so on a fresh
# rebuild apply shared first.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tf=$root/terraform

usage() {
  echo "usage: $0 <shared|all|CLUSTER> <terraform command> [args...]" >&2
  echo "clusters: $(ls "$tf/clusters" | tr '\n' ' ')" >&2
  exit 2
}

[ $# -ge 2 ] || usage
target=$1
shift
cmd=$1
shift

if [ "$target" = all ]; then
  selected=(shared)
  for d in "$tf"/clusters/*/; do
    selected+=("$(basename "$d")")
  done
else
  selected=("$target")
fi

export SOPS_AGE_KEY_FILE=${SOPS_AGE_KEY_FILE:-$root/age.key}

run() {
  local dir=$1
  shift
  sops exec-env "$root/secrets.sops.env" \
    "exec terraform -chdir=$(printf '%q' "$dir") $(printf '%q ' "$@")"
}

for name in "${selected[@]}"; do
  echo "==> $name" >&2
  if [ "$name" = shared ]; then
    run "$tf/shared" "$cmd" "$@"
    continue
  fi

  [ -d "$tf/clusters/$name" ] || { echo "unknown cluster: $name" >&2; usage; }
  key="homelab/clusters/$name.tfstate"
  dir=$tf/cluster
  init_args=(-reconfigure -input=false "-backend-config=key=$key")

  if [ "$cmd" = init ]; then
    run "$dir" init "${init_args[@]}" "$@"
    continue
  fi

  # The backend setting lives in .terraform/, which all clusters share.
  if ! grep -qF "\"$key\"" "$dir/.terraform/terraform.tfstate" 2>/dev/null; then
    echo "==> switching backend to $key" >&2
    run "$dir" init "${init_args[@]}" >/dev/null
  fi

  var_args=()
  case $cmd in
    plan | apply | destroy | import | console | refresh)
      # A saved plan already has its variables.
      saved_plan=false
      if [ "$cmd" = apply ]; then
        for a in "$@"; do
          case $a in -*) ;; *) saved_plan=true ;; esac
        done
      fi
      if [ "$saved_plan" = false ]; then
        for f in "$tf/clusters/$name"/*.tfvars; do
          var_args+=("-var-file=$f")
        done
      fi
      ;;
  esac
  run "$dir" "$cmd" ${var_args[@]+"${var_args[@]}"} "$@"
done
