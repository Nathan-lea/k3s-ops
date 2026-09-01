#!/bin/bash
# 环境依赖检查
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SELF_DIR}/lib/logging.sh"
log_init

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

if [ $MISSING -eq 1 ]; then
  log_error "Missing required tools."
  log_info "Install: vagrant (https://vagrantup.com), ansible (pip3 install ansible)"
  exit 1
fi

log_info "All checks passed. Run: ./k3s-ops.sh up"
