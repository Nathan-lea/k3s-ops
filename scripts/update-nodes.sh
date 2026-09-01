#!/bin/bash
# After updating nodes.yml, run this to apply changes
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SELF_DIR"
source "${SELF_DIR}/lib/logging.sh"
log_init

log_mark "Updating cluster nodes"

# Parse new nodes from nodes.yml
NEW_NODES=$(python3 -c "
import yaml
with open('vagrant/nodes.yml') as f:
    cfg = yaml.safe_load(f)
for n in cfg['nodes']:
    print(f\"{cfg['cluster_name']}-{n['name']} {n['role']}\")
")

log_info "Nodes defined in config:"
echo "$NEW_NODES" | while read -r host role; do
  log_info "  $host ($role)"
done

log_cmd "Starting VMs" vagrant up

echo "$NEW_NODES" | while read -r host role; do
  if [ "$role" = "server" ]; then
    log_cmd "Adding server: ${host}" ansible-playbook -i ansible/inventory.yml ansible/playbooks/k3s-add-server.yml -l "$host"
  elif [ "$role" = "agent" ]; then
    log_cmd "Adding agent: ${host}" ansible-playbook -i ansible/inventory.yml ansible/playbooks/k3s-add-agent.yml -l "$host"
  fi
done

log_mark "Update complete"
