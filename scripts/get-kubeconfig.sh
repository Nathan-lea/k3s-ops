#!/bin/bash
# Get kubeconfig from the first server node
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SELF_DIR}/lib/logging.sh"
log_init

NODE="${1:-server-1}"
KUBECONFIG_DEST="${2:-./kubeconfig}"

SERVER_HOST="k3s-demo-${NODE}"

log_cmd "Fetching kubeconfig from ${SERVER_HOST}" \
  vagrant ssh "${SERVER_HOST}" -- cat /etc/rancher/k3s/k3s.yaml 2>/dev/null > "$KUBECONFIG_DEST" || {
  log_error "Failed to get kubeconfig from ${SERVER_HOST}"
  exit 1
}

log_info "Kubeconfig saved to ${KUBECONFIG_DEST}"

# Replace localhost with server IP
SERVER_IP=$(vagrant ssh "${SERVER_HOST}" -- ip addr show eth1 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
if [ -n "$SERVER_IP" ]; then
  sed -i "s/127.0.0.1/${SERVER_IP}/g" "$KUBECONFIG_DEST"
  log_info "Server address updated to ${SERVER_IP}"
fi
