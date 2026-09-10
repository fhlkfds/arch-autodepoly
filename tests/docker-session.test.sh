#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_tasks="$repo_root/roles/docker/tasks/main.yml"
verification_tasks="$repo_root/roles/verification/tasks/main.yml"

grep -q 'argv: \[runuser, --user, "{{ admin_user }}", --, docker, info\]' "$docker_tasks"
grep -q 'argv: \[runuser, --user, "{{ admin_user }}", --, docker, run, --rm, hello-world\]' "$docker_tasks"
if grep -q 'docker_session_groups\|reset_connection' "$docker_tasks"; then
  exit 1
fi
grep -q 'argv: \[runuser, --user, "{{ admin_user }}", --, docker, info\]' "$verification_tasks"
grep -q 'argv: \[runuser, --user, "{{ admin_user }}", --, docker, run, --rm, hello-world\]' "$verification_tasks"

printf 'ok: Docker checks use a fresh user session\n'
