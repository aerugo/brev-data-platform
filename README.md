# Brev Data Platform

GPU-accelerated data platform on NVIDIA Brev with K3S, ArgoCD, Dagster, LakeFS, MinIO, and NVIDIA AI Enterprise.

## Overview

This repository contains Infrastructure as Code (IaC) for deploying a complete data platform stack:

| Component | Purpose |
|-----------|---------|
| **K3S** | Lightweight Kubernetes |
| **ArgoCD** | GitOps continuous deployment |
| **MinIO** | S3-compatible object storage |
| **LakeFS** | Git-like data versioning |
| **Dagster** | Data pipeline orchestration |
| **Marimo** | Interactive Python notebooks |
| **NVIDIA NIM** | LLM inference |
| **Safe Synthesizer** | Synthetic data generation |

---

## Prerequisites (One-Time Manual Setup)

These steps must be completed once on your local machine before using the IaC:

### 1. Install Required Tools

```bash
# macOS with Homebrew
brew install kubectl helm sops age

# Verify versions
kubectl version --client   # v1.28+
helm version               # v3.13+
sops --version             # v3.8+
age --version              # v1.1+
```

### 2. Install and Login to Brev CLI

```bash
# Install Brev CLI
curl -fsSL https://raw.githubusercontent.com/brevdev/brev-cli/main/bin/install.sh | sh

# Login to Brev (interactive - opens browser)
brev login

# Verify login
brev ls
```

**Note**: Brev CLI tokens expire periodically. Re-run `brev login` if you see authentication errors.

### 3. Generate Age Encryption Key

```bash
# Create key directory
mkdir -p ~/.config/sops/age

# Generate key pair
age-keygen -o ~/.config/sops/age/keys.txt

# View your public key (you'll need this)
grep "public key:" ~/.config/sops/age/keys.txt

# Set environment variable (add to ~/.zshrc or ~/.bashrc)
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt
```

### 4. Update .sops.yaml with Your Public Key

Edit `.sops.yaml` in the repository root and replace the Age public key with yours:

```yaml
creation_rules:
  - path_regex: .*\.enc\.yaml$
    age: YOUR_AGE_PUBLIC_KEY_HERE
```

### 5. Create Environment File

```bash
# Copy template
cp .env.example .env.local

# Edit with your credentials
# - NGC_API_KEY: Get from https://ngc.nvidia.com/setup/api-key
# - GITHUB_PAT: Run `gh auth token` or create at https://github.com/settings/tokens
# - Other credentials will be auto-generated
```

### 6. Get NGC API Key

1. Go to https://ngc.nvidia.com
2. Sign in or create account
3. Go to Setup > API Key
4. Generate and copy your key
5. Add to `.env.local` as `NGC_API_KEY=nvapi-...`

### 7. Generate Encrypted Secrets

```bash
./scripts/create-secrets.sh
```

This creates encrypted Kubernetes secrets in `k8s/apps/*/secrets.enc.yaml`.

---

## Quick Start (After Prerequisites)

### Option A: One-Command Setup

```bash
# Creates instance, bootstraps K3S, configures kubectl, applies secrets
make full-setup

# Then install ArgoCD
export KUBECONFIG=$PWD/kubeconfig.yaml
make bootstrap-argocd
```

### Option B: Step-by-Step

```bash
# 1. Create Brev GPU instance
make create-instance
# Wait ~60 seconds for instance to be ready

# 2. Bootstrap K3S with GPU support
make bootstrap-k3s

# 3. Fetch kubeconfig
make kubeconfig

# 4. Start SSH tunnel for kubectl access
make ssh-tunnel-bg

# 5. Apply secrets to cluster
export KUBECONFIG=$PWD/kubeconfig.yaml
make apply-secrets

# 6. Install ArgoCD
make bootstrap-argocd
```

### Verify Setup

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml

# Check node is ready with GPU
kubectl get nodes
kubectl describe node | grep nvidia.com/gpu

# Check namespaces created
kubectl get ns

# Check secrets applied
kubectl get secrets -A | grep -E 'minio|lakefs|ngc'

# Get ArgoCD password
make argocd-password
```

---

## Tear Down and Rebuild

To completely destroy and recreate the infrastructure:

```bash
# 1. Destroy current instance
make destroy

# 2. Recreate everything
make full-setup

# 3. Install ArgoCD
export KUBECONFIG=$PWD/kubeconfig.yaml
make bootstrap-argocd
```

---

## Commands Reference

```bash
make help                    # Show all commands

# Instance Management
make create-instance         # Create Brev GPU instance
make stop-instance           # Stop instance (saves cost)
make start-instance          # Start stopped instance
make destroy                 # Delete instance (DESTRUCTIVE)
make shell                   # SSH into instance
make status                  # Show instance status

# Kubernetes Setup
make bootstrap-k3s           # Install K3S + NVIDIA on instance
make kubeconfig              # Fetch kubeconfig from instance
make ssh-tunnel              # Start SSH tunnel (foreground)
make ssh-tunnel-bg           # Start SSH tunnel (background)
make apply-secrets           # Apply encrypted secrets to cluster
make bootstrap-argocd        # Install ArgoCD

# Full Stack
make full-setup              # Complete automated setup

# Port Forwarding (run after ssh-tunnel)
make port-forward-argocd     # https://localhost:8080
make port-forward-dagster    # http://localhost:3000
make port-forward-minio      # http://localhost:9001
make port-forward-lakefs     # http://localhost:8000
make port-forward-marimo     # http://localhost:2718

# Secrets
make create-secrets          # Generate encrypted secrets from .env.local
make edit-secret FILE=...    # Edit encrypted secret in place

# Validation
make lint                    # Lint Helm and Python
make validate                # Validate configurations
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     NVIDIA BREV INSTANCE                        │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    K3S + ArgoCD                           │  │
│  │  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐  │  │
│  │  │   Dagster   │───▶│   LakeFS    │◀───│    MinIO     │  │  │
│  │  │  Pipelines  │    │  Versioning │    │   Storage    │  │  │
│  │  └─────────────┘    └─────────────┘    └──────────────┘  │  │
│  │         │                                     ▲          │  │
│  │         ▼                                     │          │  │
│  │  ┌─────────────┐    ┌─────────────────────────────────┐  │  │
│  │  │   Marimo    │    │      NVIDIA AI Enterprise       │  │  │
│  │  │  Notebooks  │───▶│  ┌─────────┐  ┌──────────────┐  │  │  │
│  │  └─────────────┘    │  │ NIM LLM │  │Safe Synthesize│  │  │  │
│  │                     │  └─────────┘  └──────────────┘  │  │  │
│  │                     └─────────────────────────────────────┘  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Accessing Services

All services are accessed via kubectl port-forward through an SSH tunnel:

```bash
# Terminal 1: Keep SSH tunnel running
make ssh-tunnel

# Terminal 2: Port forward to service
export KUBECONFIG=$PWD/kubeconfig.yaml
make port-forward-argocd
```

| Service | Local URL | Credentials |
|---------|-----------|-------------|
| ArgoCD | https://localhost:8080 | admin / `make argocd-password` |
| MinIO | http://localhost:9001 | See `.env.local` |
| LakeFS | http://localhost:8000 | See `.env.local` |
| Dagster | http://localhost:3000 | N/A |
| Marimo | http://localhost:2718 | N/A |

---

## Troubleshooting

### Brev CLI "logged out" error
```bash
brev login  # Re-authenticate
```

### kubectl connection refused
```bash
# Make sure SSH tunnel is running
make ssh-tunnel-bg
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

### SOPS decryption fails
```bash
# Ensure Age key file is set
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt

# Test decryption
sops -d k8s/apps/minio/secrets.enc.yaml
```

### K3S node not ready
```bash
# SSH into instance and check
make shell
sudo kubectl get nodes
sudo systemctl status k3s
sudo journalctl -u k3s -f
```

### GPU not visible in Kubernetes
```bash
# Check NVIDIA device plugin
kubectl get pods -n kube-system | grep nvidia
kubectl logs -n kube-system daemonset/nvidia-device-plugin-daemonset

# Check node resources
kubectl describe node | grep nvidia.com/gpu
```

---

## Repository Structure

```
brev-data-platform/
├── k8s/                    # Kubernetes manifests
│   ├── bootstrap/          # ArgoCD installation
│   └── apps/               # Application Helm charts
│       ├── argocd-apps/    # App-of-apps definitions
│       ├── minio/          # MinIO chart + secrets
│       ├── lakefs/         # LakeFS chart + secrets
│       ├── dagster/        # Dagster chart + secrets
│       ├── marimo/         # Marimo chart + secrets
│       └── nvidia-ai/      # NIM + Safe Synth + secrets
├── dagster/                # Pipeline code
│   ├── assets/             # Dagster assets
│   ├── io_managers/        # Custom I/O managers
│   ├── resources/          # Dagster resources
│   └── tests/              # Tests
├── marimo/                 # Notebooks
│   └── notebooks/          # Marimo notebook files
├── scripts/                # Automation scripts
│   ├── bootstrap-k3s.sh    # K3S + NVIDIA setup
│   ├── bootstrap-argocd.sh # ArgoCD installation
│   ├── setup-kubeconfig.sh # Kubeconfig fetch
│   ├── create-secrets.sh   # SOPS secret generation
│   └── apply-secrets.sh    # Apply secrets to cluster
├── config/                 # Service configurations
│   ├── nim/                # NIM LLM config
│   └── safe-synthesizer/   # Safe Synth config
├── docs/                   # Documentation
│   ├── plans/              # Development plans
│   └── invariants/         # Architectural constraints
├── .sops.yaml              # SOPS encryption config
├── .env.example            # Environment template
├── .env.local              # Your credentials (git-ignored)
├── Makefile                # All commands
└── kubeconfig.yaml         # K8s config (git-ignored)
```

---

## Security

- All secrets encrypted with SOPS + Age (committed to git safely)
- NGC API keys stored as Kubernetes secrets
- No plaintext credentials in repository
- Services accessible only via SSH tunnel + port-forward (no public ingress)
- Age private key stored only on your local machine

---

## Documentation

- [Development Plan](docs/plans/active/grand_plan/development-plan.md) - Implementation roadmap
- [Invariants](docs/invariants/INVARIANTS.md) - Architectural constraints
- [Planning Protocol](docs/plans/CLAUDE.md) - How we plan features

---

## License

Proprietary - Internal Use Only
