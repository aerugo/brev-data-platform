#!/bin/bash
# Install ArgoCD using Helm

set -e

echo "=== Installing ArgoCD ==="

# Add Helm repo
echo "Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Check if values file exists
VALUES_FILE="k8s/bootstrap/argocd/values.yaml"
if [ -f "$VALUES_FILE" ]; then
    echo "Using custom values from $VALUES_FILE"
    VALUES_ARG="-f $VALUES_FILE"
else
    echo "No custom values file found, using defaults"
    VALUES_ARG=""
fi

# Install ArgoCD
echo "Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    $VALUES_ARG \
    --set server.extraArgs="{--insecure}" \
    --wait \
    --timeout 5m

echo ""
echo "=== Waiting for ArgoCD to be ready ==="
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

echo ""
echo "=== ArgoCD installed successfully! ==="
echo ""
echo "Get admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Port forward to access UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "Access: https://localhost:8080"
echo "Username: admin"
echo ""
