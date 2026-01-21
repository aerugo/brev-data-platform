#!/bin/bash
# Fetch kubeconfig from Brev instance and configure for local use

set -e

INSTANCE_NAME="${1:-brev-data-platform-dev}"
KUBECONFIG_PATH="./kubeconfig.yaml"
SSH_CONFIG="$HOME/.brev/ssh_config"

echo "=== Fetching kubeconfig from $INSTANCE_NAME ==="

# Check if Brev SSH config exists
if [ ! -f "$SSH_CONFIG" ]; then
    echo "Error: Brev SSH config not found at $SSH_CONFIG"
    echo "Make sure you have the Brev CLI installed and have created an instance"
    exit 1
fi

# Check if we can reach the instance
if ! ssh -F "$SSH_CONFIG" -o ConnectTimeout=10 -o BatchMode=yes "${INSTANCE_NAME}-host" "echo connected" >/dev/null 2>&1; then
    echo "Error: Cannot connect to instance '$INSTANCE_NAME'"
    echo "Make sure the instance is running: brev ls"
    exit 1
fi

# Copy kubeconfig from instance (need sudo for k3s kubeconfig)
echo "Copying kubeconfig..."
ssh -F "$SSH_CONFIG" -o LogLevel=ERROR "${INSTANCE_NAME}-host" 'sudo cat /etc/rancher/k3s/k3s.yaml' 2>/dev/null > "$KUBECONFIG_PATH"

if [ ! -s "$KUBECONFIG_PATH" ]; then
    echo "Error: Failed to fetch kubeconfig"
    exit 1
fi

echo ""
echo "=== Kubeconfig saved to $KUBECONFIG_PATH ==="
echo ""
echo "To use kubectl, start an SSH tunnel first:"
echo ""
echo "  # Start tunnel (run in background or separate terminal):"
echo "  ssh -F ~/.brev/ssh_config -N -L 6443:127.0.0.1:6443 ${INSTANCE_NAME}-host &"
echo ""
echo "  # Then use kubectl:"
echo "  export KUBECONFIG=\$PWD/kubeconfig.yaml"
echo "  kubectl get nodes"
echo ""
echo "  # To stop the tunnel:"
echo "  pkill -f 'ssh.*6443:127.0.0.1:6443'"
echo ""
echo "Alternatively, run commands directly on the instance:"
echo "  brev shell $INSTANCE_NAME"
echo "  sudo kubectl get nodes"
echo ""
