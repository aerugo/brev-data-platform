# Phase 0: Prerequisites & Manual Setup

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Ensure all external accounts, API keys, credentials, and local tools are ready before starting implementation. This phase is entirely manual.

---

## Invariants Enforced in This Phase

- **INV-S001**: No plaintext secrets in Git - credentials go in `.env.local` (git-ignored)

---

## Prerequisites Checklist

### 1. Brev Account & CLI

**Status**: [ ] Complete

```bash
# Verify Brev CLI is installed and logged in
brev --version
brev ls
```

**Expected output**: Shows current org and instance list (may be empty)

**If not logged in**:
```bash
brev login
```

---

### 2. NVIDIA NGC Account

**Status**: [ ] Complete

#### 2.1 Create NGC Account

1. Go to https://ngc.nvidia.com
2. Click "Sign Up" or "Sign In"
3. Complete registration (may require NVIDIA Developer account)

#### 2.2 Generate NGC API Key

1. Log into NGC
2. Click your username (top right) → **Setup**
3. Click **API Key** in left sidebar
4. Click **Generate API Key**
5. Copy and save the key (format: `nvapi-xxxxxxxxxxxxxxxxxxxx`)

**Store securely** - you'll need this in Phase 2.

#### 2.3 Verify NIM Model Access

1. In NGC, go to **Catalog** → **Models**
2. Search for "llama3-8b-instruct"
3. Click on the model
4. Verify you can see the "Deploy" or "Download" options

**Note**: Some models require NVIDIA AI Enterprise license. If access is denied, contact NVIDIA sales or use an alternative model you have access to.

---

### 3. GitHub Setup

**Status**: [ ] Complete

#### 3.1 Repository

If the repository doesn't exist on GitHub yet:

1. Go to https://github.com/new
2. Repository name: `brev-data-platform`
3. Visibility: Private (recommended)
4. **Do NOT** initialize with README, .gitignore, or license
5. Click "Create repository"

If using existing local repo:
```bash
cd /Users/hugi/GitRepos/brev-data-platform
git init
git remote add origin git@github.com:YOUR_USERNAME/brev-data-platform.git
```

#### 3.2 Personal Access Token (PAT)

1. Go to https://github.com/settings/tokens
2. Click **Generate new token** → **Generate new token (classic)**
3. Note: "ArgoCD repo access"
4. Expiration: 90 days (or custom)
5. Select scopes:
   - [x] `repo` (Full control of private repositories)
   - [x] `read:packages` (Read packages)
6. Click **Generate token**
7. Copy and save the token (format: `ghp_xxxxxxxxxxxxxxxxxxxx`)

**Store securely** - you'll need this in Phase 2.

---

### 4. Local Tools Installation

**Status**: [ ] Complete

#### macOS (Homebrew)

```bash
# Install all required tools
brew install kubectl helm sops age

# Verify installations
kubectl version --client
helm version
sops --version
age --version
```

#### Expected Versions

| Tool | Minimum Version | Check Command |
|------|-----------------|---------------|
| kubectl | 1.28.0 | `kubectl version --client` |
| helm | 3.13.0 | `helm version` |
| sops | 3.8.0 | `sops --version` |
| age | 1.1.0 | `age --version` |

#### Linux

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# sops
curl -LO https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64
chmod +x sops-v3.8.1.linux.amd64 && sudo mv sops-v3.8.1.linux.amd64 /usr/local/bin/sops

# age
curl -LO https://github.com/FiloSottile/age/releases/download/v1.1.1/age-v1.1.1-linux-amd64.tar.gz
tar xzf age-v1.1.1-linux-amd64.tar.gz
sudo mv age/age /usr/local/bin/ && sudo mv age/age-keygen /usr/local/bin/
```

---

### 5. Optional: Docker (for local Dagster development)

**Status**: [ ] Complete (optional)

```bash
# Verify Docker is installed
docker --version
docker compose version
```

Not required for deployment but useful for local Dagster testing.

---

## Credential Summary

After completing this phase, you should have:

| Credential | Format | Where to Store |
|------------|--------|----------------|
| NGC API Key | `nvapi-xxx...` | `.env.local` |
| GitHub PAT | `ghp_xxx...` | `.env.local` |
| Brev auth | (automatic via CLI) | Brev CLI handles this |

---

## Verification

Run this verification script to confirm all prerequisites:

```bash
#!/bin/bash
echo "=== Brev Data Platform Prerequisites Check ==="

echo -n "Brev CLI: "
brev --version 2>/dev/null && echo "✓" || echo "✗ Not installed"

echo -n "Brev logged in: "
brev ls 2>/dev/null && echo "✓" || echo "✗ Not logged in"

echo -n "kubectl: "
kubectl version --client --short 2>/dev/null && echo "✓" || echo "✗ Not installed"

echo -n "helm: "
helm version --short 2>/dev/null && echo "✓" || echo "✗ Not installed"

echo -n "sops: "
sops --version 2>/dev/null && echo "✓" || echo "✗ Not installed"

echo -n "age: "
age --version 2>/dev/null && echo "✓" || echo "✗ Not installed"

echo ""
echo "Manual verifications needed:"
echo "  - [ ] NGC API Key generated and saved"
echo "  - [ ] GitHub PAT generated and saved"
echo "  - [ ] GitHub repository created"
```

---

## Completion Criteria

- [ ] `brev ls` works without errors
- [ ] NGC API Key saved securely (not in Git)
- [ ] NGC account has NIM model access verified
- [ ] GitHub repository exists
- [ ] GitHub PAT saved securely (not in Git)
- [ ] kubectl 1.28+ installed
- [ ] helm 3.13+ installed
- [ ] sops 3.8+ installed
- [ ] age 1.1+ installed

---

## Next Phase

Once all prerequisites are confirmed, proceed to [Phase 1: Repository Structure](phase-1.md).
