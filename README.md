# Brev Data Platform

GPU-accelerated data platform on NVIDIA Brev with RKE2, KAI Scheduler, ArgoCD, Dagster, LakeFS, MinIO, and NVIDIA AI Enterprise.

## Overview

This repository contains Infrastructure as Code (IaC) for deploying a complete data platform stack:

| Component | Purpose |
|-----------|---------|
| **RKE2** | Enterprise Kubernetes (Run:AI compatible) |
| **KAI Scheduler** | GPU workload scheduling (fractional GPU, gang scheduling) |
| **ArgoCD** | GitOps continuous deployment |
| **MinIO** | S3-compatible object storage |
| **LakeFS** | Git-like data versioning |
| **Dagster** | Data pipeline orchestration |
| **JupyterHub + Marimo** | Multi-user interactive notebooks |
| **NVIDIA NIM** | LLM inference |
| **Safe Synthesizer** | Synthetic data generation |
| **Prometheus/Grafana/Loki** | Observability, GPU metrics & logging |

---

## Quick Start

### Step 0: Clone Repository with Submodules

```bash
# Clone with all submodules
git clone --recurse-submodules https://github.com/aerugo/brev-data-platform.git
cd brev-data-platform

# Or if already cloned without submodules:
git submodule update --init --recursive
```

**Submodules included:**
| Submodule | Path | Description |
|-----------|------|-------------|
| [brev-dagster-pipelines](https://github.com/aerugo/brev-dagster-pipelines) | `dagster/` | Dagster pipeline code (assets, resources, I/O managers) |
| [jupyterhub-singleuser](https://github.com/aerugo/jupyterhub-singleuser) | `docker/jupyterhub-singleuser/` | Custom JupyterHub singleuser image |

### Step 1: Install Required Tools

```bash
# macOS with Homebrew
brew install kubectl helm sops age brevdev/brev/brev

# Verify installations
kubectl version --client   # v1.28+
helm version               # v3.13+
sops --version             # v3.8+
age --version              # v1.1+
brev --version             # v0.6+
```

### Step 2: Login to Brev

```bash
brev login
brev ls  # Verify login
```

### Step 3: Setup Age Encryption Key

```bash
# Create key directory
mkdir -p ~/.config/sops/age

# Generate key pair (if you don't have one)
age-keygen -o ~/.config/sops/age/keys.txt

# Add to shell profile (~/.zshrc or ~/.bashrc)
echo 'export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt' >> ~/.zshrc
source ~/.zshrc
```

### Step 4: Configure Credentials (Before Setup)

```bash
# Copy and configure environment file
cp .env.example .env.local
# Edit .env.local with your credentials (NGC API key, MinIO passwords, etc.)
```

> **Important**: Configure `.env.local` BEFORE running setup so secrets are automatically created.

### Step 5: Run Interactive Setup

```bash
make setup
```

This single command handles the **complete setup**:
1. **Instance creation** - If no instance exists, shows instructions to create one via [brev.nvidia.com](https://brev.nvidia.com)
2. **Instance name** - Prompts for name (default: `brev-data-platform`)
3. **RKE2 bootstrap** - Installs Kubernetes with GPU support
4. **KAI Scheduler** - Deploys GPU workload scheduler
5. **Secrets** - Creates Kubernetes secrets from `.env.local`
6. **ArgoCD** - Installs GitOps controller
7. **App-of-Apps** - Deploys all platform applications
8. **Verification** - Confirms cluster, GPU, and service availability

> **Note**: Instance creation must be done via the Brev web console (CRUSOE A100 80GB or H200 recommended).

### Step 6: Access Services

After setup completes, the script displays all credentials. To access services:

```bash
# Set kubeconfig (shown at end of setup)
export KUBECONFIG=~/.kube/config-brev-data-platform

# Wait for ArgoCD to deploy all applications (~5-10 min)
kubectl get applications -n argocd -w

# Forward all services to localhost
make port-forward-all
```

Then open the services in your browser:
- **ArgoCD**: https://localhost:8080 (admin / password shown in setup)
- **Dagster**: http://localhost:3000
- **JupyterHub**: http://localhost:8000 (any username/password)

### Step 7: Verify Installation

```bash
# Check cluster and GPU
kubectl get nodes
kubectl describe node | grep nvidia.com/gpu

# Check all pods are running
kubectl get pods -A

# Check ArgoCD applications (should show Synced/Healthy)
kubectl get applications -n argocd

# Run full platform validation
make validate-platform
```

---

## Current Status

| Phase | Component | Status | Notes |
|-------|-----------|--------|-------|
| 3 | RKE2 + GPU | ✅ Complete | Enterprise K8s with NVIDIA device plugin |
| 4 | KAI Scheduler | ✅ Complete | v0.12.9 from NVIDIA OCI registry |
| 5 | ArgoCD | ✅ Complete | GitOps with app-of-apps pattern |
| 6 | MinIO | ✅ Complete | 50Gi persistent storage |
| 6 | LakeFS | ✅ Complete | 10Gi persistent storage |
| 7 | Monitoring | ✅ Complete | Prometheus, Grafana, Loki, DCGM Exporter |
| 8 | Dagster | ✅ Complete | Pipeline orchestration with custom user code |
| 8 | JupyterHub + Marimo | ✅ Complete | Multi-user notebooks with custom image ([ghcr.io/aerugo/jupyterhub-singleuser](https://github.com/aerugo/jupyterhub-singleuser)) |
| 9 | NVIDIA NIM | ✅ Complete | Llama 3.1 8B Instruct - OpenAI-compatible API |
| 9 | Safe Synthesizer | ✅ Complete | Scaled to 0 (single GPU constraint - NIM takes priority) |

---

## GPU Requirements

This platform requires **minimum NVIDIA A100 GPU (40GB or 80GB)**. Smaller GPUs like T4 (16GB) are NOT supported due to:

- NIM LLM memory requirements
- Safe Synthesizer memory requirements
- KAI Scheduler fractional GPU features

See [INVARIANTS.md](docs/invariants/INVARIANTS.md#inv-i003-minimum-a100-gpu-required) for details.

---

## Daily Usage

### Start Your Session

```bash
# 1. Start instance (if stopped)
brev start brev-data-platform

# 2. Setup SSH tunnel
make ssh-tunnel

# 3. Set kubeconfig
export KUBECONFIG=~/.kube/config-brev-data-platform
```

### Stop to Save Costs

```bash
# Stop instance when not in use (CRUSOE instances retain data)
brev stop brev-data-platform
```

### Access Services

All services are accessed via kubectl port-forward through SSH tunnel:

```bash
# Terminal 1: Start SSH tunnel in background (shows all credentials)
make ssh-tunnel-bg

# Terminal 2: Port forward all services (recommended)
export KUBECONFIG=~/.kube/config-brev-data-platform
make port-forward-all
```

**View all credentials at any time:**
```bash
make all-credentials
```

| Service | Local URL | Credentials |
|---------|-----------|-------------|
| ArgoCD | https://localhost:8080 | admin / `make argocd-password` |
| JupyterHub | http://localhost:8000 | Any username / any password |
| Dagster | http://localhost:3000 | N/A |
| LakeFS | http://localhost:8001 | `make lakefs-credentials` |
| MinIO | http://localhost:9001 | `make minio-credentials` |
| NIM LLM | http://localhost:8002 | N/A (OpenAI-compatible API) |
| Grafana | http://localhost:3001 | admin / `make grafana-password` |
| Prometheus | http://localhost:9090 | N/A |

---

## Commands Reference

```bash
make help                    # Show all commands

# Setup & Instance Management
make setup                   # Interactive setup (guides through everything)
make stop-instance           # Stop instance (saves cost)
make start-instance          # Start stopped instance
make delete-instance         # Delete instance (DESTRUCTIVE)
make shell                   # SSH into instance
make status                  # Show instance status
make down                    # Alias for stop-instance
make destroy                 # Alias for delete-instance

# Kubernetes Setup (usually run via make setup)
make bootstrap-rke2          # Install RKE2 + NVIDIA on instance
make bootstrap-kai           # Deploy KAI Scheduler
make kubeconfig              # Fetch kubeconfig from instance
make ssh-tunnel              # Start SSH tunnel (foreground, shows service info)
make ssh-tunnel-bg           # Start SSH tunnel (background, shows credentials)
make apply-secrets           # Apply encrypted secrets to cluster
make bootstrap-argocd        # Install ArgoCD

# Port Forwarding
make port-forward-all        # Forward all services (recommended)
make port-forward-argocd     # https://localhost:8080
make port-forward-jupyterhub # http://localhost:8000
make port-forward-dagster    # http://localhost:3000
make port-forward-lakefs     # http://localhost:8001
make port-forward-minio      # http://localhost:9001
make port-forward-nim        # http://localhost:8002
make port-forward-grafana    # http://localhost:3001

# Validation
make validate-platform       # Full platform validation (recommended)
make validate-quick          # Quick K8s health check
make validate-k8s            # K8s validation only (no Dagster)

# Secrets
make create-secrets          # Generate encrypted secrets from .env.local
make edit-secret FILE=...    # Edit encrypted secret in place

# Credentials
make all-credentials         # Show all service URLs and credentials
make argocd-password         # Get ArgoCD admin password
make grafana-password        # Get Grafana admin password
make minio-credentials       # Get MinIO root user/password
make lakefs-credentials      # Get LakeFS access key/secret

# Linting
make lint                    # Lint Helm and Python
make validate                # Validate configurations
```

---

## JupyterHub

JupyterHub provides multi-user notebook environments with a custom singleuser image:

**Image:** `ghcr.io/aerugo/jupyterhub-singleuser:latest`
**Source:** https://github.com/aerugo/jupyterhub-singleuser (submodule in `docker/jupyterhub-singleuser/`)

### Pre-installed Libraries

| Category | Libraries |
|----------|-----------|
| **Notebooks** | Marimo, JupyterLab with Marimo extension |
| **Data Science** | pandas, polars, numpy, scipy, scikit-learn |
| **Visualization** | matplotlib, seaborn, plotly |
| **Data Processing** | duckdb, pyarrow, sqlalchemy |
| **ML/AI** | PyTorch (CPU), transformers, openai, anthropic |
| **Storage** | boto3, s3fs, lakefs-client |

### User Profiles

| Profile | Resources | Use Case |
|---------|-----------|----------|
| **Standard (CPU only)** | 2 CPU, 4GB RAM | Data analysis, light workloads |
| **GPU Server** | 2 CPU, 8GB RAM, 1x GPU | ML training via KAI Scheduler |

### Environment Variables

Singleuser pods have MinIO and LakeFS credentials injected:
- `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`
- `LAKEFS_ENDPOINT`, `LAKEFS_ACCESS_KEY_ID`, `LAKEFS_SECRET_ACCESS_KEY`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    NVIDIA BREV INSTANCE (A100 80GB)                     │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │                    RKE2 + ArgoCD + KAI Scheduler                    ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐            ││
│  │  │   Dagster   │───▶│   LakeFS    │◀───│    MinIO     │            ││
│  │  │  Pipelines  │    │  Versioning │    │   Storage    │            ││
│  │  └─────────────┘    └─────────────┘    └──────────────┘            ││
│  │         │                  │                   ▲                    ││
│  │         ▼                  ▼                   │                    ││
│  │  ┌─────────────┐    ┌─────────────────────────────────────────┐    ││
│  │  │ JupyterHub  │    │      NVIDIA AI Enterprise (KAI-scheduled)│    ││
│  │  │  Notebooks  │───▶│  ┌─────────┐  ┌──────────────┐          │    ││
│  │  └─────────────┘    │  │ NIM LLM │  │Safe Synthesize│          │    ││
│  │                     │  │         │  │              │          │    ││
│  │                     │  └─────────┘  └──────────────┘          │    ││
│  │                     └─────────────────────────────────────────┘    ││
│  │                                                                     ││
│  │  ┌─────────────────────────────────────────────────────────────┐   ││
│  │  │            Observability (Prometheus/Grafana/Loki)          │   ││
│  │  │  ┌──────────┐  ┌─────────┐  ┌──────┐  ┌──────────────┐     │   ││
│  │  │  │Prometheus│  │ Grafana │  │ Loki │  │DCGM Exporter │     │   ││
│  │  │  └──────────┘  └─────────┘  └──────┘  └──────────────┘     │   ││
│  │  └─────────────────────────────────────────────────────────────┘   ││
│  └─────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Secrets Management

All secrets are encrypted with SOPS + Age before committing to git.

### Initial Setup (One Time)

```bash
# 1. Create .env.local from template
cp .env.example .env.local

# 2. Edit with your credentials
#    - NGC_API_KEY: Get from https://ngc.nvidia.com/setup/api-key
#    - MINIO_ROOT_PASSWORD: Generate with `openssl rand -base64 24`
#    - LAKEFS keys: Generate with commands in .env.example

# 3. Generate encrypted secrets
make create-secrets

# 4. Update .sops.yaml with your Age public key
grep "public key:" ~/.config/sops/age/keys.txt
# Edit .sops.yaml and replace the age: value
```

### Editing Secrets

```bash
# Edit an encrypted secret file
make edit-secret FILE=k8s/apps/minio/secrets.enc.yaml

# Re-encrypt all secrets (after changing Age key)
make create-secrets
```

---

## CI/CD Setup

GitHub Actions workflows provide continuous integration and delivery.

### GitHub Repository Secrets

Add the following secrets to enable CI workflows:

**Via CLI (recommended):**
```bash
# Add SOPS Age key for secret validation
gh secret set SOPS_AGE_KEY < ~/.config/sops/age/keys.txt
```

**Via GitHub UI:**
1. Go to: Repository → Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Add:
   | Secret Name | Value | Purpose |
   |-------------|-------|---------|
   | `SOPS_AGE_KEY` | Contents of `~/.config/sops/age/keys.txt` | Decrypt secrets in CI |

### Enable GHCR Permissions

Enable GitHub Actions to push container images to GitHub Container Registry:

**Via CLI:**
```bash
# Enable read/write permissions for workflows
gh api repos/OWNER/REPO/actions/permissions/workflow \
  -X PUT \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true
```

**Via GitHub UI:**
1. Go to: Repository → Settings → Actions → General
2. Under "Workflow permissions", select:
   - [x] Read and write permissions
   - [x] Allow GitHub Actions to create and approve pull requests (optional)
3. Click Save

### Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `pr-checks.yml` | Pull request to main | Helm lint, secrets check, Dagster lint/test |
| `dagster-build.yml` | Push to main (dagster/) | Build & push Dagster image to GHCR |
| `validate-secrets.yml` | Changes to `*.enc.yaml` | Verify SOPS encryption is valid |

### Branch Protection (Recommended)

1. Go to: Repository → Settings → Branches → Add rule
2. Branch name pattern: `main`
3. Enable:
   - [x] Require a pull request before merging
   - [x] Require status checks to pass before merging
     - Select: `helm-lint`, `secrets-check`, `dagster-check`
   - [x] Require branches to be up to date before merging

---

## Troubleshooting

### Brev CLI "logged out" error
```bash
brev login  # Re-authenticate
```

### kubectl connection refused
```bash
# Make sure SSH tunnel is running
make ssh-tunnel

# In another terminal, set kubeconfig
export KUBECONFIG=~/.kube/config

# Test connection
kubectl get nodes
```

### SOPS decryption fails
```bash
# Ensure Age key file is set
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt

# Test decryption
sops -d k8s/apps/minio/secrets/secrets.enc.yaml
```

### RKE2 node not ready
```bash
# SSH into instance and check
make shell
sudo systemctl status rke2-server
sudo journalctl -u rke2-server -f
```

### GPU not visible in Kubernetes
```bash
# Check NVIDIA device plugin
kubectl get pods -n kube-system | grep nvidia
kubectl logs -n kube-system -l app=nvidia-device-plugin-daemonset

# Check node resources
kubectl describe node | grep nvidia.com/gpu
```

### ArgoCD sync fails with "ENC[AES256..." error
ArgoCD is trying to apply SOPS-encrypted files as Kubernetes manifests.
Encrypted secrets should be in `secrets/` subdirectories with `.argoignore` files.
```bash
# Check .argoignore exists
cat k8s/apps/minio/.argoignore
# Should contain: secrets/ and *.enc.yaml
```

### MinIO fails with "couldn't find key rootUser"
The secret was created with wrong key names. MinIO expects `rootUser` and `rootPassword` (camelCase):
```bash
kubectl delete secret minio-credentials -n minio
kubectl create secret generic minio-credentials -n minio \
  --from-literal=rootUser="admin" \
  --from-literal=rootPassword="your-password"
```

### LakeFS fails with "couldn't find key auth_encrypt_secret_key"
```bash
kubectl create secret generic lakefs-credentials -n lakefs \
  --from-literal=auth_encrypt_secret_key="$(openssl rand -base64 32)"
```

### Instance creation fails in CLI
```bash
# The CLI only supports GCP which has limited GPU availability
# Use the web console instead: https://brev.nvidia.com
make create-instance-help
```

---

## Repository Structure

```
brev-data-platform/
├── k8s/                        # Kubernetes manifests
│   ├── bootstrap/              # Bootstrap configurations
│   │   └── argocd/             # ArgoCD Helm values + app-of-apps
│   └── apps/                   # Application Helm charts
│       ├── argocd-apps/        # App-of-apps definitions (ArgoCD Applications)
│       │   ├── templates/      # Individual app definitions
│       │   └── secrets/        # SOPS encrypted secrets
│       ├── kai-scheduler/      # KAI GPU Scheduler wrapper
│       ├── minio/              # MinIO S3 storage
│       │   ├── secrets/        # SOPS encrypted secrets
│       │   └── .argoignore     # Excludes secrets from ArgoCD
│       ├── lakefs/             # LakeFS data versioning
│       │   ├── templates/      # PVC for persistence
│       │   └── secrets/        # SOPS encrypted secrets
│       ├── dagster/            # Dagster pipelines
│       ├── jupyterhub/         # JupyterHub with Marimo
│       ├── monitoring/         # Prometheus, Grafana, Loki
│       ├── nvidia-nim/         # NIM LLM inference
│       └── nvidia-safe-synth/  # Safe Synthesizer
├── dagster/                    # Git submodule: github.com/aerugo/brev-dagster-pipelines
│   ├── src/brev_pipelines/     # Dagster assets, resources, I/O managers
│   └── .github/workflows/      # CI/CD for Docker image build
├── docker/                     # Docker images
│   └── jupyterhub-singleuser/  # Git submodule: github.com/aerugo/jupyterhub-singleuser
├── scripts/                    # Automation scripts
│   ├── setup-instance.sh       # Interactive setup (make setup)
│   ├── bootstrap-rke2.sh       # RKE2 + NVIDIA installation
│   ├── bootstrap-argocd.sh     # ArgoCD installation
│   ├── setup-kubeconfig.sh     # Fetch kubeconfig from instance
│   ├── create-secrets.sh       # SOPS secret generation
│   └── apply-secrets.sh        # Apply secrets to cluster
├── config/                     # Service configurations
│   ├── nim/                    # NIM LLM config
│   └── safe-synthesizer/       # Safe Synth config
├── docs/                       # Documentation
│   ├── plans/                  # Development plans
│   └── invariants/             # Architectural constraints
├── .sops.yaml                  # SOPS encryption config
├── .env.example                # Environment template
├── .env.local                  # Your credentials (git-ignored)
└── Makefile                    # All commands
```

---

## Documentation

- [Development Plan](docs/plans/active/grand_plan/development-plan.md) - Implementation roadmap
- [Invariants](docs/invariants/INVARIANTS.md) - Architectural constraints
- [Phase 3: Instance Setup](docs/plans/active/grand_plan/phases/phase-3.md) - Detailed setup guide

---

## Security

- All secrets encrypted with SOPS + Age (committed to git safely)
- NGC API keys stored as Kubernetes secrets
- No plaintext credentials in repository
- Services accessible only via SSH tunnel + port-forward (no public ingress)
- Age private key stored only on your local machine

---

## License

Proprietary - Internal Use Only
