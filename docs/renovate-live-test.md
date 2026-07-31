# Renovate + live health-test pipeline

Automated dependency updates whose green/red status is backed by a **real Flux
reconcile against the live cluster**, not just a dry-run.

## Flow

1. **Renovate** (`.github/workflows/renovate.yml`, weekly / on-demand) scans the
   repo per `renovate.json` and opens **one PR per dependency**:
   - `flux` manager → HelmRelease chart versions + OCIRepository tags
   - `kubernetes` manager → raw `image:` tags in Deployments
   - `github-actions` manager → the actions in these workflows
   - `*.sops.yaml` is ignored.
2. **Live health-test** (`.github/workflows/gitops-live-test.yml`) runs on every
   `renovate/*` PR, on the in-cluster ARC runner `gha-homelab-arc`
   (ServiceAccount `ci-deployer`, so kubectl/flux use the in-cluster config —
   the API is never exposed off-LAN). It is serialized by a `concurrency` group.
   - Arms an in-cluster **watchdog Job** (dead-man's-switch).
   - Repoints the `flux-system` GitRepository `ref.branch` from `main` to the
     PR branch → the whole cluster's desired state becomes `main + this bump`.
   - `flux reconcile` source + Kustomization layers; the **`wait: true` Ready
     condition is the verdict**.
   - **Always** repoints back to `main` and reconciles, restoring production.
   - Posts a check + a PR comment with `flux get kustomizations`.
3. On green you **merge by hand** (no auto-merge). Flux then applies it for real.

## Blast radius (accepted design)

Every Renovate PR briefly flips **all** of prod to an unmerged SHA and cycles
whatever changed. A broken infra bump can momentarily disrupt prod until it is
reverted. The **watchdog** (`gitops-watchdog-<run_id>` Job in `arc-runners`)
force-resets the ref to `main` after ~20 min even if the test runner is killed
by a bad bump (e.g. an ARC/CNI/ingress break), so the cluster self-heals.

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

No new RBAC was needed - `ci-deployer` already has (via the ARC roles):
`patch` on `source.toolkit.fluxcd.io/*` (repoint the GitRepository), `patch` on
`kustomize.toolkit.fluxcd.io/*` (reconcile), and `create/delete` on `batch/jobs`
(the watchdog). It still **cannot read Secrets** - the carve-out is intact.
