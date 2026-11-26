#!/bin/bash
# After updating nodes.yml, run this to apply changes
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SELF_DIR"
source "${SELF_DIR}/lib/logging.sh"
log_init

NODES_YML="${SELF_DIR}/vagrant/nodes.yml"
INVENTORY="${SELF_DIR}/ansible/inventory.generated.yml"
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-${SELF_DIR}/ansible/ansible.cfg}"

ensure_inventory() {
  local -a key_args=(--key-mode flat --key-dir "${HOME}/.ssh/k3s-ops")
  local first_host vagrant_key
  first_host="$(python3 -c "import yaml; c=yaml.safe_load(open('${NODES_YML}')); print(c['cluster_name']+'-'+c['nodes'][0]['name'])")"
  vagrant_key="${SELF_DIR}/.vagrant/machines/${first_host}/virtualbox/private_key"
  if [ -f "${vagrant_key}" ]; then
    key_args=(--key-mode vagrant --vagrant-dir "${SELF_DIR}/.vagrant" --provider virtualbox)
  fi
  python3 "${SELF_DIR}/scripts/gen-inventory.py" --nodes "${NODES_YML}" --out "${INVENTORY}" "${key_args[@]}" >/dev/null
}

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
ensure_inventory

echo "$NEW_NODES" | while read -r host role; do
  if [ "$role" = "server" ]; then
    log_cmd "Adding server: ${host}" ansible-playbook -i "${INVENTORY}" ansible/playbooks/k3s-add-server.yml -l "$host"
  elif [ "$role" = "agent" ]; then
    log_cmd "Adding agent: ${host}" ansible-playbook -i "${INVENTORY}" ansible/playbooks/k3s-add-agent.yml -l "$host"
  fi
done

log_mark "Update complete"
