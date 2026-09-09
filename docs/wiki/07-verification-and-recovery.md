# 7. Verification, troubleshooting, recovery

## Proving it worked

The `verification` role does this automatically at the end of every full run. To re-run just
that, without changing anything:

```bash
ansible-playbook site.yml --tags verification --ask-become-pass --ask-vault-pass
```

You get a PASS table followed by the raw output of every command it ran. Because a failed
assertion stops the play, seeing the table at all means everything passed.

To check by hand on the target:

```bash
id liam                                    # wheel, docker, libvirt present
cat /etc/sudoers.d/liam                    # liam ALL=(ALL:ALL) ALL
cat /etc/doas.conf                         # permit persist liam as root
yay --version
docker run --rm hello-world                # as liam, no sudo
readlink -f ~/.zshrc                       # /home/liam/dotfiles/zsh/.zshrc
sshd -T | grep -E 'permitrootlogin|passwordauthentication'
ufw status verbose                         # Status: active
fail2ban-client status sshd                # jail active
systemctl is-enabled docker sddm ufw fail2ban libvirtd tailscaled
```

Enabled services in the finished state, and only these: `docker`, `sddm`, `ufw`,
`fail2ban`, `libvirtd`, `tailscaled`. **`sshd` is deliberately not among them.**

---

## Common failures

### "Incorrect sudo password"
You mistyped the `--ask-become-pass` value, or a previous run already changed the password.
The password task runs last precisely so a rotation costs nothing: the run completes, and
the *next* run needs the new password.

### `pacman -Syu` fails on signatures
Handled automatically — the role refreshes `archlinux-keyring` and retries. If it fails for
any other reason the run stops on purpose, rather than guessing.

### AUR package(s) skipped
```
*** 1 AUR PACKAGE(S) SKIPPED - PROVISIONING CONTINUED WITHOUT THEM ***
```
Not a failure. A third-party `PKGBUILD` stopped building. Run `yay -S <package>` by hand on
the target to see the real error. Set `aur_fail_hard=true` if you would rather this be fatal.

### "the running kernel has no matching module tree"
A system upgrade replaced the kernel. Reboot the target and rerun:
```bash
ansible-playbook site.yml --tags docker --ask-become-pass --ask-vault-pass
```

### "nftables is not usable on this host"
Same cause, same fix — reboot first. Do not work around it by disabling Docker's iptables
support.

### "must exist on the controller and be executable"
The wallhaven checkout is missing on your machine. See
[page 4](04-configuration.md#wallhaven_dl_controller_source).

### "authorized_keys has no recognized SSH public key"
The `ssh` role refuses to disable password auth without a working key. Either set
`vault_liam_authorized_key`, or run `ssh-copy-id liam@<target>` from the controller. Nothing
has been hardened at this point.

### The SSH validation task fails
```
TASK [ssh : Verify fresh key authentication as liam before disabling passwords]
```
This runs from the controller. Test it yourself:
```bash
ssh -o BatchMode=yes liam@<target> id
```
If that prompts for anything, fix it first — usually a passphrase-protected key that is not
loaded (`ssh-add ~/.ssh/id_ed25519`), or a key that was never copied to the target. **Good
news:** the firewall roles run after this one, so a failure here means nothing was locked
down.

### `systemctl enable sddm` fails
`greetd` still owns the `display-manager.service` alias. The role disables greetd first, so
this normally cannot happen; if it does, run `systemctl disable greetd` and rerun
`--tags greeter`.

### Second run reports changes
Expected if you did not pass `-e ssh_enabled=true` — enabling `sshd` for the checks and
disabling it again is a change every time, by design. See
[page 5](05-running-the-playbook.md#reruns).

---

## Emergency recovery

All from the target's **console**, not SSH.

### Locked out by the firewall
```bash
ufw disable
```

### Locked out by SSH hardening
```bash
rm /etc/ssh/sshd_config.d/99-ansible-hardening.conf
sshd -t && systemctl restart sshd
```
Restart, never stop — a restart leaves existing sessions intact.

### fail2ban banned you
```bash
fail2ban-client set sshd unbanip <YOUR_IP>
systemctl disable --now fail2ban      # or stop banning entirely
```
Then fix `admin_ips` in `group_vars/all/main.yml`.

### SSH is off and you need it back
```bash
systemctl enable --now sshd
ufw limit 22/tcp
```
Or rerun the playbook with `-e ssh_enabled=true`.

### The machine will not boot after the boot role
Edit the kernel command line from the bootloader for one boot to remove `quiet`. Then either
set `boot_quiet: false` and rerun `--tags boot`, or restore by hand:
```bash
ls /etc/kernel/cmdline.*                       # timestamped backups
cp /etc/kernel/cmdline.<BACKUP> /etc/kernel/cmdline && mkinitcpio -P
cp /var/lib/arch-autodeploy/grub.cfg.previous /boot/grub/grub.cfg
# or just: grub-mkconfig -o /boot/grub/grub.cfg
```

### Dotfiles clobbered something
Nothing was deleted — conflicts were moved aside.
```bash
ls -d ~/dotfiles-backup-*
cd ~/dotfiles && stow -D --target ~ <package>   # unstow first
mv ~/dotfiles-backup-<TS>/<relative/path> ~/<relative/path>
```
Order matters: unstow, then restore.

### Undo a group membership
```bash
gpasswd -d liam docker
```
Do not remove `liam` from `wheel` until you have confirmed another route to root works.

Every role's task file also has inline `# Rollback:` comments next to the tasks that change
state. `docs/LOCAL-SOP.md` has a full per-step rollback section.

---

## Known repo quirks

Real inconsistencies in the repo, documented rather than silently patched:

| Where | Issue |
|---|---|
| `tests/dotfiles-idempotency.yml:9` | Loads `../group_vars/all.yml`; the real path is `group_vars/all/main.yml`. **This test cannot run as written.** |
| `README.md` | Refers to `group_vars/vault.yml{,.example}`; the real paths are `group_vars/all/vault.yml{,.example}`. |
| `README.md` Stow list | Says `Wallpapers`; `stow_packages` says `wallpaper`, and adds `greeter` and `menu`. The vars file is what actually runs. |
| `group_vars/all/vault.yml.example` | Defines `vault_admin_ip`, which is referenced nowhere. Use `admin_ips` in `main.yml`. |
| `admin_ips` | Includes `127.0.0.1`, already covered by the hardcoded `127.0.0.1/8` in the jail template. Harmless duplicate. |
| `roles/boot/tasks/main.yml` | A comment says the task leaves a `.bak` file; Ansible actually writes `<file>.<pid>.<YYYY-MM-DD@HH:MM:SS~>`. Behaviour is fine, comment is wrong. |

---

## Repo self-checks

Before committing changes, run these on the controller:

```bash
ansible-playbook --syntax-check site.yml
yamllint .
for t in tests/*.test.sh; do bash "$t"; done
```

All three are fast and need no target.

> `yamllint .` always reports one warning on `group_vars/all/vault.yml`
> (`missing document start`). That file is ciphertext, so the warning is expected and
> harmless — yamllint still exits 0. Ignore it; investigate anything else.

Next: [git workflow](08-git-workflow.md).
