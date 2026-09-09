# 2. What this repo contains

## Directory map

```
arch-autodepoly/
├── ansible.cfg                 Ansible's settings for this repo
├── site.yml                    THE PLAYBOOK — start reading here
├── requirements.yml            External Ansible collections this repo needs
├── inventory/hosts.ini         Which machine to configure
├── group_vars/all/
│   ├── main.yml                Almost every setting lives here
│   ├── vault.yml.example       Template for your secrets
│   └── vault.yml               Your secrets, encrypted. NOT in git.
├── roles/                      The actual work, split into ten roles
├── scripts/                    Helper tools you run by hand
├── tests/                      Checks that the repo still says what it should
├── docs/                       This wiki, plus the manual-procedure SOP
├── .yamllint                   YAML style rules
└── .gitignore                  artifacts/, vault.yml, *.retry
```

## Top-level files

**`site.yml`** — the entry point. Four plays that run in order:

| Play | Purpose | Roles |
|---|---|---|
| 1. Bootstrap the Arch workstation | Everything that is not security | `users`, `packages`, `boot`, `docker`, `dotfiles`, `greeter` |
| 2. Harden SSH before changing the firewall | Lock down `sshd` and prove it still works | `ssh` |
| 3. Enable the host firewall and SSH banning | Firewall, then ban repeat offenders | `ufw`, `fail2ban` |
| 4. Verify the provisioned workstation | Prove every claim, then set the password and shut SSH down | `verification` + 4 final tasks |

The order is deliberate and load-bearing. SSH is hardened *before* the firewall goes up so a
broken config is caught while you can still get in. The password is changed *last*, because
rewriting `/etc/shadow` invalidates the sudo password Ansible is currently using.

**`ansible.cfg`** — points Ansible at `inventory/hosts.ini` and `./roles`, disables `.retry`
files, and turns on `become` (sudo) globally.

**`requirements.yml`** — two collections that provide modules the built-ins do not:
`ansible.posix` (>= 2.1.0, for `authorized_key`) and `community.general` (>= 13.0.0, for
`pacman` and `ufw`). Install them with `ansible-galaxy collection install -r requirements.yml`.

**`inventory/hosts.ini`** — one line:

```ini
[arch_workstation]
workstation ansible_host=192.168.122.122 ansible_user=liam
```

`workstation` is a label. `ansible_host` is the IP to SSH to, `ansible_user` is the account
to log in as. Change both to match your machine.

## `group_vars/all/`

Variables here apply to every host. This is where you configure the build.

- **`main.yml`** — ~250 lines: the user to create, the package lists, the dotfiles repo URL,
  the Stow package list, firewall rules, theme choices. Heavily commented; the comments
  explain *why* each value is what it is. See [page 4](04-configuration.md).
- **`vault.yml.example`** — copy this to `vault.yml`, fill in, encrypt.
- **`vault.yml`** — your real secrets. Encrypted with `ansible-vault`, and listed in
  `.gitignore` so it never reaches GitHub. Loaded *after* `main.yml`, so anything you define
  here overrides `main.yml`.

## `roles/` — the ten roles

Each role is a directory with up to four parts: `tasks/main.yml` (the work),
`defaults/main.yml` (overridable settings), `templates/` (`.j2` files rendered onto the
target), `handlers/main.yml` (restart-on-change tasks), `files/` (files copied verbatim).

| Role | Tag | What it does |
|---|---|---|
| `users` | `users` | Creates `liam`, its groups, and the sudoers rule |
| `packages` | `packages` | Full upgrade, 107 official + 12 AUR packages, `yay`, `ttfx`, libvirt, Tailscale, doas |
| `boot` | `boot` | Silences the boot console, installs a GRUB theme |
| `docker` | `docker` | Installs and enables Docker, adds `liam` to the `docker` group |
| `dotfiles` | `dotfiles` | Clones the dotfiles repo and deploys 22 GNU Stow packages |
| `greeter` | `greeter` | SDDM login screen with a qylock theme |
| `ssh` | `ssh` | Hardens `sshd`, proves key-only login still works |
| `ufw` | `ufw` | Firewall: deny incoming, allow SSH (rate-limited) and LocalSend |
| `fail2ban` | `fail2ban` | Bans IPs that fail SSH auth repeatedly |
| `verification` | `verification` | Read-only. Re-proves every claim and prints the evidence |

Full detail: [page 6](06-roles-explained.md).

Only three roles carry extra assets:

- `roles/dotfiles/files/stow_manifest.py` — works out which dotfile symlinks are missing or
  wrong, and which existing files would conflict. Its JSON output drives the backup-then-stow
  logic. This is what makes the dotfiles role idempotent.
- `roles/boot/templates/09_loadfonts.j2` → `/etc/grub.d/09_loadfonts`
- `roles/{ssh,fail2ban,greeter}/templates/*.j2` → the sshd drop-in, `jail.local`, and
  `theme.conf`

## `scripts/`

- **`make-password-hash.py`** — prompts for a password twice and prints a
  `vault_liam_password_hash:` line ready to paste into `vault.yml`. It calls libxcrypt
  directly to produce a yescrypt hash, because Python 3.13 removed the `crypt` module and
  Ansible's own `password_hash` filter cannot emit yescrypt any more.
- **`prove-idempotency.sh`** — runs the playbook twice, saves both logs under `artifacts/`,
  and exits non-zero unless the second run reports `changed=0, unreachable=0, failed=0`.

## `tests/`

Cheap guards, not a full test suite.

- **`*.test.sh`** — three shell scripts that `grep` the repo to confirm specific facts still
  hold (libvirt is provisioned, Tailscale is installed but *not* authenticated, the
  wallhaven link is wired up). Run them with `for t in tests/*.test.sh; do bash "$t"; done`.
- **`dotfiles-idempotency.yml`** — an Ansible playbook that runs the `dotfiles` role against
  a throwaway home directory in `/tmp` and asserts the conflict-backup logic worked.
  **This file currently does not run**: line 9 loads `../group_vars/all.yml`, but the real
  path is `group_vars/all/main.yml`. See [known quirks](07-verification-and-recovery.md#known-repo-quirks).

## What is deliberately *not* here

No CI config, no Makefile, no Vagrant/Terraform. The repo configures one machine and is
driven by hand.

Next: [first-time setup](03-first-time-setup.md).
