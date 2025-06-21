#!/bin/bash
set -euo pipefail

# === Global Constants ===
MOK_DIR="/var/lib/shim-signed/mok"
MOK_DER="$MOK_DIR/MOK.der"
REPO_URL="https://github.com/coolgeek2019/Debian-Autosetup.git"

# === Temporary Directories ===
THEME_TMP=$(mktemp -d)
TMP=$(mktemp -d)

# === Cleanup on Exit ===
cleanup() {
  rm -rf "$THEME_TMP" "$TMP"
}
trap cleanup EXIT

# === Logging Functions ===
log()         { echo -e "\e[1;32m[+] $1\e[0m"; }
warn()        { echo -e "\e[1;33m[!] $1\e[0m"; }
err()         { echo -e "\e[1;31m[-] $1\e[0m"; exit 1; }
log_section() { echo -e "\n\e[1;34m--- $1 ---\e[0m"; }

# === Retry Wrapper for Resilient Commands ===
run_with_retry() {
  local cmd="$1" max_retries="${2:-3}" delay="${3:-5}" count=0
  until bash -c "$cmd"; do
    count=$((count + 1))
    [[ $count -ge $max_retries ]] && err "Command failed after $count attempts: $cmd"
    warn "Retry $count/$max_retries: $cmd"
    sleep "$delay"
  done
}

# === Stage 1: Initial System Setup ===
stage1() {
  log_section "Stage 1: System Setup & Configuration"

  command -v mokutil >/dev/null 2>&1 || err "mokutil not found. Please install shim-signed."
  if mokutil --sb-state | grep -iq 'disabled'; then
    err "SecureBoot is disabled. Please enable it in BIOS and rerun."
  fi

  # Update & install packages
  log "Updating system and installing packages..."
  run_with_retry "apt update"
  run_with_retry "apt full-upgrade -y"
  apt install -y --no-install-recommends \
    qemu-kvm qemu-system-x86 libvirt-daemon-system libvirt-clients virt-manager \
    gir1.2-spiceclientgtk-3.0 dnsmasq-base qemu-utils iptables git \
    zsh zsh-syntax-highlighting zsh-autosuggestions fonts-firacode
  apt autoremove -y

  # Enable libvirt networking and permissions
  log "Configuring libvirt user and network..."
  adduser "$(whoami)" libvirt
  adduser "$(whoami)" kvm
  systemctl restart libvirtd
  virsh -c qemu:///system net-autostart default
  virsh -c qemu:///system net-start default

  # Generate and register DKMS MOK
  log "Generating DKMS MOK key..."
  mkdir -p "$MOK_DIR"
  rm -f "$MOK_DIR"/*
  openssl req -new -x509 -newkey rsa:2048 -nodes \
    -keyout "$MOK_DIR/MOK.priv" -outform DER -out "$MOK_DER" \
    -days 36500 -subj "/CN=Debian_Secureboot/"
  openssl x509 -inform DER -in "$MOK_DER" -out "$MOK_DIR/MOK.pem"
  chmod 600 "$MOK_DIR/MOK.priv"
  mokutil --import "$MOK_DER"

  # DNS configuration
  if ! command -v nmcli &>/dev/null; then
    err "nmcli not found. Please install NetworkManager or configure DNS manually."
  fi
  log "Configuring DNS..."
  ETH=$(nmcli -t -f NAME,TYPE con show --active | awk -F: '$2=="ethernet"{print $1; exit}')
  [[ -n "$ETH" ]] || err "No active Ethernet connection found."
  nmcli con mod "$ETH" ipv4.dns "1.1.1.1,8.8.8.8" \
                   ipv6.dns "2606:4700:4700::1111,2001:4860:4860::8888" \
                   ipv4.ignore-auto-dns yes \
                   ipv6.ignore-auto-dns yes
  nmcli con down "$ETH" && nmcli con up "$ETH"
  sleep 3

  # Clone and deploy config files
  log "Cloning configuration repo..."
  run_with_retry "git clone --depth=1 $REPO_URL $TMP/repo"
  cp "$TMP/repo/sources.list" /etc/apt/sources.list
  cp "$TMP/repo/framework.conf" "$TMP/repo/sign_helper.sh" /etc/dkms/
  chmod +x /etc/dkms/sign_helper.sh

  # Install Kali Linux theme
  log "Installing Kali theme..."
  run_with_retry "wget -qO $THEME_TMP/kali-theme.tar 'https://gitlab.com/kalilinux/packages/kali-themes/-/archive/kali/master/kali-themes-kali-master.tar?path=share'"
  tar -xf "$THEME_TMP/kali-theme.tar" --strip-components=2 --wildcards --no-anchored -C "$USER_HOME/.local/share" "share/*"
  chown -R "$SUDO_USER:$SUDO_USER" "$USER_HOME/.local/share"

  # Set zshrc for target user
  USER_HOME=$(eval echo "~$SUDO_USER")
  cp "$TMP/repo/.zshrc" "$USER_HOME/.zshrc" || warn "Failed to copy .zshrc"
  chown "$SUDO_USER:$SUDO_USER" "$USER_HOME/.zshrc"

  # Set default shell
  if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" &>/dev/null; then
    log "Setting Zsh as default shell for user $SUDO_USER..."
    chsh -s /bin/zsh "$SUDO_USER"
  else
    warn "SUDO_USER not set or invalid. Skipping shell change."
  fi

  # Verification
  log_section "Verifying Key Configurations"
  ls "$MOK_DIR"
  head -n 10 /etc/apt/sources.list
  ls /etc/dkms
  cat /etc/dkms/* || true
  nmcli dev show | grep DNS
  cat /etc/resolv.conf
  ls "$USER_HOME/.local/share"
  [[ -f "$USER_HOME/.zshrc" ]] || warn "~/.zshrc missing!"

  # Final message
  log_section "Stage 1 Complete — Reboot Required"
  echo -e "\e[1;36mAfter reboot, you will be prompted to enroll the MOK (Machine Owner Key).\n"
  echo -e "Select 'Enroll MOK' using arrow keys, confirm password, and complete the process.\n"
  echo -e "Then run:\n  wget -qO- https://raw.githubusercontent.com/coolgeek2019/Debian-Autosetup/main/cool.sh | sudo bash\n\e[0m"
}

# === Stage 2: Post-reboot SecureBoot & NVIDIA Driver Setup ===
stage2() {
  log_section "Stage 2: SecureBoot + NVIDIA Driver Setup"

  [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc" || warn "No .zshrc to source."

  log "Verifying MOK key..."
  mokutil --test-key "$MOK_DER" || warn "MOK key not enrolled yet or inactive."

  log "Inspecting kernel logs for certificates..."
  dmesg | grep -i cert || warn "No certificate logs found in dmesg."

  log "Installing NVIDIA drivers..."
  run_with_retry "apt update"
  run_with_retry "apt install -y linux-headers-amd64 nvidia-driver firmware-misc-nonfree"

  log "Testing NVIDIA driver installation..."
  nvidia-smi || warn "nvidia-smi failed. Driver might not be active."

  log_section "Stage 2 Complete"
}

# === Main Entrypoint ===
main() {
  if [[ -f "$MOK_DER" ]] && mokutil --test-key "$MOK_DER"; then
    stage2
  else
    stage1
  fi
}

main "$@"
