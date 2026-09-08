#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages_vars="$repo_root/group_vars/all/main.yml"
packages_tasks="$repo_root/roles/packages/tasks/main.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -qE '^  - tailscale$' "$packages_vars" \
  || fail 'official package list must include tailscale'
grep -q 'name: tailscaled.service' "$packages_tasks" \
  || fail 'package role must manage tailscaled.service'
grep -q 'state: started' "$packages_tasks" \
  || fail 'package role must start tailscaled.service'
! grep -qE 'tailscale (up|login)' "$packages_tasks" \
  || fail 'tailnet authentication must remain outside provisioning'

printf 'ok: tailscale installation and daemon provisioning\n'
