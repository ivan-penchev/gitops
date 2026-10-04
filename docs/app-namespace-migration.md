# Application namespace migration

## Status and scope

Execution was approved on 2026-10-04. No workloads have moved namespaces yet.
The user confirmed cold ZFS snapshots of all four application-state volumes
with tag `namespace-migration-20261004`, created at 16:36 Proxmox host time.
Encrypted cold archives of all four state volumes were restored to disposable
storage. File hashes, numeric ownership, modes, application xattrs and SQLite
integrity passed; platform-assigned SELinux labels on disposable storage were
excluded from the comparison. All three restored apps booted with their existing
images under deny-ingress/egress policies, without shared media mounts. Private
checks confirmed initialization, authentication and the expected Arr data counts.
Native snapshot rollback itself has not been exercised.

All seven existing PVs now have `Retain` protection and live `apps` pruning is
disabled. The live-test and Renovate workflows remain disabled, FluxInstance
reconciliation and the root and `apps` Kustomizations are paused, and the four
affected Deployments are stopped. Wattbill remains running. Do not resume
reconciliation until the maintenance procedure has completed or been rolled back.

Do not merge this change or point the live source at it before completing the
live reconciliation safeguards below. A Git change to `apps.spec.prune` alone
cannot protect existing workloads: the source can reach `apps` before the root
has applied the new prune setting.

| App | Old namespace | New namespace | New workload path |
| --- | --- | --- | --- |
| Prowlarr and FlareSolverr | prowlarr | downloads | `kubernetes/apps/downloads/prowlarr/app` |
| Radarr | radarr | downloads | `kubernetes/apps/downloads/radarr/app` |
| Audiobookshelf | audiobookshelf | media | `kubernetes/apps/media/audiobookshelf/app` |

Prowlarr and Radarr stay separate Deployments and Flux Kustomizations. Sharing a
namespace does not make either depend on the other. FlareSolverr moves with
Prowlarr, so `http://flaresolverr:8191` still works. Wattbill remains directly
managed by `apps`; its manifests and namespace do not change.

Each new Flux object lives in `flux-system`, uses the existing GitRepository,
SOPS Secret and substitution ConfigMaps, and sets `targetNamespace`. Category
recipes create Namespaces and child Flux objects, not workloads. Do not add a
category-wide Kustomize `namespace:` transformer, which would relocate those
Flux objects and break access to their configuration.

The review revision contains two temporary settings:

- Each new child has `suspend: true`. Do not remove it until its PVCs are bound
  to the original volumes and the app has passed private verification.
- Parent `apps` has `prune: false`. Restore it only after the parent has dropped
  the old resources from its inventory and each child owns its new resources.

Parent `wait: true` remains the steady-state readiness policy. While children
are suspended or unready, parent readiness is not a migration success signal.
The live-test workflow must fail on suspended children, not skip them.

## Storage inventory

Read-only inspection found these bindings. Re-read them immediately before
execution and stop if any mapping, capacity, driver, node affinity or reclaim
policy differs. Record the current PVC UID, PV claimRef UID, CSI volumeHandle,
volume attributes and attachment state in a private recovery inventory.

| Old claim | Existing PV | Reclaim policy at inspection |
| --- | --- | --- |
| prowlarr/prowlarr-config | `pvc-56af07e5-87d2-4aa6-9a7f-5dd80acdb251` | Delete |
| radarr/radarr-config | `pvc-f0bdb006-3d75-492c-be8e-592fba69278f` | Delete |
| audiobookshelf/audiobookshelf-config | `pvc-23605aed-7259-4f2c-83eb-170cf7b1c096` | Delete |
| audiobookshelf/audiobookshelf-metadata | `pvc-29c79cd2-772f-4148-b591-d5026f78b45b` | Delete |
| radarr/radarr-movies-nfs | `radarr-movies-nfs` | Retain |
| radarr/radarr-downloads-nfs | `radarr-downloads-nfs` | Retain |
| audiobookshelf/audiobookshelf-media-nfs | `audiobookshelf-media-nfs` | Retain |

The four block volumes hold application state. Deleting their claims while
the policy is `Delete` can delete the underlying disks. Set all seven PVs to
`Retain` and verify the persisted values before deleting any old claim. Leave
the block PVs on `Retain` after migration; they are dynamically provisioned and
are not declared as PV objects in this repository.

The static NFS PV names, CSI volumeHandles and shares stay unchanged. Only their
claimRef namespaces change. Keep `/media/movies`, `/downloads` and
`/mnt/audiobooks` unchanged inside the containers. A Retain policy is not a
backup and does not prevent application writes from deleting files.

The new block PVC manifests deliberately do not hardcode current PV UUIDs.
Before starting a child, create its PVCs with explicit `spec.volumeName` from
the verified inventory. Otherwise `proxmox-tank` can provision empty disks.
That binding remains on the live PVC when Flux adopts it. Do not use replace,
force recreation or a delete/recreate cycle to resolve immutable-field errors.

Read-only preflight commands, always from the repository root:

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl config current-context
kubectl get kustomizations -n flux-system
kubectl get pvc -n prowlarr
kubectl get pvc -n radarr
kubectl get pvc -n audiobookshelf
kubectl get pv
kubectl get volumeattachments
```

Require `admin@homelab`. Do not use the ambient kubeconfig. Store backups,
resource exports and any rendered configuration outside the repository with
restricted permissions. Encrypt exports that contain credentials. Never print
SOPS keys, API keys, application databases or decrypted Secrets in logs.

## Before changing the source

1. Obtain execution approval. Record the currently healthy Git SHA and image
   versions. Keep that revision available locally for rollback; old LXC backups
   are not a substitute for current Kubernetes app data.
2. Disable scheduled writers and prevent manual live-test runs for the window.
   Record their previous settings. Require no active live-test runner or
   recovery watchdog, since either can switch the source back to main or resume
   the root during migration. Do not kill an active test midway through recovery.
3. Pause FluxInstance reconciliation with its supported disabled annotation,
   request reconciliation, and wait for that request to be acknowledged. Then
   suspend the root `flux-system` Kustomization and acknowledge its request.
   Suspend `apps` too and wait for any in-flight reconcile to finish. Merely
   observing `spec.suspend: true` is not enough.
4. Set the live `apps` Kustomization to `prune: false`, and read it back. Confirm
   the old app resources still belong to `apps` and that no other reconciler
   manages them. Keep the root and operator paused so neither can undo this.
5. Capture the old `apps` inventory, seven volume mappings, Deployments,
   Services, Ingresses and namespace policies. Inspect app settings privately
   for old service FQDNs, IPs or namespace-dependent integrations. Preserve the
   existing ingress hostnames. Check Prowlarr's Radarr connection and any
   FlareSolverr URL, download clients, monitoring and backup selectors.
6. Confirm `downloads` and `media` do not contain conflicting objects or PVCs.
   Stop and resolve any collision rather than adopting unknown data. Confirm
   no quota, admission policy or NetworkPolicy changes access in the new namespaces.
7. Set and verify `Retain` on every affected PV. Confirm storage supports
   detaching and reusing these exact volumes; do not proceed on an unverified
   CSI error or an unavailable original volume.

Wattbill keeps running while `apps` is suspended, but loses automatic drift
repair for that interval. Do not scale it or recreate any of its resources.

## Establish the new reconciliation boundary

With the safeguards active, merge the reviewed staging revision only after
approval, then reconcile the source to its exact main SHA. Verify the source
artifact matches it. Keep the operator and root paused throughout this phase.

Set the live parent `apps` to `wait: false` temporarily, keep `prune: false`,
and let it reconcile the new app catalog. This creates the two namespaces and
three suspended children without starting their workloads. It also reapplies
Wattbill without changing its rendered configuration. Wait for the parent's
successful applied revision and inspect its new inventory before suspending
it again.

The new inventory must contain the new namespace and child Flux objects plus
Wattbill, but none of the old Prowlarr, Radarr or Audiobookshelf workloads,
claims, namespaces or static PVs. Those old resources should still exist,
orphaned by `prune: false`. Do not delete them as a group. In particular, do not
delete an old Namespace as a shortcut for removing workloads.

Confirm every child is suspended. They depend on `infrastructure-configs`, not
on `apps`, so the parent's later readiness checks cannot create a dependency
cycle. Keep `apps` suspended while making temporary child or workload changes.

## Move one app at a time

Use Prowlarr first, then Radarr, then Audiobookshelf. Complete the checks for
one before touching the next. All commands that mutate bindings must be
reviewed against the fresh inventory, not copied from the table without checks.

1. Leave the child's Git suspension in place. Remove the old app's Ingresses
   before creating equivalent hosts in the new namespace. This avoids nginx
   duplicate-host admission errors and prevents public access during checks.
   Do not alter blog records or tunnel configuration.
2. Scale the old app to zero and wait until its pods have terminated. For
   Prowlarr, stop FlareSolverr too. Verify no remaining pod mounts its claims.
   A disabled Flux reconciler must not restore the old replica count.
3. Make a cold, encrypted backup of every state volume for that app. Include
   SQLite databases, WAL files, settings and file ownership. Audiobookshelf
   needs both `/config` and `/metadata`; Prowlarr and Radarr each need `/config`.
   Use a temporary maintenance pod to stream an archive directly into age
   encryption, with no plaintext archive written to disk. Preserve numeric
   owners, permissions, symlinks and any required extended attributes. Record
   archive checksums and the matching app image version without logging contents.
4. Restore that backup to disposable storage and verify archive integrity,
   ownership and SQLite integrity where applicable. Verify expected application
   data privately with the matching image. Keep this test isolated from public
   ingress, production integrations and shared writable media. A snapshot of
   `tank/media` does not cover these application-state volumes and is not a
   prerequisite for this namespace-only migration. Media snapshots are optional
   additional protection against application writes; the existing NFS datasets
   and their contents are not moved. Stop if the state backup restore has not
   been tested. Remove backup/test pods and ensure original volumes are unmounted
   and detached before rebinding.
5. Create only the new PVCs from the storage manifests, adding explicit
   `volumeName` for each block claim. Do not apply the whole storage file yet:
   it also contains existing static PVs whose claimRef still belongs to the old
   namespace. Check class, capacity, access modes and volume mode against the
   original PVCs. While the old claims still exist, the new ones should remain
   Pending on those exact PVs and must not allocate replacements.
6. Reconfirm `Retain`, stopped writers and backup recovery. Delete only this
   app's old PVCs. Wait for deletion and PV release. Never remove PVC/PV
   protection finalizers to bypass a stuck pod or attachment.
7. For each released PV, replace the entire old `claimRef` with the new PVC's
   namespace, name and UID. Use resourceVersion/old-UID preconditions to avoid
   racing another binder. Do not merely change the namespace and leave the old
   UID, and do not leave the PV unreserved for an unrelated claim to acquire.
   Preserve the PV itself, volumeHandle, node affinity and volume attributes.
8. Wait for every new PVC and PV pair to be Bound. Assert the original PV name,
   driver and volumeHandle, the new claim UID and expected namespace. Refuse to
   start if any claim is Pending, missing or bound to a newly provisioned disk.
9. With Flux still suspended, use a private maintenance check to verify the
   mounted state and expected ownership, then remove that pod. Start only the
   app Deployment and Service from the reviewed manifests, using the existing
   substitutions. Prowlarr also needs FlareSolverr. Do not apply an Ingress or
   the entire app recipe yet. Verify through port-forwarding or a private
   connection. Stop immediately if the app offers first-run setup or has lost data.
10. Verify the existing user accounts, settings and libraries. Check Prowlarr
    indexers, FlareSolverr and app connections; Radarr profiles, root folders,
    downloads and imports; Audiobookshelf users, libraries, playback progress
    and metadata. Keep the old Deployments at zero. Do not run two copies
    against the same state, even though a PVC reports ReadWriteOnce.
11. After those checks, temporarily resume only this child while its parent
    remains suspended. Reconcile it at the exact reviewed source revision.
    It adopts the prepared PVCs, PVs and workloads, and creates the Ingresses.
    Audiobookshelf's public Ingress is in its recipe, so this is the public
    release gate. Check HTTPS, authentication, websocket behavior and the
    expected data after it becomes reachable.
12. Require current-generation Ready and the expected `lastAppliedRevision`.
    Inspect the child's inventory and Flux ownership labels, including its
    static PVs. All migrated resources must belong to the child, not `apps`.
    Check Wattbill's health and unchanged rollout throughout the window.

If Flux reports an immutable PVC/PV change, suspend the child and investigate.
Do not enable force recreation. The repository intentionally keeps storage
classes, capacity, access modes, volume identities and mount paths unchanged.

## Finish and restore automation

After all three apps pass their checks, prepare and approve a follow-up commit
that removes the three `suspend: true` settings and their migration comments,
restores `apps.prune: true`, and updates the README's staged-status paragraph.
Do not resume the parent while Git still says the verified children are suspended.

Reconcile the source to the approved final SHA. With the root still paused,
restore live parent `wait: true` and let `apps` reconcile. Require parent and
all children Ready at that SHA, and inspect the parent inventory again before
restoring its live pruning. Reconcile once with pruning enabled and verify no
migrated resource disappears. Parent readiness alone does not prove every
child applied the current source revision; check their revisions explicitly.

Restore root reconciliation, then restore the operator's original reconciliation
annotation. Verify both settle on main and all affected objects retain the
intended prune, wait and suspend settings. Re-enable scheduled automation only
after the cluster is healthy, no migration overrides remain, and source refs
and applied revisions agree.

Old namespaces and zero-replica Deployments are rollback aids. Retain them
through the agreed rollback window. Then inspect all namespaced resource types,
confirm there are no PVCs or other needed objects, and remove the old app
objects and empty namespaces explicitly. Retain encrypted backups according
to the normal backup policy. Do not delete the retained PVs or media datasets.

The migration cannot use the ordinary Renovate live test. It changes the root
`apps` object, has suspended children, and needs controlled data movement.
After completion, routine app changes can use the updated test's child readiness
and exact-revision checks. No AI category or cross-app dependency is added here.

## Rollback and abort conditions

Stop if backups cannot be restored, a volume mapping changes, a disk is missing,
claims bind unexpectedly, a child starts early, ingress exposes an uninitialized
app, or either controller/watchdog starts reconciling outside this procedure.
Keep affected children and the parent suspended while resolving the problem.

Before deleting any old claim, rollback is to remove only the unbound new claim,
restart the old Deployment and restore its Ingress after confirming its data.

After rebinding, rollback needs another controlled transfer:

1. Block the new ingress and suspend the child, parent, root and operator.
   Stop the new app and wait for every writer and attachment to finish. Record
   whether it has made new writes. Preserve a fresh encrypted backup first.
2. Keep all PVs on `Retain`. Recreate the old claims with explicit original
   `volumeName` while the new claims reserve the volumes. Delete only the new
   claims after confirming there are no users of them. Rebind released PVs to
   the recreated old claims using their new UIDs and verify every binding.
3. Run the old namespace workload with the same image used before this move.
   Do not downgrade against a database that a newer image has migrated. If data
   is corrupt, restore the tested cold backup with the matching image. Agree on
   any loss of writes since that backup before restoring it.
4. Verify the old app privately, then restore its original Ingress. Keep the
   new Deployment at zero and remove duplicate host rules.
5. Revert the layout through an approved Git change. If only one app is being
   rolled back, retain the new layout and children for the other migrated apps;
   a full layout revert requires rolling back all three apps first. Keep parent
   pruning off while it adopts the reverted app's old objects again and drops
   that app's child Flux object from inventory. Do not delete a child with pruning enabled while it still owns
   PVs or claims. If deleting it is necessary, set `deletionPolicy: Orphan`
   first and verify that setting. Confirm inventories and ownership before
   restoring pruning, root/operator reconciliation and scheduled automation.

Do not simply revert Git while new writers are running. A revert neither moves
PVCs back nor removes old claim UIDs, and two reconcilers can fight over the
same static PVs.
