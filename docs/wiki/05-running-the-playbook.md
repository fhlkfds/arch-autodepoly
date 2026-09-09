# 5. Running the playbook

## Before the first run

Keep two things open:

1. **Your current SSH session to the target.** Do not close it. An `sshd` restart leaves
   existing sessions alive, so it is your escape hatch.
2. **Console access** (physical keyboard, VM console, IPMI). If the firewall or SSH
   hardening goes wrong, this is how you fix it.

## The three commands

```bash
# 1. Does the YAML parse?
ansible-playbook --syntax-check site.yml

# 2. Dry run: show what would change, change nothing
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --check --diff

# 3. The real thing
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --diff
```

**`--ask-become-pass`** prompts for the target's sudo password (the one you set in
[step 2](03-first-time-setup.md#step-2-prepare-the-target)).
**`--ask-vault-pass`** prompts for the vault password.
**`--diff`** prints line-by-line changes to files, so the record of what happened is in the
log.

### What `--check` cannot tell you

Check mode is a simulation. It cannot prove: AUR packages build, Docker actually runs a
container, a service survives a restart, the firewall did not lock you out, or that a fresh
SSH connection succeeds. The real run performs all of those as explicit checks. Check mode
also cannot skip the Python bootstrap, so on a truly bare target the dry run will report
errors that a real run would not — that is expected.

## What to expect

**Duration: 30–90 minutes.** The long poles are a full `pacman -Syu`, twelve AUR packages
compiled from source, and `ttfx` built with Cargo against musl.

**One reboot, on purpose.** If the system upgrade replaced the running kernel, the
`packages` role reboots the target and waits for it to come back. This is required: the old
kernel's modules are deleted by the upgrade, and without them Docker cannot build its NAT
rules. Ansible handles the reboot and reconnect itself — do not interrupt it.

**Skipped AUR packages are not failures.** The AUR is third-party. If a `PKGBUILD` stops
building, the run prints a loud banner naming the package and continues. Set
`aur_fail_hard=true` to make it fatal instead.

**The final SSH teardown.** See below.

## The SSH teardown

Because `ssh_enabled` defaults to `false`, the last three tasks of the last play:

1. check whether UFW still allows the SSH port,
2. delete that firewall rule,
3. `systemctl disable --now sshd`.

The machine then listens on nothing. This is intentional — it is a workstation, not a
server. Consequences:

- A remote run **works once**, over the `sshd` that was already up when the run started.
- The **next** remote run cannot connect. Re-enable at the target's console with
  `systemctl enable --now sshd`, or run with `-e ssh_enabled=true` to leave it up.

```bash
# keep SSH alive for repeated runs
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --diff -e ssh_enabled=true
```

## Running only part of the playbook

Every role has a tag:

```bash
ansible-playbook site.yml --tags packages --ask-become-pass --ask-vault-pass
ansible-playbook site.yml --tags dotfiles,greeter --ask-become-pass --ask-vault-pass
ansible-playbook site.yml --skip-tags boot --ask-become-pass --ask-vault-pass
```

Tags: `users`, `packages`, `boot`, `docker`, `dotfiles`, `greeter`, `ssh`, `ufw`,
`fail2ban`, `verification`, plus `password` and `ssh_teardown` for the final tasks.

Rules:

- **`users` also carries `always`**, so the account and group setup runs no matter which
  tag you select. Everything else depends on it.
- **Do not run `ufw` or `fail2ban` alone.** Both need `effective_ssh_port`, a fact the `ssh`
  role discovers from `sshd -T` at run time. Without it, `ufw` fails its opening assertion.
  Run `--tags ssh,ufw,fail2ban` together.
- `verification` is read-only and safe to run any time:
  `ansible-playbook site.yml --tags verification --ask-become-pass --ask-vault-pass`

## Reruns

The playbook is idempotent — rerunning after a failure is the normal way to recover. Fix the
cause, run the same command again. Modules skip work that is already done.

To prove idempotency:

```bash
scripts/prove-idempotency.sh inventory/hosts.ini \
  --ask-become-pass --ask-vault-pass -e ssh_enabled=true
```

It runs the playbook twice, writes both transcripts to `artifacts/`, and fails unless the
second `PLAY RECAP` shows `changed=0, unreachable=0, failed=0`.

> `-e ssh_enabled=true` is required here. With the default, enabling `sshd` for the checks
> and disabling it again is a change on *every* run by design, so the second run can never
> report zero changes.

## Running against localhost instead

To build the machine you are sitting at, with no SSH:

```ini
# inventory/hosts.ini
[arch_workstation]
workstation ansible_connection=local ansible_user=liam
```

`ssh_validation_host` auto-resolves to `127.0.0.1` when the connection is local, so the key
checks become loopback SSH to yourself — which still needs `sshd` running and your key in
`~/.ssh/authorized_keys`.

If you would rather skip Ansible entirely for a single local machine, use
[`docs/LOCAL-SOP.md`](../LOCAL-SOP.md), which is the same work as copy-pasteable shell
commands.

## Reading a failure

```
TASK [docker : Require a working nftables control plane for Docker networking] ***
fatal: [workstation]: FAILED! => {"assertion": "...", "msg": "Docker provisioning
stopped before enabling docker.service because nftables is not usable ..."}
```

Assertions in this repo are written to tell you three things: what was checked, what to do
about it, and — importantly — **what state was and was not changed**. Read the whole
`fail_msg`; most of them name the exact fix. Then see
[page 7](07-verification-and-recovery.md).

Next: [what each role does](06-roles-explained.md).
