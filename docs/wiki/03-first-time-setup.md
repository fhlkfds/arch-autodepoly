# 3. First-time setup

Four steps. Step 2 is the one people skip and then get stuck on.

---

## Step 1: Prepare the controller

The controller is the machine you run `ansible-playbook` from. It needs Ansible, git, and
an SSH client. On Arch:

```bash
sudo pacman -S --needed ansible git openssh
```

On Debian/Ubuntu: `sudo apt install ansible git openssh-client`. On macOS:
`brew install ansible`. The controller does **not** have to be Arch — only the target does.

Clone the repo and install the two collections it depends on:

```bash
git clone <your-repo-url> ~/Projects/arch-autodepoly
cd ~/Projects/arch-autodepoly
ansible-galaxy collection install -r requirements.yml
```

Verify:

```bash
ansible --version                                  # core 2.21+ is known good
ansible-galaxy collection list | grep -E 'posix|community.general'
```

You want `ansible.posix >= 2.1.0` and `community.general >= 13.0.0`.

### The wallhaven checkout

One task copies a script from **the controller** to the target, because it lives in a
private repo the target cannot clone. If you do not have access to that repo, see
[page 4](04-configuration.md#wallhaven_dl_controller_source) for how to point it elsewhere
or skip it. Otherwise:

```bash
git clone git@github.com:fhlkfds/wallhaven-tools.git ~/Projects/wallhaven-tools
test -x ~/Projects/wallhaven-tools/wallhaven-dl && echo OK
```

---

## Step 2: Prepare the target

This is the important one. **The playbook creates the `liam` account, but it has to log in
as somebody first.** Ansible connects as `ansible_user` from the inventory — `liam` — so
that account must already exist on the target before the first run.

On a fresh Arch install, from the target's console:

```bash
# as root on the target
pacman -S --needed openssh sudo
useradd -m -G wheel liam
passwd liam

# let wheel use sudo
EDITOR=nano visudo          # uncomment: %wheel ALL=(ALL:ALL) ALL

systemctl enable --now sshd
ip addr                     # note the IP — you need it for the inventory
```

That is the minimum. The `users` role will then fix up the shell, the seven supplementary
groups, and the sudoers rule properly.

Assumptions the playbook enforces and will refuse to run without:

| Requirement | Checked by | Why |
|---|---|---|
| Arch Linux | `site.yml` assert on `os_family` | Everything uses `pacman` |
| x86_64 | `site.yml` assert on `architecture` | The `ttfx` build pins `x86_64-unknown-linux-musl` |
| Network access | implicitly | Full `pacman -Syu`, git clones, AUR builds |

Python is **not** a prerequisite — the first task in `site.yml` installs it over `raw` SSH
before any normal module runs.

Now set the inventory to match:

```bash
$EDITOR inventory/hosts.ini
```

```ini
[arch_workstation]
workstation ansible_host=192.168.1.50 ansible_user=liam
```

If the target's SSH runs on a non-standard port, add `ansible_port=2222`.

---

## Step 3: Set up SSH keys

The `ssh` role disables password authentication. Before it does, it proves that key-based
login works — and refuses to continue if it cannot. So you need a key pair.

On the controller:

```bash
ssh-keygen -t ed25519          # press Enter for no passphrase, or use an agent
ssh-copy-id liam@192.168.1.50  # installs the public key on the target
ssh liam@192.168.1.50          # must succeed WITHOUT asking for a password
```

That last command must work non-interactively. If it prompts for a password, the playbook
will fail at the SSH preflight check.

> **Why no passphrase?** The validation task runs `ssh` with `BatchMode=yes`, which refuses
> to prompt for anything. A passphrase-protected key works only if it is loaded into
> `ssh-agent` first (`ssh-add ~/.ssh/id_ed25519`).

---

## Step 4: Create the vault

The vault holds two secrets: your account password (as a hash, never plaintext) and your
SSH public key.

```bash
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
```

Generate the password hash:

```bash
python3 scripts/make-password-hash.py
```

It prompts twice and prints a line like:

```
vault_liam_password_hash: '$y$j9T$abcd...'
```

Edit `group_vars/all/vault.yml` and fill in all three keys:

```yaml
---
vault_liam_password_hash: "$y$j9T$abcd..."          # from the script above
vault_liam_authorized_key: "ssh-ed25519 AAAAC3... you@host"   # cat ~/.ssh/id_ed25519.pub
vault_admin_ip: "192.0.2.10/32"                     # see the note below
```

Then encrypt it and pick a vault password you will remember:

```bash
ansible-vault encrypt group_vars/all/vault.yml
```

Confirm it worked — the file should now start with a vault header:

```bash
head -1 group_vars/all/vault.yml
# $ANSIBLE_VAULT;1.1;AES256
```

### Notes on the vault keys

- **`vault_liam_password_hash`** — if you leave it empty (`""`), the final password task is
  skipped and the run says so. The account keeps whatever password you set in Step 2.
- **`vault_liam_authorized_key`** — may be omitted only if a valid key is already in
  `/home/liam/.ssh/authorized_keys` on the target (which Step 3 did). If both are missing,
  the `ssh` role aborts rather than lock you out.
- **`vault_admin_ip`** — present in the example file but **not actually referenced anywhere
  in the repo**. The whitelist that matters is `admin_ips` in `group_vars/all/main.yml`.
  Edit that instead, or override it from `vault.yml` if you would rather not keep your
  network layout in a tracked file.

To edit the vault later: `ansible-vault edit group_vars/all/vault.yml`.
To read it: `ansible-vault view group_vars/all/vault.yml`.

---

## Pre-flight check

```bash
ansible-playbook --syntax-check site.yml         # parses?
ansible -m ping all --ask-become-pass            # can Ansible reach the target?
```

`ping` should return `SUCCESS`. If it does not, fix SSH before going further.

Next: [configuration](04-configuration.md).
