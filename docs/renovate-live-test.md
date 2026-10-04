# Renovate live health tests

The live test applies a Renovate PR to the homelab cluster and checks the child
Flux Kustomizations. It changes running workloads, not a preview environment.
A passing result requires both a successful PR test and verified recovery to `main`.

## Test scope

Renovate runs weekly or on demand through `.github/workflows/renovate.yml`.
Its managers update Flux chart/OCI references, Kubernetes images, and GitHub
Actions. Files matching `*.sops.yaml` are ignored.

`.github/workflows/gitops-live-test.yml` accepts only same-repository
`renovate/*` PRs targeting `main`. Runs share a concurrency group and use the
in-cluster ARC runner `gha-homelab-arc` with ServiceAccount `ci-deployer`.
The Kubernetes API does not need to be exposed outside the cluster network.

**The root Kustomization is deliberately suspended during testing.** Only
`infrastructure-controllers`, `infrastructure-configs`, and `apps` are explicitly
reconciled against the PR. Changes under `kubernetes/clusters/homelab/` are rejected,
including renamed files moved out of that directory. Those manifests need a
separate root/controller migration test. In particular, this workflow cannot
validate a FluxInstance, Flux Operator, or Flux controller upgrade while their
owning root is suspended. A workflow-only update also does not prove workload
behavior changed.

## Branch switching

1. Require an idle cluster: no previous watchdog Job, an unsuspended source and
   root, and a source selecting only `main`. API discovery errors fail the run.
2. If `FluxInstance/flux` exists in `flux-system`, require its GitRepository sync
   to own `flux-system` and select `refs/heads/main`. The instance must be Ready
   and not already paused. Without this instance, use the legacy source/root path.
3. Create `gitops-watchdog-<run_id>-<attempt>` in `arc-runners` and wait for its
   container to run before changing Flux. It carries its own recovery script and
   does not depend on the runner filesystem.
4. In operator mode, atomically set
   `fluxcd.controlplane.io/reconcile: disabled` and a fresh
   `reconcile.fluxcd.io/requestedAt`. Wait until the instance's
   `status.lastHandledReconcileAt` acknowledges that exact request. This drains
   any older reconciliation; the annotation alone does not interrupt work already
   in progress. Suspend the root with the same request/acknowledgment pattern.
5. While paused, set the instance's `spec.sync.ref` to the PR branch and replace
   the generated source's entire `spec.ref`. Operator mode uses
   `name: refs/heads/<branch>`; legacy mode uses `branch: <branch>`. Replacing the
   whole ref removes any higher-precedence selector left behind by migration.
6. Reconcile the source and require its artifact revision to equal
   `<branch>@sha1:<pull-request-head-sha>`. Reconcile the three child layers with
   six-minute health timeouts. Each must be Ready and have applied that exact
   revision. Check the source and both pauses around each layer so a branch
   movement or unexpected resume cannot produce a passing result against `main`.

The pause annotation is documented in the
[FluxInstance API](https://fluxoperator.dev/docs/crd/fluxinstance/).
Acknowledgment behavior was checked against Flux Operator v0.61.0's
[reconcile path](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/internal/controller/fluxinstance_controller.go)
and [status finalizer](https://github.com/controlplaneio-fluxcd/flux-operator/blob/v0.61.0/internal/controller/common.go),
and kustomize-controller v1.7.2's
[status finalizer](https://github.com/fluxcd/kustomize-controller/blob/v1.7.2/internal/controller/kustomization_controller.go).
A pause acknowledgment timeout aborts the switch rather than assuming the
controllers have stopped.

## Recovery and watchdog

The runner's `always()` cleanup and the watchdog use the same commands:

1. Pause and drain the operator, then suspend and drain the root.
2. Restore the instance sync ref and GitRepository selector to `main`.
3. Reconcile the source and verify a `main` artifact **before** enabling the
   operator or resuming the root. This avoids applying cached PR YAML on resume.
4. Restore the instance's original reconcile annotation, either absent or
   `enabled`, and wait for its acknowledged, Ready reconciliation.
5. Resume and reconcile the root, then reconcile the three children. Require
   all four to have applied the verified main revision and recheck the source
   and instance refs.
6. Delete the watchdog only after successful recovery. A recovery error keeps
   it armed, fails the workflow, and is reported as unconfirmed in the PR comment.

The watchdog starts recovery about 20 minutes after creation, even if the runner
is lost. Pod restarts retain that original deadline. Failed recovery attempts
retry every 15 seconds; the Job has a total deadline of 140 minutes and permits
six pod retries. A leftover Job blocks the next live test so old recovery cannot
race a new branch switch. Completed Jobs expire after five minutes.

This is not guaranteed disaster recovery. Recovery needs the Kubernetes API,
working Flux controllers, a runnable watchdog pod, and access to the Git source.
A broken CNI, failed controller, revoked permissions, or unavailable source can
prevent it. If restoration is unconfirmed, inspect the Job logs and Flux state
before retrying or merging. Keep the root suspended until the source artifact
is confirmed to be from `main`; restore `FluxInstance/flux.spec.sync.ref` too,
not just the generated GitRepository. Do not delete a pending recovery Job merely
to bypass the next run's preflight.

## Blast radius

A test points the shared workload source at an unmerged branch. Child layers may
apply those changes automatically as well as through explicit reconciliation.
A broken infrastructure update can disrupt production before recovery completes.
The root and operator stay paused, but their existing controllers keep running.
Review the PR and recovery result before merging by hand; a green run is not a
blanket approval of changes outside the tested child layers.

## One-time manual setup

The pipeline is **dormant** until this is done.

1. Create a **fine-grained PAT** on `ivan-penchev/gitops`:
   - **Contents: Read and write**
   - **Pull requests: Read and write**
   - (Metadata: Read-only is added automatically.)

   > This must be a real PAT, **not** the default `GITHUB_TOKEN`: PRs opened by
   > `GITHUB_TOKEN` do not trigger other workflows, so the live-test would never
   > run. It is also a *different* token from the ARC registration PAT (which is
   > Administration-scoped).

2. Add it as an **Actions repository secret** named `RENOVATE_TOKEN`
   (Settings -> Secrets and variables -> Actions), or:

   ```bash
   gh secret set RENOVATE_TOKEN --repo ivan-penchev/gitops
   ```

3. (Optional) Kick the first run: **Actions -> renovate -> Run workflow**.

## RBAC

Apply the runner RBAC in
`kubernetes/infrastructure/controllers/actions-runner-controller.yaml` before
using operator-mode live tests. The namespace-scoped `arc-ci-flux-instance` Role
allows `get`, `list`, `watch`, and `patch` only on FluxInstance `flux` in
`flux-system`. Its RoleBinding grants those permissions to
`arc-runners/ci-deployer`, used by both the runner and watchdog. Name-restricted
list/watch supports `kubectl wait` for that instance; other FluxInstances remain
outside this Role.

Existing ARC roles supply source/Kustomization reconciliation and suspension,
and watchdog Job/pod access. This change does not add Secret access, token
creation, impersonation, or cluster-wide FluxInstance permissions.
