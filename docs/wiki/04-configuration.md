# 4. Configuration

Everything lives in `group_vars/all/main.yml` unless noted. Values there are already sane;
this page tells you which ones are actually *yours* to set.

Precedence, lowest to highest: role `defaults/main.yml` → `group_vars/all/main.yml` →
`group_vars/all/vault.yml` → `-e` on the command line.

---

## Must change

### `inventory/hosts.ini`
The target's IP and login account. See [page 3](03-first-time-setup.md).

### `admin_ips`
IP addresses and CIDR ranges that fail2ban will **never** ban. If you get this wrong you can
ban yourself out of your own machine.

```yaml
admin_ips:
  - 10.2.1.0/24
  - 192.168.1.1
  - 127.0.0.1
  - 192.168.1.0/24
```

Play 3 refuses to run unless every entry matches `^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$` — a
bare IPv4 address or address/prefix. No hostnames, no IPv6. For a remote target, use the
public source address the target *sees you coming from*, not the target's own address.

### The vault keys
`vault_liam_password_hash` and `vault_liam_authorized_key`. See [page 3](03-first-time-setup.md#step-4-create-the-vault).

### `wallhaven_dl_controller_source`
```yaml
wallhaven_dl_controller_source: >-
  {{ lookup('ansible.builtin.env', 'HOME') }}/Projects/wallhaven-tools/wallhaven-dl
```
`fhlkfds/wallhaven-tools` is a **private** repo, so unlike every other external source in
this playbook the target cannot clone it — there are no GitHub credentials there, and
`ssh_allow_agent_forwarding` is `false`. The `packages` role therefore copies the script
from the controller's checkout to `~/Projects/wallhaven-tools/wallhaven-dl` on the target,
then symlinks it into `~/.local/bin`.

If your checkout is elsewhere, point this at it. If you do not have access to that repo at
all, delete these four tasks from `roles/packages/tasks/main.yml` (`Check for the wallhaven
downloader source on the controller` through `Copy the wallhaven downloader from the
controller checkout`) plus the link task, or the run will stop there.

---

## Probably change

### `admin_user` / `admin_home` / `admin_shell`
```yaml
admin_user: liam
admin_home: "/home/{{ admin_user }}"
admin_shell: /usr/bin/zsh
```
If you change `admin_user`, also change `ansible_user` in the inventory to match — the `ssh`
role asserts they are the same before it disables root login.

### `dotfiles_repo_url` / `stow_packages`
```yaml
dotfiles_repo_url: https://github.com/fhlkfds/dotfiles.git
dotfiles_repo_version: main
stow_packages: [ai, browser, cliphist, fastfetch, greeter, hypr, hyprlock, kitty,
                menu, modes, noctalia, quickshell, rofi, screensaver, security,
                swaync, systemd, wallpaper, windows, wofi, xdg, zsh]
```
Point at your own dotfiles. `stow_packages` must name directories that exist at the top
level of that repo — each becomes a set of symlinks into `$HOME`. If you swap the repo, also
update `stow_key_links`, which the `verification` role uses to prove seven specific symlinks
resolve correctly.

### `ssh_enabled`
```yaml
ssh_enabled: false
```
`false` means: harden and prove `sshd` during the run, then stop and disable it at the end,
and delete its firewall rule. The finished machine listens on nothing.

Set it to `true` if this is a machine you administer remotely. You can also override per-run
without editing the file: `-e ssh_enabled=true`.

### `localsend_port` / `localsend_source_ranges`
```yaml
localsend_port: 53317
localsend_source_ranges:
  - 10.2.1.0/24
  - 192.168.1.0/24
```
Opens TCP **and** UDP on that port, but only from those ranges. UDP carries LocalSend's
multicast discovery; without it you must add every device by IP manually. Set the list to
`[]` to close the port entirely.

### `ufw_lan_rules`
Empty by default. Add your own LAN-scoped rules:
```yaml
ufw_lan_rules:
  - { port: "1714:1764", proto: udp, from_ip: "192.168.1.0/24", comment: "KDE Connect LAN" }
```

### Theme choices
```yaml
sddm_theme: star-rail                    # any directory under qylock's themes/
greeter_theme_slug: tokyo-night          # dotfiles theme, fresh-box fallback only
boot_grub_theme_resolution: 1920x1080    # or 2560x1440 — those are the only two
boot_grub_theme_name: frieren
```
`sddm_theme` may be a nested variant such as `clockwork/orbital`; it is installed under just
the last path component. Some qylock themes expect a font that cannot be redistributed — the
role reports where to drop it and falls back to a default font.

---

## Rarely change

### Package lists
`official_packages` (107), `aur_packages` (12), `docker_packages` (3). Adding a name to
`official_packages` is enough — the role installs the whole list with `--needed`. Removing a
name does **not** uninstall it from a machine that already has it.

### `boot_quiet` / `boot_quiet_params`
```yaml
boot_quiet: true
boot_quiet_params: [quiet, loglevel=3, systemd.show_status=false,
                    rd.systemd.show_status=false, rd.udev.log_level=3,
                    udev.log_level=3, vt.global_cursor_default=0]
```
Set `boot_quiet: false` while debugging a boot problem. Any key listed here *replaces* an
existing value for the same key on the kernel command line; keys not listed are preserved.

### `roles/packages/defaults/main.yml`
```yaml
aur_fail_hard: false        # true = an unbuildable AUR package stops the whole run
aur_install_retries: 2      # total yay attempts per package, not extra ones
aur_install_retry_delay: 10 # seconds between attempts
```
The AUR is third-party. By default a package that will not build is reported loudly and
skipped, and provisioning continues.

### `fail2ban_bantime` / `_findtime` / `_maxretry`
`1h` / `10m` / `5`. Five failures in ten minutes gets you banned for an hour.

---

## Do not change without reading the comments

These have long explanatory comments above them in `main.yml` and the role files, and the
values are load-bearing:

| Variable | Why |
|---|---|
| `sddm_display_server: wayland` | Requires `weston` to be installed to host the greeter. Switching to `x11` needs `xorg-server` added to the package list. |
| `sddm_wayland_compositor_command: ""` | Empty on purpose, so SDDM uses the compositor compiled into the installed version. |
| `ssh_validation_host` | Auto-resolves to `127.0.0.1` for local runs, otherwise the target's address. Used for the fresh key-auth checks. |
| `ttfx_git_rev` | A pinned, inspected commit. Unpinning means building whatever upstream HEAD happens to be. |
| `boot_grub_cfg_backup_path` | Lives outside `/boot` because `/boot` is vfat and cannot store the colons in Ansible's timestamped backup names. |

## Checking your work

Render the effective values without changing anything:

```bash
ansible -m debug -a 'var=admin_ips' all --ask-vault-pass
ansible -m debug -a 'var=official_packages' all --ask-vault-pass
```

Next: [running the playbook](05-running-the-playbook.md).
