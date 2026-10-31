# Backups

Once a week the Proxmox host copies the whole `tank` pool to a USB drive.
The drive stays powered off the rest of the time, so a bad command on the
host between runs can't touch it.

The scripts live in [`host/backup/`](../host/backup). They run on the
Proxmox host, outside Terraform and Flux.

## How a run works

`tank-backup.timer` fires Sunday at 03:00 and starts `tank-backup`, which:

1. Turns the drive on with `usb-drive on`.
2. Imports the `backup` pool.
3. Takes a recursive snapshot `tank@bk-<date>`.
4. Runs `syncoid` to send `tank` to `backup/tank`. After the first run it
   sends only what changed since the last `bk-` snapshot.
5. Deletes all but the newest two `bk-` snapshots of each dataset, on both
   pools. The newest one is the base for next week's send.
6. Exports the pool and turns the drive off, even when a step fails.

The first run copies everything, about 730 GB. Later runs take minutes.

The snapshots are crash-consistent. A VM disk looks like the VM lost power
at that moment. That's fine for files, but databases should also get a dump
of their own. See issue #115.

## Powering the drive off

The Seagate's USB bridge ignores spin-down commands from `hdparm` and
`sdparm`, so the drive can't be told to sleep. Instead `usb-drive off`
disables the USB port it sits on, through
`/sys/bus/usb/devices/.../usbN-portM/disable`. The drive loses its
connection and stops spinning. `usb-drive on` enables the port and the
drive spins back up in about 3 seconds.

A USB 3 socket shows up as two kernel ports, a USB 3 one and a USB 2
peer. The script disables both. With only one disabled, the drive
reconnects through the other.

Order matters. If the drive loses a USB 3 link, it drops off the bus but
the disk keeps spinning. So when the drive is on USB 3, `usb-drive off`
disables the USB 3 port first, waits for the drive to reconnect on USB 2,
then disables the USB 2 port. Losing a USB 2 link makes the enclosure
stop the disk.

The port is found from the drive itself, by its serial in `/dev/disk/by-id`.
`usb-drive off` writes the port to `/var/lib/usb-drive/ports` so `on` knows
which one to enable. If you move the drive to another socket while it's off,
`on` fails. Plug it back in, or replug it anywhere and run `usb-drive off`
once.

`usb-drive-off.service` turns the drive off at boot, because the kernel
enables every port when it starts.

## Set it up

You need the drive plugged into a USB 3 port. At USB 2 speed the first copy
takes about 6 hours.

```sh
curl -fsSL https://raw.githubusercontent.com/ivan-penchev/gitops/main/host/backup/install.sh | bash
```

This installs `sanoid`, which provides `syncoid`, copies the scripts to
`/usr/local/sbin` and the units to `/etc/systemd/system`, and enables the
timer. Settings are in `/etc/default/tank-backup`. Set `DISK_ID` there if
you use a different drive.

Then format the drive. This erases it and asks you to type the pool name
first:

```sh
tank-backup init
```

The pool is created with `cachefile=none` so the host never imports it at
boot, and `volmode=none` so copied VM disks don't show up as block devices.
Everything on it is read-only and unmounted.

Run the first backup by hand and follow it:

```sh
systemctl start --no-block tank-backup && journalctl -fu tank-backup
```

## Check on it

```sh
systemctl list-timers tank-backup.timer   # last and next run
journalctl -u tank-backup -n 30           # output of the last run
usb-drive status                          # should say off
```

Nothing alerts on a failed run yet.

## Restore

Turn the drive on and import the pool. It's read-only, so nothing changes
by accident:

```sh
usb-drive on
zpool import -d /dev/disk/by-id -o cachefile=none backup
zfs list -t snapshot -r backup/tank/<dataset>
```

To get a dataset or VM disk back, send it to `tank` under a new name and
point the guest at it:

```sh
zfs send backup/tank/vm-131-disk-0@bk-<date> | zfs receive tank/vm-131-disk-0-restored
```

When you're done:

```sh
zpool export backup && usb-drive off
```
