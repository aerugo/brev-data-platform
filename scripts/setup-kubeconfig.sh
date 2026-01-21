#!/bin/bash
# Fetch kubeconfig from Brev instance and configure for local use

set -e

INSTANCE_NAME="${1:-brev-data-platform-dev}"
KUBECONFIG_PATH="./kubeconfig.yaml"

echo "=== Fetching kubeconfig from $INSTANCE_NAME ==="

# Check if instance exists
if ! brev ls 2>/dev/null | grep -q "$INSTANCE_NAME"; then
    echo "Error: Instance '$INSTANCE_NAME' not found"
    echo "Available instances:"
    brev ls
    exit 1
fi

# Copy kubeconfig from instance
echo "Copying kubeconfig..."
brev copy "$INSTANCE_NAME:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_PATH"

# Get instance hostname/IP for SSH config
# Brev handles networking via SSH, so we need to update the server address
# The kubeconfig will use 127.0.0.1:6443 which works via brev's SSH tunnel

# For direct access, we'd need the instance IP, but port-forward via brev is more reliable
# Keeping localhost for now - use with: brev port-forward or brev shell

echo ""
echo "=== Kubeconfig saved to $KUBECONFIG_PATH ==="
echo ""
echo "To use kubectl, you have two options:"
echo ""
echo "Option 1: Use brev shell (recommended)"
echo "  brev shell $INSTANCE_NAME"
echo "  # Then run kubectl commands directly on the instance"
echo ""
echo "Option 2: Port forward K3S API (advanced)"
echo "  # In one terminal:"
echo "  brev port-forward $INSTANCE_NAME -p 6443:6443"
echo "  # In another terminal:"
echo "  export KUBECONFIG=$PWD/kubeconfig.yaml"
echo "  kubectl get nodes"
echo ""
