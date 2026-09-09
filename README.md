# Arch workstation provisioning

This playbook provisions one Arch Linux workstation. It creates `liam`, updates
the whole system, installs the applications referenced by the current dotfiles
repository, builds AUR packages as `liam`, enables Docker, deploys every approved
Stow package, and then hardens SSH, UFW, and fail2ban in lockout-safe order.

The dotfiles inventory was derived from
`fhlkfds/dotfiles@e834654423281ce5f5feae248ba628cb019b427c` on 2026-09-06.
The playbook still clones `main`, so review upstream changes before a later run.

## Stow layout found upstream

The upstream README defines these packages:

```text
ai browser cliphist fastfetch hypr hyprlock kitty modes noctalia quickshell
rofi screensaver security swaync systemd windows Wallpapers wofi xdg zsh
```

`docs`, `tests`, and `system` are explicitly excluded. The playbook also omits
the upstream `Wallpapers` package and stows `wallpaper` instead, matching the
package directory that actually exists upstream. Stow runs with `--no-folding`,
which makes every managed file
an individually verifiable symlink.

Before Stow runs, an existing target that does not already point into
`~/dotfiles` is moved to `~/dotfiles-backup-<timestamp>/` with the same relative
path. New deployments use `--no-folding`; a correct folded directory link from
an older Stow run is also accepted. The Git checkout uses `force: false`; local
changes are never overwritten.

## Package inventory

Official repository packages are declared in `group_vars/all/main.yml`. The list
includes the base toolchain, Hyprland and its active Quickshell stack, shell and
font dependencies, capture tools, retained Wofi/SwayNC/Noctalia components,
browser helpers, virtualization clients, Docker dependencies used by the
Windows helper, OpenSSH, and the package-specific dependencies documented by the
repo.

These names were confirmed in the configured Arch repositories:

```text
base-devel git stow sudo zsh curl openssh hyprland hyprpaper hypridle hyprlock
hyprsunset hyprpolkitagent kitty rofi quickshell wl-clipboard cliphist libnotify
python jq playerctl udiskie pipewire wireplumber networkmanager
networkmanager-openvpn openvpn tailscale bluez-utils
iputils polkit nautilus gnome-disk-utility spotify-launcher obsidian virt-manager
libvirt qemu-full dnsmasq btop imv mpv zathura zathura-pdf-mupdf neovim grim
slurp hyprpicker gpu-screen-recorder satty ffmpeg imagemagick tesseract
tesseract-data-eng v4l-utils ddcutil pam-u2f libfido2 gnupg rust musl rust-musl
socat freerdp yt-dlp libheif file libqalculate papirus-icon-theme
ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji eza zsh-syntax-highlighting
zsh-autosuggestions fzf fastfetch cava wofi swaync pacman-contrib opendoas
power-profiles-daemon brightnessctl zbar translate-shell python-gobject
xdg-desktop-portal xdg-desktop-portal-hyprland wtype gifski vulkan-tools
mesa-utils opencode docker docker-compose docker-buildx ufw fail2ban
```

The AUR RPC confirmed these package bases:

```text
brave-bin claude-code helium-browser-bin hermes-agent-desktop hyprvoice-bin
localsend-bin looking-glass mpvpaper pokemon-colorscripts-git t3code-bin
wl-screenrec-git xdg-terminal-exec
```

`ttfx` is in neither the official repositories nor AUR. The dotfiles repo ships
`install-ttfx`, which builds the upstream Git repository with Cargo's lockfile
for `x86_64-unknown-linux-musl`. The packages role follows that route, pins the
inspected upstream commit, and checks that `~/.local/bin/ttfx` is static. This is
why the playbook currently refuses non-x86_64 targets.

Oh My Zsh, Powerlevel10k, and `fzf-tab` are also absent from the dotfiles Git
tree by design. Their documented upstream repositories are cloned with the Git
module and `force: false`.

## Required variables

Install the collections, copy the example vault, replace every placeholder, and
encrypt it:

```bash
ansible-galaxy collection install -r requirements.yml
cp group_vars/vault.yml.example group_vars/vault.yml
ansible-vault encrypt group_vars/vault.yml
```

`vault_liam_password_hash` must be a crypt-compatible password hash, never a
plain password. If it is omitted, the password task is skipped and the final
report says so. `vault_liam_authorized_key` may be omitted only when a valid key
already exists in `/home/liam/.ssh/authorized_keys`.

`vault_admin_ip` is required. Fail2ban will not start until that IP or CIDR is in
`ignoreip`. This is intentional. For a remote target, use the public source
address the host sees, not the target host's address.

If the controller needs a particular private key for the fresh SSH checks, set
`ssh_validation_identity_file` outside the vault to its local path. The private
key is never copied or printed by Ansible.

## Inventory and execution

The default inventory connects to `192.168.122.122` as `liam`. Root login is
disabled during the run:

```ini
[arch_workstation]
workstation ansible_host=192.168.122.122 ansible_user=liam
```

Test the SSH connection before running Ansible:

```bash
ssh liam@192.168.122.122
```

If the host uses a non-default SSH port, add `-p PORT` to `ssh` and set
`ansible_port=PORT` in `inventory/hosts.ini`. For a specific private key, use
`ssh -i ~/.ssh/KEY liam@192.168.122.122` and set
`ssh_validation_identity_file` to the same controller-side key path.

Keep the current SSH session open and retain console access for the first run.
Check the plan, then run it with diff output so the SSH change is recorded:

```bash
ansible-playbook --syntax-check site.yml
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --check --diff
ansible-playbook site.yml --ask-become-pass --ask-vault-pass --diff
```

Check mode cannot prove AUR builds, Docker, a service restart, firewall reachability,
or a new SSH connection. The real run performs those checks. SSH key login is
tested once before password authentication is disabled, again after `sshd` is
restarted, again after UFW is enabled, and once in final verification.

The first play starts with `gather_facts: false`. A guarded `raw` task installs
the official `python` package with a full `pacman -Syu`, resets the SSH
connection, and only then runs Ansible fact gathering. This is required for a
minimal Arch host where `/usr/bin/python3` does not exist yet. Check mode cannot
avoid this bootstrap; use a real run with `--ask-become-pass`.

Tags are `users`, `packages`, `boot`, `docker`, `dotfiles`, `greeter`, `ssh`,
`ufw`, `fail2ban`, and `verification`. The users role also carries `always`,
because every other role depends on the account and group state. Avoid running
`ufw` or `fail2ban` alone; they require the SSH role's discovered port and
successful key check.

No desktop, NetworkManager, user unit, or Wayland service is enabled. The
libvirt system daemon is enabled and started so virt-manager can connect to
`qemu:///system`; `liam` is added to the `libvirt` group and the playbook checks
that URI as the administrator. A new login is required for the group
membership to apply to an already-open graphical session.
Stow may place unit files in the home directory, but the playbook does not
activate them. Only `docker.service`, `sddm.service`, `ufw.service`, and
`fail2ban.service`, and `libvirtd.service` are left enabled.

`tailscaled.service` is also enabled and started, but the machine is not
enrolled into a tailnet by Ansible. From the workstation, authenticate it with
`sudo tailscale up` when you are ready.

The login screen is SDDM showing a theme from
[qylock](https://github.com/Darkkal44/qylock) (GPL-3.0), selected with
`sddm_theme`. qylock's `sddm.sh` is interactive, so the
greeter role does what that script does rather than running it: copy
`themes/<name>` into `/usr/share/sddm/themes/` and write `[Theme] Current` into
`/etc/sddm.conf.d/theme.conf`. The upstream repository is about 1.1 GB because
each theme carries its own video and image assets, so only the selected theme is
fetched, with a blobless sparse checkout. Some themes expect a font that qylock
cannot redistribute; the role reports where to drop it and the theme falls back
to a default font until you do. `sddm_display_server` defaults to `wayland`,
which is why `weston` is installed to host the greeter; set it to `x11` and add
`xorg-server` if a theme misbehaves under Wayland.

greetd, greetd-regreet and greetd-tuigreet were dropped from `official_packages`
when the login manager was switched, but they are not force-removed, so a host
that already has them keeps a working fallback: `systemctl disable sddm &&
systemctl enable greetd`, then reboot. The greeter role disables greetd before
enabling SDDM, because `systemctl enable sddm` fails while greetd still owns the
`display-manager.service` alias. It never stops a running display manager, so a
switch on a live machine takes effect at the next reboot.

`sshd.service` is deliberately not among them. `ssh_enabled` defaults to false:
the ssh role still installs and proves the hardened sshd configuration during a
run, and the final task of the final play then stops and disables sshd and
removes its UFW allowance, so nothing listens on the SSH port afterwards. A
remote run therefore works once, over the sshd that is already up, but cannot
open a new connection afterwards; start sshd from the console or run with
`-e ssh_enabled=true` before provisioning remotely again. That also means
`prove-idempotency.sh` needs `-e ssh_enabled=true`, because enabling sshd for the
checks and disabling it again is a change on every run by design.

LocalSend is reachable on port 53317, TCP and UDP, from the ranges in
`localsend_source_ranges` only. UDP carries its multicast discovery, so closing
it would force adding every device by IP by hand.

The boot role silences the boot console. This host boots a unified kernel image,
so the cmdline is baked into the image from `/etc/kernel/cmdline` and editing
`/etc/default/grub` alone changes nothing; the role writes both and rebuilds the
UKI. Parameters take effect on the next boot. Set `boot_quiet: false` to keep the
console verbose while debugging a boot problem.

Hardware enrollment and account authentication are intentionally left alone.
The playbook installs PAM U2F tools but does not enroll a YubiKey or deploy the
repo's `system/pam.d` examples. It also does not authenticate Spotify, browsers,
AI agents, VPNs, or the Windows VM; generate machine-specific monitor profiles;
install the external GAM directory referenced by `.zshrc`; generate an active
theme; or activate the Stowed user unit. These steps need hardware, credentials,
or a live graphical session. The Codex CLI has no exact official/AUR package in
the checked repositories, so the `ai` launcher will report it missing until it
is installed by its upstream method.

## Evidence and idempotency

The verification play prints a pass/fail table followed by unedited command
output for user and group state, sudoers, Yay, every configured package, Docker,
the effective SSH policy and fresh key connection, UFW, fail2ban, and key Stow
links. A failed assertion stops the play, so a PASS table is printed only after
all checks succeed.

Run the full playbook twice to produce the requested idempotency evidence:

```bash
scripts/prove-idempotency.sh inventory/hosts.ini --ask-become-pass --ask-vault-pass
```

The script saves both transcripts under `artifacts/` and fails unless every host
in the second recap reports `changed=0`, `unreachable=0`, and `failed=0`.

## Recovery notes

Existing SSH sessions survive an `sshd` restart. If the fresh key check fails,
the firewall roles never run. From a retained root console, remove
`/etc/ssh/sshd_config.d/99-ansible-hardening.conf`, validate with `sshd -t`, and
restart `sshd.service`.

If a quiet boot hides a failure you need to see, edit the kernel cmdline from the
bootloader for one boot, or set `boot_quiet: false` and rerun `--tags boot`.
`/etc/kernel/cmdline` and `/etc/default/grub` are backed up in place. The
previous `grub.cfg` goes to `/var/lib/arch-autodeploy/grub.cfg.previous` instead,
because `/boot` is a vfat EFI partition that rejects the colons in Ansible's
timestamped backup names and cannot store an arbitrary mode. `grub.cfg` is
regenerable anyway with `grub-mkconfig -o /boot/grub/grub.cfg`.

To recover from a firewall mistake, run `ufw disable` from the console. To stop
banning while preserving UFW, run `systemctl disable --now fail2ban`. Stow
conflicts can be restored from the reported backup directory after unstowing the
owning package.
