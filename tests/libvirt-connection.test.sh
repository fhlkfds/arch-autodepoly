#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages_tasks="$repo_root/roles/packages/tasks/main.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q 'name: libvirt' "$packages_tasks" \
  || fail 'package role must create the libvirt group'
grep -q 'groups: libvirt' "$packages_tasks" \
  || fail 'package role must add the admin user to libvirt'
grep -q 'name: libvirtd.service' "$packages_tasks" \
  || fail 'package role must manage libvirtd.service'
grep -q 'argv: \[virsh' "$packages_tasks" \
  || fail 'package role must verify libvirt with virsh'
grep -q 'qemu:///system' "$packages_tasks" \
  || fail 'verification must use the system QEMU libvirt URI'

printf 'ok: libvirt system connection provisioning\n'
