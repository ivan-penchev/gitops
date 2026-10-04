# Renovate live health tests

The live test applies a Renovate or explicitly opted-in PR to the homelab cluster and checks the child
Flux Kustomizations. It changes running workloads, not a preview environment.
A passing result requires both a successful PR test and verified recovery to `main`.

## Test scope

Renovate runs weekly or on demand through `.github/workflows/renovate.yml`.
Its managers update Flux chart/OCI references, Kubernetes images, and GitHub
Actions. Files matching `*.sops.yaml` are ignored.

`.github/workflows/gitops-live-test.yml` accepts same-repository PRs targeting
`main`: `renovate/*` branches run automatically; other branches require a
maintainer to apply the `gitops-live-test` label. Fork PRs are never eligible.
Runs share a concurrency group and use the in-cluster ARC runner
`gha-homelab-arc` with ServiceAccount `ci-deployer`. The Kubernetes API does not
need to be exposed outside the cluster network.

Adding `gitops-live-test` starts the test. Leaving it on the PR also opts in
subsequent pushes and reopen events; remove it to stop future non-Renovate runs.
An unrelated label does not start a run. Before cluster access, the workflow
re-reads the PR and rejects closed PRs, changed heads or bases, forks, and removed
opt-ins. Removing the label does not cancel an already running test or its
recovery. Review the manifests **and workflow code** before applying the label:
this grants the PR workflow access to a privileged live-cluster runner, not a
sandbox. Do not cancel recovery or merge until main restoration is confirmed.

**The root Kustomization is deliberately suspended during testing.** The workflow
explicitly reconciles `infrastructure-controllers`, `infrastructure-configs`,
`apps`, and the direct Flux Kustomizations owned by `apps` in `flux-system` against
the PR. Changes under `kubernetes/clusters/homelab/` are rejected,
including renamed files moved out of that directory. Those manifests need a
separate root/controller migration test. In particular, this workflow cannot
validate a FluxInstance, Flux Operator, or Flux controller upgrade while their
owning root is suspended. A workflow-only update also does not prove workload
behavior changed.

Child discovery selects both Flux ownership labels:
`kustomize.toolkit.fluxcd.io/name=apps` and
`kustomize.toolkit.fluxcd.io/namespace=flux-system`. This covers the per-app
`prowlarr`, `radarr`, and `audiobookshelf` Kustomizations without hard-coding their
names. It does not recurse into grandchildren or discover Kustomizations outside
`flux-system`. Wattbill remains a direct resource of `apps`, not a separately
reconciled Flux Kustomization.

The workflow fails on a suspended child. It never unsuspends or skips one, in
both the PR verdict and recovery. The staged namespace migration therefore cannot
pass this test while its children have `spec.suspend: true`. This workflow is not
a substitute for the approved data migration and per-app activation steps.

## Branch switching

1. Require an idle cluster: no previous watchdog Job, an unsuspended source and
   root, and a source selecting only `main`. API discovery errors fail the run.
2. If `FluxInstance/flux` exists in `flux-system`, require its GitRepository sync
   to own `flux-system` and select `refs/heads/main`. The instance must be Ready
   and not already paused. Without this instance, use the legacy source/root path.
3. Create `gitops-watchdog-<run_id>-<attempt>` in `arc-runners` and wait for its
   readiness probe to pass before changing Flux. Readiness requires successful
   Kubernetes API access with the recovery client's configuration, not just a
   running container. It carries its own recovery script and does not depend on
   the runner filesystem.
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
   `refs/heads/<branch>@sha1:<pull-request-head-sha>` in operator mode, or
   `<branch>@sha1:<pull-request-head-sha>` in legacy mode. The SHA must match the
   immutable PR head, not just the current tip of its branch.
7. Reconcile the three layers in order. While `apps` reconciles, discover its
   children and request their reconciliation before waiting for `apps` to finish.
   This avoids blocking child requests behind the parent's health wait. Discover
   again after `apps` completes, then explicitly reconcile and check every child.
   Parent Ready alone can reflect children that are still Ready at an old revision.
8. Require each layer and discovered child to acknowledge its reconciliation
   request, report Ready for its current generation, and have applied the exact
   PR revision. Both `status.observedGeneration` and the Ready condition's
   `observedGeneration` must match `metadata.generation`. Discovered children must
   use GitRepository `flux-system` in `flux-system`, with an omitted source
   namespace also allowed. Check the source and both pauses around each layer so
   branch movement or an unexpected resume cannot produce a passing result
   against `main`.

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

Both clients use an explicit, temporary kubeconfig referencing the projected
`ci-deployer` token file and CA; tokens are not copied into it or printed. The
runner exports its path through `GITHUB_ENV`, so nested `sh` processes inherit it.
The watchdog creates its own config inside its Pod. This preserves token rotation
and TLS verification while avoiding kubectl's default-config fallback: adding
`--request-timeout` alone was observed to bypass automatic in-cluster credentials
and connect to `localhost:8080` instead.

The watchdog uses `ghcr.io/fluxcd/flux-cli:v2.9.6`, whose Alpine-based image includes
`/bin/sh`, `date`, `sleep`, and kubectl 1.36 (matching the cluster's minor version).
The previous `registry.k8s.io/kubectl` image had no shell and could not run recovery.
When changing this image or authentication, smoke-test the generated Job as its
non-root user with `ci-deployer`, confirm API-backed readiness, and delete the
smoke-test Job **before its recovery deadline**. Offline tests cannot prove image
contents or real service-account access.

The runner's `always()` cleanup and the watchdog use the same commands:

1. Pause and drain the operator, then suspend and drain the root.
2. Restore the instance sync ref and GitRepository selector to `main`.
3. Reconcile the source and verify a `main` artifact **before** enabling the
   operator or resuming the root. Its revision must start with
   `refs/heads/main@sha1:` in operator mode or `main@sha1:` in legacy mode.
   This avoids applying cached PR YAML on resume.
4. Restore the instance's original reconcile annotation, either absent or
   `enabled`, and wait for its acknowledged, Ready reconciliation.
5. Resume and reconcile the root, then reconcile the three layers and the
   discovered children of `apps`. Use the same child discovery, reconciliation,
   suspension, and current-generation Ready checks as the PR verdict. Require
   the root, layers, and children to have applied the exact verified main revision,
   then recheck the source and instance refs.
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

## Offline workflow checks

Run the focused regression tests from the repository root:

```bash
python3 -B .github/tests/test_gitops_live_test.py
```

These tests use Python's standard library and local `sh`, `bash`, and Node.js.
They execute the PR authorization script with mocked GitHub responses, check safe
branch inputs, syntax-check the embedded scripts, and exercise the shared shell
functions with mocked Kubernetes calls. Coverage includes operator and
legacy revision formats, immutable PR SHA checks, children discovered after the
parent starts applying, stale Ready generations and revisions, suspended children,
and the shared recovery path. They also check credential-file references, nested
shell configuration inheritance, missing-credential failures, and the watchdog's
API-readiness gate. They do not contact a cluster or prove live controller behavior.

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
