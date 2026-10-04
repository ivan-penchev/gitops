# Disposable Flux version transition test

`.github/workflows/flux-upgrade-test.yml` tests Flux Operator and Flux distribution
version changes on disposable kind clusters. It uses **GitHub-hosted
`ubuntu-24.04` runners**, not the homelab ARC runner, production kubeconfig, or
repository secrets. It never connects to the homelab or deploys its workloads.
A green result is evidence for a separate, manually approved production rollout,
not permission to merge or upgrade production automatically.

## Inputs and safety boundary

The harness compares these manifests below
`kubernetes/clusters/homelab/flux-system/`:

- `flux-operator-source.yaml`: Operator chart version in `spec.ref.tag`.
- `flux-operator.yaml`: Operator HelmRelease configuration.
- `flux-instance.yaml`: Flux version in `spec.distribution.version`.

Only those two version fields may differ between baseline and candidate. Other
semantic differences in these three manifests fail preflight rather than being
silently treated as an upgrade test. Every other file under `flux-system/` is
compared recursively, byte for byte: additions, deletions, and changes are rejected,
including changes to `kustomization.yaml`, nested files, or comments and formatting
in those other files. Only the three parsed input files are exempt from that byte
comparison; their semantic version-only guard still applies. This is not a general
root-manifest test and does not validate files outside the installation directory.

The cluster receives **generated safe fixtures only**. Neither the homelab sync
configuration nor its `spec.kustomize.patches` is loaded. The test does not render
or apply the homelab root. Operator charts and Flux images come from public
upstream sources; no private registry credentials are required. An independent
Git fixture and a tiny Helm chart containing ConfigMaps provide observable
reconciliation work without real applications or sensitive data. The fixture's
generated bare Git repository is copied into the server container with `docker cp`,
not shared through a host bind mount. Each publication copies Git objects before
refs, then verifies the served branch points to the expected commit. No production
files are copied into the fixture server.

The workflow uses ordinary `pull_request`, never `pull_request_target`, with
`contents: read` as its only token permission. Both checkouts disable persisted
credentials. PR execution checks out the immutable head SHA from the head
repository (including forks) into `candidate`, and the immutable base SHA into
`baseline`; it does not test GitHub's synthetic merge commit. Candidate code is
untrusted and runs only in the disposable hosted job. GitHub may require approval
before running a fork contribution. Do not add secrets, privileged environments,
or a production runner to this workflow.

## Scenario plan

CI runs one stable check, **Flux version transition**, with a 40-minute job
timeout. The `candidate` scenario (also the CLI default) starts a **fresh baseline**
Operator and Flux pair, then publishes the exact candidate pair together in one
generated Git commit. There is no forced Operator-first intermediate stage, even
when both versions change. This exercises actual same-commit candidate-pair
reconciliation, not every possible controller timing or the homelab's state.

There is no version-change filter: unchanged pairs still run to exercise setup
and reconciliation. An unchanged pair is a **baseline smoke test, not a version
transition**. Changed runs report mode `transition`; unchanged runs report
`baseline-smoke`.

Optional CLI diagnostics remain available but are not required CI jobs:

| Scenario | Target Operator | Target Flux | Transition |
| --- | --- | --- | --- |
| `operator` | Candidate | Baseline | Upgrade the Operator, hold Flux fixed |
| `flux` | Baseline | Candidate | Change Flux, hold the Operator fixed |
| `combined` | Candidate | Candidate | Upgrade the Operator first, then change Flux |

An independent `flux` diagnostic can fail because the old Operator does not
bundle the target distribution, even when the grouped candidate pair succeeds.
That unsupported intermediate pair must not block a grouped PR: the required
check tests the actual candidate pair, not a hypothetical split upgrade.
Neither candidate nor combined success guarantees production ordering or all
reconciliation interleavings.

Operator downgrades are always rejected. A Flux downgrade is allowed only when
the Operator is unchanged; mixing a Flux downgrade with an Operator change is
rejected. A downgrade PR from Flux `2.9.6` to `2.9.5` at Operator `0.61.0` changes
only `spec.distribution.version` in `flux-instance.yaml`. This is an explicit,
reviewed version transition, not an automatic post-upgrade rollback test or an
Operator downgrade.

Helm CLI bootstraps the baseline Operator once. A real Flux `OCIRepository` and
`HelmRelease` then take over Operator self-management, including chart upgrades;
this is not a test that merely calls `helm upgrade`. Flux distribution changes
are reconciled through `FluxInstance/flux`.

## Readiness and behavioral checks

The generated root Kustomization uses `wait: false` because it owns the
FluxInstance, while the Operator waits for that root: recursive resource-health
waiting would create a readiness cycle. This does not waive overall health checks.
The harness checks the root's current readiness and exact applied revision, then
checks the FluxInstance, both HelmReleases, controllers, and probes separately.

Before and after each scenario's transition, the harness verifies:

- Operator self-management resources and the FluxInstance are Ready for their
  **current observed generations**, not a stale Ready condition.
- The latest Operator HelmRelease history entry has the exact expected chart
  version, including the source artifact digest suffix, and `deployed` status;
  Helm independently reports the same deployment.
- Operator and controller Deployments have completed their current rollouts.
  Operator Deployment images match the deployed chart's rendered Deployment;
  Flux controller images match the applied FluxInstance component versions, and
  active controller Pods have ready containers with observed image IDs.
- FluxInstance, GitRepository, OCIRepository, Kustomization, and HelmRelease CRDs
  have their `Established` condition.
- The independent Git source becomes Ready, advances to an exact new Git
  revision, and the fixture Kustomization applies that revision.
- The tiny Helm chart's latest release history entry has the exact expected chart
  version, including the Git revision suffix, and `deployed` status; its ConfigMap
  reflects the stage and chart version.
- Deliberate Kustomize-managed and Helm-managed ConfigMap drift is healed.
- A ConfigMap removed from the Git manifests is pruned. Removal of objects from
  the Helm chart is not currently exercised.

The generated Git chart uses the `Revision` reconcile strategy, so its observed
chart version is `<Chart.yaml version>+<Git SHA's first 12 characters>`. The
Operator's observed chart version is `<Operator version>+<OCI manifest digest's
first 12 characters>`. These build-metadata suffixes are compared exactly against
the current source artifact; they are not stripped or accepted through loose
version matching. The Git artifact revision remains `refs/heads/main@sha1:<SHA>`.

These checks exercise source-controller, kustomize-controller, and
helm-controller behavior. Notification-controller readiness covers its rollout
only, not external notification delivery.

## Running the workflow

PRs targeting any branch, including stacked PRs, trigger the workflow when they change:

- `kubernetes/clusters/homelab/flux-system/**`
- `.github/workflows/flux-upgrade-test.yml`
- `.github/scripts/flux-upgrade/**`
- `.github/tests/test_flux_upgrade.py`

For a stacked manifest-only PR, use the pipeline/harness PR's head branch as its
base. The check compares that PR's actual immutable base/head SHAs. After the
first PR merges, retarget the stacked PR to `main` and rerun CI against its new
base before merging. Configure **Flux version transition** as the required check;
the optional diagnostic scenarios are not merge gates.

For a manual comparison, open **Actions → flux-upgrade-test → Run workflow**.
Select the candidate branch/ref and supply `baseline_ref` (default `main`). The
candidate is the workflow run's immutable `github.sha`; the baseline ref is
resolved during checkout. Use an immutable baseline commit SHA for reproducible
manual runs, particularly when the baseline branch is moving.

Python 3.12 and `PyYAML==6.0.3` run the offline regression suite before cluster
creation. Each job then installs checksum-verified official Linux AMD64 binaries:
kind `v0.33.0`, kubectl `v1.36.4`, and Helm `v3.20.0`. SHA-256 checksums are pinned
in the workflow; update and verify them against the upstream release when
changing a tool version. No downloaded installation script is executed.

The harness invocation is:

```sh
python candidate/.github/scripts/flux-upgrade/run.py \
  --base baseline \
  --candidate candidate \
  --scenario candidate \
  --artifacts "$RUNNER_TEMP/flux-transition"
```

The default node image is
`kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed`,
published for kind `v0.33.0` with AMD64 and ARM64 support. The hosted workflow
installs AMD64 tools; the node image's ARM64 support does not make that workflow
an ARM64 runner test.

## Diagnostics and cleanup

The harness creates a dedicated temporary kubeconfig and uniquely prefixed kind
cluster and fixture Docker container. Its `finally` cleanup removes its own
resources on success, failure, and handled SIGTERM. A hard kill or runner loss can
prevent process cleanup; destruction of the disposable hosted runner is the
remaining isolation boundary. New commits may cancel older runs in the same
workflow concurrency group without affecting production.

The `always()` artifact step retains only the explicit `flux-transition`
diagnostics directory for seven days, including `summary.json`, nonsecret resource JSON,
controller logs, and fixture-server logs. **Kubeconfigs, credential files, full repositories, and fixture
working directories must never enter that directory.** Upload does not sweep the
workspace or runner temporary directory. Failures before harness startup may
have no artifact; inspect the failing setup or offline-test step in that case.
Inspect both the summary and individual job logs before treating a run as upgrade
evidence. Offline tests alone do not prove that an actual version transition has
succeeded.

## Limitations and production rollout

- kind uses its own CNI: this is not validation of production NetworkPolicy,
  networking, storage, DNS, SOPS decryption, or application health.
- The Kubernetes node uses the same minor version as the homelab, not necessarily
  its exact patch version or distribution, topology, or admission configuration.
- Public chart/image availability and hosted-runner network access are test
  dependencies. Registry outages are not necessarily upgrade regressions.
- The generated fixtures exclude production sync and patches deliberately; they
  cannot prove those settings survive an upgrade or that the homelab root remains
  healthy.
- The existing [Renovate live health test](renovate-live-test.md) still rejects
  changes under `kubernetes/clusters/homelab/`. This test does not relax that gate
  or make the suspended-root live test suitable for controller upgrades.
- Production changes require a separately reviewed, manually approved rollout,
  explicit reconciliation ordering, production health checks, and out-of-band
  recovery access that does not depend on healthy Flux controllers.
