# Brev Data Platform - Development Plan

**Status**: In Progress
**Created**: 2026-01-21
**Updated**: 2026-01-21
**Branch**: `main`
**Spec**: [spec.md](spec.md)

## Summary

Deploy a complete GPU-accelerated data platform on NVIDIA Brev, including RKE2 Kubernetes cluster, KAI Scheduler for GPU workloads, ArgoCD GitOps, Dagster pipelines, LakeFS/MinIO storage, observability stack, Marimo notebooks, and NVIDIA AI Enterprise services (NIM LLM + Safe Synthesizer).

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md`:

- **INV-I004**: Cloud-init for RKE2 bootstrap - RKE2 must be installed via cloud-init or bootstrap script
- **INV-K001**: Namespace per application - Each service gets its own namespace
- **INV-K002**: Resource limits on all pods - No unbounded resource consumption
- **INV-K003**: GPU resources explicitly requested - NIM/Safe Synth must request `nvidia.com/gpu`
- **INV-K005**: No `latest` image tags - All images use specific versions
- **INV-S001**: No plaintext secrets in Git - All secrets SOPS encrypted
- **INV-S002**: SOPS configuration in repository root - `.sops.yaml` must exist
- **INV-S003**: NGC API key as Kubernetes secret - Never in plain ConfigMaps
- **INV-G001**: App-of-apps pattern for ArgoCD - Single entry point for all applications
- **INV-G003**: Source of truth is Git - No manual kubectl changes

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-I005**: Brev instance naming convention - Instance must be named `brev-data-platform-dev`
- **NEW INV-K006**: Sync wave ordering - Bootstrap/KAI (0) → Storage/Observability (1) → Platform (2) → AI (3)
- **NEW INV-K007**: KAI Scheduler for GPU workloads - All GPU pods must use `schedulerName: kai-scheduler`
- **NEW INV-K008**: RKE2 as Kubernetes distribution - Required for Run:AI compatibility
- **NEW INV-O001**: GPU metrics via DCGM Exporter - All GPU workloads must be observable
- **NEW INV-O002**: Centralized logging - All pod logs aggregated to Loki

## Current State Analysis

The repository has foundational structure with implementation in progress:

```
brev-data-platform/
├── .CLAUDE.md                  ✓ Created
├── .claude/
│   ├── agents/                 ✓ 8 agents created
│   └── skills/brev/            ✓ Brev CLI skill created
├── docs/
│   ├── plans/                  ✓ Planning protocol
│   └── invariants/             ✓ Invariants documented
├── k8s/
│   ├── bootstrap/argocd/       ✓ ArgoCD setup
│   └── apps/                   ✓ Helm charts created
├── dagster/                    ✓ Scaffold created
├── marimo/                     ✓ Directory created
├── scripts/
│   ├── bootstrap-rke2.sh       ✓ RKE2 bootstrap
│   ├── cloud-init/rke2-gpu.yaml ✓ Cloud-init script
│   └── setup-kubeconfig.sh     ✓ Kubeconfig fetch
├── .github/workflows/          ✗ Not created
├── .sops.yaml                  ✓ Created
├── .env.example                ✓ Created
└── Makefile                    ✓ Created
```

## Solution Design

### Deployment Flow

```
Phase 0: Prerequisites & Manual Setup
         ↓
Phase 1: Repository Structure
         ↓
Phase 2: Secrets & Encryption Setup
         ↓
Phase 3: Brev Instance Creation + RKE2
         ↓
Phase 4: KAI Scheduler (GPU Scheduling)
         ↓
Phase 5: ArgoCD Bootstrap
         ↓
Phase 6: Storage Layer (MinIO + LakeFS)
         ↓
Phase 7: Observability Stack (Prometheus, Grafana, Loki, DCGM)
         ↓
Phase 8: Data Platform (Dagster + JupyterHub)
         ↓
Phase 9: NVIDIA AI Enterprise (with KAI Scheduling)
         ↓
Phase 10: CI/CD Workflows
         ↓
Phase 10.1: Dagster Pipelines Repository
         ↓
Phase 11: Sample Pipeline & Validation
```

### Key Design Decisions

1. **Brev CLI over Terraform**: Simpler setup, already authenticated, faster iteration
2. **RKE2 over K3S**: Run:AI compatible, FIPS compliant, enterprise-ready
3. **KAI Scheduler**: Open-source GPU scheduler for fractional GPUs, gang scheduling
4. **Cloud-init for RKE2**: Reproducible, automated installation on instance creation
5. **Port-forward for access**: No ingress complexity, secure by default
6. **App-of-apps pattern**: Single ArgoCD Application manages all services
7. **Sync waves**: Ensures dependencies deploy in correct order (KAI first)
8. **PLG Stack (Prometheus/Loki/Grafana)**: Standard observability stack with DCGM for GPU metrics

## Phase Overview

| Phase | Description | Type | Deliverables | Manual Steps |
|-------|-------------|------|--------------|--------------|
| 0 | Prerequisites & Manual Setup | Setup | Accounts, API keys, local tools | Yes - many |
| 1 | Repository Structure | Infrastructure | Directory scaffold, Makefile | No |
| 2 | Secrets & Encryption Setup | Security | SOPS config, Age keys, .env files | Yes - key generation |
| 3 | Brev Instance + RKE2 | Infrastructure | Running RKE2 cluster with GPU | Yes - instance creation |
| 4 | KAI Scheduler | Kubernetes | GPU scheduling enabled | No |
| 5 | ArgoCD Bootstrap | Kubernetes | ArgoCD deployed and configured | No |
| 6 | Storage Layer | Kubernetes | MinIO + LakeFS running | No |
| 7 | Observability Stack | Monitoring | Prometheus, Grafana, Loki, DCGM Exporter | No |
| 8 | Data Platform | Application | Dagster + JupyterHub/Marimo running | No |
| 9 | NVIDIA AI Enterprise | Application | NIM + Safe Synthesizer (KAI scheduled) | No |
| 10 | CI/CD Workflows | Integration | GitHub Actions configured | Yes - GitHub secrets |
| 10.1 | Dagster Pipelines Repository | Application | Separate repo, custom Docker image | Yes - create repo |
| 11 | Sample Pipeline | Validation | End-to-end demo working | No |

---

## Phase 0: Prerequisites & Manual Setup

**Goal**: Ensure all accounts, credentials, and local tools are ready
**Type**: Setup (Manual)
**Detailed Plan**: [phases/phase-0.md](phases/phase-0.md)

### Manual Steps Required

#### 1. Verify Brev Account & CLI

```bash
# Check Brev login status
brev ls

# If not logged in:
brev login
```

#### 2. Create NVIDIA NGC Account & Get API Key

1. Go to https://ngc.nvidia.com
2. Sign up or log in
3. Go to **Setup** → **API Key**
4. Click **Generate API Key**
5. Save the key securely (starts with `nvapi-`)

#### 3. Verify NVIDIA AI Enterprise Access

1. In NGC, go to **Catalog** → **Models**
2. Search for "gpt-oss" or available NIM models
3. Verify you have access (may require AI Enterprise license)

#### 4. Create GitHub Repository (if not exists)

1. Go to https://github.com/new
2. Create repository `brev-data-platform`
3. Set visibility (private recommended)
4. Do NOT initialize with README (we have content)

#### 5. Generate GitHub Personal Access Token

1. Go to https://github.com/settings/tokens
2. Click **Generate new token (classic)**
3. Select scopes: `repo`, `read:packages`
4. Save the token securely

#### 6. Install Local Tools

```bash
# macOS with Homebrew
brew install kubectl helm sops age

# Verify installations
kubectl version --client
helm version
sops --version
age --version
```

### Deliverables

- [ ] Brev CLI logged in and working
- [ ] NGC API Key saved securely
- [ ] NGC account has NIM model access
- [ ] GitHub repository created
- [ ] GitHub PAT generated
- [ ] Local tools installed (kubectl, helm, sops, age)

### Success Criteria

- [ ] `brev ls` returns without error
- [ ] NGC API Key starts with `nvapi-`
- [ ] `kubectl version --client` shows 1.28+
- [ ] `helm version` shows 3.13+
- [ ] `sops --version` shows 3.8+
- [ ] `age --version` shows 1.1+

---

## Phase 1: Repository Structure

**Goal**: Create the full directory structure and Makefile
**Type**: Infrastructure
**Detailed Plan**: [phases/phase-1.md](phases/phase-1.md)

### Deliverables

1. Full directory structure per `.CLAUDE.md`
2. `Makefile` with all commands
3. `.gitignore` for sensitive files
4. `.env.example` documenting required variables
5. `README.md` with quick start

### Files to Create

| File/Directory | Purpose |
|----------------|---------|
| `scripts/cloud-init/rke2-gpu.yaml` | RKE2 + GPU bootstrap script |
| `scripts/bootstrap-rke2.sh` | Manual RKE2 bootstrap |
| `scripts/setup-kubeconfig.sh` | Fetch kubeconfig from Brev |
| `k8s/bootstrap/` | ArgoCD initial setup |
| `k8s/apps/` | Application Helm charts |
| `k8s/apps/kai-scheduler/` | KAI Scheduler chart |
| `dagster/` | Pipeline code scaffold |
| `marimo/` | Notebooks directory |
| `config/` | Service configurations |
| `Makefile` | Developer commands |
| `.gitignore` | Ignore patterns |
| `.env.example` | Environment template |

### Validation Approach

```bash
# Verify structure
find . -type d | head -30

# Verify Makefile
make help
```

### Success Criteria

- [ ] All directories created
- [ ] Makefile has all documented commands
- [ ] `.gitignore` excludes sensitive files
- [ ] `.env.example` documents all variables

---

## Phase 2: Secrets & Encryption Setup

**Goal**: Configure SOPS + Age encryption and create encrypted secrets
**Type**: Security
**Detailed Plan**: [phases/phase-2.md](phases/phase-2.md)

### Manual Steps Required

#### 1. Generate Age Key Pair

```bash
# Create directory for age keys
mkdir -p ~/.config/sops/age

# Generate key pair
age-keygen -o ~/.config/sops/age/keys.txt

# Display public key (needed for .sops.yaml)
age-keygen -y ~/.config/sops/age/keys.txt
```

#### 2. Create Local Environment File

Create `.env.local` (git-ignored) with your credentials:

```bash
# .env.local - DO NOT COMMIT
NGC_API_KEY=nvapi-xxxxxxxxxxxxxxxxxxxx
GITHUB_PAT=ghp_xxxxxxxxxxxxxxxxxxxx
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=<generate-strong-password>
LAKEFS_ACCESS_KEY_ID=<generate>
LAKEFS_SECRET_ACCESS_KEY=<generate>
```

### Deliverables

1. `.sops.yaml` with Age public key
2. Age key pair in `~/.config/sops/age/keys.txt`
3. `.env.local` with all credentials (git-ignored)
4. `k8s/apps/*/secrets.enc.yaml` encrypted secret files
5. `scripts/encrypt-secret.sh` helper script

### Validation Approach

```bash
# Verify SOPS can encrypt
echo "test: value" | sops -e --input-type yaml /dev/stdin

# Verify SOPS can decrypt
sops -d k8s/apps/minio/secrets.enc.yaml
```

### Success Criteria

- [ ] Age key pair exists locally
- [ ] `.sops.yaml` has correct public key
- [ ] Can encrypt and decrypt test file
- [ ] All secret files end with `.enc.yaml`
- [ ] `git status` shows no unencrypted secrets

---

## Phase 3: Brev Instance + RKE2

**Goal**: Create GPU instance and bootstrap RKE2 cluster
**Type**: Infrastructure
**Detailed Plan**: [phases/phase-3.md](phases/phase-3.md)

### Manual Steps Required

#### 1. Create Brev Instance

```bash
# Create GPU instance (H200 recommended)
make create-instance
# Or: brev create brev-data-platform-dev -g "gpu-h200-sxm.1gpu-16vcpu-200gb"

# Wait for instance to be ready
brev ls
```

#### 2. Bootstrap RKE2

```bash
# Run bootstrap script
make bootstrap-rke2

# Or manually:
brev shell brev-data-platform-dev
sudo /tmp/bootstrap-rke2.sh
```

### Deliverables

1. `scripts/bootstrap-rke2.sh` - RKE2 bootstrap script
2. `scripts/cloud-init/rke2-gpu.yaml` - Cloud-init alternative
3. Running Brev instance with RKE2
4. `nvidia-smi` working inside RKE2 pods
5. Kubeconfig retrieved to local machine

### Validation Approach

```bash
# Verify instance running
brev ls

# SSH and check RKE2
brev shell brev-data-platform-dev
kubectl get nodes
nvidia-smi

# From local machine (after kubeconfig setup)
make kubeconfig
make ssh-tunnel-bg
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
kubectl get pods -n kube-system
```

### Success Criteria

- [ ] `brev ls` shows instance running
- [ ] RKE2 node is Ready
- [ ] `nvidia-smi` shows GPU inside instance
- [ ] NVIDIA device plugin pods running
- [ ] Local kubectl can connect via SSH tunnel

---

## Phase 4: KAI Scheduler

**Goal**: Deploy KAI Scheduler for advanced GPU workload scheduling
**Type**: Kubernetes
**Detailed Plan**: [phases/phase-4.md](phases/phase-4.md)

### Deliverables

1. `k8s/apps/kai-scheduler/` - KAI Scheduler Helm chart
2. KAI Scheduler running in `kube-system` namespace
3. GPU workloads can use `schedulerName: kai-scheduler`

### Validation Approach

```bash
# Check KAI Scheduler pods
kubectl get pods -n kube-system -l app=kai-scheduler

# Verify scheduler is working
kubectl get events --field-selector reason=Scheduled | grep kai-scheduler
```

### Success Criteria

- [ ] KAI Scheduler pod running
- [ ] Scheduler registered with API server
- [ ] Can schedule test GPU pod with `schedulerName: kai-scheduler`

---

## Phase 5: ArgoCD Bootstrap

**Goal**: Deploy ArgoCD and configure GitOps
**Type**: Kubernetes
**Detailed Plan**: [phases/phase-5.md](phases/phase-5.md)

### Deliverables

1. `k8s/bootstrap/argocd/` - ArgoCD Helm chart values
2. `k8s/bootstrap/argocd-apps.yaml` - App-of-apps root Application
3. ArgoCD running and accessible
4. Repository connected to ArgoCD

### Validation Approach

```bash
# Port forward ArgoCD
make port-forward-argocd

# Get admin password
make argocd-password

# Access UI at https://localhost:8080
```

### Success Criteria

- [ ] ArgoCD namespace exists
- [ ] ArgoCD server pod running
- [ ] Can access ArgoCD UI via port-forward
- [ ] Repository is connected
- [ ] App-of-apps Application is synced

---

## Phase 6: Storage Layer (MinIO + LakeFS)

**Goal**: Deploy MinIO object storage and LakeFS versioning
**Type**: Kubernetes
**Detailed Plan**: [phases/phase-6.md](phases/phase-6.md)

### Deliverables

1. `k8s/apps/minio/` - MinIO Helm chart
2. `k8s/apps/lakefs/` - LakeFS Helm chart
3. MinIO running with `raw-data` and `data-products` buckets
4. LakeFS connected to MinIO with main repository

### Validation Approach

```bash
# Port forward MinIO console
make port-forward-minio

# Port forward LakeFS
make port-forward-lakefs

# Verify via UI or CLI
```

### Success Criteria

- [ ] MinIO pods running
- [ ] MinIO console accessible
- [ ] Buckets created (`raw-data`, `data-products`, `lakefs`)
- [ ] LakeFS pods running
- [ ] LakeFS connected to MinIO
- [ ] LakeFS repository `main-repo` exists

---

## Phase 7: Observability Stack

**Goal**: Deploy monitoring and logging stack for GPU and application observability
**Type**: Monitoring
**Detailed Plan**: [phases/phase-7.md](phases/phase-7.md)

### Deliverables

1. `k8s/apps/monitoring/` - Observability Helm chart with:
   - Prometheus for metrics collection
   - Grafana for visualization
   - Loki for log aggregation
   - Promtail for log shipping
   - DCGM Exporter for GPU metrics
2. Pre-configured GPU dashboard
3. All services deployed in `monitoring` namespace

### Validation Approach

```bash
# Port forward Grafana
make port-forward-grafana

# Get Grafana password
make grafana-password

# Access at http://localhost:3001
# Check GPU dashboard for H200 metrics
```

### Success Criteria

- [ ] Prometheus running and scraping targets
- [ ] DCGM Exporter collecting GPU metrics
- [ ] Grafana accessible with pre-loaded dashboards
- [ ] Loki receiving logs from all namespaces
- [ ] GPU utilization visible in Grafana

---

## Phase 8: Data Platform (Dagster + JupyterHub)

**Goal**: Deploy Dagster pipeline orchestration and Marimo notebooks
**Type**: Application
**Detailed Plan**: [phases/phase-8.md](phases/phase-8.md)

### Deliverables

1. `k8s/apps/dagster/` - Dagster Helm chart
2. `k8s/apps/marimo/` - Marimo deployment
3. `dagster/` - Pipeline code with LakeFS I/O manager
4. `marimo/` - Sample notebooks

### Validation Approach

```bash
# Port forward Dagster
make port-forward-dagster

# Port forward Marimo
make port-forward-marimo
```

### Success Criteria

- [ ] Dagster webserver running
- [ ] Dagster daemon running
- [ ] Dagster UI shows assets
- [ ] Marimo accessible
- [ ] Can query LakeFS data from Marimo

---

## Phase 9: NVIDIA AI Enterprise

**Goal**: Deploy NIM LLM and Safe Synthesizer with KAI Scheduling
**Type**: Application
**Detailed Plan**: [phases/phase-9.md](phases/phase-9.md)

### Manual Steps Required

Verify NGC credentials are in encrypted secrets:

```bash
# Decrypt and verify NGC key is present
sops -d k8s/apps/nvidia-ai/secrets.enc.yaml | grep NGC_API_KEY
```

### Deliverables

1. `k8s/apps/nvidia-nim/` - NIM LLM Helm chart (with KAI scheduler)
2. `k8s/apps/nvidia-safe-synth/` - Safe Synthesizer Helm chart (with KAI scheduler)
3. `config/nim/` - Model configuration
4. `config/safe-synthesizer/` - Synth configuration
5. Both services running and scheduled via KAI

### Validation Approach

```bash
# Port forward NIM
make port-forward-nim

# Test inference
curl -X POST http://localhost:8001/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-oss-120b", "prompt": "Hello", "max_tokens": 50}'

# Verify KAI scheduling
kubectl get pods -n nvidia-ai -o jsonpath='{.items[*].spec.schedulerName}'
```

### Success Criteria

- [ ] NIM pod running (may take time to download model)
- [ ] NIM scheduled by KAI Scheduler
- [ ] NIM using GPU (`nvidia-smi` shows process)
- [ ] NIM responds to inference requests
- [ ] Safe Synthesizer pod running
- [ ] Safe Synthesizer scheduled by KAI Scheduler
- [ ] Safe Synthesizer can process requests

---

## Phase 10: CI/CD Workflows

**Goal**: Configure GitHub Actions for automation
**Type**: Integration
**Detailed Plan**: [phases/phase-10.md](phases/phase-10.md)

### Manual Steps Required

#### Add GitHub Repository Secrets

Go to GitHub repo → Settings → Secrets and variables → Actions

| Secret Name | Value |
|-------------|-------|
| `SOPS_AGE_KEY` | Contents of `~/.config/sops/age/keys.txt` |

#### Enable GitHub Container Registry

1. Go to repo → Settings → Actions → General
2. Enable "Read and write permissions" for workflows

### Deliverables

1. `.github/workflows/pr-checks.yml` - PR validation
2. `.github/workflows/dagster-build.yml` - Build Dagster image
3. `.github/workflows/helm-lint.yml` - Lint charts
4. Repository secrets configured

### Validation Approach

```bash
# Create test PR
git checkout -b test/ci
echo "# test" >> README.md
git add . && git commit -m "Test CI"
git push -u origin test/ci
# Create PR and verify checks run
```

### Success Criteria

- [ ] PR checks run on pull request
- [ ] Helm lint passes
- [ ] Secrets check passes
- [ ] Dagster build succeeds on merge to main

---

## Phase 11: Sample Pipeline & Validation

**Goal**: Create end-to-end demo pipeline and validate full stack
**Type**: Validation
**Detailed Plan**: [phases/phase-11.md](phases/phase-11.md)

### Deliverables

1. Sample Dagster pipeline that:
   - Ingests data to MinIO
   - Processes via NIM LLM
   - Generates synthetic data via Safe Synthesizer
   - Writes results to LakeFS
2. Marimo notebook demonstrating the workflow
3. Full stack validation checklist

### Validation Approach

```bash
# Trigger pipeline in Dagster UI
# Monitor execution
# Verify data in LakeFS
# Query results in Marimo
```

### Success Criteria

- [ ] Pipeline runs without errors
- [ ] Data visible in LakeFS commits
- [ ] NIM inference results in pipeline
- [ ] Synthetic data generated
- [ ] End-to-end flow documented

---

## Validation Strategy

### Infrastructure Validation

- Brev instance running: `brev ls`
- RKE2 healthy: `kubectl get nodes`
- GPU available: `kubectl describe node | grep nvidia`

### Kubernetes Validation

- All pods running: `kubectl get pods -A`
- No CrashLoopBackOff
- Resource limits respected: `kubectl top pods -A`
- KAI Scheduler working: `kubectl get events | grep kai-scheduler`

### Observability Validation

- Prometheus: Scraping targets, including DCGM
- Grafana: Dashboards loaded, GPU metrics visible
- Loki: Receiving logs from all namespaces
- DCGM Exporter: GPU metrics available

### Application Validation

- Dagster: UI loads, assets visible
- Marimo: Notebooks execute
- NIM: Inference endpoint responds
- Safe Synth: Can generate data

### Integration Validation

- ArgoCD: All apps synced
- GitOps: Push triggers sync
- CI/CD: Workflows execute
- KAI: GPU pods scheduled correctly

---

## Documentation Updates

After implementation is complete:

- [ ] `docs/invariants/INVARIANTS.md` - Add INV-I005, INV-K006, INV-K007, INV-K008
- [ ] `README.md` - Quick start guide
- [ ] `.CLAUDE.md` - Update if conventions changed

---

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 0 | Complete | 2026-01-21 | 2026-01-21 | Manual setup |
| Phase 1 | Complete | 2026-01-21 | 2026-01-21 | Repository structure |
| Phase 2 | Complete | 2026-01-21 | 2026-01-21 | Secrets setup |
| Phase 3 | Complete | 2026-01-21 | 2026-01-21 | Brev + RKE2 |
| Phase 4 | Complete | 2026-01-21 | 2026-01-21 | KAI Scheduler v0.12.9 |
| Phase 5 | Complete | 2026-01-21 | 2026-01-21 | ArgoCD with app-of-apps |
| Phase 6 | Complete | 2026-01-21 | 2026-01-22 | MinIO + LakeFS with persistence |
| Phase 7 | Complete | 2026-01-22 | 2026-01-22 | Prometheus, Grafana, Loki, DCGM |
| Phase 8 | Complete | 2026-01-22 | 2026-01-22 | Dagster + JupyterHub/Marimo |
| Phase 9 | Complete | 2026-01-22 | 2026-01-22 | NVIDIA NIM Llama 3.1 8B |
| Phase 10 | Complete | 2026-01-22 | 2026-01-22 | GitHub Actions CI/CD |
| Phase 10.1 | Complete | 2026-01-22 | 2026-01-22 | Dagster repo + Docker image |
| Phase 11 | Pending | | | Validation |
