# LOCAL-SOP — reproduce `site.yml` by hand on one fresh Arch PC

Manual translation of the `arch-autodepoly` Ansible playbook. Same machine acts as
controller and target: no SSH inventory, no second computer. Everything below runs
as `root` unless the step says otherwise; user-scoped work uses `sudo -u liam -H`.

**What the playbook does:** creates `liam` with sudo/doas, full-upgrades Arch, installs
107 official + 12 AUR packages, builds `yay` and `ttfx`, enables libvirt/tailscaled,
silences the boot console and themes GRUB, enables Docker, deploys 22 GNU Stow dotfile
packages, installs an SDDM/qylock login theme, hardens `sshd`, enables UFW + fail2ban,
verifies everything, sets the account password, then **stops and disables sshd**.

## Role index

| SOP section | Role | Playbook tags | Play |
|---|---|---|---|
| §5 Step 0 | *(play 1 pre_tasks)* | `always` | 1 |
| §5 Step 1 | `users` | `users`, `always` | 1 |
| §5 Step 2 | `packages` | `packages` | 1 |
| §5 Step 3 | `boot` | `boot` | 1 |
| §5 Step 4 | `docker` | `docker` | 1 |
| §5 Step 5 | `dotfiles` | `dotfiles` | 1 |
| §5 Step 6 | `greeter` | `greeter` | 1 |
| §5 Step 7 | `ssh` | `ssh` | 2 |
| §5 Step 8 | *(play 3 pre_task assert)* | `fail2ban` | 3 |
| §5 Step 9 | `ufw` | `ufw` | 3 |
| §5 Step 10 | `fail2ban` | `fail2ban` | 3 |
| §5 Step 11 | `verification` | `verification` | 4 |
| §5 Step 12 | *(play 4 post_task: password)* | `users`, `password` | 4 |
| §5 Step 13 | *(play 4 post_tasks: SSH teardown)* | `ssh`, `ssh_teardown` | 4 |

---

## 1. Assumptions

- Arch Linux x86_64, rolling, booted from a normal `pacstrap` install with networking up.
  The playbook asserts `os_family == Archlinux` and `architecture == x86_64` and refuses
  anything else (the `ttfx` build pins `x86_64-unknown-linux-musl`).
- `/boot` may be a vfat EFI system partition. Nothing under `/boot` is given an owner or
  a mode, because vfat cannot store them.
- Blank slate: every step assumes the state does not exist yet. No "skip if already done".
- You have console access. Do not do this over a network session you cannot lose — §5
  Step 13 deliberately shuts SSH down.

## 2. Cannot run as written on one PC / must be pre-supplied

| Ref | Issue | What you do instead |
|---|---|---|
| F1 | The `ssh`, `ufw` and `verification` roles run 4 `delegate_to: localhost` SSH checks | With `ansible_connection: local`, `ssh_validation_host` is `127.0.0.1`. They become loopback SSH to yourself as `liam`. Kept as real steps below. Needs a passphrase-less key (`BatchMode=yes`). |
| F2 | `vault_liam_authorized_key` gates the whole ssh role | Generate a keypair for `liam` in §4 Step P4 before Step 7. |
| F3 | `wallhaven-dl` comes from the **private** repo `fhlkfds/wallhaven-tools`, so the target cannot clone it | The `packages` role copies it from the controller's checkout (`wallhaven_dl_controller_source`). On a single local PC controller and target are the same machine, so you must have the checkout at `/home/liam/Projects/wallhaven-tools`. §4 Step P5. |
| F4 | `greeter` calls `/home/liam/.local/bin/theme` | Supplied by the external `fhlkfds/dotfiles` repo via Step 5. If upstream dropped it, Step 6 fails. |
| F5 | `boot` needs `/etc/kernel/cmdline` (UKI) and/or `/etc/default/grub` + `/usr/bin/grub-mkconfig` | On a stock install with neither, Step 3 is a no-op. Do not create them to "make it work" — that changes how the box boots. |
| F6 | End state has no SSH server | `ssh_enabled: false`. Everything SSH-related is torn down in Step 13. |
| F7 | `packages` may reboot | Step 2.16. Reboot, then resume at Step 2.17. |
| F13 | `--ask-become-pass` / `--ask-vault-pass` | No analogue. You are already root; the password hash goes straight into `usermod -p`. |
| F14 | `no_log: true` tasks (authorized key, password hash) | Do not paste secrets into a logged terminal. |

Repo issues found, **not fixed**:

- F8 `tests/dotfiles-idempotency.yml:9` loads `../group_vars/all.yml`; the real path is `group_vars/all/main.yml`. Test cannot run.
- F9 README says `group_vars/vault.yml{,.example}`; real paths are `group_vars/all/vault.yml{,.example}`.
- F10 README Stow list says `Wallpapers`; `stow_packages` says `wallpaper`, and adds `greeter` and `menu`. The vars file is what runs.
- F11 `admin_ips` includes `127.0.0.1`, already covered by the template's hardcoded `127.0.0.1/8`.
- F12 `roles/boot/tasks/main.yml` comment claims a `.bak` backup; Ansible actually writes `<file>.<pid>.<YYYY-MM-DD@HH:MM:SS~>`.
- `vault_admin_ip` appears in `vault.yml.example` but is referenced nowhere; `admin_ips` is hardcoded in `group_vars/all/main.yml`.

---

## 3. Variables

Non-secret values are filled in for real. Substitute the `<PLACEHOLDER>`s.

### Global (group_vars/all/main.yml)

| Name | Effective value | Used by |
|---|---|---|
| `admin_user` | `liam` | every role |
| `admin_home` | `/home/liam` | every role |
| `admin_shell` | `/usr/bin/zsh` | users |
| `admin_password_hash` | `<PASSWORD_HASH>` — crypt(3) hash, e.g. yescrypt `$y$…`. Generate with `scripts/make-password-hash.py`. Empty ⇒ Step 12 is skipped. | Step 12 |
| `admin_authorized_key` | `<SSH_PUBLIC_KEY>` — one `ssh-ed25519 AAAA… ` line. Empty ⇒ an existing `authorized_keys` must already hold a valid key. | Step 7 |
| `admin_ips` | `10.2.1.0/24`, `192.168.1.1`, `127.0.0.1`, `192.168.1.0/24` | Step 8, Step 10 |
| `ssh_validation_host` | `127.0.0.1` (local connection) | Steps 7, 9, 11 |
| `ssh_validation_identity_file` | `""` (use default keys / agent) | Steps 7, 9, 11 |
| `ssh_allow_agent_forwarding` | `false` | Step 7 template |
| `ssh_enabled` | `false` | Step 13 |
| `effective_ssh_port` | discovered at runtime from `sshd -T`; **`22`** on stock Arch | Steps 9, 10, 13 |
| `workstation_groups` | `wheel video audio input storage optical lp` | Step 1 |
| `official_packages` | 107 names, listed in Step 2.2 | Steps 2, 11 |
| `aur_packages` | 12 names, listed in Step 2.11 | Steps 2, 11 |
| `docker_packages` | `docker docker-compose docker-buildx` | Steps 4, 11 |
| `dotfiles_repo_url` / `_version` / `_path` | `https://github.com/fhlkfds/dotfiles.git` / `main` / `/home/liam/dotfiles` | Step 5 |
| `stow_packages` | 22 names, listed in Step 5.2 | Step 5 |
| `stow_key_links` | 7 pairs, listed in §7 | Step 11 |
| `wallhaven_dl_source` | `/home/liam/Projects/wallhaven-tools/wallhaven-dl` (on the target) | Step 2.14 |
| `wallhaven_dl_controller_source` | `$HOME/Projects/wallhaven-tools/wallhaven-dl` → `/home/liam/Projects/wallhaven-tools/wallhaven-dl` (on the controller; private repo, cannot be cloned target-side) | Step 2.14 |
| `wallhaven_dl_link` | `/home/liam/.local/bin/wallhaven-dl` | Step 2.14 |
| `oh_my_zsh_repo_url` | `https://github.com/ohmyzsh/ohmyzsh.git` | Step 2.12 |
| `powerlevel10k_repo_url` | `https://github.com/romkatv/powerlevel10k.git` | Step 2.12 |
| `fzf_tab_repo_url` | `https://github.com/Aloxaf/fzf-tab.git` | Step 2.12 |
| `ttfx_repo_url` / `ttfx_git_rev` | `https://github.com/omacom-io/ttfx` / `7203e354498462064b7c0a89375051f65cf2ce99` | Step 2.15 |
| `greeter_theme_slug` | `tokyo-night` | Step 6.2 |
| `qylock_repo_url` / `_version` / `_path` | `https://github.com/Darkkal44/qylock.git` / `main` / `/home/liam/builds/qylock` | Step 6.3 |
| `sddm_theme` | `star-rail` | Step 6 |
| `sddm_theme_font_note` | `DIN Next, saved as font.ttf` | Step 6.5 (report only) |
| `sddm_themes_dir` | `/usr/share/sddm/themes` | Step 6.6 |
| `sddm_conf_path` | `/etc/sddm.conf.d/theme.conf` | Step 6.7 |
| `sddm_display_server` | `wayland` | Step 6.7 |
| `sddm_wayland_compositor_command` | `""` — empty, so no `[Wayland]` block is rendered | Step 6.7 |
| `fail2ban_bantime` / `_findtime` / `_maxretry` | `1h` / `10m` / `5` | Step 10 |
| `ufw_lan_rules` | `[]` — loop produces no rules | Step 9.3 |
| `localsend_port` | `53317` | Step 9.4 |
| `localsend_source_ranges` | `10.2.1.0/24`, `192.168.1.0/24` | Step 9.4 |

### roles/packages/defaults/main.yml

| Name | Effective value | Used by |
|---|---|---|
| `aur_fail_hard` | `false` — an unbuildable AUR package is reported and skipped | Step 2.11 |
| `aur_install_retries` | `2` — total attempts per package, not extra ones | Step 2.11 |
| `aur_install_retry_delay` | `10` (seconds) | Step 2.11 |

### roles/boot/defaults/main.yml

| Name | Effective value | Used by |
|---|---|---|
| `boot_quiet` | `true` | Step 3.2 |
| `boot_quiet_params` | `quiet loglevel=3 systemd.show_status=false rd.systemd.show_status=false rd.udev.log_level=3 udev.log_level=3 vt.global_cursor_default=0` | Step 3.2 |
| `boot_uki_cmdline_path` | `/etc/kernel/cmdline` | Step 3.2 |
| `boot_grub_default_path` | `/etc/default/grub` | Steps 3.1, 3.3, 3.10 |
| `boot_grub_cfg_path` | `/boot/grub/grub.cfg` | Step 3.11 |
| `boot_grub_mkconfig_path` | `/usr/bin/grub-mkconfig` | Step 3.1 |
| `boot_grub_loadfonts_path` | `/etc/grub.d/09_loadfonts` | Step 3.9 |
| `boot_backup_dir` | `/var/lib/arch-autodeploy` | Step 3.11 |
| `boot_grub_cfg_backup_path` | `/var/lib/arch-autodeploy/grub.cfg.previous` | Step 3.11 |
| `boot_grub_theme_enabled` | `true` | Step 3.4 |
| `boot_grub_theme_name` | `frieren` | Step 3.4 |
| `boot_grub_theme_repo_url` / `_version` / `_path` | `https://github.com/crocodile13/frieren-grub-theme.git` / `main` / `/home/liam/builds/frieren-grub-theme` | Step 3.4 |
| `boot_grub_themes_dir` | `/boot/grub/themes` | Step 3.6 |
| `boot_grub_theme_dir` (derived) | `/boot/grub/themes/frieren` | Step 3.6 |
| `boot_grub_theme_resolution` | `1920x1080` | Steps 3.6, 3.10 |
| `boot_grub_theme_variant` (derived) | `theme: theme_1080p.txt`, `background: background_1080.png` | Step 3.6 |
| `boot_grub_theme_prune_unused_fonts` | `true` | Step 3.8 |
| `boot_min_free_boot_mb` | `50` | Step 3.5 |

---

## 4. Prerequisites

From a bare Arch ISO state, with a booted, networked install.

**P1 — base tooling the manual procedure itself needs.** The playbook's `raw` pre_task
does the equivalent of the first line; the rest replaces Ansible's own modules.

```bash
pacman -Syu --needed --noconfirm python
pacman -S --needed --noconfirm git base-devel sudo stow jq
```

Verify:
```bash
python3 -V && git --version && stow --version | head -1
```

**P2 — assert the platform.** Both are hard preconditions; the playbook refuses otherwise.

```bash
grep -q '^ID=arch' /etc/os-release && echo OS_OK || echo 'STOP: not Arch'
[ "$(uname -m)" = x86_64 ] && echo ARCH_OK || echo 'STOP: ttfx pins x86_64-unknown-linux-musl'
```

**P3 — this repository on disk.** The SOP references `roles/dotfiles/files/stow_manifest.py`.

```bash
ls /home/liam/Projects/arch-autodepoly/roles/dotfiles/files/stow_manifest.py
```

**P4 — an SSH keypair for `liam` (F1, F2).** Required before Step 7; `BatchMode=yes` means
no passphrase, or the key must be loaded in an agent.

```bash
sudo -u liam -H ssh-keygen -t ed25519 -N '' -f /home/liam/.ssh/id_ed25519
sudo -u liam -H cat /home/liam/.ssh/id_ed25519.pub   # this is <SSH_PUBLIC_KEY>
```

**P5 — the wallhaven downloader checkout (F3).** `packages` asserts this file is a regular,
executable file on the controller and aborts if it is not. `fhlkfds/wallhaven-tools` is a
**private** repo, so it cannot be cloned anonymously — clone it with credentials that can
read it (SSH remote, or `gh repo clone`):

```bash
sudo -u liam -H git clone git@github.com:fhlkfds/wallhaven-tools.git \
  /home/liam/Projects/wallhaven-tools
test -x /home/liam/Projects/wallhaven-tools/wallhaven-dl && echo WALLHAVEN_OK
```

On this single-PC setup controller and target are the same machine, so this checkout
satisfies both `wallhaven_dl_controller_source` and the copy destination.

**P6 — the password hash (`<PASSWORD_HASH>`), for Step 12.**

```bash
python3 /home/liam/Projects/arch-autodepoly/scripts/make-password-hash.py
# prints: vault_liam_password_hash: '$y$...'
```

---

## 5. Steps, in playbook execution order

### Step 0 — Play 1 pre_tasks (tags: `always`)

**0.1 Bootstrap Python** — already done in P1. Idempotent equivalent:

```bash
[ -x /usr/bin/python3 ] || pacman -Syu --needed --noconfirm python
```
*Why:* every Ansible module needs a remote interpreter. Locally this is just `python`.
*Verify:* `python3 -V`

**0.2 Reconnect / gather facts** — no local action. `meta: reset_connection` and `setup`
have no meaning on the machine itself.

**0.3 / 0.4 Platform asserts** — done in P2.

---

### Step 1 — role `users` (tags: `users`, `always`)

**1.1 Primary group.**
```bash
groupadd -f liam
```
*Why:* `liam`'s primary group must exist before the account.
*Verify:* `getent group liam`

**1.2 Workstation groups.**
```bash
for g in wheel video audio input storage optical lp; do groupadd -f "$g"; done
```
*Why:* the seven supplementary groups in `workstation_groups`.
*Verify:* `for g in wheel video audio input storage optical lp; do getent group "$g" >/dev/null && echo "ok $g"; done`

**1.3 Create the account (no password).**
```bash
id liam >/dev/null 2>&1 \
  || useradd --create-home --home-dir /home/liam --shell /usr/bin/zsh \
             --gid liam --groups wheel,video,audio,input,storage,optical,lp liam
usermod -d /home/liam -s /usr/bin/zsh -g liam -aG wheel,video,audio,input,storage,optical,lp liam
```
*Why:* `append: true` — memberships are added, never replaced. The password is
deliberately not set here; that is Step 12.
*Verify:* `id liam`

**1.4 Sudoers rule (validated).**
```bash
printf 'liam ALL=(ALL:ALL) ALL\n' > /tmp/sudoers.liam
/usr/sbin/visudo -cf /tmp/sudoers.liam \
  && install -o root -g root -m 0440 /tmp/sudoers.liam /etc/sudoers.d/liam \
  && rm -f /tmp/sudoers.liam
```
*Why:* `copy` with `validate: /usr/sbin/visudo -cf %s` — never install an unparseable
sudoers fragment.
*Verify:* `visudo -cf /etc/sudoers.d/liam && cat /etc/sudoers.d/liam`

**1.5 Verify membership and sudo policy (the role's own asserts).**
```bash
id liam | grep -q '(wheel)' && echo WHEEL_OK || echo 'STOP: liam not in wheel'
sudo -l -U liam
```
*Why:* the role asserts `'wheel' in id output` and stops the play otherwise.

**1.6 Password status report.** Informational only:
```bash
echo "Password will be applied in Step 12 from <PASSWORD_HASH>."
```

---

### Step 2 — role `packages` (tag: `packages`)

**2.1 Full upgrade, with the keyring rescue path.**
```bash
pacman -Syu --noconfirm 2>&1 | tee /tmp/syu.log \
  || { grep -Eiq 'signature|keyring|unknown trust|invalid or corrupted package' /tmp/syu.log \
       && pacman -Sy --noconfirm archlinux-keyring && pacman -Syu --noconfirm; }
```
*Why:* the role's `block`/`rescue`. The rescue only fires on a signature/keyring failure —
any other cause is a hard stop, "refusing a speculative keyring repair".
*Verify:* `pacman -Qu; echo "pending upgrades: $?"` (rc 1 / empty output = fully upgraded)

**2.2 Install the 107 official packages.**
```bash
pacman -S --needed --noconfirm \
  base-devel git stow sudo zsh curl openssh hyprland hyprpaper hypridle hyprlock \
  hyprsunset hyprpolkitagent kitty rofi quickshell wl-clipboard cliphist libnotify \
  python jq playerctl udiskie pipewire wireplumber networkmanager \
  networkmanager-openvpn openvpn tailscale bluez-utils iputils polkit nautilus \
  gnome-disk-utility spotify-launcher obsidian virt-manager libvirt qemu-full dnsmasq \
  btop imv mpv zathura zathura-pdf-mupdf neovim grim slurp hyprpicker \
  gpu-screen-recorder sddm weston qt6-declarative qt6-5compat qt6-svg qt6-multimedia \
  qt6-multimedia-ffmpeg gst-plugins-base gst-plugins-good gst-plugins-bad \
  gst-plugins-ugly satty ffmpeg imagemagick tesseract tesseract-data-eng v4l-utils \
  ddcutil pam-u2f libfido2 gnupg rust musl rust-musl socat freerdp yt-dlp libheif file \
  libqalculate papirus-icon-theme ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji \
  eza zsh-syntax-highlighting zsh-autosuggestions fzf fastfetch cava wofi swaync \
  pacman-contrib opendoas power-profiles-daemon brightnessctl zbar translate-shell \
  python-gobject xdg-desktop-portal xdg-desktop-portal-hyprland wtype gifski \
  xdg-user-dirs vulkan-tools mesa-utils opencode
```
*Why:* `official_packages`, verbatim and in list order. `greetd*` are deliberately absent
but are **not** removed from a host that has them.
*Verify:* `pacman -Q base-devel hyprland sddm weston opencode >/dev/null && echo OFFICIAL_OK`

**2.3 libvirt group.**
```bash
groupadd -f libvirt
```
*Verify:* `getent group libvirt`

**2.4 Add `liam` to libvirt.**
```bash
usermod -aG libvirt liam
```
*Why:* `qemu:///system`'s socket is restricted to root and the `libvirt` group.
*Verify:* `id -nG liam | tr ' ' '\n' | grep -qx libvirt && echo LIBVIRT_GROUP_OK`

**2.5 Reconnect** (`meta: reset_connection`) — locally, supplementary groups are picked up
by any fresh login. Every `sudo -u liam -H` below starts a fresh process, so this is
automatic. No action.

**2.6 libvirtd.**
```bash
systemctl enable --now libvirtd.service
```
*Verify:* `systemctl is-enabled libvirtd.service && systemctl is-active libvirtd.service`

**2.7 Prove the system QEMU connection as `liam`.**
```bash
[ "$(sudo -u liam -H virsh -c qemu:///system uri)" = 'qemu:///system' ] \
  && echo VIRSH_OK || echo 'STOP: libvirt system URI check failed'
```
*Why:* the role's `failed_when` demands rc 0 and exactly `qemu:///system` on stdout.

**2.8 tailscaled.**
```bash
systemctl enable --now tailscaled.service
```
*Why:* daemon only. Tailnet login is deliberately left to you (`sudo tailscale up`) — the
playbook must never authenticate the device.
*Verify:* `systemctl is-active tailscaled.service`

**2.9 doas rule (validated).**
```bash
printf 'permit persist liam as root\n' > /tmp/doas.conf
/usr/bin/doas -C /tmp/doas.conf \
  && install -o root -g root -m 0440 /tmp/doas.conf /etc/doas.conf \
  && rm -f /tmp/doas.conf
```
*Why:* the stowed `zsh` dotfiles alias `sudo` to `doas`; `opendoas` ships no default
config, so without this every interactive `sudo` on the host breaks.
*Verify:* `doas -C /etc/doas.conf; echo rc=$?; cat /etc/doas.conf`

**2.10 Build `yay` as `liam`.**
```bash
install -d -o liam -g liam -m 0755 /home/liam/builds
yay --version >/dev/null 2>&1 || {
  sudo -u liam -H git clone https://aur.archlinux.org/yay.git /home/liam/builds/yay
  printf 'liam ALL=(root) NOPASSWD: /usr/bin/pacman\n' > /tmp/sudoers.makepkg
  /usr/sbin/visudo -cf /tmp/sudoers.makepkg \
    && install -o root -g root -m 0440 /tmp/sudoers.makepkg /etc/sudoers.d/liam-makepkg
  sudo -u liam -H env HOME=/home/liam NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 \
      CLICOLOR_FORCE=0 TERM=dumb CI=true \
      bash -c 'cd /home/liam/builds/yay && makepkg -si --noconfirm'
}
rm -f /etc/sudoers.d/liam-makepkg /tmp/sudoers.makepkg
```
*Why:* `makepkg` refuses root; the temporary NOPASSWD-pacman grant is narrowly scoped and
removed unconditionally (the role's `always:` block), even if the build fails.
*Verify:* `yay --version && test ! -e /etc/sudoers.d/liam-makepkg && echo YAY_OK`

**2.11 AUR packages, batch then per-package retry.**
```bash
AUR="brave-bin claude-code helium-browser-bin hermes-agent-desktop hyprvoice-bin \
localsend-bin looking-glass mpvpaper pokemon-colorscripts-git t3code-bin \
wl-screenrec-git xdg-terminal-exec"

MISSING=""; for p in $AUR; do pacman -Q "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
echo "missing:$MISSING"

if [ -n "$MISSING" ]; then
  printf 'liam ALL=(root) NOPASSWD: /usr/bin/pacman\n' > /tmp/sudoers.yay
  /usr/sbin/visudo -cf /tmp/sudoers.yay \
    && install -o root -g root -m 0440 /tmp/sudoers.yay /etc/sudoers.d/liam-yay

  YAYENV='env HOME=/home/liam NO_COLOR=1 FORCE_COLOR=0 CLICOLOR=0 CLICOLOR_FORCE=0 TERM=dumb CI=true'
  SKIPPED=""
  if ! sudo -u liam -H $YAYENV yay -S --needed --noconfirm --answerclean None --answerdiff None $MISSING; then
    for p in $MISSING; do
      ok=0
      for attempt in 1 2; do                       # aur_install_retries = 2 total attempts
        sudo -u liam -H $YAYENV yay -S --needed --noconfirm \
             --answerclean None --answerdiff None "$p" && { ok=1; break; }
        [ "$attempt" = 1 ] && sleep 10             # aur_install_retry_delay = 10
      done
      [ "$ok" = 1 ] || SKIPPED="$SKIPPED $p"
    done
  fi
  rm -f /etc/sudoers.d/liam-yay /tmp/sudoers.yay
  [ -n "$SKIPPED" ] && printf '*** AUR PACKAGE(S) SKIPPED - PROVISIONING CONTINUED WITHOUT THEM ***%s\n' "$SKIPPED"
fi
```
*Why:* `aur_fail_hard: false` — an AUR package that will not build after its retry budget
is reported loudly and skipped, not fatal. Set `aur_fail_hard=true` semantics by stopping
here manually if `$SKIPPED` is non-empty.
*Verify:* `pacman -Q brave-bin claude-code t3code-bin xdg-terminal-exec; test ! -e /etc/sudoers.d/liam-yay && echo NO_TEMP_GRANT`

**2.12 Zsh framework repos, as `liam`.**
```bash
sudo -u liam -H git clone --depth 1 --branch master \
  https://github.com/ohmyzsh/ohmyzsh.git /home/liam/.oh-my-zsh
sudo -u liam -H git clone --depth 1 --branch master \
  https://github.com/romkatv/powerlevel10k.git \
  /home/liam/.oh-my-zsh/custom/themes/powerlevel10k
sudo -u liam -H git clone --depth 1 --branch master \
  https://github.com/Aloxaf/fzf-tab.git \
  /home/liam/.oh-my-zsh/custom/plugins/fzf-tab
```
*Why:* absent from the dotfiles tree by design; cloned with `force: false` so local changes
are never overwritten.
*Verify:* `ls -d /home/liam/.oh-my-zsh/.git /home/liam/.oh-my-zsh/custom/themes/powerlevel10k/.git /home/liam/.oh-my-zsh/custom/plugins/fzf-tab/.git`

**2.13 XDG user directories.**
```bash
[ -f /home/liam/.config/user-dirs.dirs ] || sudo -u liam -H env HOME=/home/liam xdg-user-dirs-update
install -d -o liam -g liam -m 0755 /home/liam/.local/bin
```
*Why:* `creates:` guard; then the user-local bin directory the next two steps need.
*Verify:* `cat /home/liam/.config/user-dirs.dirs; ls -ld /home/liam/.local/bin`

**2.14 wallhaven-dl: assert the checkout, place the script, link it.**
```bash
test -f /home/liam/Projects/wallhaven-tools/wallhaven-dl \
  && test -x /home/liam/Projects/wallhaven-tools/wallhaven-dl \
  || echo 'STOP: wallhaven-dl checkout missing or not executable (see P5)'
install -d -o liam -g liam -m 0755 /home/liam/Projects/wallhaven-tools
chown liam:liam /home/liam/Projects/wallhaven-tools/wallhaven-dl
chmod 0755      /home/liam/Projects/wallhaven-tools/wallhaven-dl
[ -e /home/liam/.local/bin/wallhaven-dl ] || \
  sudo -u liam -H ln -s /home/liam/Projects/wallhaven-tools/wallhaven-dl \
                        /home/liam/.local/bin/wallhaven-dl
```
*Why:* the role copies the script from the controller's checkout because the repo is
private and the target has no credentials for it. On one PC the copy is a no-op (source and
destination are the same path), so only the directory, mode and link matter here.
`force: false` — an existing command path is never replaced.
*Verify:* `readlink -f /home/liam/.local/bin/wallhaven-dl; test -x /home/liam/.local/bin/wallhaven-dl && echo EXEC_OK`

**2.15 Build `ttfx` (static musl) as `liam`.**
```bash
if ! file /home/liam/.local/bin/ttfx 2>/dev/null | grep -Eq 'statically linked|static-pie linked'; then
  sudo -u liam -H env HOME=/home/liam cargo install --locked \
    --root /home/liam/.local --target x86_64-unknown-linux-musl \
    --git https://github.com/omacom-io/ttfx \
    --rev 7203e354498462064b7c0a89375051f65cf2ce99 ttfx
fi
```
*Why:* the dotfiles' `install-ttfx` route, pinned to an inspected commit. This is why the
playbook refuses non-x86_64 hosts.
*Verify:* `file /home/liam/.local/bin/ttfx | grep -E 'statically linked|static-pie linked' && echo TTFX_OK`

**2.16 Reboot if the upgrade replaced the running kernel's modules (F7).**
```bash
if [ ! -d "/usr/lib/modules/$(uname -r)" ]; then
  echo 'Rebooting into the kernel just installed.'; systemctl reboot
fi
```
*Why:* a full `-Syu` that replaces the kernel deletes `/usr/lib/modules/<running release>`.
Without the module tree, `nft_chain_nat`/`nft_compat` cannot load and Docker cannot build
its NAT chain. Every later role depends on it.
*Resume:* log back in and continue at 2.17.

**2.17 Confirm the module tree.**
```bash
test -d "/usr/lib/modules/$(uname -r)" \
  && echo "MODULES_OK $(uname -r)" \
  || echo "STOP: running kernel $(uname -r) has no module tree; check bootloader/initramfs"
```

---

### Step 3 — role `boot` (tag: `boot`)

Read F5 first. If neither GRUB nor a UKI cmdline is present, this whole step is a no-op —
do not manufacture the files.

**3.1 Detect GRUB.**
```bash
BOOT_GRUB_PRESENT=false
[ -f /etc/default/grub ] && [ -x /usr/bin/grub-mkconfig ] && BOOT_GRUB_PRESENT=true
echo "boot_grub_present=$BOOT_GRUB_PRESENT"
```

**3.2 Quiet UKI cmdline** (only if `/etc/kernel/cmdline` exists).
```bash
[ -f /etc/kernel/cmdline ] && python3 - <<'PY'
import re, shutil, datetime, os
params = ["quiet","loglevel=3","systemd.show_status=false","rd.systemd.show_status=false",
          "rd.udev.log_level=3","udev.log_level=3","vt.global_cursor_default=0"]
pat = re.compile(r"^(%s)(=|$)" % "|".join(re.escape(p.split("=")[0]) for p in params))
path = "/etc/kernel/cmdline"
old = open(path).read()
new = " ".join([t for t in old.split() if not pat.match(t)] + params) + "\n"
if new != old:
    shutil.copy2(path, path + "." + datetime.datetime.now().strftime("%Y-%m-%d@%H:%M:%S~"))
    open(path, "w").write(new)
    os.chmod(path, 0o644)
    print("CHANGED")
else:
    print("UNCHANGED")
PY
```
*Why:* any parameter whose key is in `boot_quiet_params` replaces the existing value
(so a stale `loglevel=7` is not duplicated); every other parameter is preserved.
*Verify:* `cat /etc/kernel/cmdline`

**3.3 Rebuild the UKI — only if 3.2 printed `CHANGED`.**
```bash
mkinitcpio -P
```
*Why:* the cmdline is baked into the unified kernel image at build time; editing the file
alone changes nothing.
*Verify:* `ls -l /boot/EFI/Linux/arch-linux.efi`

**3.4 Quiet GRUB cmdline + clone the theme** (only if `$BOOT_GRUB_PRESENT` is true).
```bash
python3 - <<'PY'
import re, shutil, datetime
params = ["quiet","loglevel=3","systemd.show_status=false","rd.systemd.show_status=false",
          "rd.udev.log_level=3","udev.log_level=3","vt.global_cursor_default=0"]
pat = re.compile(r"^(%s)(=|$)" % "|".join(re.escape(p.split("=")[0]) for p in params))
path = "/etc/default/grub"
text = open(path).read()
m = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text, re.M)
cur = m.group(1) if m else ""
line = 'GRUB_CMDLINE_LINUX_DEFAULT="%s"' % " ".join(
    [t for t in cur.split() if not pat.match(t)] + params)
new = (re.sub(r'^GRUB_CMDLINE_LINUX_DEFAULT=.*$', line, text, flags=re.M)
       if re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT=', text, re.M) else text + line + "\n")
if new != text:
    shutil.copy2(path, path + "." + datetime.datetime.now().strftime("%Y-%m-%d@%H:%M:%S~"))
    open(path, "w").write(new); print("CHANGED")
else:
    print("UNCHANGED")
PY

install -d -o liam -g liam -m 0755 /home/liam/builds
sudo -u liam -H git clone --depth 1 --branch main \
  https://github.com/crocodile13/frieren-grub-theme.git \
  /home/liam/builds/frieren-grub-theme
```
*Why:* GRUB is kept in step with the UKI even though the UKI is what boots. Only the theme
keys and cmdline are touched — upstream's `install.sh` is **not** run, because it rewrites
`GRUB_CMDLINE_LINUX_DEFAULT` with AppArmor flags for an AppArmor that is not installed.
*Verify:* `grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub`

**3.5 Refuse a nearly full ESP.**
```bash
AVAIL=$(df -BM --output=avail /boot 2>/dev/null | tail -1 | tr -dc 0-9)
[ "${AVAIL:-0}" -gt 50 ] && echo "BOOT_SPACE_OK ${AVAIL}M" \
  || echo "STOP: /boot has ${AVAIL}M free, below boot_min_free_boot_mb=50"
```
*Why:* filling the ESP breaks the next kernel upgrade or UKI rebuild.

**3.6 Deploy the theme** (skip if the installed background already matches the source).
```bash
SRC=/home/liam/builds/frieren-grub-theme/frieren-theme
DST=/boot/grub/themes/frieren
test -f "$SRC/background_1080.png" || echo 'STOP: background_1080.png missing upstream'
A=$(sha1sum "$DST/background.png" 2>/dev/null | cut -d' ' -f1)
B=$(sha1sum "$SRC/background_1080.png" | cut -d' ' -f1)
if [ "$A" != "$B" ]; then
  mkdir -p /boot/grub/themes
  rm -rf "$DST"
  cp -r "$SRC" "$DST"
  cp "$DST/theme_1080p.txt"     "$DST/theme.txt"
  cp "$DST/background_1080.png" "$DST/background.png"
fi
```
*Why:* no owner/mode anywhere under `/boot` — vfat cannot represent them, and asking makes
the copy fail. Plain `cp -r` for the same reason.
*Verify:* `ls /boot/grub/themes/frieren/theme.txt /boot/grub/themes/frieren/background.png`

**3.7 Drop the now-redundant resolution variants.**
```bash
find /boot/grub/themes/frieren -maxdepth 1 -type f \
  \( -name 'theme_*.txt' -o -name 'background_*.png' \) -delete
```
*Verify:* `ls /boot/grub/themes/frieren/`

**3.8 Prune fonts `theme.txt` does not name.**
```bash
KEEP=$(grep -oE 'fonts/[-A-Za-z0-9_.]+\.pf2' /boot/grub/themes/frieren/theme.txt \
       | sed 's|fonts/||' | sort -u)
if [ -n "$KEEP" ]; then
  for f in /boot/grub/themes/frieren/fonts/*.pf2; do
    grep -qxF "$(basename "$f")" <<<"$KEEP" || rm -f "$f"
  done
fi
```
*Why:* the theme ships ~13 MB of fonts, several unreferenced, all of them read at every
boot off the ESP. A `theme.txt` this pattern cannot parse leaves every font in place
rather than stripping all of them.
*Verify:* `ls /boot/grub/themes/frieren/fonts/`

**3.9 Install `/etc/grub.d/09_loadfonts`.** See §6 for the rendered content.
```bash
{
  cat <<'HDR'
#!/bin/sh
# Managed by Ansible (roles/boot). Do not edit by hand; rerun the role instead.
# grub-mkconfig runs every executable in /etc/grub.d in order and appends its
# stdout to grub.cfg. GRUB does not load a theme's fonts just because theme.txt
# names them, so without these lines the menu falls back to the default font at
# the default size.
#
# The paths use ${prefix}, not upstream's ($root)/boot/..., because /boot here
# is its own EFI system partition: GRUB's $root is then that partition and the
# /boot component does not exist inside it. ${prefix} is the directory GRUB was
# installed into, so it resolves correctly whether or not /boot is separate.
# The heredoc is quoted so ${prefix} reaches grub.cfg literally and is expanded
# by GRUB at boot rather than by this shell.
cat << 'GRUBEOF'
HDR
  for f in $(ls /boot/grub/themes/frieren/fonts/*.pf2 2>/dev/null | xargs -r -n1 basename | sort); do
    printf 'loadfont ${prefix}/themes/frieren/fonts/%s\n' "$f"
  done
  echo GRUBEOF
} > /tmp/09_loadfonts
install -o root -g root -m 0755 /tmp/09_loadfonts /etc/grub.d/09_loadfonts && rm -f /tmp/09_loadfonts
```
*Why:* regenerated from whatever fonts survived 3.8, so it cannot drift out of step.
*Verify:* `cat /etc/grub.d/09_loadfonts && test -x /etc/grub.d/09_loadfonts && echo LOADFONTS_OK`

**3.10 Point GRUB at the theme.**
```bash
python3 - <<'PY'
import re, shutil, datetime
pairs = [("GRUB_THEME", '"/boot/grub/themes/frieren/theme.txt"'),
         ("GRUB_GFXMODE", "1920x1080"),
         ("GRUB_GFXPAYLOAD_LINUX", "keep"),
         ("GRUB_TERMINAL_OUTPUT", '"gfxterm"'),
         ("GRUB_TIMEOUT_STYLE", "menu")]
path = "/etc/default/grub"
text = orig = open(path).read()
for k, v in pairs:
    line = "%s=%s" % (k, v)
    if re.search(r'^#?%s=' % re.escape(k), text, re.M):
        text = re.sub(r'^#?%s=.*$' % re.escape(k), line, text, count=1, flags=re.M)
    else:
        text += line + "\n"
if text != orig:
    shutil.copy2(path, path + "." + datetime.datetime.now().strftime("%Y-%m-%d@%H:%M:%S~"))
    open(path, "w").write(text); print("CHANGED")
else:
    print("UNCHANGED")
PY
```
*Why:* the regex also matches the commented-out defaults Arch ships. `GRUB_CMDLINE_LINUX_DEFAULT`
and `GRUB_TIMEOUT` are deliberately left alone.
*Verify:* `grep -E '^(GRUB_THEME|GRUB_GFXMODE|GRUB_GFXPAYLOAD_LINUX|GRUB_TERMINAL_OUTPUT|GRUB_TIMEOUT_STYLE)=' /etc/default/grub`

**3.11 Regenerate `grub.cfg` — candidate, syntax-check, install.** Run only if any of
3.4 / 3.6 / 3.9 / 3.10 changed something.
```bash
install -d -o root -g root -m 0700 /var/lib/arch-autodeploy
[ -f /boot/grub/grub.cfg ] && install -o root -g root -m 0600 \
  /boot/grub/grub.cfg /var/lib/arch-autodeploy/grub.cfg.previous
grub-mkconfig -o /boot/grub/grub.cfg.ansible-new
grub-script-check /boot/grub/grub.cfg.ansible-new \
  && cp /boot/grub/grub.cfg.ansible-new /boot/grub/grub.cfg
rm -f /boot/grub/grub.cfg.ansible-new
```
*Why:* a bad generation must never replace a working config. The backup goes to the root
filesystem because vfat rejects the colons in timestamped names and cannot store a mode.
*Verify:* `grub-script-check /boot/grub/grub.cfg && echo GRUBCFG_OK; ls -l /var/lib/arch-autodeploy/grub.cfg.previous`

**3.12 Report.** These changes only take effect at the next boot.

---

### Step 4 — role `docker` (tag: `docker`)

**4.1 Install Docker.**
```bash
pacman -S --needed --noconfirm docker docker-compose docker-buildx
```
*Verify:* `pacman -Q docker docker-compose docker-buildx`

**4.2 Kernel module guard.**
```bash
test -d "/usr/lib/modules/$(uname -r)" \
  && echo DOCKER_KERNEL_OK \
  || echo "STOP: running kernel $(uname -r) has no module tree; reboot and resume at Step 4"
```
*Why:* stops **before** changing any Docker state.

**4.3 nftables control plane guard.**
```bash
nft list ruleset >/dev/null 2>&1 \
  && echo NFT_OK \
  || echo 'STOP: nftables unusable; reboot after a kernel upgrade. Do not disable Docker iptables support.'
```

**4.4 docker group.**
```bash
groupadd -f docker
```
*Verify:* `getent group docker`

**4.5 Add `liam` to docker.**
```bash
usermod -aG docker liam
```
*Security:* docker group members are effectively root. Acceptable on this personal
workstation; drop it on a reused multi-user host.
*Verify:* `id -nG liam | tr ' ' '\n' | grep -qx docker && echo DOCKER_GROUP_OK`

**4.6 Reconnect** (`meta: reset_connection`) — no action; each `sudo -u liam -H` gets fresh
initgroups.

**4.7 Prove the membership is live in `liam`'s session.**
```bash
sudo -u liam -H id -nG | tr ' ' '\n' | grep -qx docker \
  && echo SESSION_DOCKER_OK \
  || echo 'STOP: docker not in the live session. Do not relax the socket permissions.'
```

**4.8 Enable Docker.**
```bash
systemctl enable --now docker.service
```
*Verify:* `systemctl is-enabled docker.service && systemctl is-active docker.service`

**4.9 Docker reachable by `liam` without sudo.**
```bash
sudo -u liam -H env HOME=/home/liam docker info >/dev/null && echo DOCKER_INFO_OK
```

**4.10 hello-world smoke test.**
```bash
sudo -u liam -H env HOME=/home/liam docker run --rm hello-world
```
*Verify:* the container prints "Hello from Docker!".

---

### Step 5 — role `dotfiles` (tag: `dotfiles`)

**5.1 Clone / fast-forward the dotfiles repo as `liam`.**
```bash
if [ -d /home/liam/dotfiles/.git ]; then
  sudo -u liam -H git -C /home/liam/dotfiles pull --ff-only origin main
else
  sudo -u liam -H git clone --branch main \
    https://github.com/fhlkfds/dotfiles.git /home/liam/dotfiles
fi
```
*Why:* `force: false` — local changes are never overwritten.
*Verify:* `sudo -u liam -H git -C /home/liam/dotfiles log --oneline -1`

**5.2 Back up conflicts, then Stow all 22 packages.** Faithful port of the manifest →
conflict-backup → `stow` chain.
```bash
sudo -u liam -H python3 - <<'PY'
import json, os, subprocess, datetime
REPO   = "/home/liam/dotfiles"
HOME   = "/home/liam"
SCRIPT = "/home/liam/Projects/arch-autodepoly/roles/dotfiles/files/stow_manifest.py"
PKGS   = ("ai browser cliphist fastfetch greeter hypr hyprlock kitty menu modes "
          "noctalia quickshell rofi screensaver security swaync systemd wallpaper "
          "windows wofi xdg zsh").split()

plan = json.loads(subprocess.run(
    ["python3", SCRIPT, "--repo", REPO, "--home", HOME, *PKGS],
    capture_output=True, text=True, check=True).stdout)

conflicts = plan["conflicts"]
if conflicts:
    stamp  = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")   # iso8601_basic_short
    backup = f"{HOME}/dotfiles-backup-{stamp}"
    os.makedirs(backup, mode=0o700, exist_ok=True)
    for c in conflicts:
        os.makedirs(os.path.join(backup, os.path.dirname(c["relative"])),
                    mode=0o700, exist_ok=True)
        subprocess.run(["mv", "--", c["target"],
                        os.path.join(backup, c["relative"])], check=True)
    print("conflicts backed up to", backup)
else:
    print("no conflicts")

for p in PKGS:
    subprocess.run(["stow", "--no-folding", "--target", HOME, p], cwd=REPO, check=True)
print("stow complete")
PY
```
*Why:* only targets that do **not** already resolve into `~/dotfiles` are moved aside, into
`~/dotfiles-backup-<timestamp>/` at the same relative path. `--no-folding` makes every
managed file an individually verifiable symlink.
*Verify:* see 5.3.

**5.3 Re-run the manifest and assert nothing is left unresolved.**
```bash
sudo -u liam -H python3 /home/liam/Projects/arch-autodepoly/roles/dotfiles/files/stow_manifest.py \
  --repo /home/liam/dotfiles --home /home/liam \
  ai browser cliphist fastfetch greeter hypr hyprlock kitty menu modes noctalia \
  quickshell rofi screensaver security swaync systemd wallpaper windows wofi xdg zsh \
  | jq -e '.needs_changes | length == 0' >/dev/null \
  && echo STOW_OK \
  || echo 'STOP: unexpected Stow targets remain'
```

---

### Step 6 — role `greeter` (tag: `greeter`)

**6.1 Hide the uwsm-managed Hyprland session entry.**
```bash
[ -e /usr/share/wayland-sessions/hyprland-uwsm.desktop ] && \
  mv -- /usr/share/wayland-sessions/hyprland-uwsm.desktop \
        /usr/share/wayland-sessions/hyprland-uwsm.desktop.disabled
```
*Why:* both `hyprland.desktop` and `hyprland-uwsm.desktop` register the same
`DesktopNames=Hyprland`, which is what makes a greeter default to the uwsm-managed session.
Renamed, not deleted; a `hyprland` upgrade can restore it, so re-check after upgrades.
*Verify:* `ls /usr/share/wayland-sessions/`

**6.2 Render the themed dotfiles (only on a box that has never done it).**
```bash
CUR=$(sudo -u liam -H env HOME=/home/liam /home/liam/.local/bin/theme current 2>/dev/null | tr -d '\n')
if [ ! -e /home/liam/.config/greeter/regreet.toml ]; then
  sudo -u liam -H env HOME=/home/liam /home/liam/.local/bin/theme set "${CUR:-tokyo-night}"
fi
```
*Why:* an existing theme choice always wins; `greeter_theme_slug=tokyo-night` is only the
fresh-box fallback. `regreet.toml` is used purely as the "has a theme ever been rendered"
marker. SDDM does **not** read this theme — `sddm_theme` below is what themes the login screen.
*Verify:* `ls /home/liam/.config/greeter/regreet.toml`

**6.3 Sparse, blobless clone of qylock as `liam`.**
```bash
install -d -o liam -g liam -m 0755 /home/liam/builds
[ -e /home/liam/builds/qylock/.git ] || sudo -u liam -H env HOME=/home/liam \
  git clone --depth 1 --filter=blob:none --sparse --branch main \
  https://github.com/Darkkal44/qylock.git /home/liam/builds/qylock
```
*Why:* a full clone is ~1.1 GB because every theme carries its own video assets. This theme
is ~25 MB. Cloned once, not auto-updated — delete the directory to pick up changes.
*Verify:* `ls -d /home/liam/builds/qylock/.git`

**6.4 Check out only `themes/star-rail`.**
```bash
CURPATHS=$(sudo -u liam -H env HOME=/home/liam \
  git -C /home/liam/builds/qylock sparse-checkout list 2>/dev/null)
[ "$CURPATHS" = "themes/star-rail" ] || sudo -u liam -H env HOME=/home/liam \
  git -C /home/liam/builds/qylock sparse-checkout set themes/star-rail
test -f /home/liam/builds/qylock/themes/star-rail/metadata.desktop \
  && echo THEME_SOURCE_OK \
  || echo 'STOP: no theme at themes/star-rail with a metadata.desktop. SDDM not reconfigured.'
```
*Verify:* `sudo -u liam -H git -C /home/liam/builds/qylock sparse-checkout list`

**6.5 Font report (informational; a missing font is not an error).**
```bash
ls /home/liam/builds/qylock/themes/star-rail/font/*.ttf \
   /home/liam/builds/qylock/themes/star-rail/font/*.otf 2>/dev/null \
  || cat <<'MSG'
The star-rail theme ships no font, which qylock cannot bundle for copyright reasons.
Expected font: DIN Next, saved as font.ttf.
Drop it in /home/liam/builds/qylock/themes/star-rail/font/ and rerun this step for the intended look.
The login screen works without it, using a fallback font.
MSG
```

**6.6 Install the theme system-wide.**
```bash
install -d -o root -g root -m 0755 /usr/share/sddm/themes
mkdir -p /usr/share/sddm/themes/star-rail
cp -r /home/liam/builds/qylock/themes/star-rail/. /usr/share/sddm/themes/star-rail/
chown -R root:root /usr/share/sddm/themes/star-rail
find /usr/share/sddm/themes/star-rail -type d -exec chmod 0755 {} +
find /usr/share/sddm/themes/star-rail -type f -exec chmod 0644 {} +
```
*Why:* `sddm_theme` may be a nested variant (`clockwork/orbital`); upstream installs those
under just the basename, hence `star-rail`. The trailing-slash copy puts contents at
`themes/star-rail/`, not `themes/star-rail/star-rail/`.
*Verify:* `ls /usr/share/sddm/themes/star-rail/metadata.desktop`

**6.7 Write `/etc/sddm.conf.d/theme.conf`.** Rendered content in §6.
```bash
install -d -o root -g root -m 0755 /etc/sddm.conf.d
cat > /etc/sddm.conf.d/theme.conf <<'EOF'
# Managed by Ansible (roles/greeter). Local edits are overwritten on the next
# run. This is the same path qylock's own sddm.sh writes, so running that
# script by hand replaces this file rather than silently shadowing it.
[Theme]
Current=star-rail

[General]
DisplayServer=wayland
EOF
chown root:root /etc/sddm.conf.d/theme.conf && chmod 0644 /etc/sddm.conf.d/theme.conf
```
*Verify:* `cat /etc/sddm.conf.d/theme.conf`

**6.8 Read the current display-manager state (before enabling/disabling anything).**
```bash
DM_RUNNING=false
for u in greetd.service sddm.service; do
  systemctl is-active --quiet "$u" && DM_RUNNING=true
done
echo "greeter_dm_running=$DM_RUNNING"
```

**6.9 Disable greetd, if its unit exists.**
```bash
systemctl list-unit-files greetd.service >/dev/null 2>&1 \
  && systemctl cat greetd.service >/dev/null 2>&1 \
  && systemctl disable greetd.service
```
*Why:* greetd must give up the `display-manager.service` alias first; `systemctl enable sddm`
fails outright while greetd still owns it. greetd is deliberately **not stopped** — stopping
a running display manager kills the session on its VT.

**6.10 Enable SDDM.**
```bash
systemctl enable sddm.service
```
*Verify:* `systemctl is-enabled sddm.service; readlink -f /etc/systemd/system/display-manager.service`

**6.11 Start SDDM only if nothing is already driving a VT.**
```bash
if [ "$DM_RUNNING" = false ]; then
  systemctl start sddm.service
else
  echo 'A display manager was already running; SDDM is enabled but not started.'
  echo 'Reboot to land on the star-rail login screen. greetd is disabled and will not come back.'
fi
```
*Verify:* `systemctl is-active sddm.service`

---

### Step 7 — role `ssh` (play 2, tag: `ssh`)

**7.1 Connection assert.** Local connection ⇒ passes trivially. No action.

**7.2 `.ssh` directory.**
```bash
install -d -o liam -g liam -m 0700 /home/liam/.ssh
```
*Verify:* `ls -ld /home/liam/.ssh`

**7.3 Install the administrative public key.** `no_log` task — do not echo secrets.
```bash
# <SSH_PUBLIC_KEY> = the ssh-ed25519 line from P4
sudo -u liam -H sh -c 'umask 077; printf "%s\n" "<SSH_PUBLIC_KEY>" >> /home/liam/.ssh/authorized_keys'
```
*Why:* `exclusive: false`, `manage_dir: false` — the key is appended, existing keys survive.
Skip this only if `authorized_keys` already holds a valid key.
*Verify:* `wc -l /home/liam/.ssh/authorized_keys`

**7.4 Ensure the file exists even with no key supplied.**
```bash
[ -e /home/liam/.ssh/authorized_keys ] || \
  install -o liam -g liam -m 0600 /dev/null /home/liam/.ssh/authorized_keys
```

**7.5 Enforce ownership and mode.**
```bash
chown liam:liam /home/liam/.ssh/authorized_keys
chmod 0600 /home/liam/.ssh/authorized_keys
```
*Verify:* `ls -l /home/liam/.ssh/authorized_keys`

**7.6 Refuse to disable password auth without a usable key.**
```bash
ssh-keygen -l -f /home/liam/.ssh/authorized_keys >/dev/null 2>&1 \
  && echo AUTHKEY_OK \
  || echo 'STOP: authorized_keys has no recognized SSH public key. Supply one before continuing.'
```

**7.7 Start sshd before the preflight check.**
```bash
systemctl enable --now sshd.service
```
*Verify:* `systemctl is-active sshd.service`

**7.8 Discover the effective SSH port.**
```bash
SSH_PORT=$(sshd -T | awk 'tolower($1)=="port"{print $2; exit}')
echo "effective_ssh_port=$SSH_PORT"   # 22 on stock Arch — carry this to Steps 9, 10, 13
```

**7.9 Preflight: fresh, non-multiplexed key auth as `liam` (F1).**
```bash
sudo -u liam -H ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" liam@127.0.0.1 id
```
*Why:* the controller-side check, which on this box is loopback. It must pass **before**
password authentication is turned off. `ssh_validation_identity_file` is empty, so default
keys / the agent are used.

**7.10 Ensure sshd reads the drop-in directory (notifies the restart handler).**
```bash
grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config || {
  cp /etc/ssh/sshd_config /tmp/sshd_config.candidate
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /tmp/sshd_config.candidate
  /usr/bin/sshd -t -f /tmp/sshd_config.candidate \
    && cp /tmp/sshd_config.candidate /etc/ssh/sshd_config
  rm -f /tmp/sshd_config.candidate
}
```
*Why:* `insertbefore: BOF` with `validate: sshd -t -f %s`. sshd is first-value-wins, so the
Include must come first.
*Verify:* `head -1 /etc/ssh/sshd_config`

**7.11 Install the hardening drop-in (notifies the restart handler).** Rendered content in §6.
```bash
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /tmp/99-ansible-hardening.conf <<'EOF'
# Managed by Ansible. Local overrides must be reviewed against sshd's
# first-value-wins rule before this file is changed.
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
/usr/bin/sshd -t -f /tmp/99-ansible-hardening.conf \
  && install -o root -g root -m 0600 /tmp/99-ansible-hardening.conf \
       /etc/ssh/sshd_config.d/99-ansible-hardening.conf
rm -f /tmp/99-ansible-hardening.conf
```
*Verify:* `cat /etc/ssh/sshd_config.d/99-ansible-hardening.conf; ls -l /etc/ssh/sshd_config.d/`

**7.12 Validate the complete configuration.**
```bash
sshd -t && echo SSHD_SYNTAX_OK
```

**7.13 → HANDLER FLUSH (`meta: flush_handlers`).** This is where the playbook restarts sshd.
```bash
systemctl restart sshd.service
```
*Why:* a restart leaves established sessions intact; never `stop` sshd here.
*Verify:* `systemctl is-active sshd.service`

**7.14 Wait for the port.**
```bash
for i in $(seq 1 30); do
  (exec 3<>/dev/tcp/127.0.0.1/"$SSH_PORT") 2>/dev/null && { echo PORT_OPEN; break; }
  sleep 1
done
```

**7.15 Post-restart key auth (F1).**
```bash
sudo -u liam -H ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" liam@127.0.0.1 id
```

**7.16 Assert the effective policy.**
```bash
sshd -T | tr 'A-Z' 'a-z' | grep -E \
 '^(permitrootlogin no|passwordauthentication no|pubkeyauthentication yes|kbdinteractiveauthentication no|maxauthtries 3|x11forwarding no|allowagentforwarding no|clientaliveinterval 300|clientalivecountmax 2)$' \
 | sort | tee /tmp/ssh-effective
[ "$(wc -l < /tmp/ssh-effective)" -eq 9 ] && echo SSH_HARDENED_OK || echo 'STOP: hardening incomplete'
```

---

### Step 8 — Play 3 pre_task assert (tag: `fail2ban`)

```bash
ADMIN_IPS="10.2.1.0/24 192.168.1.1 127.0.0.1 192.168.1.0/24"
BAD=0
for ip in $ADMIN_IPS; do
  echo "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' || BAD=1
done
[ -n "$ADMIN_IPS" ] && [ "$BAD" -eq 0 ] \
  && echo ADMIN_IPS_OK \
  || echo 'STOP: every admin_ips entry must be a bare IPv4 address or address/prefix. No UFW or fail2ban changes made.'
```
*Why:* the firewall play refuses to start without a validated whitelist. Gate, no state change.

---

### Step 9 — role `ufw` (tag: `ufw`)

**9.1 Require the discovered port.**
```bash
[ "${SSH_PORT:-0}" -gt 0 ] && [ "$SSH_PORT" -lt 65536 ] \
  && echo "SSH_PORT_OK $SSH_PORT" \
  || echo 'STOP: run Step 7 before Step 9 so the real SSH port is known.'
```

**9.2 Install UFW.**
```bash
pacman -S --needed --noconfirm ufw
```
*Verify:* `pacman -Q ufw`

**9.3 Rate-limit SSH.**
```bash
ufw limit "$SSH_PORT"/tcp comment 'Rate-limited SSH'
```
*Why:* added even though `ssh_enabled` is false, because Steps 9 and 11 both open a fresh
SSH connection to prove the firewall did not lock the host out. Step 13 removes it again.
*Verify:* `ufw status | grep "$SSH_PORT"`

**9.4 LAN rules.** `ufw_lan_rules` is `[]` — nothing to do. Then LocalSend:
```bash
for r in 10.2.1.0/24 192.168.1.0/24; do
  for p in tcp udp; do
    ufw allow from "$r" to any port 53317 proto "$p" comment 'LocalSend LAN'
  done
done
```
*Why:* TCP carries transfers, UDP carries multicast discovery — with UDP closed, every peer
must be added by IP by hand. Scoped to LAN ranges because LocalSend authenticates nothing
beyond an in-app prompt.
*Verify:* `ufw status | grep 53317`

**9.5 Default policies.**
```bash
ufw default deny incoming
ufw default allow outgoing
```
*Verify:* `ufw status verbose | grep Default`

**9.6 Enable UFW.**
```bash
ufw --force enable
systemctl enable --now ufw.service
```
*Verify:* `ufw status verbose; systemctl is-enabled ufw.service`

**9.7 Assert.**
```bash
ufw status verbose > /tmp/ufw.out
grep -q 'Status: active' /tmp/ufw.out \
  && grep -q "$SSH_PORT" /tmp/ufw.out \
  && grep -q '53317' /tmp/ufw.out \
  && echo UFW_OK \
  || { echo 'STOP: UFW inactive or missing the SSH/LocalSend port:'; cat /tmp/ufw.out; }
```

**9.8 Fresh key auth after the firewall came up (F1).**
```bash
sudo -u liam -H ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" liam@127.0.0.1 id
```
*Why:* proves the firewall did not lock the host out.

---

### Step 10 — role `fail2ban` (tag: `fail2ban`)

**10.1 Whitelist assert.** Same check as Step 8. Repeat it here.

**10.2 Install fail2ban.**
```bash
pacman -S --needed --noconfirm fail2ban
```
*Verify:* `pacman -Q fail2ban`

**10.3 Write `/etc/fail2ban/jail.local`** (notifies the restart handler). Rendered in §6.
```bash
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
banaction = nftables-multiport
ignoreip = 127.0.0.1/8 ::1 10.2.1.0/24 192.168.1.1 127.0.0.1 192.168.1.0/24

[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
EOF
chown root:root /etc/fail2ban/jail.local && chmod 0644 /etc/fail2ban/jail.local
```
*Verify:* `cat /etc/fail2ban/jail.local`

**10.4 Validate before touching the service.**
```bash
fail2ban-client -t && echo F2B_SYNTAX_OK
```

**10.5 Enable and start.**
```bash
systemctl enable --now fail2ban.service
```
*Verify:* `systemctl is-enabled fail2ban.service && systemctl is-active fail2ban.service`

**10.6 → HANDLER FLUSH (`meta: flush_handlers`).**
```bash
systemctl restart fail2ban.service
```

**10.7 Assert the jail.**
```bash
fail2ban-client status sshd | grep -q 'Status for the jail: sshd' \
  && echo F2B_JAIL_OK || echo 'STOP: sshd jail not active'
```

---

### Step 11 — role `verification` (play 4, tag: `verification`)

Read-only. Every check must pass before Steps 12–13.

```bash
id liam
visudo -cf /etc/sudoers
cat /etc/sudoers.d/liam
doas -C /etc/doas.conf; echo "rc=$?"
cat /etc/doas.conf
yay --version

pacman -Q base-devel git stow sudo zsh curl openssh hyprland hyprpaper hypridle \
  hyprlock hyprsunset hyprpolkitagent kitty rofi quickshell wl-clipboard cliphist \
  libnotify python jq playerctl udiskie pipewire wireplumber networkmanager \
  networkmanager-openvpn openvpn tailscale bluez-utils iputils polkit nautilus \
  gnome-disk-utility spotify-launcher obsidian virt-manager libvirt qemu-full dnsmasq \
  btop imv mpv zathura zathura-pdf-mupdf neovim grim slurp hyprpicker \
  gpu-screen-recorder sddm weston qt6-declarative qt6-5compat qt6-svg qt6-multimedia \
  qt6-multimedia-ffmpeg gst-plugins-base gst-plugins-good gst-plugins-bad \
  gst-plugins-ugly satty ffmpeg imagemagick tesseract tesseract-data-eng v4l-utils \
  ddcutil pam-u2f libfido2 gnupg rust musl rust-musl socat freerdp yt-dlp libheif file \
  libqalculate papirus-icon-theme ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji \
  eza zsh-syntax-highlighting zsh-autosuggestions fzf fastfetch cava wofi swaync \
  pacman-contrib opendoas power-profiles-daemon brightnessctl zbar translate-shell \
  python-gobject xdg-desktop-portal xdg-desktop-portal-hyprland wtype gifski \
  xdg-user-dirs vulkan-tools mesa-utils opencode \
  brave-bin claude-code helium-browser-bin hermes-agent-desktop hyprvoice-bin \
  localsend-bin looking-glass mpvpaper pokemon-colorscripts-git t3code-bin \
  wl-screenrec-git xdg-terminal-exec \
  docker docker-compose docker-buildx ufw fail2ban

pacman -Qi base-devel
sudo -u liam -H env HOME=/home/liam docker info
sudo -u liam -H env HOME=/home/liam docker run --rm hello-world
sshd -t; echo "rc=$?"
sshd -T
```

Re-derive the port and run the final loopback check (F1):
```bash
SSH_PORT=$(sshd -T | awk 'tolower($1)=="port"{print $2; exit}')
sudo -u liam -H ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" liam@127.0.0.1 id

ufw status verbose
fail2ban-client status sshd
fail2ban-client get sshd actions
fail2ban-client get sshd ignoreip
```

Stow key links:
```bash
for pair in \
 "/home/liam/.zshrc|/home/liam/dotfiles/zsh/.zshrc" \
 "/home/liam/.config/hypr/hyprland.lua|/home/liam/dotfiles/hypr/.config/hypr/hyprland.lua" \
 "/home/liam/.config/quickshell/shell.qml|/home/liam/dotfiles/quickshell/.config/quickshell/shell.qml" \
 "/home/liam/.config/kitty/kitty.conf|/home/liam/dotfiles/kitty/.config/kitty/kitty.conf" \
 "/home/liam/.local/bin/desktop-mode|/home/liam/dotfiles/modes/.local/bin/desktop-mode" \
 "/home/liam/.local/bin/ascii-screensaver|/home/liam/dotfiles/screensaver/.local/bin/ascii-screensaver" \
 "/home/liam/.config/systemd/user/hypr-monitor-watch.service|/home/liam/dotfiles/systemd/.config/systemd/user/hypr-monitor-watch.service" ; do
  t=${pair%%|*}; s=${pair##*|}
  r=$(readlink -f "$t" 2>/dev/null)
  [ "$r" = "$s" ] && echo "ok  $t" || echo "BAD Stow link: $t -> ${r:-<missing>}"
done
```

Final assert set (all must hold):
```bash
id liam | grep -q '(wheel)'                                        && echo ok wheel
id liam | grep -q '(docker)'                                       && echo ok docker
[ "$(cat /etc/sudoers.d/liam)" = 'liam ALL=(ALL:ALL) ALL' ]        && echo ok sudoers
[ "$(cat /etc/doas.conf)" = 'permit persist liam as root' ]        && echo ok doas
ufw status verbose | grep -q 'Status: active'                      && echo ok ufw-active
ufw status verbose | grep -q "$SSH_PORT"                           && echo ok ufw-ssh-port
fail2ban-client status sshd | grep -q 'Status for the jail: sshd'  && echo ok f2b-jail
fail2ban-client get sshd actions | grep -q 'nftables-multiport'    && echo ok f2b-action
for ip in 10.2.1.0/24 192.168.1.1 127.0.0.1 192.168.1.0/24; do
  fail2ban-client get sshd ignoreip | grep -q -- "$ip" || echo "MISSING ignoreip $ip"
done
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'permitrootlogin no'           && echo ok rootlogin
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'passwordauthentication no'    && echo ok passwordauth
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'pubkeyauthentication yes'     && echo ok pubkey
```

---

### Step 12 — Set the administrative password (post_task; tags: `users`, `password`)

`no_log` task. Run this **only after Step 11 passes**.

```bash
usermod -p '<PASSWORD_HASH>' liam
```
*Why:* deliberately the second-to-last action. Rewriting `/etc/shadow` invalidates the sudo
password Ansible is using; anywhere earlier and every later privilege escalation fails,
leaving a half-provisioned host. Skip entirely if `admin_password_hash` is empty.
*Verify:* `getent shadow liam | cut -d: -f2 | cut -c1-4`  (should show the hash prefix, e.g. `$y$j`)

---

### Step 13 — SSH teardown (post_tasks; tags: `ssh`, `ssh_teardown`)

Runs because `ssh_enabled: false`. **This closes the port you may be connected over.**
Have console access.

**13.1 Check whether UFW still allows the port.**
```bash
ufw status > /tmp/ufw-teardown.out; echo "rc=$?"
```

**13.2 Delete the rule, only if it is actually present.**
```bash
grep -q "$SSH_PORT" /tmp/ufw-teardown.out \
  && ufw delete limit "$SSH_PORT"/tcp \
  || echo 'rule not present; leaving UFW alone'
```
*Verify:* `ufw status | grep -c "$SSH_PORT"` → `0`

**13.3 Stop and disable sshd.**
```bash
systemctl disable --now sshd.service
```
*Why:* Arch's `sshd.service` sets `KillMode=process`, so an established session survives the
stop. There is no `sshd.socket` on this host, so disabling the service is enough.
*Verify:* `systemctl is-enabled sshd.service; systemctl is-active sshd.service; ss -ltnp | grep -c ":$SSH_PORT " ` → `disabled`, `inactive`, `0`

---

## 6. Rendered templates

Four Jinja2 templates, rendered with the effective values from §3.

### `/etc/ssh/sshd_config.d/99-ansible-hardening.conf` — root:root 0600
Source `roles/ssh/templates/99-ansible-hardening.conf.j2`; `ssh_allow_agent_forwarding: false`.

```
# Managed by Ansible. Local overrides must be reviewed against sshd's
# first-value-wins rule before this file is changed.
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

### `/etc/fail2ban/jail.local` — root:root 0644
Source `roles/fail2ban/templates/jail.local.j2`; `effective_ssh_port` shown as `22` (stock Arch).

```
[DEFAULT]
banaction = nftables-multiport
ignoreip = 127.0.0.1/8 ::1 10.2.1.0/24 192.168.1.1 127.0.0.1 192.168.1.0/24

[sshd]
enabled = true
port = 22
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
```

### `/etc/sddm.conf.d/theme.conf` — root:root 0644
Source `roles/greeter/templates/sddm-qylock.conf.j2`. `sddm_wayland_compositor_command` is
empty, so the `[Wayland]` block is **not** rendered.

```
# Managed by Ansible (roles/greeter). Local edits are overwritten on the next
# run. This is the same path qylock's own sddm.sh writes, so running that
# script by hand replaces this file rather than silently shadowing it.
[Theme]
Current=star-rail

[General]
DisplayServer=wayland
```

### `/etc/grub.d/09_loadfonts` — root:root 0755
Source `roles/boot/templates/09_loadfonts.j2`. The `loadfont` lines are **derived at run
time** from the `.pf2` files surviving Step 3.8, sorted by basename — so the exact list
depends on what upstream's `theme_1080p.txt` references. Header is fixed:

```sh
#!/bin/sh
# Managed by Ansible (roles/boot). Do not edit by hand; rerun the role instead.
# grub-mkconfig runs every executable in /etc/grub.d in order and appends its
# stdout to grub.cfg. GRUB does not load a theme's fonts just because theme.txt
# names them, so without these lines the menu falls back to the default font at
# the default size.
#
# The paths use ${prefix}, not upstream's ($root)/boot/..., because /boot here
# is its own EFI system partition: GRUB's $root is then that partition and the
# /boot component does not exist inside it. ${prefix} is the directory GRUB was
# installed into, so it resolves correctly whether or not /boot is separate.
# The heredoc is quoted so ${prefix} reaches grub.cfg literally and is expanded
# by GRUB at boot rather than by this shell.
cat << 'GRUBEOF'
loadfont ${prefix}/themes/frieren/fonts/<FONT_1>.pf2
loadfont ${prefix}/themes/frieren/fonts/<FONT_2>.pf2
GRUBEOF
```

Confirm the real list after Step 3.9 with:
```bash
grep -oE 'fonts/[-A-Za-z0-9_.]+\.pf2' /boot/grub/themes/frieren/theme.txt | sort -u
```

### Non-template managed files (`copy` with literal content)

| Path | Owner/mode | Content | Validator |
|---|---|---|---|
| `/etc/sudoers.d/liam` | root:root 0440 | `liam ALL=(ALL:ALL) ALL` | `/usr/sbin/visudo -cf %s` |
| `/etc/doas.conf` | root:root 0440 | `permit persist liam as root` | `/usr/bin/doas -C %s` |
| `/etc/sudoers.d/liam-makepkg` | root:root 0440 | `liam ALL=(root) NOPASSWD: /usr/bin/pacman` | `visudo -cf` — **removed unconditionally** |
| `/etc/sudoers.d/liam-yay` | root:root 0440 | `liam ALL=(root) NOPASSWD: /usr/bin/pacman` | `visudo -cf` — **removed unconditionally** |

---

## 7. Verification checklist — final end state

Run all of it; every line should print an `ok`.

```bash
SSH_PORT=$(grep -E '^port ' <(sshd -T 2>/dev/null) | awk '{print $2}'); SSH_PORT=${SSH_PORT:-22}

# users
id liam | grep -q '(wheel)'   && echo 'ok  users: wheel'
id liam | grep -q '(libvirt)' && echo 'ok  users: libvirt'
id liam | grep -q '(docker)'  && echo 'ok  users: docker'
[ "$(getent passwd liam | cut -d: -f7)" = /usr/bin/zsh ] && echo 'ok  users: shell'
[ "$(cat /etc/sudoers.d/liam)" = 'liam ALL=(ALL:ALL) ALL' ] && echo 'ok  users: sudoers'
[ "$(stat -c %a /etc/sudoers.d/liam)" = 440 ] && echo 'ok  users: sudoers mode'
[ "$(cat /etc/doas.conf)" = 'permit persist liam as root' ] && echo 'ok  users: doas'
! ls /etc/sudoers.d/liam-makepkg /etc/sudoers.d/liam-yay >/dev/null 2>&1 && echo 'ok  users: no temp grants'

# packages
pacman -Q ufw fail2ban docker docker-compose docker-buildx >/dev/null && echo 'ok  packages: core'
yay --version >/dev/null && echo 'ok  packages: yay'
file /home/liam/.local/bin/ttfx | grep -Eq 'statically linked|static-pie linked' && echo 'ok  packages: ttfx static'
readlink -f /home/liam/.local/bin/wallhaven-dl | grep -q wallhaven-tools/wallhaven-dl && echo 'ok  packages: wallhaven-dl link'
ls -d /home/liam/.oh-my-zsh/custom/themes/powerlevel10k /home/liam/.oh-my-zsh/custom/plugins/fzf-tab >/dev/null && echo 'ok  packages: zsh framework'
[ -f /home/liam/.config/user-dirs.dirs ] && echo 'ok  packages: xdg user dirs'
systemctl is-active --quiet libvirtd.service  && echo 'ok  packages: libvirtd'
[ "$(sudo -u liam -H virsh -c qemu:///system uri)" = 'qemu:///system' ] && echo 'ok  packages: qemu:///system'
systemctl is-active --quiet tailscaled.service && echo 'ok  packages: tailscaled (not enrolled)'
[ -d "/usr/lib/modules/$(uname -r)" ] && echo 'ok  packages: kernel module tree'

# boot  (skip lines that do not apply — see F5)
grep -q 'vt.global_cursor_default=0' /etc/kernel/cmdline 2>/dev/null && echo 'ok  boot: UKI cmdline'
grep -q 'vt.global_cursor_default=0' /etc/default/grub  2>/dev/null && echo 'ok  boot: GRUB cmdline'
[ -f /boot/grub/themes/frieren/theme.txt ] && echo 'ok  boot: frieren theme'
grep -q '^GRUB_THEME="/boot/grub/themes/frieren/theme.txt"' /etc/default/grub 2>/dev/null && echo 'ok  boot: GRUB_THEME'
[ -x /etc/grub.d/09_loadfonts ] && echo 'ok  boot: 09_loadfonts'
[ -f /var/lib/arch-autodeploy/grub.cfg.previous ] && echo 'ok  boot: grub.cfg backup'

# docker
systemctl is-enabled --quiet docker.service && systemctl is-active --quiet docker.service && echo 'ok  docker: service'
sudo -u liam -H env HOME=/home/liam docker info >/dev/null 2>&1 && echo 'ok  docker: rootless-group access'
sudo -u liam -H env HOME=/home/liam docker run --rm hello-world >/dev/null 2>&1 && echo 'ok  docker: hello-world'

# dotfiles
sudo -u liam -H python3 /home/liam/Projects/arch-autodepoly/roles/dotfiles/files/stow_manifest.py \
  --repo /home/liam/dotfiles --home /home/liam \
  ai browser cliphist fastfetch greeter hypr hyprlock kitty menu modes noctalia \
  quickshell rofi screensaver security swaync systemd wallpaper windows wofi xdg zsh \
  | jq -e '.needs_changes | length == 0' >/dev/null && echo 'ok  dotfiles: manifest clean'
[ "$(readlink -f /home/liam/.zshrc)" = /home/liam/dotfiles/zsh/.zshrc ] && echo 'ok  dotfiles: .zshrc'
[ "$(readlink -f /home/liam/.config/hypr/hyprland.lua)" = /home/liam/dotfiles/hypr/.config/hypr/hyprland.lua ] && echo 'ok  dotfiles: hyprland.lua'
[ "$(readlink -f /home/liam/.config/quickshell/shell.qml)" = /home/liam/dotfiles/quickshell/.config/quickshell/shell.qml ] && echo 'ok  dotfiles: shell.qml'
[ "$(readlink -f /home/liam/.config/kitty/kitty.conf)" = /home/liam/dotfiles/kitty/.config/kitty/kitty.conf ] && echo 'ok  dotfiles: kitty.conf'
[ "$(readlink -f /home/liam/.local/bin/desktop-mode)" = /home/liam/dotfiles/modes/.local/bin/desktop-mode ] && echo 'ok  dotfiles: desktop-mode'
[ "$(readlink -f /home/liam/.local/bin/ascii-screensaver)" = /home/liam/dotfiles/screensaver/.local/bin/ascii-screensaver ] && echo 'ok  dotfiles: ascii-screensaver'
[ "$(readlink -f /home/liam/.config/systemd/user/hypr-monitor-watch.service)" = /home/liam/dotfiles/systemd/.config/systemd/user/hypr-monitor-watch.service ] && echo 'ok  dotfiles: hypr-monitor-watch'

# greeter
[ ! -e /usr/share/wayland-sessions/hyprland-uwsm.desktop ] && echo 'ok  greeter: uwsm session hidden'
[ -f /usr/share/sddm/themes/star-rail/metadata.desktop ] && echo 'ok  greeter: star-rail installed'
grep -q '^Current=star-rail' /etc/sddm.conf.d/theme.conf && echo 'ok  greeter: theme.conf Current'
grep -q '^DisplayServer=wayland' /etc/sddm.conf.d/theme.conf && echo 'ok  greeter: theme.conf DisplayServer'
! grep -q '^\[Wayland\]' /etc/sddm.conf.d/theme.conf && echo 'ok  greeter: no compositor override'
systemctl is-enabled --quiet sddm.service && echo 'ok  greeter: sddm enabled'
[ -f /home/liam/.config/greeter/regreet.toml ] && echo 'ok  greeter: theme rendered'

# ssh  (config persists; the service is intentionally down)
sshd -t && echo 'ok  ssh: syntax'
head -1 /etc/ssh/sshd_config | grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' && echo 'ok  ssh: Include first'
[ "$(stat -c %a /etc/ssh/sshd_config.d/99-ansible-hardening.conf)" = 600 ] && echo 'ok  ssh: drop-in mode'
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'permitrootlogin no'        && echo 'ok  ssh: PermitRootLogin no'
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'passwordauthentication no' && echo 'ok  ssh: PasswordAuthentication no'
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'pubkeyauthentication yes'  && echo 'ok  ssh: PubkeyAuthentication yes'
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'maxauthtries 3'            && echo 'ok  ssh: MaxAuthTries 3'
sshd -T | tr 'A-Z' 'a-z' | grep -qx 'allowagentforwarding no'   && echo 'ok  ssh: AllowAgentForwarding no'
[ "$(systemctl is-enabled sshd.service)" = disabled ] && echo 'ok  ssh: disabled (ssh_enabled=false)'
! systemctl is-active --quiet sshd.service && echo 'ok  ssh: stopped'
[ "$(ss -ltn | grep -c ":$SSH_PORT ")" = 0 ] && echo 'ok  ssh: nothing listening'

# ufw
systemctl is-enabled --quiet ufw.service && echo 'ok  ufw: enabled'
ufw status verbose | grep -q 'Status: active' && echo 'ok  ufw: active'
ufw status verbose | grep -q 'deny (incoming)' && echo 'ok  ufw: default deny in'
ufw status verbose | grep -q 'allow (outgoing)' && echo 'ok  ufw: default allow out'
[ "$(ufw status | grep -c 53317)" -ge 4 ] && echo 'ok  ufw: LocalSend tcp+udp on both ranges'
[ "$(ufw status | grep -c "$SSH_PORT/tcp")" = 0 ] && echo 'ok  ufw: SSH rule removed (teardown)'

# fail2ban
systemctl is-enabled --quiet fail2ban.service && systemctl is-active --quiet fail2ban.service && echo 'ok  fail2ban: service'
fail2ban-client status sshd | grep -q 'Status for the jail: sshd' && echo 'ok  fail2ban: sshd jail'
fail2ban-client get sshd actions | grep -q nftables-multiport && echo 'ok  fail2ban: nftables action'
for ip in 10.2.1.0/24 192.168.1.1 127.0.0.1 192.168.1.0/24; do
  fail2ban-client get sshd ignoreip | grep -q -- "$ip" && echo "ok  fail2ban: ignoreip $ip"
done

# password
getent shadow liam | cut -d: -f2 | grep -q '^\$' && echo 'ok  password: hash set'
```

**Enabled units in the finished state, and only these:** `docker.service`, `sddm.service`,
`ufw.service`, `fail2ban.service`, `libvirtd.service`, `tailscaled.service`.
`sshd.service` is deliberately **not** among them.

**Deliberately left undone by the playbook** — do these by hand if you want them:
`sudo tailscale up` (tailnet enrolment); YubiKey/PAM U2F enrolment; the repo's
`system/pam.d` examples; Spotify/browser/AI-agent/VPN/Windows-VM authentication;
machine-specific monitor profiles; the GAM directory `.zshrc` references; activating the
Stowed user systemd units. `codex` has no official/AUR package, so the `ai` launcher will
report it missing.

---

## 8. Rollback

Reverse order of Step numbers. Each block undoes exactly one state-changing step.

**Step 13 — restore SSH**
```bash
systemctl enable --now sshd.service
ufw limit 22/tcp comment 'Rate-limited SSH'
```

**Step 12 — password**
```bash
passwd liam        # set it by hand at the console
```

**Step 10 — fail2ban**
```bash
systemctl disable --now fail2ban.service
rm -f /etc/fail2ban/jail.local
pacman -Rns fail2ban            # only if you also want the package gone
```

**Step 9 — UFW**
```bash
ufw disable                     # fastest recovery from a firewall mistake
ufw delete allow from 10.2.1.0/24 to any port 53317 proto tcp
ufw delete allow from 10.2.1.0/24 to any port 53317 proto udp
ufw delete allow from 192.168.1.0/24 to any port 53317 proto tcp
ufw delete allow from 192.168.1.0/24 to any port 53317 proto udp
ufw delete limit 22/tcp
systemctl disable --now ufw.service
```

**Step 7 — SSH hardening** (from a root console; never `stop` sshd)
```bash
rm -f /etc/ssh/sshd_config.d/99-ansible-hardening.conf
sed -i '\|^Include /etc/ssh/sshd_config.d/\*\.conf$|d' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd.service
```

**Step 6 — greeter / back to greetd**
```bash
systemctl disable sddm.service
systemctl enable greetd.service        # only if greetd is still installed
rm -f /etc/sddm.conf.d/theme.conf
rm -rf /usr/share/sddm/themes/star-rail
mv -- /usr/share/wayland-sessions/hyprland-uwsm.desktop.disabled \
      /usr/share/wayland-sessions/hyprland-uwsm.desktop
rm -rf /home/liam/builds/qylock
# then reboot
```

**Step 5 — dotfiles**
```bash
# Unstow one package, then restore its backed-up originals:
sudo -u liam -H sh -c 'cd /home/liam/dotfiles && stow -D --target /home/liam PACKAGE'
ls -d /home/liam/dotfiles-backup-*
mv /home/liam/dotfiles-backup-<TIMESTAMP>/<RELATIVE_PATH> /home/liam/<RELATIVE_PATH>
```
Order matters: `stow -D` first, then move the backup back.

**Step 4 — Docker**
```bash
systemctl disable --now docker.service
gpasswd -d liam docker           # then log out all liam sessions
pacman -Rns docker docker-compose docker-buildx
```

**Step 3 — boot**
```bash
# UKI cmdline: restore the timestamped backup, then rebuild
ls /etc/kernel/cmdline.*
cp /etc/kernel/cmdline.<BACKUP> /etc/kernel/cmdline && mkinitcpio -P
# GRUB defaults: restore the timestamped backup
ls /etc/default/grub.*
cp /etc/default/grub.<BACKUP> /etc/default/grub
# GRUB theme
rm -f /etc/grub.d/09_loadfonts
rm -rf /boot/grub/themes/frieren
rm -rf /home/liam/builds/frieren-grub-theme
# grub.cfg: restore the saved copy, or just regenerate
cp /var/lib/arch-autodeploy/grub.cfg.previous /boot/grub/grub.cfg
# or: grub-mkconfig -o /boot/grub/grub.cfg
```
If a quiet boot hides a failure you need to see, edit the cmdline from the bootloader for
one boot instead of rolling the whole role back.

**Step 2 — packages**
```bash
rm -f /etc/doas.conf                       # interactive `sudo` (aliased to doas) breaks again
rm -f /etc/sudoers.d/liam-makepkg /etc/sudoers.d/liam-yay
systemctl disable --now tailscaled.service
systemctl disable --now libvirtd.service
gpasswd -d liam libvirt
rm -f /home/liam/.local/bin/wallhaven-dl
rm -f /home/liam/.local/bin/ttfx
rm -rf /home/liam/.oh-my-zsh
rm -rf /home/liam/builds/yay
pacman -Rns yay
# Package removal: pacman -Rns <names>. There is no safe bulk undo for a full -Syu.
```

**Step 1 — users**
```bash
rm -f /etc/sudoers.d/liam
gpasswd -d liam GROUP                      # per unwanted supplementary group
# Do NOT remove liam from wheel until another sudo path is tested.
userdel -r liam                            # destroys /home/liam; last resort
```

**Step 0 — Python bootstrap**
Nothing to reverse; `python` is an official package the packages role installs anyway.
