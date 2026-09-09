# 1. How Ansible works

Skip this page if you already use Ansible. Otherwise it is the only theory you need.

## The mental model

Ansible is a program that runs on **your** computer, logs into **another** computer over
SSH, and runs commands there to put it into a described state. Nothing is installed on the
machine being configured — no agent, no daemon. It just needs SSH and Python.

```
  YOUR MACHINE                          THE MACHINE BEING BUILT
  "the controller"                      "the target" / "managed node"
  ┌──────────────────┐                  ┌──────────────────────────┐
  │ ansible-playbook │ ──── SSH ──────▶ │ runs pacman, systemctl,  │
  │ this repo        │                  │ writes /etc files, ...   │
  └──────────────────┘                  └──────────────────────────┘
```

In this repo the controller is wherever you cloned the repo, and the target is the host in
`inventory/hosts.ini` (by default `192.168.122.122`).

## The 12 terms

**Inventory** — the list of machines to configure. Here: `inventory/hosts.ini`, one host
named `workstation` in a group named `arch_workstation`.

**Playbook** — the top-level YAML file describing the work. Here: `site.yml`.

**Play** — one section of a playbook, aimed at one group of hosts. `site.yml` has four
plays, run top to bottom.

**Task** — one unit of work. "Install these packages." "Write this file."

**Module** — the code that performs a task. `community.general.pacman` installs packages,
`ansible.builtin.copy` writes files, `ansible.builtin.systemd_service` manages services.
You name a module and give it arguments; it figures out the commands.

**Role** — a reusable bundle of tasks, templates and default variables, living in one
directory. This repo has ten: `users`, `packages`, `boot`, `docker`, `dotfiles`, `greeter`,
`ssh`, `ufw`, `fail2ban`, `verification`.

**Variable** — a named value, e.g. `admin_user: liam`. Written `{{ admin_user }}` when used.
Defined in `group_vars/all/main.yml` (applies everywhere) or a role's `defaults/main.yml`
(role-specific, lowest priority, easy to override).

**Template** — a file with variables in it, rendered before being written to the target.
Files ending `.j2` (Jinja2). Example: `roles/fail2ban/templates/jail.local.j2` becomes
`/etc/fail2ban/jail.local` with your real IP addresses filled in.

**Handler** — a task that only runs if something notified it, and only once at the end.
Used for "restart the service, but only if the config actually changed."

**Fact** — information Ansible gathers about the target (OS, architecture, mounted
filesystems). Referenced as `ansible_facts.*`.

**Tag** — a label on a role or task, so you can run just part of the playbook:
`--tags docker`.

**become** — "use sudo." This repo sets `become = True` globally in `ansible.cfg`, so
almost everything runs as root on the target. Tasks that must run as the normal user say
`become_user: liam`.

## Idempotency — the one property that matters

A correct Ansible run is **idempotent**: running it twice produces the same result as
running it once, and the second run reports zero changes. Modules check current state
before acting — `pacman` only installs what is missing, `copy` only writes if the content
differs.

This is why you can safely rerun the playbook after a failure. It is also why
`scripts/prove-idempotency.sh` exists: it runs the playbook twice and fails unless the
second run reports `changed=0`.

## Reading the output

```
TASK [packages : Install official packages derived from the dotfiles repository] ***
changed: [workstation]
```

- `ok` — already in the desired state, nothing done.
- `changed` — the target was modified.
- `skipped` — a `when:` condition was false.
- `failed` — stop and read the message.

At the end you get a `PLAY RECAP` with counts per host. On a second run you want
`changed=0  failed=0`.

## Vault — how secrets are stored

`ansible-vault` encrypts a file with a password. This repo keeps your password hash and SSH
public key in `group_vars/all/vault.yml`, encrypted, and `.gitignore` keeps it out of git
anyway. You supply the vault password at run time with `--ask-vault-pass`.

Next: [what this repo contains](02-what-this-repo-contains.md).
