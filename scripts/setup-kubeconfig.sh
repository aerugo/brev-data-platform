#!/bin/bash
# Fetch kubeconfig from Brev instance and configure for local use
# Supports both RKE2 (default) and K3S

set -e

INSTANCE_NAME="${1:-brev-data-platform}"
KUBECONFIG_PATH="./kubeconfig.yaml"
SSH_CONFIG="$HOME/.brev/ssh_config"

# Kubeconfig paths for different distributions
RKE2_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

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

# Try RKE2 first (preferred), then fall back to K3S
echo "Checking for RKE2..."
if ssh -F "$SSH_CONFIG" -o LogLevel=ERROR "${INSTANCE_NAME}-host" "sudo test -f $RKE2_KUBECONFIG" 2>/dev/null; then
    echo "Found RKE2 installation"
    REMOTE_KUBECONFIG="$RKE2_KUBECONFIG"
    K8S_DISTRO="RKE2"
elif ssh -F "$SSH_CONFIG" -o LogLevel=ERROR "${INSTANCE_NAME}-host" "sudo test -f $K3S_KUBECONFIG" 2>/dev/null; then
    echo "Found K3S installation (legacy)"
    REMOTE_KUBECONFIG="$K3S_KUBECONFIG"
    K8S_DISTRO="K3S"
else
    echo "Error: No Kubernetes installation found"
    echo "Run 'make bootstrap-rke2' to install RKE2"
    exit 1
fi

# Copy kubeconfig from instance
echo "Copying kubeconfig from $K8S_DISTRO..."
ssh -F "$SSH_CONFIG" -o LogLevel=ERROR "${INSTANCE_NAME}-host" "sudo cat $REMOTE_KUBECONFIG" 2>/dev/null > "$KUBECONFIG_PATH"

if [ ! -s "$KUBECONFIG_PATH" ]; then
    echo "Error: Failed to fetch kubeconfig"
    exit 1
fi

# Update the server address to use localhost (for SSH tunnel)
# RKE2 and K3S both use 6443 as the API server port
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' 's|server:.*|server: https://127.0.0.1:6443|g' "$KUBECONFIG_PATH"
else
    # Linux
    sed -i 's|server:.*|server: https://127.0.0.1:6443|g' "$KUBECONFIG_PATH"
fi

echo ""
echo "=== Kubeconfig saved to $KUBECONFIG_PATH ($K8S_DISTRO) ==="
echo ""
echo "To use kubectl, start an SSH tunnel first:"
echo ""
echo "  # Start tunnel (run in background or separate terminal):"
echo "  make ssh-tunnel-bg"
echo "  # Or manually:"
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
