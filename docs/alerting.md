# Failure notifications

Telegram destination: `HomeLabPenchevBot`, channel `-1003812945390`. The bot must
be a channel administrator with **Post Messages** permission.

## Two independent notification paths

- **Flux errors**: `kubernetes/notifications/telegram/` defines a Provider and an
  error-only Alert. `kubernetes/clusters/homelab/notifications.yaml` reconciles
  them with SOPS decryption, independently of the monitoring stack. Sources,
  Kustomizations, Helm releases and the FluxInstance are covered. Kind/namespace
  pairs are explicit: add entries in `alert.yaml` when introducing new namespaces
  or source kinds. Successful reconciliations are deliberately not sent.
- **Monitoring alarms**: the existing kube-prometheus-stack default rules feed
  Alertmanager. `kubernetes/apps/monitor/configs/telegram-alertmanagerconfig.yaml`
  forwards `warning` and `critical` alerts and sends recovery notifications.
  The HelmRelease selects only configs labelled `alertmanager: homelab` in
  `monitoring`. Namespace matcher enforcement is disabled for these trusted
  configs so node alerts and workloads outside `monitoring` are included.

The existing chart inhibition rules remain intact: a critical alert inhibits a
warning for the same namespace/alert name. Watchdog, InfoInhibitor and informational
alerts do not go to Telegram. Alerts group by name and namespace, wait 30 seconds
before the initial message, update groups every 5 minutes, and repeat unchanged
incidents every 12 hours. A recovery message may therefore take up to 5 minutes.

## Basic coverage

The pinned chart's existing rules cover:

| Area | Example alarms |
| --- | --- |
| Node health | `KubeNodeNotReady`, node filesystem space/inode exhaustion |
| Workloads | `KubePodCrashLooping`, `KubePodNotReady`, deployment replica mismatch |
| Storage | `KubePersistentVolumeFillingUp`, `KubePersistentVolumeErrors` |
| Scraping and monitoring | `TargetDown`, Prometheus/Alertmanager failures |
| Deployments and sources | Flux reconciliation, chart install/upgrade and source fetch errors |

These are not duplicate custom rules. Thresholds and `for` durations come from the
pinned kube-prometheus-stack chart. Disabled Talos control-plane scrape jobs do
not provide scheduler/controller-manager/etcd alarms. Proxmox-exporter metrics
alone do not add bespoke Proxmox, ZFS or LXC alarm rules.

## Secrets and rotation

The same bot credential is encrypted in two namespace-local SOPS Secrets:

- `kubernetes/notifications/telegram/telegram-token.sops.yaml` (`flux-system`)
- `kubernetes/apps/monitor/configs/telegram-token.sops.yaml` (`monitoring`)

Both use Secret name `telegram-bot-token`, key `token`. Neither consumer stores a
literal credential in its configuration. Flux decrypts using bootstrap's
`sops-age` Secret; the Prometheus Operator resolves Alertmanager's Secret reference.
Kubernetes necessarily stores the decrypted Secret at runtime: SOPS protects Git,
not cluster administrators or a compromised control plane.

Rotate a credential exposed in chat through BotFather before relying on it
long-term. Edit **both** encrypted files using SOPS (with `SOPS_AGE_KEY_FILE`
pointing at the private age key), then publish/reconcile both owning
Kustomizations. Never put the replacement token in a CLI argument, Git file,
issue or PR comment. Treat decrypted temporary files and editor swap files as
secrets. The channel ID is not a credential.

## Deployment and verification

The cluster follows `main`, not a local working tree or the Pi-hole draft branch.
The configuration becomes persistent only after it is published to `main` and
reconciled. Do not rely on temporary `kubectl` changes as deployment.

Always use the repository kubeconfig explicitly; the shell's default context may
point at a different cluster:

```sh
export KUBECONFIG="$PWD/kubeconfig"
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization notifications
flux reconcile kustomization monitoring-prometheus
flux reconcile helmrelease kube-prometheus-stack -n monitoring
flux reconcile kustomization monitoring-configs
kubectl -n flux-system get provider telegram
kubectl -n flux-system get alert telegram-errors
kubectl -n monitoring get alertmanagerconfig telegram
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 \
  -c alertmanager -- amtool check-config /etc/alertmanager/config_out/alertmanager.env.yaml
```

For a safe end-to-end test, use a clearly labelled synthetic warning with a unique
alert name and `namespace: default` through Alertmanager's `/api/v2/alerts` API.
Verify a firing message, then submit the same labels with `endsAt` set to now and
verify the recovery. Test routing for an unnamespaced node alert as well; a
namespace-scoped receiver can otherwise silently miss it. Confirm Telegram
notification counters increase without delivery-failure counters increasing.
Avoid testing by stopping production workloads.

For Flux, create a disposable GitRepository targeting a deliberately nonexistent
branch of this repository. Verify its error notification, then delete the test
GitRepository. Do not change or break the real `flux-system` source. Provider and
Alert resources do not expose a Ready condition in the installed API; verify
actual delivery rather than waiting for a condition that does not exist.

## Limits

Both paths run inside the homelab. If Proxmox, the entire cluster, LAN, power or
Internet access fails, they may be unable to send anything. Add an independent
external heartbeat/dead-man's-switch monitor for whole-site failure detection;
Watchdog is currently muted, not connected to such a service. Telegram itself is
also a dependency. Notifications include workload names and alert descriptions,
so keep secrets out of resource names and alert annotations.
