#!/usr/bin/env bash
# Boots a throwaway Talos cluster in Docker with the same Talos version, config
# contract, cluster patch and Cilium inline manifest as a real cluster, checks
# it, then runs `talosctl upgrade-k8s` if the Kubernetes version changed.
#
# Usage: talos-docker-test.sh <cluster> [base-ref]
#
#   cluster   directory name under terraform/clusters/
#   base-ref  git ref to read the starting Kubernetes version from, for
#             example origin/main. Without it the cluster starts at the
#             version in the working tree and skips the upgrade.
#
# Docker can't test Talos OS upgrades, the ISO install or Proxmox. It only
# covers what runs inside Kubernetes.
set -euo pipefail

cluster=${1:?usage: talos-docker-test.sh <cluster> [base-ref]}
base_ref=${2:-}
vars=terraform/clusters/$cluster/talos-versions.tfvars
name=talos-ci
work=${RUNNER_TEMP:-$(mktemp -d)}/talos-docker-test
mkdir -p "$work/bin"
export PATH=$work/bin:$PATH
export TALOSCONFIG=$work/talosconfig
export KUBECONFIG=$work/kubeconfig

tfvar() { sed -n "s/^$1 *= *\"\(.*\)\"/\1/p"; }

talos_version=$(tfvar talos_version <"$vars")
contract=$(tfvar talos_config_contract <"$vars")
k8s_to=$(tfvar kubernetes_version <"$vars")
k8s_from=$k8s_to
if [[ -n $base_ref ]] && git cat-file -e "$base_ref:$vars" 2>/dev/null; then
  k8s_from=$(git show "$base_ref:$vars" | tfvar kubernetes_version)
fi

# talosctl generates the config in its own minor version's format. Terraform
# renders with talos_config_contract, so use the newest talosctl of that minor.
if [[ $talos_version == "$contract".* ]]; then
  talosctl_version=$talos_version
else
  talosctl_version=$(curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
    "https://api.github.com/repos/siderolabs/talos/releases?per_page=100" |
    jq -r --arg p "$contract." '.[] | select(.prerelease | not) | .tag_name | select(startswith($p))' |
    sort -V | tail -1)
fi
[[ -n $talosctl_version ]] || { echo "no talosctl release for contract $contract" >&2; exit 1; }

echo "cluster=$cluster talos=$talos_version contract=$contract config-talosctl=$talosctl_version kubernetes=$k8s_from->$k8s_to"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m); [[ $arch == x86_64 ]] && arch=amd64; [[ $arch == aarch64 ]] && arch=arm64
asset=talosctl-$os-$arch

fetch_talosctl() {
  local version=$1 dest=$work/bin/$2
  local base=https://github.com/siderolabs/talos/releases/download/$version
  curl -fsSL "$base/$asset" -o "$dest"
  curl -fsSL "$base/sha256sum.txt" | grep " _out/$asset\$\| $asset\$" | sed "s| .*|  $dest|" | sha256sum --check --strict
  chmod +x "$dest"
}

# talosctl-config renders the configs. talosctl matches the running Talos and
# does everything else, since only it knows that release's upgrade paths.
fetch_talosctl "$talosctl_version" talosctl-config
fetch_talosctl "$talos_version" talosctl

# Docker only supports the cluster-wide part of the patch. The machine part
# sets the install disk, installer image and nameserver, none of which apply.
yq '{"cluster": .cluster}' talos/patches/cluster.yaml.tmpl >"$work/cluster-patch.yaml"
yq -n '.cluster.inlineManifests = [{"name": "cilium", "contents": load_str("talos/cilium/cilium.yaml")}]' \
  >"$work/cilium-patch.yaml"

cleanup() {
  status=$?
  if ((status != 0)); then
    kubectl get nodes -o wide || true
    kubectl get pods -A -o wide || true
    kubectl get events -A --sort-by=.lastTimestamp | tail -40 || true
  fi
  talosctl-config cluster destroy --name "$name" --state "$work/state" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

talosctl-config cluster create docker \
  --name "$name" \
  --state "$work/state" \
  --image "ghcr.io/siderolabs/talos:$talos_version" \
  --kubernetes-version "$k8s_from" \
  --subnet 10.5.0.0/24 \
  --workers 1 \
  --config-patch "@$work/cluster-patch.yaml" \
  --config-patch-controlplanes "@$work/cilium-patch.yaml" \
  --talosconfig-destination "$TALOSCONFIG"

# The first control plane gets the second address of --subnet.
cp_ip=10.5.0.2
talosctl -n "$cp_ip" kubeconfig "$KUBECONFIG" --force

check() {
  local want=$1
  kubectl wait --for=condition=Ready nodes --all --timeout=5m
  kubectl -n kube-system rollout status ds/cilium --timeout=5m
  kubectl -n kube-system rollout status deploy/cilium-operator --timeout=5m
  kubectl -n kube-system rollout status deploy/coredns --timeout=5m
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief

  local got
  got=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' | sort -u)
  [[ $got == "v$want" ]] || { echo "nodes run $got, want v$want" >&2; return 1; }

  # A server on the worker and a client on the control plane, so the request
  # crosses nodes through Cilium's service handling and CoreDNS.
  kubectl delete ns smoke --ignore-not-found --wait
  kubectl create ns smoke
  kubectl -n smoke apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
spec:
  selector:
    matchLabels: {app: echo}
  template:
    metadata:
      labels: {app: echo}
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: echo
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args: ["netexec", "--http-port=8080"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
---
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  selector: {app: echo}
  ports:
    - port: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      effect: NoSchedule
  containers:
    - name: client
      image: busybox:1.37
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: [ALL]}
      command:
        - sh
        - -c
        - |
          for i in $(seq 1 60); do
            if nslookup echo.smoke.svc.cluster.local && wget -qO- -T 5 http://echo.smoke:8080/hostname; then
              exit 0
            fi
            sleep 5
          done
          exit 1
EOF
  kubectl -n smoke rollout status deploy/echo --timeout=3m
  kubectl -n smoke wait pod/client --for=jsonpath='{.status.phase}'=Succeeded --timeout=6m ||
    { kubectl -n smoke logs client; return 1; }
  kubectl -n smoke logs client | tail -1
  echo
}

check "$k8s_from"

if [[ $k8s_from != "$k8s_to" ]]; then
  talosctl -n "$cp_ip" upgrade-k8s --to "$k8s_to"
  check "$k8s_to"
fi

echo "talos docker test passed"
