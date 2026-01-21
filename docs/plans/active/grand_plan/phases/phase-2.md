# Phase 2: Secrets & Encryption Setup

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Configure SOPS with Age encryption for secret management. Create encrypted secret files for all services that will be deployed in later phases.

---

## Invariants Enforced in This Phase

- **INV-S001**: No plaintext secrets in Git - All secrets must be SOPS encrypted
- **INV-S002**: SOPS configuration in repository root - `.sops.yaml` must exist
- **INV-S003**: NGC API key as Kubernetes secret - Stored encrypted
- **INV-S004**: MinIO credentials encrypted - Never plaintext

---

## Manual Steps

### Step 2.1: Generate Age Key Pair

```bash
# Create directory for age keys (if not exists)
mkdir -p ~/.config/sops/age

# Generate key pair
age-keygen -o ~/.config/sops/age/keys.txt

# Display the public key (you'll need this)
echo "Your Age public key:"
age-keygen -y ~/.config/sops/age/keys.txt
```

**Save the public key** - it looks like: `age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

### Step 2.2: Create .env.local

Create `.env.local` with your actual credentials:

```bash
# Copy the example
cp .env.example .env.local

# Edit with your values
# Use your preferred editor
nano .env.local
```

Fill in:
- `NGC_API_KEY` - From NGC Setup page
- `GITHUB_PAT` - From GitHub tokens page
- `MINIO_ROOT_USER` - Choose a username (e.g., `admin`)
- `MINIO_ROOT_PASSWORD` - Generate: `openssl rand -base64 24`
- `LAKEFS_ACCESS_KEY_ID` - Generate: `openssl rand -hex 10 | tr '[:lower:]' '[:upper:]'`
- `LAKEFS_SECRET_ACCESS_KEY` - Generate: `openssl rand -base64 32`

---

## Files to Create

### 1. .sops.yaml

```yaml
# SOPS Configuration
# All files matching these patterns will be encrypted with Age

creation_rules:
  # Kubernetes secret files
  - path_regex: .*\.enc\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # Replace with YOUR public key

  - path_regex: .*\.enc\.json$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # Replace with YOUR public key

  # Environment files
  - path_regex: .*\.env\.enc$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  # Replace with YOUR public key
```

**Important**: Replace the `age1xxx...` placeholder with your actual Age public key from Step 2.1.

### 2. k8s/apps/minio/secrets.enc.yaml

First create the plaintext version (DO NOT COMMIT):

```yaml
# k8s/apps/minio/secrets.yaml (temporary, delete after encrypting)
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: minio
type: Opaque
stringData:
  root-user: "admin"  # From .env.local MINIO_ROOT_USER
  root-password: "your-generated-password"  # From .env.local MINIO_ROOT_PASSWORD
```

Encrypt and delete plaintext:

```bash
cd k8s/apps/minio
sops -e secrets.yaml > secrets.enc.yaml
rm secrets.yaml  # Delete plaintext immediately!
```

### 3. k8s/apps/lakefs/secrets.enc.yaml

Create plaintext (temporary):

```yaml
# k8s/apps/lakefs/secrets.yaml (temporary)
apiVersion: v1
kind: Secret
metadata:
  name: lakefs-credentials
  namespace: lakefs
type: Opaque
stringData:
  access-key-id: "YOUR_LAKEFS_ACCESS_KEY"  # From .env.local
  secret-access-key: "YOUR_LAKEFS_SECRET_KEY"  # From .env.local
  # LakeFS also needs MinIO credentials to connect
  minio-access-key: "admin"  # Same as MinIO root user
  minio-secret-key: "your-minio-password"  # Same as MinIO root password
```

Encrypt:

```bash
cd k8s/apps/lakefs
sops -e secrets.yaml > secrets.enc.yaml
rm secrets.yaml
```

### 4. k8s/apps/nvidia-ai/secrets.enc.yaml

Create plaintext (temporary):

```yaml
# k8s/apps/nvidia-ai/secrets.yaml (temporary)
apiVersion: v1
kind: Secret
metadata:
  name: ngc-credentials
  namespace: nvidia-ai
type: Opaque
stringData:
  api-key: "nvapi-your-ngc-api-key"  # From .env.local NGC_API_KEY
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
          "username": "$oauthtoken",
          "password": "nvapi-your-ngc-api-key"
        }
      }
    }
```

Encrypt:

```bash
cd k8s/apps/nvidia-ai
sops -e secrets.yaml > secrets.enc.yaml
rm secrets.yaml
```

### 5. k8s/apps/argocd-apps/secrets.enc.yaml

Create plaintext (temporary):

```yaml
# k8s/apps/argocd-apps/secrets.yaml (temporary)
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
  url: https://github.com/YOUR_USERNAME/brev-data-platform.git
  username: git
  password: "ghp_your-github-pat"  # From .env.local GITHUB_PAT
```

Encrypt:

```bash
cd k8s/apps/argocd-apps
sops -e secrets.yaml > secrets.enc.yaml
rm secrets.yaml
```

### 6. k8s/apps/dagster/secrets.enc.yaml

Create plaintext (temporary):

```yaml
# k8s/apps/dagster/secrets.yaml (temporary)
apiVersion: v1
kind: Secret
metadata:
  name: dagster-env-secrets
  namespace: dagster
type: Opaque
stringData:
  # MinIO/LakeFS connection
  MINIO_ENDPOINT: "minio.minio.svc.cluster.local:9000"
  MINIO_ACCESS_KEY: "admin"
  MINIO_SECRET_KEY: "your-minio-password"
  LAKEFS_ENDPOINT: "http://lakefs.lakefs.svc.cluster.local:8000"
  LAKEFS_ACCESS_KEY_ID: "your-lakefs-access-key"
  LAKEFS_SECRET_ACCESS_KEY: "your-lakefs-secret-key"
  # NVIDIA NIM
  NIM_ENDPOINT: "http://nim-llm.nvidia-ai.svc.cluster.local:8000"
  NGC_API_KEY: "nvapi-your-key"
```

Encrypt:

```bash
cd k8s/apps/dagster
sops -e secrets.yaml > secrets.enc.yaml
rm secrets.yaml
```

---

## Helper Script

Create `scripts/create-secrets.sh` to streamline secret creation:

```bash
#!/bin/bash
# Helper script to create encrypted secrets from .env.local

set -e

if [ ! -f ".env.local" ]; then
    echo "Error: .env.local not found. Copy .env.example and fill in values."
    exit 1
fi

# Source environment variables
source .env.local

echo "Creating encrypted secrets..."

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# MinIO secrets
cat > "$TEMP_DIR/minio-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: minio
type: Opaque
stringData:
  root-user: "${MINIO_ROOT_USER}"
  root-password: "${MINIO_ROOT_PASSWORD}"
EOF

sops -e "$TEMP_DIR/minio-secrets.yaml" > k8s/apps/minio/secrets.enc.yaml
echo "✓ Created k8s/apps/minio/secrets.enc.yaml"

# LakeFS secrets
cat > "$TEMP_DIR/lakefs-secrets.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: lakefs-credentials
  namespace: lakefs
type: Opaque
stringData:
  access-key-id: "${LAKEFS_ACCESS_KEY_ID}"
  secret-access-key: "${LAKEFS_SECRET_ACCESS_KEY}"
  minio-access-key: "${MINIO_ROOT_USER}"
  minio-secret-key: "${MINIO_ROOT_PASSWORD}"
EOF

sops -e "$TEMP_DIR/lakefs-secrets.yaml" > k8s/apps/lakefs/secrets.enc.yaml
echo "✓ Created k8s/apps/lakefs/secrets.enc.yaml"

# NVIDIA secrets
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

sops -e "$TEMP_DIR/nvidia-secrets.yaml" > k8s/apps/nvidia-ai/secrets.enc.yaml
echo "✓ Created k8s/apps/nvidia-ai/secrets.enc.yaml"

# ArgoCD repo secrets
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

sops -e "$TEMP_DIR/argocd-secrets.yaml" > k8s/apps/argocd-apps/secrets.enc.yaml
echo "✓ Created k8s/apps/argocd-apps/secrets.enc.yaml"

# Dagster secrets
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

sops -e "$TEMP_DIR/dagster-secrets.yaml" > k8s/apps/dagster/secrets.enc.yaml
echo "✓ Created k8s/apps/dagster/secrets.enc.yaml"

echo ""
echo "All secrets created successfully!"
echo "Verify with: sops -d k8s/apps/minio/secrets.enc.yaml"
```

Make executable:

```bash
chmod +x scripts/create-secrets.sh
```

---

## Validation Approach

```bash
# Verify .sops.yaml exists and has your key
cat .sops.yaml

# Test encryption
echo "test: value" > /tmp/test.yaml
sops -e /tmp/test.yaml > /tmp/test.enc.yaml
sops -d /tmp/test.enc.yaml
rm /tmp/test.yaml /tmp/test.enc.yaml

# Verify all secret files are encrypted
for f in k8s/apps/*/secrets.enc.yaml; do
    if grep -q "sops:" "$f"; then
        echo "✓ $f is encrypted"
    else
        echo "✗ $f is NOT encrypted!"
    fi
done

# Verify no plaintext secrets
git status | grep -v ".enc.yaml" | grep "secrets" && echo "WARNING: Unencrypted secrets!" || echo "✓ No plaintext secrets"
```

---

## Completion Criteria

- [ ] Age key pair exists at `~/.config/sops/age/keys.txt`
- [ ] `.sops.yaml` has correct Age public key
- [ ] `.env.local` has all credentials filled in
- [ ] `k8s/apps/minio/secrets.enc.yaml` encrypted
- [ ] `k8s/apps/lakefs/secrets.enc.yaml` encrypted
- [ ] `k8s/apps/nvidia-ai/secrets.enc.yaml` encrypted
- [ ] `k8s/apps/argocd-apps/secrets.enc.yaml` encrypted
- [ ] `k8s/apps/dagster/secrets.enc.yaml` encrypted
- [ ] All encrypted files contain `sops:` metadata
- [ ] No plaintext secrets in git status
- [ ] Can decrypt any encrypted file with `sops -d`

---

## Next Phase

Once secrets are configured, proceed to [Phase 3: Brev Instance + K3S](phase-3.md).
