#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vars_file="$repo_root/group_vars/all/main.yml"
packages_tasks="$repo_root/roles/packages/tasks/main.yml"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q 'wallhaven_dl_source: "{{ admin_home }}/Projects/wallhaven-tools/wallhaven-dl"' "$vars_file" \
  || fail 'wallhaven-dl source path is not configured'
grep -q 'wallhaven_dl_link: "{{ admin_home }}/.local/bin/wallhaven-dl"' "$vars_file" \
  || fail 'wallhaven-dl link path is not configured'
grep -q '^wallhaven_tools_repo_url: https://github.com/fhlkfds/wallhaven-tools.git$' "$vars_file" \
  || fail 'wallhaven-tools repository is not configured'
grep -q 'path: "{{ admin_home }}/.local/bin"' "$packages_tasks" \
  || fail 'package role must create the user-local executable directory'
grep -q 'repo: "{{ wallhaven_tools_repo_url }}"' "$packages_tasks" \
  || fail 'package role must clone wallhaven-tools onto a fresh target'
grep -q 'dest: "{{ wallhaven_dl_link }}"' "$packages_tasks" \
  || fail 'package role must create the wallhaven-dl link'
grep -q 'force: false' "$packages_tasks" \
  || fail 'package role must not overwrite an existing command path'

printf 'ok: wallhaven-dl user-local link provisioning\n'
