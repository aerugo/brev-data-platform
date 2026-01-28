#!/usr/bin/env bash
# Deploy SOPS-encrypted secrets to Kubernetes
# These secrets are excluded from ArgoCD sync and must be deployed manually
#
# Usage: ./scripts/deploy-secrets.sh
#
# Prerequisites:
# - SOPS installed
# - Age private key in ~/.config/sops/age/keys.txt
# - kubectl configured to access the cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Deploying SOPS-encrypted secrets ==="

# Function to deploy a single secret file
deploy_secret() {
    local file="$1"
    echo "Deploying: $file"
    sops -d "$file" | kubectl apply -f -
}

# Dagster secrets
echo ""
echo "--- Dagster Namespace ---"
deploy_secret "$REPO_ROOT/k8s/apps/dagster/secrets/secrets.enc.yaml"
deploy_secret "$REPO_ROOT/k8s/apps/dagster/secrets/nds-credentials.enc.yaml"

# ArgoCD apps secrets (if any)
if [ -f "$REPO_ROOT/k8s/apps/argocd-apps/secrets/secrets.enc.yaml" ]; then
    echo ""
    echo "--- ArgoCD Apps Secrets ---"
    deploy_secret "$REPO_ROOT/k8s/apps/argocd-apps/secrets/secrets.enc.yaml"
fi

echo ""
echo "=== Secrets deployed successfully ==="
echo ""
echo "Note: If NDS (NeMo Data Store) was reset, you may need to regenerate the token:"
echo "  kubectl exec -n nvidia-ai \$(kubectl get pod -n nvidia-ai -l app=data-store -o jsonpath='{.items[0].metadata.name}') -- \\"
echo "    gitea admin user generate-access-token --username datastore_admin --token-name dagster-api --scopes 'write:repository,read:repository'"
echo ""
echo "Then update k8s/apps/dagster/secrets/nds-credentials.enc.yaml and re-run this script."
