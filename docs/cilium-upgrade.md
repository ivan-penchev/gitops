# Upgrading Cilium

Cilium is rendered from the Helm chart into `talos/cilium/cilium.yaml` and
bootstrapped through Talos `cluster.inlineManifests`. Flux doesn't manage it and
Renovate doesn't bump it, so upgrades are manual.

Talos only creates inline-manifest objects that are missing. It never updates
them. An upgrade therefore has two parts. You apply the new render to the live
cluster yourself, then push the same render into the control-plane machine
config. The second part matters because a cluster rebuild or the next
`talosctl upgrade-k8s` applies whatever the machine config holds. Skip it and
the next `upgrade-k8s` rolls Cilium back.

## Rules

- Move one minor version per hop, to the latest patch of each minor. Cilium
  doesn't support skipping minors. Start with the latest patch of the version
  you're on.
- Before each hop, read the "Upgrade notes" section of the target version's
  guide at `https://docs.cilium.io/en/v1.<minor>/operations/upgrade/`. Look for
  anything that touches `talos/cilium/values.yaml` or
  `kubernetes/infrastructure/configs/cilium-lb.yaml`.
- Check the target supports our Kubernetes version at
  `https://docs.cilium.io/en/v1.<minor>/network/kubernetes/requirements/`.
- Render with `talos/cilium/render.sh`, not a bare `helm template`. Each render
  generates new TLS keys for `cilium-ca` and `hubble-server-certs`. The script
  keeps the existing Secrets so the upgrade doesn't rotate them.
- Apply with `--server-side --field-manager=talos`. Talos created the objects
  with server-side apply under the `talos` field manager. Reusing it means
  fields dropped from a newer chart get removed from the live objects. This is
  the same apply `talosctl upgrade-k8s` does.

List the available versions:

```bash
helm search repo cilium/cilium --versions | head -40   # after: helm repo add cilium https://helm.cilium.io
```

## Before you start

```bash
export KUBECONFIG=$PWD/kubeconfig TALOSCONFIG=$PWD/talosconfig
kubectl get nodes
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
kubectl get svc -A --field-selector spec.type=LoadBalancer   # write down the EXTERNAL-IPs
```

All nodes should be Ready and the status should say `OK`.

## Each hop

Set the target, then run the steps in order. Don't start the next hop until
step 5 is clean.

```bash
V=1.17.18
```

1. Render.

   ```bash
   talos/cilium/render.sh $V
   ```

2. Review what changes on the live cluster.

   ```bash
   kubectl diff --server-side --field-manager=talos --force-conflicts -f talos/cilium/cilium.yaml
   ```

3. Pre-pull the new images with Cilium's pre-flight check, so agents don't sit
   waiting on image pulls during the rollout. The pre-flight render only
   contains `cilium-pre-flight*` objects, so deleting it is safe.

   ```bash
   helm template cilium cilium --repo https://helm.cilium.io --version $V \
     -n kube-system -f talos/cilium/values.yaml \
     --set preflight.enabled=true --set agent=false --set operator.enabled=false \
     > /tmp/cilium-preflight.yaml
   kubectl apply -f /tmp/cilium-preflight.yaml
   kubectl -n kube-system rollout status ds/cilium-pre-flight-check --timeout=10m
   kubectl -n kube-system rollout status deploy/cilium-pre-flight-check --timeout=10m
   kubectl delete -f /tmp/cilium-preflight.yaml
   ```

4. Apply and wait for the rollout.

   ```bash
   kubectl apply --server-side --field-manager=talos --force-conflicts -f talos/cilium/cilium.yaml
   kubectl -n kube-system rollout status ds/cilium --timeout=10m
   kubectl -n kube-system rollout status ds/cilium-envoy --timeout=10m
   kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m
   ```

5. Verify.

   ```bash
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg version
   kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
   kubectl get svc -A --field-selector spec.type=LoadBalancer   # same EXTERNAL-IPs as before
   kubectl run dnstest -it --rm --restart=Never --image=busybox:1.37 -- nslookup kubernetes.default
   kubectl get pods -A | grep -vE 'Running|Completed'
   flux get kustomizations -A
   ```

   Also open an app behind the internal ingress (`192.168.68.40`) and one
   behind the Cloudflare tunnel.

## After the last hop

1. Commit `talos/cilium/cilium.yaml`.
2. Push the render into the control-plane machine config.

   ```bash
   export SOPS_AGE_KEY_FILE=$PWD/age.key
   sops exec-env secrets.sops.env 'cd terraform && terraform plan'
   ```

   Expect an in-place update to the control-plane
   `talos_machine_configuration_apply` and nothing else. If the plan shows
   unrelated changes, apply with
   `-target='talos_machine_configuration_apply.this["cp-1"]'`. Changing
   `inlineManifests` doesn't reboot the node or touch live objects.

   ```bash
   sops exec-env secrets.sops.env 'cd terraform && terraform apply'
   ```

## Rolling back

Render the previous version with `render.sh` and apply it the same way. Cilium
supports going back one minor. Read the "Downgrade" section of the upgrade guide
for the version you're leaving first.

## Version notes

- 1.19 deprecates `cilium.io/v2alpha1` for `CiliumLoadBalancerIPPool`. Once the
  cluster runs 1.19, change the pool in
  `kubernetes/infrastructure/configs/cilium-lb.yaml` to `cilium.io/v2`.
  `CiliumL2AnnouncementPolicy` stays on `v2alpha1` through 1.20.
- 1.20 changes the default `envoy.xdsMode` to `ads`. It only affects Envoy L7
  features (L7 policy, Cilium ingress, Gateway API), which we don't use.
