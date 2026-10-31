# Sonarr migration plan

Move Sonarr off CasaOS and into the cluster, next to Radarr and Prowlarr in the
`downloads` namespace. Radarr is the template. Same image family, same non-root
uid, same storage pattern, same cold copy.

Status: draft. The open questions below block the build.

## What runs today

I read this from the Sonarr API on 2026-10-31.

| Item | Value |
|------|-------|
| Host | CasaOS LXC 200 at 192.168.68.10, Docker container |
| Image | Alpine based, almost certainly `lscr.io/linuxserver/sonarr` |
| Version | 4.0.16.2944, SQLite |
| Library | 15 series, 209.5 GB, all under root folder `/tv` |
| Downloads | qBittorrent at 192.168.68.30:8090, category `tv-sonarr` |
| Remote path mapping | `/downloads/` to `/downloads/` |
| Indexers | 6, pushed by Prowlarr |
| Notification | Jellyfin at 192.168.68.25:8096, library refresh on import |
| Hardlinks | Enabled, but `/tv` and `/downloads` are different ZFS datasets, so imports copy |
| Auth | Basic, disabled for local addresses |

Prowlarr reaches Sonarr at `http://192.168.68.10:8989/`.

Sonarr shows `/tv` at 1410 GB total and `/downloads` at 1350 GB. Different
totals fit the ZFS layout, where `tank/media/tv` and `tank/media/torrent-download`
are separate datasets. I have not confirmed the CasaOS bind mounts yet.

## Target

- Namespace `downloads`, Flux Kustomization `sonarr` at
  `kubernetes/apps/downloads/sonarr`, depending on `infrastructure-configs`.
- Image `lscr.io/linuxserver/sonarr:4.0.20.3014-ls2`. Sonarr migrates the
  database forward on first start. It never migrates down, so the CasaOS copy
  stays as the rollback.
- Runs as uid and gid 100000, the owner of the media tree on the fileserver. The
  NFS export ignores supplemental groups, so only the owner can write.
- A root init container chowns the config PVC. No `fsGroup`, because that would
  make kubelet chown the whole NFS mount.
- `DOTNET_gcServer=0` from the start. Radarr OOMed without it.
- Config PVC: 2Gi on `proxmox-tank`.
- Two static NFS PVs, `sonarr-tv-nfs` at `/srv/media/tv` mounted on `/tv`, and
  `sonarr-downloads-nfs` at `/srv/media/torrent-download` mounted on
  `/downloads`. These are the paths the database already uses, so it needs no
  edits.
- Internal ingress `sonarr.${lan_domain}` with the Homepage annotations Radarr
  uses. No public exposure.

## Fileserver change

The fileserver LXC 110 does not expose the `tv` dataset yet. `/srv/media/tv` on
the fileserver is an empty, root owned directory on the parent dataset.

1. Add `tv` to `fileserver.child_datasets` in `terraform/shared/shared.auto.tfvars`.
   Terraform then writes the export line.
2. You run the bind mount on the Proxmox host as root@pam, because the API token
   cannot set bind mounts:
   `pct set 110 -mp3 /tank/media/tv,mp=/srv/media/tv` and `pct reboot 110`.
   The exact command comes from the `fileserver_host_mount_command` output.
3. Remove the empty `/srv/media/tv` directory on the parent dataset first, or the
   bind mount hides it. Do not `rmdir` while anything is mounted there. That is
   how `movies` got detached during the Radarr work.
4. Check from a pod that `/srv/media/tv` shows the series and is owned by 100000.

If the tv files are owned by someone other than 100000, Sonarr can read but not
import. We would need a one-time chown on the host.

## Cutover

1. Merge the fileserver change, apply `terraform/shared`, run the host command.
2. Merge the Sonarr manifests. Flux starts an empty Sonarr.
3. Stop the Sonarr container on CasaOS. You tar `sonarr.db` and `config.xml`
   from its `/config` volume and serve the tarball over HTTP on the LAN.
4. I scale Sonarr to 0, load the files into the PVC with a root helper pod,
   chown to 100000 and scale back up. The API key stays the same.
5. Check that all 15 series resolve with no missing files, qBittorrent tests
   green, and the Jellyfin notification tests green.
6. Point Prowlarr's Sonarr app at `https://sonarr.${lan_domain}` and run a sync.
7. Leave the CasaOS container stopped for a week as the rollback, then remove it.

## Open questions

1. Which host paths does CasaOS bind into the container for `/tv`, `/downloads`
   and `/config`? I need `pct config 200` from the host and
   `docker inspect sonarr` from CasaOS. If `/tv` is not `tank/media/tv`, the
   fileserver step changes.
2. Who owns the files under `tank/media/tv`? `ls -ln /tank/media/tv | head` on
   the host answers it.
3. Does anything else on CasaOS use Sonarr, for example Jellyseerr or Overseerr?
   Those need the new URL too.
4. Should Sonarr keep its own Flux Kustomization, like Radarr, or share one?
   I suggest its own.
5. Jellyfin still runs on LXC 102. The notification keeps working by IP. Fine for
   now?
