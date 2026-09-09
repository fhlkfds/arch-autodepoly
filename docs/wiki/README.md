# arch-autodepoly wiki

This repository turns one fresh Arch Linux machine into a fully configured Hyprland
workstation, using Ansible. It installs ~120 packages, deploys a dotfiles repo, themes the
boot screen and login screen, enables Docker, and hardens SSH + firewall + intrusion
banning — in an order designed so you cannot lock yourself out halfway through.

You do not need to know Ansible or Arch to use it. Read the pages in order.

## Pages

| # | Page | What it covers |
|---|---|---|
| 1 | [How Ansible works](01-how-ansible-works.md) | The 12 terms you need. Read this first if you have never used Ansible. |
| 2 | [What this repo contains](02-what-this-repo-contains.md) | Every file and directory, explained. |
| 3 | [First-time setup](03-first-time-setup.md) | Preparing the controller and the target machine. The part people get wrong. |
| 4 | [Configuration](04-configuration.md) | Which variables you must change, which you might, which to leave alone. |
| 5 | [Running the playbook](05-running-the-playbook.md) | The actual commands, dry runs, tags, reruns. |
| 6 | [What each role does](06-roles-explained.md) | Role-by-role, in execution order, with the files each one touches. |
| 7 | [Verification, troubleshooting, recovery](07-verification-and-recovery.md) | Proving it worked, fixing it when it did not, undoing changes. |
| 8 | [Git workflow](08-git-workflow.md) | Committing your changes and pushing them, without leaking secrets. |

## The 60-second version

You run Ansible on **your machine** (the *controller*). It connects over SSH to the
**machine being built** (the *target*) and configures it. They can be the same machine, but
this repo is set up for two.

```bash
# on the controller, one time
sudo pacman -S --needed ansible git openssh
ansible-galaxy collection install -r requirements.yml
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
# edit vault.yml with your password hash + SSH public key, then:
ansible-vault encrypt group_vars/all/vault.yml

# check what would change, without changing it
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --check --diff

# do it for real
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --diff
```

Expect the real run to take **30–90 minutes** — it does a full system upgrade, compiles AUR
packages, and builds a Rust binary from source. It may reboot the target once, on purpose.

## Two things that surprise people

1. **The finished machine has no SSH server.** `ssh_enabled` defaults to `false`. The
   playbook installs and proves a hardened `sshd` during the run, then stops and disables it
   as the very last step. A remote run works once; the next one needs you to re-enable SSH
   at the console, or to pass `-e ssh_enabled=true`. See
   [page 5](05-running-the-playbook.md#the-ssh-teardown).

2. **The target must already have a `liam` account you can SSH into.** The playbook creates
   and normalizes that account, but it has to log in as somebody first. See
   [page 3](03-first-time-setup.md#step-2-prepare-the-target).

## Related documents

- [`../LOCAL-SOP.md`](../LOCAL-SOP.md) — the same work translated into manual shell commands,
  for reproducing the whole thing by hand on one PC with no Ansible at all.
- [`../../README.md`](../../README.md) — the original design notes, written for someone who
  already knows the stack.
