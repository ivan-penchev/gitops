# Failure notifications

Flux and Alertmanager send alerts through `HomeLabPenchevBot` to Telegram channel
`-1003812945390`. The bot needs channel administrator access with Post Messages
permission.

## What sends alerts

Flux reports errors from sources, Kustomizations, Helm releases and the
FluxInstance. Its Provider and Alert live in `kubernetes/notifications/telegram/`.
The Flux Kustomization in `kubernetes/clusters/homelab/notifications.yaml` decrypts
and applies them without depending on the monitoring stack. Add entries in
`alert.yaml` when you introduce a namespace or source kind. Flux does not send
successful reconciliations to Telegram.

Alertmanager sends `warning` and `critical` alerts, followed by recovery messages.
Its receiver lives in
`kubernetes/apps/monitor/configs/telegram-alertmanagerconfig.yaml`. The HelmRelease
selects configs labelled `alertmanager: homelab` in the `monitoring` namespace.
These configs can route alerts from any namespace, including node alerts with no
namespace label.

The chart's inhibition rules still apply. A critical alert suppresses a warning
with the same namespace and alert name. Watchdog, InfoInhibitor and informational
alerts stay out of Telegram.

Alertmanager groups alerts by name and namespace. It waits 30 seconds before the
first message, sends group updates every 5 minutes, and repeats unchanged alerts
every 12 hours. Recovery messages can take up to 5 minutes.

## Which failures are covered

Flux reports deployment and source errors. The monitoring alarms use the existing
kube-prometheus-stack rules, without adding custom rules.

| Area | Example alarms |
| --- | --- |
| Node health | `KubeNodeNotReady`, node filesystem space or inode exhaustion |
| Workloads | `KubePodCrashLooping`, `KubePodNotReady`, deployment replica mismatch |
| Storage | `KubePersistentVolumeFillingUp`, `KubePersistentVolumeErrors` |
| Scraping and monitoring | `TargetDown`, Prometheus and Alertmanager failures |
| Deployments and sources | Flux reconciliation, chart install or upgrade, and source fetch errors |

The pinned chart sets the monitoring thresholds and `for` durations. Talos
control-plane scrape jobs are disabled, so they provide no scheduler,
controller-manager or etcd alarms. Proxmox-exporter collects metrics, but this
configuration adds no Proxmox, ZFS or LXC alarm rules.

## Secrets and rotation

SOPS encrypts the bot token in two Secrets, one for each consumer's namespace:

- `kubernetes/notifications/telegram/telegram-token.sops.yaml` in `flux-system`
- `kubernetes/apps/monitor/configs/telegram-token.sops.yaml` in `monitoring`

Both Secrets use the name `telegram-bot-token` and key `token`. Flux decrypts them
with bootstrap's `sops-age` Secret. The Prometheus Operator reads Alertmanager's
token through its Secret reference. SOPS keeps the token out of plaintext Git
files. It does not hide the runtime Secret from cluster administrators or protect
it from a compromised control plane.

Rotate the token through BotFather if you have shared it in chat. Set
`SOPS_AGE_KEY_FILE` to the private age key's path, then use SOPS to edit both
encrypted files. Publish the changes and reconcile both Kustomizations. Keep the
plaintext token out of CLI arguments, Git, issues and PR comments. Decrypted
temporary files and editor swap files also need protection. The channel ID is not
a credential.

## Deploy and verify

Merge the configuration into `main`, which the cluster follows, then reconcile
Flux. Local edits and temporary `kubectl` changes do not deploy it through GitOps.

Use the repository kubeconfig. The shell's default context may point at a
different cluster:

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

Test without stopping production workloads. Post a synthetic warning to
Alertmanager's `/api/v2/alerts` API with `Content-Type: application/json`, a unique
alert name and `namespace: default`. Check that Telegram receives the firing
message. Submit the same labels with `endsAt` set to now and check for the recovery
message. Also test routing for a node alert with no namespace label. Notification
counters should increase without an increase in delivery failures.

To test Flux, create a disposable GitRepository that points to a nonexistent
branch of this repository. Check that Telegram receives the error, then delete
the test GitRepository. Do not edit the real `flux-system` source. Provider and
Alert resources have no Ready condition in the installed API, so verify delivery
in Telegram.

## What this cannot report

Both senders run inside the homelab. They cannot reliably report a loss of
Proxmox, the cluster, LAN, power or Internet access. Use an external heartbeat
monitor to detect a whole-site outage. Watchdog is muted and has no external
receiver. Telegram must also be available for delivery to work.

Messages include workload names and alert descriptions. Keep secrets out of
resource names and alert annotations.
