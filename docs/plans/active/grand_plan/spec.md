# Feature: Brev Data Platform - Full Stack Deployment

**Status**: Draft
**Created**: 2026-01-21
**Updated**: 2026-01-21
**Category**: Infrastructure + Kubernetes + Application + Integration

## Goal

Deploy a complete GPU-accelerated data platform on NVIDIA Brev with RKE2 Kubernetes, KAI Scheduler for GPU workloads, ArgoCD GitOps, Dagster pipelines, LakeFS/MinIO storage, observability stack, and NVIDIA AI Enterprise services (NIM LLM + Safe Synthesizer).

## Background

This project creates a development environment that replicates an on-premises NVIDIA GPU data platform. The purpose is to experiment with workflows using the NVIDIA Enterprise AI stack in a reproducible, on-demand cloud environment. The entire stack should be deployable via GitOps, with infrastructure managed as code.

### Why RKE2 + KAI Scheduler?

- **RKE2**: Enterprise-grade Kubernetes from Rancher/SUSE. Required for Run:AI compatibility (K3S is not supported). FIPS-compliant and production-ready.
- **KAI Scheduler**: Open-source GPU scheduler from NVIDIA/Run:AI. Enables fractional GPU allocation, gang scheduling, and topology-aware placement.

### Target Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       NVIDIA BREV INSTANCE (H200)                        │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │                    RKE2 + ArgoCD + KAI Scheduler                     ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐             ││
│  │  │   Dagster   │───▶│   LakeFS    │◀───│    MinIO     │             ││
│  │  │  Pipelines  │    │  Versioning │    │   Storage    │             ││
│  │  └─────────────┘    └─────────────┘    └──────────────┘             ││
│  │         │                  │                   ▲                     ││
│  │         ▼                  ▼                   │                     ││
│  │  ┌─────────────┐    ┌─────────────────────────────────────────┐     ││
│  │  │   Marimo    │    │      NVIDIA AI Enterprise (KAI-scheduled)│     ││
│  │  │  Notebooks  │───▶│  ┌─────────┐  ┌──────────────┐          │     ││
│  │  └─────────────┘    │  │ NIM LLM │  │Safe Synthesize│          │     ││
│  │                     │  │(GPT-OSS)│  │  (80GB VRAM) │          │     ││
│  │                     │  └─────────┘  └──────────────┘          │     ││
│  │                     └─────────────────────────────────────────┘     ││
│  │                                                                      ││
│  │  ┌─────────────────────────────────────────────────────────────┐    ││
│  │  │            Observability (Prometheus/Grafana/Loki)           │    ││
│  │  │  ┌──────────┐  ┌─────────┐  ┌──────┐  ┌──────────────┐      │    ││
│  │  │  │Prometheus│  │ Grafana │  │ Loki │  │DCGM Exporter │      │    ││
│  │  │  └──────────┘  └─────────┘  └──────┘  └──────────────┘      │    ││
│  │  └─────────────────────────────────────────────────────────────┘    ││
│  └─────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘
```

## Acceptance Criteria

### Infrastructure
- [ ] AC1: Brev GPU instance (H200) can be created/destroyed via `brev` CLI commands
- [ ] AC2: RKE2 cluster is running with GPU support (nvidia-container-toolkit)
- [ ] AC3: kubectl commands work from local machine via kubeconfig + SSH tunnel
- [ ] AC4: KAI Scheduler is deployed and scheduling GPU workloads

### GitOps
- [ ] AC5: ArgoCD is deployed and accessible via port-forward
- [ ] AC6: All applications are managed via ArgoCD app-of-apps pattern
- [ ] AC7: Pushing to `main` branch triggers automatic sync

### Data Platform
- [ ] AC8: MinIO console is accessible and buckets are created
- [ ] AC9: LakeFS is connected to MinIO and repositories exist
- [ ] AC10: Dagster UI shows pipelines and assets can be materialized
- [ ] AC11: Marimo notebooks can query data from LakeFS

### NVIDIA AI
- [ ] AC12: NIM LLM (GPT-OSS 120B) endpoint responds to inference requests
- [ ] AC13: Safe Synthesizer can generate synthetic data
- [ ] AC14: Dagster pipelines can call NIM and Safe Synthesizer
- [ ] AC15: GPU workloads are scheduled via KAI Scheduler

### Observability
- [ ] AC16: Prometheus collects metrics from all services
- [ ] AC17: DCGM Exporter provides GPU metrics (utilization, memory, temperature)
- [ ] AC18: Grafana dashboards show GPU and cluster health
- [ ] AC19: Loki aggregates logs from all namespaces

### CI/CD
- [ ] AC20: GitHub Actions lint and validate on PRs
- [ ] AC21: Dagster image builds automatically on merge

### Security
- [ ] AC22: All secrets are SOPS encrypted in Git
- [ ] AC23: NGC API key is stored as Kubernetes secret
- [ ] AC24: No plaintext credentials in repository

## Technical Requirements

### Infrastructure Changes

Since we're using Brev CLI directly (not Terraform provider), infrastructure is managed via:
- Brev CLI commands documented in `Makefile`
- Cloud-init scripts for RKE2 bootstrap in `scripts/cloud-init/`
- Bootstrap scripts in `scripts/`

### Kubernetes Distribution

| Aspect | Choice | Rationale |
|--------|--------|-----------|
| Distribution | RKE2 | Run:AI compatible, FIPS compliant, enterprise-ready |
| GPU Scheduler | KAI Scheduler | Fractional GPUs, gang scheduling, topology-aware |
| CNI | Canal | Default for RKE2, Calico policies + Flannel overlay |
| Container Runtime | containerd | Default for RKE2, NVIDIA runtime configured |

### Kubernetes Changes (Helm)

| Chart | Namespace | Sync Wave | Purpose |
|-------|-----------|-----------|---------|
| `kai-scheduler` | `kube-system` | 0 | GPU workload scheduling |
| `argocd` | `argocd` | 0 | GitOps controller |
| `minio` | `minio` | 1 | Object storage |
| `lakefs` | `lakefs` | 1 | Data versioning |
| `monitoring` | `monitoring` | 1 | Observability stack |
| `dagster` | `dagster` | 2 | Pipeline orchestration |
| `marimo` | `marimo` | 2 | Interactive notebooks |
| `nvidia-nim` | `nvidia-ai` | 3 | LLM inference |
| `nvidia-safe-synth` | `nvidia-ai` | 3 | Synthetic data |

### Application Changes

- Dagster pipelines in `dagster/` directory
- I/O managers for LakeFS/MinIO integration
- NVIDIA service resources for pipeline access
- KAI Scheduler annotations for GPU workloads

### GitOps Changes

- ArgoCD Application manifests for each service
- App-of-apps root application
- Sync waves for dependency ordering (KAI first, then storage, then apps)

## Dependencies

### External Services & Accounts

| Service | Required | Purpose | How to Obtain |
|---------|----------|---------|---------------|
| NVIDIA Brev Account | Yes | GPU cloud hosting | https://brev.nvidia.com |
| GitHub Account | Yes | Repository hosting, CI/CD | https://github.com |
| NVIDIA NGC Account | Yes | NIM models, container registry | https://ngc.nvidia.com |
| NVIDIA AI Enterprise License | Yes | NIM, Safe Synthesizer | Via NGC organization |

### API Keys & Credentials Needed

| Credential | Where Used | Storage Location |
|------------|------------|------------------|
| Brev API Key | Brev CLI auth | Already logged in locally |
| NGC API Key | Pull NVIDIA containers, NIM auth | `.env.local` + K8s Secret |
| GitHub PAT | ArgoCD repo access | K8s Secret (SOPS encrypted) |
| Age Private Key | SOPS decryption | Local `~/.config/sops/age/keys.txt` |

### Software Prerequisites (Local Machine)

| Tool | Version | Purpose |
|------|---------|---------|
| `brev` CLI | Latest | Instance management |
| `kubectl` | 1.28+ | Kubernetes access |
| `helm` | 3.13+ | Chart management |
| `sops` | 3.8+ | Secret encryption |
| `age` | 1.1+ | Encryption keys |
| `git` | 2.40+ | Version control |

## Out of Scope

- Production-grade high availability (single-node RKE2)
- Multi-tenant access control
- Automated backup/restore
- Custom domain with TLS certificates (port-forward only)
- Full Run:AI installation (using open-source KAI Scheduler instead)

## Security Considerations

### Secret Management
- All secrets encrypted with SOPS + Age before commit
- Age public key stored in `.sops.yaml`
- Private key never committed (local only)
- Kubernetes secrets created via SOPS-encrypted files

### Network Security
- All services accessible only via port-forward (no public ingress)
- RKE2 API server accessible via Brev SSH tunnel
- No public endpoints exposed

### Credential Rotation
- Document process for rotating NGC API key
- Document process for rotating MinIO credentials

## Resource Requirements

### Brev Instance

| Resource | Specification | Notes |
|----------|---------------|-------|
| GPU | 1x H200 (141GB VRAM) | Sufficient for NIM + Safe Synth |
| CPU | 16 vCPUs | Included with H200 instance |
| RAM | 200GB | Included with H200 instance |
| Storage | 256GB SSD | Expandable |
| Cost | ~$4.20/hr | On Nebius cloud |

### Kubernetes Resources (Per Service)

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit | GPU | Scheduler |
|---------|-------------|-----------|----------------|--------------|-----|-----------|
| KAI Scheduler | 100m | 500m | 256Mi | 512Mi | - | default |
| ArgoCD | 250m | 500m | 256Mi | 512Mi | - | default |
| MinIO | 500m | 2000m | 1Gi | 4Gi | - | default |
| LakeFS | 250m | 1000m | 512Mi | 2Gi | - | default |
| Prometheus | 500m | 2000m | 2Gi | 4Gi | - | default |
| Grafana | 100m | 500m | 256Mi | 512Mi | - | default |
| Dagster | 500m | 2000m | 1Gi | 4Gi | - | default |
| Marimo | 250m | 1000m | 512Mi | 2Gi | - | default |
| NIM LLM | 8000m | 16000m | 64Gi | 128Gi | 1 | kai-scheduler |
| Safe Synth | 8000m | 16000m | 64Gi | 128Gi | 1 | kai-scheduler |

### GPU Allocation Strategy

With KAI Scheduler, GPU workloads can be managed efficiently:

| Workload | GPU Fraction | GPU Memory | Priority |
|----------|--------------|------------|----------|
| NIM LLM (GPT-OSS 120B) | 1.0 | ~80GB | High |
| Safe Synthesizer | 1.0 | ~80GB | Medium |

Note: H200 has 141GB VRAM. When running NIM and Safe Synth simultaneously, KAI can manage scheduling. For sequential workloads, each gets full GPU access.

## Open Questions

- [x] Q1: Which specific NIM model to deploy? → GPT-OSS 120B (fits on H200)
- [x] Q2: Terraform vs Brev CLI for provisioning? → Brev CLI (simpler, already logged in)
- [x] Q3: K3S vs RKE2? → RKE2 (Run:AI compatible, enterprise-ready)
- [x] Q4: How to schedule GPU workloads? → KAI Scheduler (open-source from Run:AI)
- [ ] Q5: What sample Dagster pipeline to create for demo?
- [ ] Q6: What synthetic data use case for Safe Synthesizer demo?
