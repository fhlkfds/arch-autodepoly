#!/usr/bin/env bash
set -euo pipefail

# Guards the properties of the snapshot role that are easy to break silently
# and expensive to discover at the next reboot. Static checks on the repository,
# in the style of the other tests here; the live boot path is verified by the
# role itself and by docs/snapshots.md's reboot procedure.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defaults="$repo_root/roles/snapshots/defaults/main.yml"
preflight="$repo_root/roles/snapshots/tasks/preflight.yml"
store="$repo_root/roles/snapshots/tasks/store.yml"
snapper="$repo_root/roles/snapshots/tasks/snapper.yml"
hooks="$repo_root/roles/snapshots/tasks/hooks.yml"
boot="$repo_root/roles/snapshots/tasks/boot.yml"
machi="$repo_root/roles/snapshots/templates/machi.j2"
site="$repo_root/site.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The design is btrfs-only and must stop rather than half-configure a host that
# cannot support it.
grep -q 'snapshots_root_fstype == "btrfs"' "$preflight" \
  || fail 'the role must assert a btrfs root filesystem before changing anything'
grep -q 'snapshots_root_subvol != "<FS_TREE>"' "$preflight" \
  || fail 'the role must refuse a root mounted from the filesystem root'

# Nothing machine-specific may be hardcoded: every UUID, device and user comes
# from discovery or a variable.
# Comments are stripped first: the role documents what it discovers (for
# example "e.g. /dev/mapper/root"), which is not the same as depending on it.
if find "$repo_root/roles/snapshots" -type f -print0 \
    | xargs -0 sed 's/#.*$//' \
    | grep -qE '55e3a769|3156-5D75|d0dd0736|/dev/mapper/root|nvme0n1'; then
  fail 'a machine-specific UUID or device node is hardcoded in the snapshots role'
fi
grep -q '"{{ admin_user }}"' "$defaults" \
  || fail 'the allowed snapper users must come from admin_user, not a literal name'

# snap-pac reads SNAPPER_CONFIGS and nothing else; with the shipped empty value
# no pre-update snapshot is ever created, which fails silently.
grep -q 'SNAPPER_CONFIGS="{{ snapshots_config_name }}"' "$snapper" \
  || fail 'snap-pac needs the snapper config registered in /etc/conf.d/snapper'

# The pacman hooks are snap-pac's; the role must configure them rather than
# reimplement their triggers, and must not abort a transaction on low space.
grep -q 'dest: /etc/snap-pac.ini' "$hooks" \
  || fail 'the role must configure snap-pac rather than ship its own pre/post hooks'
if sed 's/#.*$//' "$repo_root/roles/snapshots/templates/machi-space.hook.j2" \
    | grep -q 'AbortOnFail'; then
  fail 'the free-space hook must warn, not block a package transaction'
fi

# A read-only snapshot cannot complete boot without the overlayfs hook, so the
# hook and the initramfs rebuild that installs it must both stay.
grep -q 'snapshots_overlayfs_hook_name' "$boot" \
  || fail 'the overlayfs initcpio hook must be added to HOOKS'
grep -q 'notify: rebuild initramfs' "$boot" \
  || fail 'changing HOOKS must rebuild the initramfs'

# grub-btrfsd runs the generator without grub-mkconfig, so microcode has to be
# named explicitly or every regenerated entry loses it.
grep -q 'GRUB_BTRFS_CUSTOM_MICROCODE' "$boot" \
  || fail 'snapshot boot entries must load CPU microcode explicitly'

# grub-btrfsd regenerates on the first inotify event, so a deletion can leave a
# menu entry for a snapshot that is already gone. The retention pass must
# regenerate after it finishes deleting.
grep -q 'snapper-cleanup.service.d/override.conf' "$boot" \
  || fail 'the daily cleanup must regenerate the snapshot boot menu afterwards'
grep -q 'ExecStartPost' "$repo_root/roles/snapshots/templates/snapper-cleanup-override.conf.j2" \
  || fail 'the cleanup drop-in must regenerate the menu after cleanup, not before'
grep -q 'boot_menu_note(config, force=True)' "$machi" \
  || fail 'machi cleanup must regenerate the boot menu rather than trust the daemon'

# grub.cfg is only ever replaced by a candidate that was syntax-checked and
# still has at least as many entries as the live file.
grep -q 'grub-script-check' "$boot" \
  || fail 'a generated grub.cfg must be syntax-checked before it is installed'
grep -q 'Refuse a candidate grub.cfg that lost boot entries' "$boot" \
  || fail 'a grub.cfg that lost boot entries must not be installed'

# The store must be a mounted subvolume; a plain directory would be captured by
# every later snapshot of the root subvolume.
grep -q 'Require the snapshot store to be mounted' "$store" \
  || fail 'the role must prove the snapshot store is mounted'
grep -q 'Refuse to displace an existing nested snapshot subvolume' "$store" \
  || fail 'the role must not delete a pre-existing nested .snapshots subvolume'

# machi must never delete without being asked, and never escalate by itself.
grep -q 'refusing to delete snapshots without confirmation' "$machi" \
  || fail 'machi cleanup must refuse to delete without confirmation'
if grep -qE '^\s*(subprocess|os)\.\w+\(\s*\[?"?(sudo|doas)' "$machi"; then
  fail 'machi must not escalate privileges on its own'
fi
grep -q 'created_by=machi' "$machi" \
  || fail 'manual snapshots must be identifiable in snapper userdata'

# A role-level tag is added to every task, so listing the narrow tags in
# site.yml would make --tags machi run the whole role.
grep -qE '^\s+tags: \[snapshots\]$' "$site" \
  || fail 'the snapshots role must carry only the snapshots tag in site.yml'
for tag in btrfs snapshots boot machi; do
  grep -q "tags: \[.*${tag}.*\]" "$repo_root/roles/snapshots/tasks/main.yml" \
    || fail "the ${tag} tag must select part of the snapshots role"
done

printf 'ok: bootable snapshot role guards\n'
