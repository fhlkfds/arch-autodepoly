# Bootable Btrfs snapshots

Automatic snapshots of the root subvolume before every package transaction, a
manual `machi snapshot` command, and a GRUB submenu that boots any of them.

Managed by `roles/snapshots`. Apply with:

```bash
ansible-playbook -i inventory/local.ini site.yml --tags snapshots --ask-become-pass
```

## What is installed, and why

| Package | Why this one |
| --- | --- |
| `snapper` | The snapshot engine. In `extra`, upstream-maintained, and the only btrfs snapshot tool on Arch with per-config retention algorithms, a pre/post snapshot model and a D-Bus interface that lets a non-root user list and create snapshots. |
| `snap-pac` | The pacman hooks. In `extra`. Its triggers are already exactly right (`Type = Package`, `Operation = Install/Upgrade/Remove`), so nothing here reimplements them. |
| `grub-btrfs` | The boot menu. Generates `menuentry` blocks for every snapshot, detects a separate `/boot`, and ships the initcpio hook that makes a read-only snapshot bootable. |
| `btrfs-progs`, `inotify-tools` | Already present; listed so the role does not depend on another role having installed them. |

Timeshift was rejected: it has no pacman integration, so it cannot take a
snapshot *before* a transaction. It is left installed but unused — it was never
configured on this host (`btrfs_mode` is `false`, no timers exist). The one
thing it did own was `grub-btrfsd`, which this role repoints (see
[Boot menu](#how-a-snapshot-is-offered-at-boot)).

Snapper was chosen over a hand-written `btrfs subvolume snapshot` script
because retention, free-space limits, pre/post pairing and the unprivileged
D-Bus path are all things that script would have to grow.

## Layout

The host already used the flat `archinstall` layout. The role added one
subvolume:

```
subvolid=5 (filesystem root, not mounted during normal operation)
├── @            → /                      the system; this is what gets snapshotted
├── @home        → /home                  excluded
├── @log         → /var/log               excluded
├── @pkg         → /var/cache/pacman/pkg  excluded
└── @snapshots   → /.snapshots            the snapshot store   ← added
```

Snapshots live at `/.snapshots/<number>/snapshot` and are **read-only**.

`@snapshots` is top-level rather than a nested `@/.snapshots` for two reasons:

* the rollback procedure below replaces `@` wholesale, which would take a
  nested store — and every snapshot in it — with it;
* `btrfs subvolume snapshot` does not descend into nested subvolumes, so a
  top-level store also keeps the snapshots out of the snapshots.

This cost one **additive** line in `/etc/fstab`. No existing line was changed,
and the original file is kept at
`/var/lib/arch-autodeploy/fstab.before-snapshots`.

### What is excluded, and what is not

Excluded for free, because `btrfs subvolume snapshot` skips nested subvolumes
and other filesystems: `/home`, `/var/log`, `/var/cache/pacman/pkg`,
`/.snapshots`, `/boot` (a vfat ESP), `/tmp` (tmpfs), `/var/lib/machines`,
`/var/lib/portables`.

**Not excluded**, and worth knowing about on this host:

| Path | Size today |
| --- | --- |
| `/var/lib/libvirt` | ~75 GB |
| `/var/lib/containerd` | ~47 GB |
| `/var/lib/docker` | ~4.5 GB |

A snapshot costs nothing when taken, but it pins every extent the live system
later overwrites or deletes. VM disk images and container layers are the
heaviest churn on the machine, so each retained snapshot can hold onto gigabytes
of superseded VM data. This is why retention defaults are far below snapper's
shipped values.

It also means **a rollback reverts those paths too** — VM disks and container
state included. If that becomes a problem, move them onto their own
subvolumes; that is a data migration, not a config change, so this role does
not do it:

```bash
# Sketch, with libvirt and docker stopped, and a backup taken first.
systemctl stop libvirtd docker
mount -o subvolid=5 /dev/mapper/root /mnt
btrfs subvolume create /mnt/@libvirt
rsync -aHAX --info=progress2 /var/lib/libvirt/ /mnt/@libvirt/
# add an fstab line for /var/lib/libvirt with subvol=/@libvirt, mount it,
# verify, then remove the old data.
```

## Retention and free-space safeguards

Set in `roles/snapshots/defaults/main.yml`; the effective values are visible
with `snapper -c root get-config`.

| Variable | Default | Effect |
| --- | --- | --- |
| `snapshots_number_limit` | `10` | Automatic (pre/post) snapshots kept. Each transaction makes a pair, so this is about the last five transactions. |
| `snapshots_number_limit_important` | `5` | Kept for transactions touching `snapshots_important_packages` (kernel, mkinitcpio, grub, systemd). |
| `snapshots_number_min_age` | `3600` | Nothing is deleted before this age, so a cleanup right after an update cannot remove the snapshot that update just made. |
| `snapshots_space_limit` | `0.25` | Cleanup keeps deleting while snapshots occupy more than this fraction of the filesystem. |
| `snapshots_free_limit` | `0.25` | Cleanup keeps deleting while less than this fraction of the filesystem is free. |
| `snapshots_min_free_gib` | `20` | `machi snapshot create` refuses below this; the pacman hook warns. |
| `snapshots_timeline_enabled` | `false` | Hourly snapshots. Off: the point here is pre-update snapshots, and hourly snapshots of the churn above fill a disk fastest. |

Three independent guards:

1. **`snapper-cleanup.timer`** (enabled) applies the limits above daily. This
   is the only thing that enforces them — `snap-pac` tags snapshots with the
   `number` algorithm but never runs it.
2. **`machi snapshot create`** refuses outright below `snapshots_min_free_gib`
   and prints what to reclaim.
3. **The pacman pre-transaction hook** warns below the same floor but
   deliberately never blocks: a full disk is a reason to reclaim space, not a
   reason to refuse a security update.

Manual snapshots (`machi snapshot create`) get **no** cleanup algorithm, so
they are never rotated out. That is deliberate — you asked for them — but it
means they are yours to delete.

## Automatic pre-update snapshots

`snap-pac` ships two pacman hooks, `05-snap-pac-pre.hook` (PreTransaction) and
`zz-snap-pac-post.hook` (PostTransaction). Both trigger only on
`Type = Package` with `Operation = Install`, `Upgrade` or `Remove`, so:

* `pacman -Syu`, `pacman -S <pkg>`, `pacman -R <pkg>` → snapshot pair;
* `yay`, `paru` and any other AUR helper → same hooks, because they all install
  through pacman;
* `pacman -Sy`, `pacman -Q`, `pacman -Sw` (download only), a failed dependency
  resolution → **nothing**, because no package changes.

What gets recorded:

```
# │ Type   │ Pre # │ Date                     │ User │ Cleanup │ Description
2 │ pre    │       │ Fri Sep 11 09:01:06 2026 │ root │ number  │ pacman -S --noconfirm inotify-tools
3 │ post   │     2 │ Fri Sep 11 09:01:06 2026 │ root │ number  │ inotify-tools
```

The pre snapshot's description is the command line that triggered it and the
post snapshot's is the packages involved — snap-pac's own defaults, kept
because nothing else records either. The timestamp and the `pre`/`post` type
are stored by snapper alongside, and all four appear in the GRUB menu.

Useful extras:

```bash
snapper -c root status 2..3      # every file a transaction changed
SNAP_PAC_SKIP=y pacman -S <pkg>  # skip the snapshot for one transaction
```

To turn the pre/post pair into a single pre snapshot, set
`snapshots_snap_pac_post: false`. To stop automatic snapshots entirely, set
`snapshots_auto_pre_update: false` — the hooks still run but create nothing,
which is cleaner and more reversible than deleting files pacman owns.

## Manual commands

```bash
machi snapshot create                      # "manual snapshot (machi)"
machi snapshot create "before nvidia swap" # your own description
machi snapshot list
machi snapshot cleanup                     # applies retention, after confirming
machi snapshot cleanup --yes               # same, unattended
machi snapshot space-check                 # what the pacman hook runs
```

`list` and `create` need no `sudo`: the snapper config lists
`snapshots_allow_users` in `ALLOW_USERS`, so they work over snapper's D-Bus
interface as your own user, and the snapshot records who took it. If that
access is ever missing, `machi` prints the exact command to rerun rather than
escalating by itself.

`cleanup` never deletes silently: it lists what exists, prints the retention
policy that will be applied, states that manual snapshots are exempt, and asks
before doing anything. In a non-interactive context it refuses unless `--yes`
is given.

## How a snapshot is offered at boot

`/etc/grub.d/41_snapshots-btrfs` writes `/boot/grub/grub-btrfs.cfg`, and
`grub.cfg` carries a wrapper that sources it:

```
submenu 'Arch Linux snapshots' {
    configfile "${prefix}/grub-btrfs.cfg"
}
```

So `grub.cfg` itself does not change when snapshots come and go — only the
sourced file does. `grub-btrfsd.service` watches `/.snapshots` with inotify and
regenerates it within seconds of a snapshot appearing, so the menu does not go
stale between Ansible runs.

Deletion is less reliable, and this role works around it. The daemon runs
`inotifywait -e create -e delete` and regenerates on the *first* event it sees,
but deleting a snapshot is several filesystem operations — so it sometimes
rebuilds the menu while the subvolume still exists, then sees no further event
and leaves an entry for a snapshot that is gone. Selecting such an entry fails
to boot, because the kernel cannot mount the missing subvolume. Two backstops:

* `snapper-cleanup.service` carries an Ansible-managed drop-in with
  `ExecStartPost=-/etc/grub.d/41_snapshots-btrfs`, so the daily retention pass
  always leaves a correct menu.
* `machi snapshot cleanup` regenerates unconditionally rather than trusting the
  daemon.

After deleting a snapshot **by hand** with `snapper delete`, refresh the menu
yourself if you care about it before the next cleanup run:

```bash
sudo /etc/grub.d/41_snapshots-btrfs
```

A stale entry is cosmetic until you select it, and regenerating is idempotent,
so this is safe to run at any time.

**At boot:** pick *Arch Linux snapshots* → choose a row (date, subvolume, type,
description) → pick the kernel entry inside it.

A generated entry looks like this:

```
linux  "/vmlinuz-linux" root=UUID=<root> cryptdevice=UUID=<luks>:root \
       rootfstype=btrfs loglevel=3 quiet \
       rootflags=rw,relatime,compress=zstd:3,ssd,space_cache=v2,subvol="@snapshots/2/snapshot"
initrd "/intel-ucode.img" "/initramfs-linux.img"
```

Two things about this host shape it:

* **`/boot` is a separate vfat ESP**, so the kernel and initramfs live *outside*
  every snapshot. grub-btrfs detects that and points snapshot entries at the
  ESP copies. See [the kernel caveat](#the-one-real-caveat-kernel-modules).
* **Snapshots are read-only, and Arch cannot boot a read-only root.** The
  `grub-btrfs-overlayfs` initcpio hook (added to `HOOKS` in
  `/etc/mkinitcpio.conf` by this role) notices a read-only btrfs root and
  stacks a tmpfs overlay on it. A booted snapshot then behaves like a live
  image: fully writable, and **everything you change in it is lost on reboot**.
  The snapshot itself is never modified. Because `/boot` is separate, the single
  initramfs on the ESP carries this hook for *every* snapshot entry, including
  snapshots taken before the hook existed.

### The one real caveat: kernel modules

Because the kernel comes from the ESP and not from the snapshot, booting a
snapshot that predates a **kernel upgrade** gives you the *new* kernel running
against the snapshot's *older* `/usr/lib/modules`. The system boots — btrfs,
overlayfs and the LUKS unlock are all in the initramfs — but modules for the
running kernel are missing, so some hardware and features will not work.

That is fine for what snapshot boots are for: getting a shell to inspect or
roll back. It is not a working desktop. After a permanent rollback, resync the
kernel and its modules:

```bash
pacman -S linux        # reinstalls the kernel matching the rolled-back modules
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg
```

Snapshots that do *not* straddle a kernel upgrade have no mismatch at all.

## Rolling back permanently

Booting a snapshot is temporary — the overlay is discarded on reboot. To keep
it, `@` has to be replaced by a writable copy of the snapshot. This is
deliberately **not** automated: it is irreversible in the sense that it changes
what the system is, and it is one command away from being wrong.

`snapper rollback` is **not** the command for this layout. It expects the
openSUSE arrangement where `/` is itself a snapshot; here `/` is `@`, and
`snapper rollback` would not do what you mean.

Do this instead, from a booted snapshot or an Arch live USB (with the LUKS
container already unlocked, e.g. `cryptsetup open /dev/nvme0n1p2 root`):

```bash
# 1. Mount the filesystem root, where the subvolumes live.
mount -o subvolid=5 /dev/mapper/root /mnt

# 2. Confirm what you are about to do.
ls /mnt                      # expect @ @home @log @pkg @snapshots
snapper -c root list         # pick the snapshot number, e.g. 2

# 3. Move the current system aside. Keep it: this is your undo.
mv /mnt/@ /mnt/@.broken-$(date +%Y%m%d)

# 4. Create a writable copy of the snapshot as the new @.
#    No -r: the new root must be writable.
btrfs subvolume snapshot /mnt/@snapshots/2/snapshot /mnt/@

# 5. Reboot into it.
umount /mnt && reboot
```

Afterwards:

```bash
# Only once the rolled-back system is proven good:
mount -o subvolid=5 /dev/mapper/root /mnt
btrfs subvolume delete /mnt/@.broken-YYYYMMDD
```

To undo step 3 before deleting it, reverse the move: `mv /mnt/@ /mnt/@.rejected
&& mv /mnt/@.broken-YYYYMMDD /mnt/@`.

Notes:

* `/home`, `/var/log` and the package cache are **not** rolled back — they are
  separate subvolumes. Usually what you want; occasionally not.
* Snapshots survive, because `@snapshots` is top-level and step 3 only touches
  `@`.
* If the kernel changed between the snapshot and now, resync it as described
  above.

## Disabling and uninstalling

To stop new snapshots but keep everything that exists:

```yaml
snapshots_auto_pre_update: false
```

To leave every managed file untouched on the next run (this does **not**
uninstall anything already deployed):

```yaml
snapshots_enabled: false
```

To remove the feature completely, by hand:

```bash
# 1. Stop the automation.
systemctl disable --now grub-btrfsd.service snapper-cleanup.timer snapper-timeline.timer

# 2. Delete the snapshots. Irreversible.
snapper -c root list
for n in $(snapper -c root --machine-readable csv list | awk -F, 'NR>1 && $3!=0 {print $3}'); do
  snapper -c root delete "$n"
done

# 3. Remove the boot integration.
rm -f /boot/grub/grub-btrfs.cfg
sed -i 's/ grub-btrfs-overlayfs//' /etc/mkinitcpio.conf
mkinitcpio -P
pacman -Rns grub-btrfs snap-pac snapper
grub-mkconfig -o /boot/grub/grub.cfg      # drops the snapshot submenu wrapper

# 4. Remove the store and its fstab line.
umount /.snapshots
cp /var/lib/arch-autodeploy/fstab.before-snapshots /etc/fstab   # or edit out the one line
mount -o subvolid=5 /dev/mapper/root /mnt
btrfs subvolume delete /mnt/@snapshots
umount /mnt
rmdir /.snapshots

# 5. Remove machi and its hook.
rm -rf /usr/local/bin/machi /etc/machi /etc/pacman.d/hooks/00-machi-snapshot-space.hook
```

Also remove the `snapshots` role from `site.yml`, or it will all come back on
the next run.

## Troubleshooting

### Low disk space

```bash
machi snapshot list                      # how many, and how much is free
btrfs filesystem usage /                 # the real picture, including unallocated
snapper -c root list                     # which snapshots are exempt from cleanup
```

Reclaim, least destructive first:

```bash
machi snapshot cleanup                   # apply retention now
sudo paccache -rk1                       # old package tarballs (in @pkg, not snapshotted)
sudo journalctl --vacuum-size=200M       # journals (in @log, not snapshotted)
sudo snapper -c root delete <n>          # a specific snapshot, including manual ones
```

If `df` says there is space but writes fail with `ENOSPC`, metadata is
exhausted rather than data — `btrfs filesystem usage /` shows it, and
`btrfs balance start -dusage=50 /` is the usual fix.

Lower `snapshots_number_limit` and rerun the role to keep fewer snapshots
permanently.

### No snapshot entries in the boot menu

Work down this list:

```bash
findmnt /.snapshots                      # store mounted?
snapper -c root list                     # any snapshots to offer?
grep SNAPPER_CONFIGS /etc/conf.d/snapper # must be "root", or snap-pac creates nothing
ls -l /boot/grub/grub-btrfs.cfg          # generated?
grep grub-btrfs.cfg /boot/grub/grub.cfg  # sourced by grub.cfg?
systemctl status grub-btrfsd             # daemon watching /.snapshots, not /run/timeshift?
```

Regenerate by hand:

```bash
sudo /etc/grub.d/41_snapshots-btrfs      # rewrites grub-btrfs.cfg only
sudo grub-mkconfig -o /boot/grub/grub.cfg  # rewrites grub.cfg, restores the wrapper
```

An empty `grub-btrfs.cfg` with snapshots present usually means the generator
found no kernel: check that `/boot` holds `vmlinuz-linux` and
`initramfs-linux.img`.

### A boot menu entry for a snapshot that no longer exists

Selecting it drops you into a GRUB or kernel error, because the subvolume is
gone. It is a stale menu, not a damaged system. Regenerate:

```bash
sudo /etc/grub.d/41_snapshots-btrfs
```

This happens when a deletion races `grub-btrfsd`, as described
[above](#how-a-snapshot-is-offered-at-boot). The daily cleanup and
`machi snapshot cleanup` both regenerate afterwards, so it only persists after
a manual `snapper delete`.

Empty numbered directories left in `/.snapshots` after a deletion are normal
and are ignored by the generator, which enumerates btrfs subvolumes rather than
directories.

If entries exist but boot drops to an emergency shell, the overlayfs hook is
missing from the initramfs:

```bash
lsinitcpio /boot/initramfs-linux.img | grep grub-btrfs-overlayfs
grep ^HOOKS= /etc/mkinitcpio.conf
sudo mkinitcpio -P
```

### Snapshot creation failed

```bash
snapper -c root create --description test    # the raw error
journalctl -u snapperd -n 50
findmnt /.snapshots
ls /etc/snapper/configs/
```

Known specifics:

* **`pacman` prints `==> root:` with no number.** snap-pac does not check
  snapper's exit code, so a failed snapshot is reported as an empty number and
  the transaction continues. Run the `snapper create` above to see the real
  error. A stale `/tmp/snap-pac-pre_root` can then break the *next* post
  snapshot; delete it.
* **`Config 'root' not found`** — `/etc/snapper/configs/root` is missing. Rerun
  the role.
* **No pre-update snapshots at all, no errors** — `SNAPPER_CONFIGS` in
  `/etc/conf.d/snapper` is empty. That is the only place snap-pac looks, and
  the shipped value is `""`. Rerun the role.
* **Permission denied as your own user** — your user is not in `ALLOW_USERS`.
  Add it to `snapshots_allow_users` and rerun, or use `sudo`.
