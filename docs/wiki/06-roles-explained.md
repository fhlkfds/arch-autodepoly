# 6. What each role does

In execution order. For each role: what it changes, and the safety logic worth knowing.

---

## Play 1 pre-tasks — bootstrap

Before any role, `site.yml` does four things:

1. **Installs Python over `raw` SSH.** Every Ansible module needs a Python interpreter on
   the target, including the one that installs Python. `raw` runs a plain shell command over
   SSH with no module machinery, so it can break that circle. It runs
   `pacman -Syu --needed --noconfirm python` only if `/usr/bin/python3` is missing.
2. **Resets the connection**, so the new interpreter is picked up.
3. **Gathers facts.**
4. **Asserts** the target is Arch and x86_64, and stops if not.

---

## 1. `users` — tag `users` (and `always`)

**Changes:** creates the `liam` group; creates `wheel video audio input storage optical lp`;
creates the `liam` account with home `/home/liam` and shell `/usr/bin/zsh`; writes
`/etc/sudoers.d/liam` (mode 0440) containing `liam ALL=(ALL:ALL) ALL`.

**Worth knowing:**
- Group membership is **appended**, never replaced. Existing memberships survive.
- The sudoers file is validated with `visudo -cf` *before* installation. A syntax error is
  caught in a temp file, not in `/etc/sudoers.d`.
- **The password is deliberately not set here.** Rewriting `/etc/shadow` mid-run would
  invalidate the sudo password Ansible is using, and every subsequent task would fail with
  "Incorrect sudo password". It happens as the very last task of the last play instead.

---

## 2. `packages` — tag `packages`

The biggest role. In order:

1. **Full system upgrade** (`pacman -Syu`). Wrapped in a `block`/`rescue`: if the upgrade
   fails *and* the error mentions signatures or the keyring, it refreshes
   `archlinux-keyring` and retries. Any other failure stops the run — it explicitly refuses
   "a speculative keyring repair".
2. **107 official packages** — the Hyprland stack, Qt/GStreamer for the greeter, fonts,
   capture tools, virtualization, shell tooling.
3. **libvirt**: creates the group, adds `liam`, enables `libvirtd`, then proves
   `virsh -c qemu:///system uri` works *as `liam`* — so virt-manager can connect without
   root after a fresh login.
4. **Tailscale**: enables and starts `tailscaled`, but deliberately does **not** run
   `tailscale up`. Enrolling a device in a tailnet is an interactive, device-specific action
   and stays a manual step.
5. **`/etc/doas.conf`** containing `permit persist liam as root`, validated with `doas -C`.
   Needed because the stowed zsh dotfiles alias `sudo` to `doas`, and `opendoas` ships no
   default config — without this every interactive `sudo` on the box breaks.
6. **Builds `yay`** as `liam` from the AUR. `makepkg` refuses to run as root, so the role
   temporarily writes `/etc/sudoers.d/liam-makepkg` granting passwordless `pacman` only, and
   removes it in an `always:` block even if the build fails.
7. **Twelve AUR packages.** Tries one batch install; if that fails, retries each package
   individually up to `aur_install_retries` times. Every package ends in exactly one of three
   states: installed, "retryable failure" (a host/controller problem — stops the run), or
   "upstream broken" (the PKGBUILD genuinely does not build — reported loudly, skipped).
8. **Oh My Zsh, Powerlevel10k, fzf-tab** cloned as `liam`.
9. **XDG user directories** and `~/.local/bin`.
10. **`wallhaven-dl`** copied from the controller's checkout (private repo — see
    [page 4](04-configuration.md#wallhaven_dl_controller_source)) and symlinked into
    `~/.local/bin`.
11. **`ttfx`** built with Cargo against `x86_64-unknown-linux-musl` at a pinned commit, then
    checked to confirm the result is actually statically linked.
12. **Reboots if the kernel was replaced.** A full upgrade deletes
    `/usr/lib/modules/<running release>`. Without it the running kernel cannot load
    `nft_chain_nat`, and Docker cannot build its NAT chain. Every later role depends on that
    module tree, so the reboot happens here rather than failing later.

---

## 3. `boot` — tag `boot`

**Changes:** the kernel command line, and the GRUB menu theme.

Two independent jobs that share one `grub.cfg` regeneration at the end:

- **Quiet boot.** Writes `quiet loglevel=3 systemd.show_status=false ...` to
  `/etc/kernel/cmdline` (and rebuilds the unified kernel image with `mkinitcpio -P`) and to
  `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`. Both are handled because this host
  boots a UKI — the cmdline is baked into the image at build time, so editing GRUB alone
  changes nothing.
- **GRUB theme.** Clones the `frieren` theme, copies it to `/boot/grub/themes/frieren`,
  selects the files for your resolution, prunes fonts `theme.txt` does not reference (~13 MB
  of unused fonts otherwise sit on the EFI partition and are read at every boot), writes
  `/etc/grub.d/09_loadfonts`, and sets the theme keys in `/etc/default/grub`.

**Worth knowing:**
- Every step is conditional on the files existing. On a machine with no GRUB and no
  `/etc/kernel/cmdline`, **this role does nothing at all** — that is correct behaviour, not
  a bug.
- Nothing under `/boot` gets an owner or mode, because vfat cannot store them.
- `grub.cfg` is generated to a candidate path, syntax-checked with `grub-script-check`, and
  only then moved into place. The previous copy goes to
  `/var/lib/arch-autodeploy/grub.cfg.previous`.
- Changes take effect at the **next boot**.

---

## 4. `docker` — tag `docker`

**Changes:** installs `docker docker-compose docker-buildx`, creates the `docker` group,
adds `liam`, enables `docker.service`.

**Worth knowing:**
- Two guards run *before* anything is changed: the running kernel must have a module tree,
  and `nft list ruleset` must work. If either fails the role stops without touching Docker
  state, and tells you to reboot.
- Supplementary groups are fixed at login, so after adding `liam` to `docker` the role drops
  and remakes its connection to get fresh `initgroups` — otherwise the socket test would run
  in a stale session and hit permission denied.
- Proves the result twice: `docker info` and `docker run --rm hello-world`, both as `liam`
  without sudo.
- **Security note:** `docker` group members are effectively root. Acceptable on a personal
  workstation; remove the membership on a shared host.

---

## 5. `dotfiles` — tag `dotfiles`

**Changes:** clones `~/dotfiles`, then creates symlinks throughout `$HOME` with GNU Stow.

How it works:

1. Clone or fast-forward the dotfiles repo (`force: false` — local changes are never
   overwritten).
2. Run `roles/dotfiles/files/stow_manifest.py`, which walks every git-tracked file in the 22
   Stow packages and reports, as JSON: which target paths are missing, which already resolve
   correctly, and which are **conflicts** (a real file, or a symlinked parent directory,
   blocking the link).
3. Move only the conflicting paths into `~/dotfiles-backup-<timestamp>/`, preserving their
   relative layout.
4. Run `stow --no-folding --target ~ <package>` for each package. `--no-folding` means every
   managed file is an individual symlink, so each one is independently verifiable.
5. Re-run the manifest and assert nothing is left unresolved.

**Worth knowing:** the backup step is what makes this safe to run on a machine that already
has config files. Nothing is deleted; it is moved aside and the path is reported.

---

## 6. `greeter` — tag `greeter`

**Changes:** the login screen — SDDM showing a theme from the qylock collection.

1. Renames `/usr/share/wayland-sessions/hyprland-uwsm.desktop` to `.disabled`. Both
   Hyprland session files register the same `DesktopNames`, which is what makes greeters
   default to the uwsm-managed session instead of the plain one. Renamed, not deleted — and
   re-checked every run, because a `hyprland` package upgrade restores the original.
2. Runs `~/.local/bin/theme set` (from the dotfiles) if the desktop theme has never been
   rendered. An existing theme choice always wins; `greeter_theme_slug` is only the
   fresh-box fallback.
3. Clones qylock with a **blobless sparse checkout** — the full repo is ~1.1 GB because every
   theme ships its own video assets; one theme is ~25 MB.
4. Copies the theme to `/usr/share/sddm/themes/<name>` and writes `/etc/sddm.conf.d/theme.conf`.
5. Disables `greetd` (it must give up the `display-manager.service` alias before
   `systemctl enable sddm` will work), enables `sddm`, and starts it **only if no display
   manager is currently running** — starting one while another owns the VT would kill the
   session. Otherwise it tells you to reboot.

**Worth knowing:** qylock's own `sddm.sh` installer is interactive (fzf pickers, `read`
prompts), so this role does what that script does rather than running it, writing to the
same config path so the two do not shadow each other.

---

## Play 2 · 7. `ssh` — tag `ssh`

**Changes:** `/etc/ssh/sshd_config.d/99-ansible-hardening.conf` (mode 0600) with
`PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`,
`MaxAuthTries 3`, `X11Forwarding no`, `AllowAgentForwarding no`, `ClientAliveInterval 300`,
`ClientAliveCountMax 2`.

The lockout-safe sequence:

1. Ensure `~/.ssh` exists and install the vaulted public key.
2. **Refuse to continue** unless `ssh-keygen -l` recognizes a key in `authorized_keys`.
3. Start `sshd`, discover the real port from `sshd -T`.
4. **Prove key auth works** with a fresh, non-multiplexed SSH connection from the
   controller — before passwords are disabled.
5. Write the drop-in, validated by `sshd -t -f` before installation.
6. Flush handlers → restart `sshd` (a restart, never a stop: existing sessions survive).
7. Wait for the port, **prove key auth again**, then assert all nine settings are actually
   in effect according to `sshd -T`.

If step 4 fails, nothing is hardened and the firewall roles never run.

---

## Play 3 · 8. `ufw` — tag `ufw`

**Changes:** installs `ufw`; rate-limits the SSH port; opens LocalSend (53317 TCP+UDP) from
the trusted ranges only; sets default deny-incoming / allow-outgoing; enables the firewall
and its service.

Then **opens a fresh SSH connection from the controller** to prove the firewall did not lock
the host out.

The SSH allowance is added even when `ssh_enabled` is false, because this role and the
verification role both need SSH to prove themselves. The final play deletes it afterwards.

## Play 3 · 9. `fail2ban` — tag `fail2ban`

**Changes:** installs `fail2ban`; writes `/etc/fail2ban/jail.local` with the
`nftables-multiport` ban action, your `admin_ips` in `ignoreip`, and an `[sshd]` jail using
the systemd backend; enables and starts the service.

Config is validated with `fail2ban-client -t` before the service is touched. Play 3 also
re-asserts the `admin_ips` whitelist in a pre-task, so a bad value stops the run **before**
any firewall change.

---

## Play 4 · 10. `verification` — tag `verification`

**Read-only.** Runs ~20 commands and asserts on their output: user identity and groups,
sudoers and doas validity and exact content, `yay`, every configured package via `pacman -Q`,
Docker as `liam` plus a `hello-world` container, `sshd -t` and the effective policy, a fresh
key-authenticated SSH connection, UFW status, the fail2ban jail/action/ignoreip, and that
seven key Stow symlinks resolve into `~/dotfiles`.

Then it prints a PASS table and the unedited output of every command, so the run leaves
evidence rather than a claim. A failed assertion stops the play, so the PASS table only
appears if everything passed.

## Play 4 post-tasks

1. **Set the password** from the vault hash (`update_password: always`). Last for the reason
   given in the `users` section.
2. **Tear down SSH** if `ssh_enabled` is false: delete the UFW rule (only if it is actually
   present), then stop and disable `sshd`. Arch's `sshd.service` uses `KillMode=process`, so
   the session Ansible is running over survives long enough to report back.

Next: [verification and recovery](07-verification-and-recovery.md).
