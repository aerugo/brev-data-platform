#!/bin/bash
# Create encrypted Kubernetes secrets from .env.local

set -e

# Check for .env.local
if [ ! -f ".env.local" ]; then
    echo "Error: .env.local not found"
    echo "Copy .env.example to .env.local and fill in your values"
    exit 1
fi

# Check for SOPS_AGE_KEY_FILE
if [ -z "$SOPS_AGE_KEY_FILE" ]; then
    export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
fi

if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
    echo "Error: Age key not found at $SOPS_AGE_KEY_FILE"
    echo "Generate one with: age-keygen -o ~/.config/sops/age/keys.txt"
    exit 1
fi

# Source environment variables
source .env.local

# Get Age public key from .sops.yaml
AGE_PUBLIC_KEY=$(grep 'age:' .sops.yaml | head -1 | awk '{print $2}')
if [ -z "$AGE_PUBLIC_KEY" ]; then
    echo "Error: Could not find Age public key in .sops.yaml"
    exit 1
fi

echo "=== Creating encrypted secrets ==="
echo "Using Age key: ${AGE_PUBLIC_KEY:0:20}..."

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# -----------------------------------------------------------------------------
# MinIO secrets
# -----------------------------------------------------------------------------
echo "Creating MinIO secrets..."
cat > "$TEMP_DIR/minio-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: minio
type: Opaque
stringData:
  rootUser: "${MINIO_ROOT_USER}"
  rootPassword: "${MINIO_ROOT_PASSWORD}"
EOF

mkdir -p k8s/apps/minio/secrets
sops --config /dev/null --age "$AGE_PUBLIC_KEY" -e "$TEMP_DIR/minio-secrets.yaml" > k8s/apps/minio/secrets/secrets.enc.yaml
echo "  ✓ k8s/apps/minio/secrets/secrets.enc.yaml"

# -----------------------------------------------------------------------------
# LakeFS secrets
# -----------------------------------------------------------------------------
echo "Creating LakeFS secrets..."
cat > "$TEMP_DIR/lakefs-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: lakefs-credentials
  namespace: lakefs
type: Opaque
stringData:
  # Auth encryption key (required by LakeFS chart)
  auth_encrypt_secret_key: "$(openssl rand -base64 32)"
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: lakefs
type: Opaque
stringData:
  # MinIO credentials for S3 backend (same namespace for cross-reference)
  rootUser: "${MINIO_ROOT_USER}"
  rootPassword: "${MINIO_ROOT_PASSWORD}"
EOF

mkdir -p k8s/apps/lakefs/secrets
sops --config /dev/null --age "$AGE_PUBLIC_KEY" -e "$TEMP_DIR/lakefs-secrets.yaml" > k8s/apps/lakefs/secrets/secrets.enc.yaml
echo "  ✓ k8s/apps/lakefs/secrets/secrets.enc.yaml"

# -----------------------------------------------------------------------------
# NVIDIA AI secrets
# -----------------------------------------------------------------------------
echo "Creating NVIDIA AI secrets..."
cat > "$TEMP_DIR/nvidia-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ngc-credentials
  namespace: nvidia-ai
type: Opaque
stringData:
  api-key: "${NGC_API_KEY}"
---
apiVersion: v1
kind: Secret
metadata:
  name: ngc-image-pull
  namespace: nvidia-ai
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {
      "auths": {
        "nvcr.io": {
          "username": "\$oauthtoken",
          "password": "${NGC_API_KEY}"
        }
      }
    }
EOF

mkdir -p k8s/apps/nvidia-ai/secrets
sops --config /dev/null --age "$AGE_PUBLIC_KEY" -e "$TEMP_DIR/nvidia-secrets.yaml" > k8s/apps/nvidia-ai/secrets/secrets.enc.yaml
echo "  ✓ k8s/apps/nvidia-ai/secrets/secrets.enc.yaml"

# -----------------------------------------------------------------------------
# ArgoCD repo secrets
# -----------------------------------------------------------------------------
echo "Creating ArgoCD repo secrets..."
cat > "$TEMP_DIR/argocd-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-credentials
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/${GITHUB_REPO}.git
  username: git
  password: "${GITHUB_PAT}"
EOF

mkdir -p k8s/apps/argocd-apps/secrets
sops --config /dev/null --age "$AGE_PUBLIC_KEY" -e "$TEMP_DIR/argocd-secrets.yaml" > k8s/apps/argocd-apps/secrets/secrets.enc.yaml
echo "  ✓ k8s/apps/argocd-apps/secrets/secrets.enc.yaml"

# -----------------------------------------------------------------------------
# Dagster secrets
# -----------------------------------------------------------------------------
echo "Creating Dagster secrets..."
cat > "$TEMP_DIR/dagster-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: dagster-env-secrets
  namespace: dagster
type: Opaque
stringData:
  MINIO_ENDPOINT: "minio.minio.svc.cluster.local:9000"
  MINIO_ACCESS_KEY: "${MINIO_ROOT_USER}"
  MINIO_SECRET_KEY: "${MINIO_ROOT_PASSWORD}"
  LAKEFS_ENDPOINT: "http://lakefs.lakefs.svc.cluster.local:8000"
  LAKEFS_ACCESS_KEY_ID: "${LAKEFS_ACCESS_KEY_ID}"
  LAKEFS_SECRET_ACCESS_KEY: "${LAKEFS_SECRET_ACCESS_KEY}"
  NIM_ENDPOINT: "http://nim-llm.nvidia-ai.svc.cluster.local:8000"
  NGC_API_KEY: "${NGC_API_KEY}"
EOF

mkdir -p k8s/apps/dagster/secrets
sops --config /dev/null --age "$AGE_PUBLIC_KEY" -e "$TEMP_DIR/dagster-secrets.yaml" > k8s/apps/dagster/secrets/secrets.enc.yaml
echo "  ✓ k8s/apps/dagster/secrets/secrets.enc.yaml"

# -----------------------------------------------------------------------------
# Marimo secrets (same access as Dagster)
# -----------------------------------------------------------------------------
echo "Creating Marimo secrets..."
cat > "$TEMP_DIR/marimo-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: marimo-env-secrets
  namespace: marimo
type: Opaque
stringData:
  MINIO_ENDPOINT: "minio.minio.svc.cluster.local:9000"
  MINIO_ACCESS_KEY: "${MINIO_ROOT_USER}"
  MINIO_SECRET_KEY: "${MINIO_ROOT_PASSWORD}"
  LAKEFS_ENDPOINT: "http://lakefs.lakefs.svc.cluster.local:8000"
  LAKEFS_ACCESS_KEY_ID: "${LAKEFS_ACCESS_KEY_ID}"
  LAKEFS_SECRET_ACCESS_KEY: "${LAKEFS_SECRET_ACCESS_KEY}"
EOF

mkdir -p k8s/apps/marimo/secrets
sops --config /dev/null --age "$AGE_PUBLIC_KEY" -e "$TEMP_DIR/marimo-secrets.yaml" > k8s/apps/marimo/secrets/secrets.enc.yaml
echo "  ✓ k8s/apps/marimo/secrets/secrets.enc.yaml"

echo ""
echo "=== All secrets created successfully! ==="
echo ""
echo "Verify with: sops -d k8s/apps/minio/secrets/secrets.enc.yaml"
echo ""
echo "To apply all secrets to cluster:"
echo "  make apply-secrets"
echo ""
