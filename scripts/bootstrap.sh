#!/bin/bash
# 环境依赖检查
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SELF_DIR}/lib/logging.sh"
log_init

OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
OS_ARCH="$(uname -m 2>/dev/null || echo unknown)"
log_info "Host: ${OS_NAME} ${OS_ARCH}"

if [ "$OS_NAME" = "Darwin" ]; then
  if [ "$OS_ARCH" = "arm64" ] || [ "$OS_ARCH" = "aarch64" ]; then
    log_warn "Apple Silicon detected. Teaching environment requires VirtualBox >= 7.1 and Vagrant >= 2.4."
    log_warn "If VirtualBox ARM is unstable, set network.provider in vagrant/nodes.yml (vmware_desktop/parallels) as an escape hatch."
  else
    log_info "macOS Intel detected. VirtualBox + Vagrant + Ansible are required."
  fi
fi

version_ge() {
  # return 0 if $1 >= $2 (major.minor), else 1; defensive on parse failure
  local a="$1" b="$2"
  local a1 a2 b1 b2
  a1="$(printf '%s' "$a" | awk -F. '{print $1+0}')" || return 1
  a2="$(printf '%s' "$a" | awk -F. '{print $2+0}')" || return 1
  b1="$(printf '%s' "$b" | awk -F. '{print $1+0}')" || return 1
  b2="$(printf '%s' "$b" | awk -F. '{print $2+0}')" || return 1
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -ge "$b2" ]
}

check_cmd() {
  if command -v "$1" &>/dev/null; then
    log_info "$1: $($1 --version 2>&1 | head -1)"
  else
    log_error "$1: NOT FOUND"
    return 1
  fi
}

MISSING=0
check_cmd "vagrant"  || MISSING=1
check_cmd "vboxmanage" || log_warn "vboxmanage not found, VirtualBox may not be installed"
check_cmd "ansible"  || MISSING=1
check_cmd "python3"  || MISSING=1

if [ "$OS_NAME" = "Darwin" ] && { [ "$OS_ARCH" = "arm64" ] || [ "$OS_ARCH" = "aarch64" ]; }; then
  if command -v vagrant >/dev/null 2>&1; then
    VAGRANT_VER="$(vagrant --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+/) {print $i; exit}}')"
    if [ -n "$VAGRANT_VER" ] && ! version_ge "$VAGRANT_VER" "2.4"; then
      log_warn "Vagrant ${VAGRANT_VER} detected; Apple Silicon recommends Vagrant >= 2.4."
    fi
  fi
  if command -v vboxmanage >/dev/null 2>&1; then
    VBOX_VER="$(vboxmanage --version 2>/dev/null | awk -F_ '{print $1}' | awk -F'r' '{print $1}')"
    if [ -n "$VBOX_VER" ] && ! version_ge "$VBOX_VER" "7.1"; then
      log_warn "VirtualBox ${VBOX_VER} detected; Apple Silicon recommends VirtualBox >= 7.1."
    fi
  fi
fi

if [ $MISSING -eq 1 ]; then
  log_error "Missing required tools."
  log_info "Install: vagrant (https://vagrantup.com), ansible (pip3 install ansible)"
  exit 1
fi

log_info "All checks passed. Run: ./k3s-ops.sh up"
