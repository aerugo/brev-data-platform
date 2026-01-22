#!/bin/bash
# Apply SOPS-encrypted secrets to the Kubernetes cluster
# Requires: KUBECONFIG set, SOPS_AGE_KEY_FILE set, cluster accessible

set -e

# Check prerequisites
if [ -z "$KUBECONFIG" ]; then
    export KUBECONFIG="$PWD/kubeconfig.yaml"
fi

if [ ! -f "$KUBECONFIG" ]; then
    echo "Error: KUBECONFIG not found at $KUBECONFIG"
    echo "Run: ./scripts/setup-kubeconfig.sh"
    exit 1
fi

if [ -z "$SOPS_AGE_KEY_FILE" ]; then
    export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
fi

if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
    echo "Error: Age key not found at $SOPS_AGE_KEY_FILE"
    exit 1
fi

# Get instance name from .env.local or KUBECONFIG
INSTANCE_NAME="${BREV_INSTANCE_NAME:-}"
if [ -z "$INSTANCE_NAME" ] && [ -f "$PWD/.env.local" ]; then
    INSTANCE_NAME=$(grep "^BREV_INSTANCE_NAME=" "$PWD/.env.local" 2>/dev/null | cut -d'=' -f2)
fi
INSTANCE_NAME="${INSTANCE_NAME:-brev-data-platform}"

# Test cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to cluster"
    echo "Make sure SSH tunnel is running:"
    echo "  ssh -F ~/.brev/ssh_config -N -L 6443:127.0.0.1:6443 ${INSTANCE_NAME}-host &"
    exit 1
fi

echo "=== Applying encrypted secrets to cluster ==="
echo ""

# List of secrets to apply (secrets are in secrets/ subdirectories)
SECRETS=(
    "k8s/apps/minio/secrets/secrets.enc.yaml:minio"
    "k8s/apps/lakefs/secrets/secrets.enc.yaml:lakefs"
    "k8s/apps/nvidia-ai/secrets/secrets.enc.yaml:nvidia-ai"
    "k8s/apps/argocd-apps/secrets/secrets.enc.yaml:argocd"
    "k8s/apps/dagster/secrets/secrets.enc.yaml:dagster"
    "k8s/apps/jupyterhub/secrets/secrets.enc.yaml:jupyterhub"
)

for secret_entry in "${SECRETS[@]}"; do
    SECRET_FILE="${secret_entry%%:*}"
    NAMESPACE="${secret_entry##*:}"

    if [ -f "$SECRET_FILE" ]; then
        echo "Applying $SECRET_FILE to namespace $NAMESPACE..."
        sops -d "$SECRET_FILE" | kubectl apply -n "$NAMESPACE" -f -
        echo "  ✓ Applied"
    else
        echo "  ⚠ Skipping $SECRET_FILE (not found)"
    fi
done

echo ""
echo "=== Secrets applied successfully! ==="
echo ""
echo "Verify with:"
echo "  kubectl get secrets -A | grep -E 'minio|lakefs|ngc|dagster|jupyterhub|repo'"
echo ""
