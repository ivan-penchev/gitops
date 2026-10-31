# Sonarr migration plan

Move Sonarr off CasaOS and into the cluster, next to Radarr and Prowlarr in the
`downloads` namespace. Radarr is the template. Same image family, same non-root
uid, same storage pattern, same cold copy.

Status: the fileserver exports `tv` (applied 2026-10-31). The Sonarr manifests wait for the merge.

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

CasaOS is an unprivileged LXC. The Proxmox API shows its bind mounts:

| LXC mount | Host path |
|-----------|-----------|
| mp0 `/downloads` | `/tank/media/torrent-download` |
| mp2 `/media/tv` | `/tank/media/tv` |
| mp3 `/tank` | `/tank/media` |

Docker then maps the LXC paths into the container. Sonarr shows `/tv` at
1410 GB total and `/downloads` at 1350 GB, so they are different datasets. That
fits `/tv` coming from `tank/media/tv`. The container's `/config` sits somewhere
on the LXC root disk. We find the exact path during the cold copy.

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

1. `terraform/shared/shared.auto.tfvars` lists `tv` in
   `fileserver.child_datasets`. Terraform writes the export line and prints the
   new `fileserver_host_mount_command`.
2. You run the bind mount on the Proxmox host as root@pam, because the API token
   cannot set bind mounts:
   `pct set 110 -mp3 /tank/media/tv,mp=/srv/media/tv && pct reboot 110`.
   The reboot pauses the Radarr and Audiobookshelf NFS mounts for a few seconds.
   They use `hard` mounts, so they wait and resume.
3. Leave the empty `/srv/media/tv` directory alone. The bind mount covers it. Do
   not `rmdir` anything under `/srv/media`. That is how `movies` got detached
   during the Radarr work.
4. I apply `terraform/shared` and check from the fileserver that `/srv/media/tv`
   shows the series.

The tv files belong to uid and gid 100000, the same as movies, so Sonarr can
write them without a chown. The dataset holds 195G.

## Cutover

1. Run the host command, then I apply `terraform/shared` from this branch. The
   Sonarr PVs need the `tv` export before Flux creates them.
2. Merge this PR. Flux starts an empty Sonarr.
3. Stop the Sonarr container on CasaOS. You tar `sonarr.db` and `config.xml`
   from its `/config` volume and serve the tarball over HTTP on the LAN.
4. I scale Sonarr to 0, load the files into the PVC with a root helper pod,
   chown to 100000 and scale back up. The API key stays the same.
5. Check that all 15 series resolve with no missing files, qBittorrent tests
   green, and the Jellyfin notification tests green.
6. Point Prowlarr's Sonarr app at `https://sonarr.${lan_domain}` and run a sync.
7. Leave the CasaOS container stopped for a week as the rollback, then remove it.

## Decisions

- Sonarr gets its own Flux Kustomization, like Radarr.
- Nothing else uses Sonarr, so only Prowlarr needs the new URL.
- Jellyfin stays on LXC 102 for now. The notification keeps working by IP.

## Still to check

1. Host path of the container's `/config` on CasaOS, during the cold copy.
