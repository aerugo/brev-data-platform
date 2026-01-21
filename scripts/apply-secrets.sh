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

# Test cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to cluster"
    echo "Make sure SSH tunnel is running:"
    echo "  ssh -F ~/.brev/ssh_config -N -L 6443:127.0.0.1:6443 brev-data-platform-dev-host &"
    exit 1
fi

echo "=== Applying encrypted secrets to cluster ==="
echo ""

# List of secrets to apply
SECRETS=(
    "k8s/apps/minio/secrets.enc.yaml:minio"
    "k8s/apps/lakefs/secrets.enc.yaml:lakefs"
    "k8s/apps/nvidia-ai/secrets.enc.yaml:nvidia-ai"
    "k8s/apps/argocd-apps/secrets.enc.yaml:argocd"
    "k8s/apps/dagster/secrets.enc.yaml:dagster"
    "k8s/apps/marimo/secrets.enc.yaml:marimo"
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
echo "  kubectl get secrets -A | grep -E 'minio|lakefs|ngc|dagster|marimo|repo'"
echo ""
