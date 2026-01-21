# Feature: Brev Data Platform - Full Stack Deployment

**Status**: Draft
**Created**: 2026-01-21
**Category**: Infrastructure + Kubernetes + Application + Integration

## Goal

Deploy a complete GPU-accelerated data platform on NVIDIA Brev with K3S, ArgoCD GitOps, Dagster pipelines, LakeFS/MinIO storage, and NVIDIA AI Enterprise services (NIM LLM + Safe Synthesizer).

## Background

This project creates a development environment that replicates an on-premises NVIDIA GPU data platform. The purpose is to experiment with workflows using the NVIDIA Enterprise AI stack in a reproducible, on-demand cloud environment. The entire stack should be deployable via GitOps, with infrastructure managed as code.

### Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     NVIDIA BREV INSTANCE                         │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    K3S + ArgoCD                            │  │
│  │  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐   │  │
│  │  │   Dagster   │───▶│   LakeFS    │◀───│    MinIO     │   │  │
│  │  │  Pipelines  │    │  Versioning │    │   Storage    │   │  │
│  │  └─────────────┘    └─────────────┘    └──────────────┘   │  │
│  │         │                  │                   ▲          │  │
│  │         ▼                  ▼                   │          │  │
│  │  ┌─────────────┐    ┌─────────────────────────────────┐   │  │
│  │  │   Marimo    │    │      NVIDIA AI Enterprise       │   │  │
│  │  │  Notebooks  │───▶│  ┌─────────┐  ┌──────────────┐  │   │  │
│  │  └─────────────┘    │  │ NIM LLM │  │Safe Synthesize│  │   │  │
│  │                     │  └─────────┘  └──────────────┘  │   │  │
│  │                     └─────────────────────────────────────┘   │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Acceptance Criteria

### Infrastructure
- [ ] AC1: Brev GPU instance can be created/destroyed via `brev` CLI commands
- [ ] AC2: K3S cluster is running with GPU support (nvidia-container-toolkit)
- [ ] AC3: kubectl commands work from local machine via kubeconfig

### GitOps
- [ ] AC4: ArgoCD is deployed and accessible via port-forward
- [ ] AC5: All applications are managed via ArgoCD app-of-apps pattern
- [ ] AC6: Pushing to `main` branch triggers automatic sync

### Data Platform
- [ ] AC7: MinIO console is accessible and buckets are created
- [ ] AC8: LakeFS is connected to MinIO and repositories exist
- [ ] AC9: Dagster UI shows pipelines and assets can be materialized
- [ ] AC10: Marimo notebooks can query data from LakeFS

### NVIDIA AI
- [ ] AC11: NIM LLM endpoint responds to inference requests
- [ ] AC12: Safe Synthesizer can generate synthetic data
- [ ] AC13: Dagster pipelines can call NIM and Safe Synthesizer

### CI/CD
- [ ] AC14: GitHub Actions lint and validate on PRs
- [ ] AC15: Dagster image builds automatically on merge

### Security
- [ ] AC16: All secrets are SOPS encrypted in Git
- [ ] AC17: NGC API key is stored as Kubernetes secret
- [ ] AC18: No plaintext credentials in repository

## Technical Requirements

### Infrastructure Changes (Terraform)

Since we're using Brev CLI directly (not Terraform provider), infrastructure is managed via:
- Brev CLI commands documented in `scripts/`
- Cloud-init scripts for K3S bootstrap in `scripts/cloud-init/`

### Kubernetes Changes (Helm)

| Chart | Namespace | Purpose |
|-------|-----------|---------|
| `argocd` | `argocd` | GitOps controller |
| `minio` | `minio` | Object storage |
| `lakefs` | `lakefs` | Data versioning |
| `dagster` | `dagster` | Pipeline orchestration |
| `marimo` | `marimo` | Interactive notebooks |
| `nvidia-nim` | `nvidia-ai` | LLM inference |
| `nvidia-safe-synth` | `nvidia-ai` | Synthetic data |

### Application Changes

- Dagster pipelines in `dagster/` directory
- I/O managers for LakeFS/MinIO integration
- NVIDIA service resources for pipeline access

### GitOps Changes

- ArgoCD Application manifests for each service
- App-of-apps root application
- Sync waves for dependency ordering

## Dependencies

### External Services & Accounts

| Service | Required | Purpose | How to Obtain |
|---------|----------|---------|---------------|
| NVIDIA Brev Account | Yes | GPU cloud hosting | https://brev.dev |
| GitHub Account | Yes | Repository hosting, CI/CD | https://github.com |
| NVIDIA NGC Account | Yes | NIM models, container registry | https://ngc.nvidia.com |
| NVIDIA AI Enterprise License | Yes | NIM, Safe Synthesizer | Contact NVIDIA sales |

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

- Production-grade high availability (single-node K3S)
- Multi-tenant access control
- Automated backup/restore
- Custom domain with TLS certificates
- Monitoring stack (Prometheus/Grafana) - can be added later
- Log aggregation (Loki) - can be added later

## Security Considerations

### Secret Management
- All secrets encrypted with SOPS + Age before commit
- Age public key stored in `.sops.yaml`
- Private key never committed (local only)
- Kubernetes secrets created via SOPS-encrypted files

### Network Security
- All services accessible only via port-forward (no public ingress)
- K3S API server accessible via Brev SSH tunnel
- No public endpoints exposed

### Credential Rotation
- Document process for rotating NGC API key
- Document process for rotating MinIO credentials

## Resource Requirements

### Brev Instance

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| GPU | 1x A100-40GB | 1x A100-80GB |
| CPU | 8 cores | 16 cores |
| RAM | 64GB | 128GB |
| Storage | 200GB SSD | 500GB SSD |

### Kubernetes Resources (Per Service)

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit | GPU |
|---------|-------------|-----------|----------------|--------------|-----|
| ArgoCD | 250m | 500m | 256Mi | 512Mi | - |
| MinIO | 500m | 2000m | 1Gi | 4Gi | - |
| LakeFS | 250m | 1000m | 512Mi | 2Gi | - |
| Dagster | 500m | 2000m | 1Gi | 4Gi | - |
| Marimo | 250m | 1000m | 512Mi | 2Gi | - |
| NIM LLM | 4000m | 8000m | 16Gi | 32Gi | 1 |
| Safe Synth | 2000m | 4000m | 8Gi | 16Gi | 1 |

## Open Questions

- [x] Q1: Which specific NIM model to deploy? → Start with `meta/llama3-8b-instruct`
- [x] Q2: Terraform vs Brev CLI for provisioning? → Brev CLI (simpler, already logged in)
- [ ] Q3: What sample Dagster pipeline to create for demo?
- [ ] Q4: What synthetic data use case for Safe Synthesizer demo?
