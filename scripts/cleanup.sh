#!/bin/bash
# Cleanup local artifacts
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SELF_DIR"
source "${SELF_DIR}/lib/logging.sh"
log_init

log_mark "Cleanup local artifacts"

if [ -f kubeconfig ]; then
  rm -f kubeconfig
  log_info "Removed kubeconfig"
fi

if [ -d /tmp/ansible-cache ]; then
  rm -rf /tmp/ansible-cache
  log_info "Removed /tmp/ansible-cache"
fi

find ansible -name "*.retry" -delete 2>/dev/null || true

log_mark "Cleanup complete"
