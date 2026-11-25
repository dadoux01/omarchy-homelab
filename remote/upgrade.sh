# Interactive system upgrade, run in a terminal with `ssh -t host sh <file>`
# so it works whatever the login shell is. Every step asks for confirmation
# through the package manager itself; sudo (or doas) prompts for a password.
if [ "$(id -u)" = 0 ]; then S=""
elif command -v sudo >/dev/null 2>&1; then S="sudo"
elif command -v doas >/dev/null 2>&1; then S="doas"
else echo "Neither sudo nor doas is available."; exit 1
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ -d /etc/pve ] && command -v apt-get >/dev/null 2>&1; then
  # Proxmox VE must always be upgraded with full-upgrade (dist-upgrade).
  step "apt (Proxmox VE)"; $S apt-get update && $S apt-get dist-upgrade
elif command -v apt-get >/dev/null 2>&1; then
  step "apt"; $S apt-get update && $S apt-get --with-new-pkgs upgrade
elif command -v dnf >/dev/null 2>&1; then
  step "dnf"; $S dnf upgrade --refresh
elif command -v yum >/dev/null 2>&1; then
  step "yum"; $S yum update
elif command -v pacman >/dev/null 2>&1; then
  step "pacman"; $S pacman -Syu
elif command -v zypper >/dev/null 2>&1; then
  step "zypper"; $S zypper refresh && $S zypper update
elif command -v apk >/dev/null 2>&1; then
  step "apk"; $S apk upgrade -U -i
elif command -v xbps-install >/dev/null 2>&1; then
  step "xbps"; $S xbps-install -Su
else
  echo "No supported package manager found."
fi

if command -v flatpak >/dev/null 2>&1; then
  step "flatpak"; flatpak update
fi
if command -v snap >/dev/null 2>&1; then
  step "snap"; $S snap refresh
fi
