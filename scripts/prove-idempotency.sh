#!/usr/bin/env bash
set -euo pipefail

inventory=${1:-inventory/hosts.ini}
if (($#)); then
  shift
fi

mkdir -p artifacts
first_log=artifacts/first-run.log
second_log=artifacts/second-run.log

ansible-playbook -i "$inventory" site.yml --diff "$@" | tee "$first_log"
ansible-playbook -i "$inventory" site.yml --diff "$@" | tee "$second_log"

recap=$(awk '/PLAY RECAP/{capture=1; next} capture && NF {print}' "$second_log")
printf '%s\n' "$recap"

if grep -Eq 'changed=[1-9][0-9]*|unreachable=[1-9][0-9]*|failed=[1-9][0-9]*' <<<"$recap"; then
  printf 'Second run was not idempotent; inspect %s\n' "$second_log" >&2
  exit 1
fi

printf 'PASS: second run reported changed=0, unreachable=0, failed=0\n'
