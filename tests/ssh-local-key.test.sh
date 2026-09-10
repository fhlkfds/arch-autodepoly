#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ssh_tasks="$repo_root/roles/ssh/tasks/main.yml"

grep -q 'generate_ssh_key: true' "$ssh_tasks"
grep -q 'ssh_key_file: .ssh/id_ed25519' "$ssh_tasks"
grep -q 'key: "{{ local_ssh_key.ssh_public_key }}"' "$ssh_tasks"
grep -q "(ansible_connection | default('ssh')) == 'local'" "$ssh_tasks"

printf 'ok: local SSH key bootstrap\n'
