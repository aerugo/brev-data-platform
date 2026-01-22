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
| **Marimo** | Interactive Python notebooks |
| **NVIDIA NIM** | LLM inference |
| **Safe Synthesizer** | Synthetic data generation |
| **Prometheus/Grafana/Loki** | Observability, GPU metrics & logging |

---

## Quick Start

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

### Step 4: Create A100 Instance (Web Console Required)

> **Important**: The Brev CLI only supports GCP which lacks A100 availability. You must create the instance via the web console.

1. Go to [https://brev.nvidia.com](https://brev.nvidia.com)
2. Select your organization
3. Click **GPUs** → Select **A100 • 80 GiB VRAM** from **CRUSOE** provider
   - Recommended: CRUSOE offers flexible storage, stop/start without data loss
   - Instance type: `a100-80gb.1x` (~$1.98/hr)
4. Configure:
   - **Disk Storage**: 256 GiB
   - **Software**: VM Mode w/ Jupyter
   - **Name**: `brev-data-platform-dev`
5. Click **Deploy** and wait for "Running" status (~7 minutes)

### Step 5: Run Automated Setup

Once your instance is running:

```bash
make setup
```

This interactive script will:
- Prompt for instance name (or auto-detect)
- Bootstrap RKE2 with GPU support
- Fetch kubeconfig to your local machine
- Setup SSH tunnel for kubectl access
- Verify cluster connectivity and GPU availability

### Step 6: Deploy KAI Scheduler

```bash
# Ensure SSH tunnel is running (in a separate terminal)
make ssh-tunnel

# Deploy KAI Scheduler for GPU workloads
make bootstrap-kai

# Verify KAI Scheduler (7 pods should be running)
kubectl get pods -n kai-scheduler
```

### Step 7: Create Secrets from .env.local

Before deploying applications, create the required secrets:

```bash
# 1. Copy and configure environment file
cp .env.example .env.local
# Edit .env.local with your credentials

# 2. Create secrets manually (if you don't have the SOPS Age key)
source .env.local

# MinIO credentials
kubectl create ns minio
kubectl create secret generic minio-credentials -n minio \
  --from-literal=rootUser="$MINIO_ROOT_USER" \
  --from-literal=rootPassword="$MINIO_ROOT_PASSWORD"

# LakeFS credentials (needs MinIO creds + auth key)
kubectl create ns lakefs
kubectl create secret generic minio-credentials -n lakefs \
  --from-literal=rootUser="$MINIO_ROOT_USER" \
  --from-literal=rootPassword="$MINIO_ROOT_PASSWORD"
kubectl create secret generic lakefs-credentials -n lakefs \
  --from-literal=auth_encrypt_secret_key="$(openssl rand -base64 32)"

# ArgoCD GitHub repo access (for private repos)
kubectl create ns argocd
kubectl create secret generic repo-creds -n argocd \
  --from-literal=url=https://github.com/aerugo/brev-data-platform.git \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_PAT" \
  -l argocd.argoproj.io/secret-type=repository
```

> **Note**: If you have the SOPS Age key configured, you can use `make apply-secrets` instead.

### Step 8: Deploy ArgoCD

```bash
# Install ArgoCD
make bootstrap-argocd

# Wait for ArgoCD pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s

# Get ArgoCD password
make argocd-password

# Access ArgoCD UI (in another terminal)
make port-forward-argocd
# Open https://localhost:8080, login with admin/<password>
```

### Step 9: Verify Installation

```bash
# Check cluster
kubectl get nodes
kubectl describe node | grep nvidia.com/gpu

# Check all pods
kubectl get pods -A

# Check ArgoCD applications
kubectl get applications -n argocd

# Expected: All apps should show Synced/Healthy
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
| 7 | Monitoring | 🔲 Pending | Prometheus/Grafana/Loki |
| 8 | Dagster | 🔲 Pending | Pipeline orchestration |
| 8 | Marimo | 🔲 Pending | Notebooks |
| 9 | NVIDIA NIM | 🔲 Pending | LLM inference |
| 9 | Safe Synthesizer | 🔲 Pending | Synthetic data |

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
brev start brev-data-platform-dev

# 2. Setup SSH tunnel
make ssh-tunnel

# 3. Set kubeconfig
export KUBECONFIG=~/.kube/config-brev-data-platform-dev
```

### Stop to Save Costs

```bash
# Stop instance when not in use (CRUSOE instances retain data)
brev stop brev-data-platform-dev
```

### Access Services

All services are accessed via kubectl port-forward through SSH tunnel:

```bash
# Terminal 1: Keep SSH tunnel running
make ssh-tunnel

# Terminal 2: Port forward to service
export KUBECONFIG=~/.kube/config-brev-data-platform-dev
make port-forward-argocd
```

| Service | Command | Local URL | Credentials |
|---------|---------|-----------|-------------|
| ArgoCD | `make port-forward-argocd` | https://localhost:8080 | admin / `make argocd-password` |
| MinIO | `make port-forward-minio` | http://localhost:9001 | See `.env.local` |
| LakeFS | `make port-forward-lakefs` | http://localhost:8000 | See `.env.local` |
| Dagster | `make port-forward-dagster` | http://localhost:3000 | N/A |
| Marimo | `make port-forward-marimo` | http://localhost:2718 | N/A |
| Grafana | `make port-forward-grafana` | http://localhost:3001 | admin / `make grafana-password` |
| Prometheus | `make port-forward-prometheus` | http://localhost:9090 | N/A |

---

## Commands Reference

```bash
make help                    # Show all commands

# Instance Management
make setup                   # Interactive setup (recommended for first time)
make create-instance-help    # Show web console instructions for A100
make stop-instance           # Stop instance (saves cost)
make start-instance          # Start stopped instance
make delete-instance         # Delete instance (DESTRUCTIVE)
make shell                   # SSH into instance
make status                  # Show instance status

# Kubernetes Setup
make bootstrap-rke2          # Install RKE2 + NVIDIA on instance
make bootstrap-kai           # Deploy KAI Scheduler
make kubeconfig              # Fetch kubeconfig from instance
make ssh-tunnel              # Start SSH tunnel (foreground)
make apply-secrets           # Apply encrypted secrets to cluster
make bootstrap-argocd        # Install ArgoCD

# Port Forwarding
make port-forward-argocd     # https://localhost:8080
make port-forward-dagster    # http://localhost:3000
make port-forward-minio      # http://localhost:9001
make port-forward-lakefs     # http://localhost:8000
make port-forward-marimo     # http://localhost:2718
make port-forward-grafana    # http://localhost:3001

# Secrets
make create-secrets          # Generate encrypted secrets from .env.local
make edit-secret FILE=...    # Edit encrypted secret in place

# Passwords
make argocd-password         # Get ArgoCD admin password
make grafana-password        # Get Grafana admin password

# Validation
make lint                    # Lint Helm and Python
make validate                # Validate configurations
```

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
│  │  │   Marimo    │    │      NVIDIA AI Enterprise (KAI-scheduled)│    ││
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
│       ├── marimo/             # Marimo notebooks
│       ├── monitoring/         # Prometheus, Grafana, Loki
│       ├── nvidia-nim/         # NIM LLM inference
│       └── nvidia-safe-synth/  # Safe Synthesizer
├── dagster/                    # Pipeline code
│   ├── assets/                 # Dagster assets
│   ├── io_managers/            # Custom I/O managers
│   └── resources/              # Dagster resources
├── marimo/                     # Notebooks
│   └── notebooks/              # Marimo notebook files
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
