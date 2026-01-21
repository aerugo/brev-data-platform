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

## Quick Start

### Prerequisites

- [Brev CLI](https://brev.dev) installed and logged in
- kubectl, helm, sops, age installed
- NGC API key from [NVIDIA NGC](https://ngc.nvidia.com)

### 1. Setup Environment

```bash
# Copy environment template
cp .env.example .env.local

# Edit with your credentials
nano .env.local
```

### 2. Create Secrets

```bash
# Generate encrypted secrets
./scripts/create-secrets.sh
```

### 3. Create Instance

```bash
# Create GPU instance on Brev
make create-instance

# Check status
make status
```

### 4. Bootstrap K3S

```bash
# SSH into instance
make shell

# On the instance, run the cloud-init script manually
# or wait for automated setup
```

### 5. Deploy Stack

```bash
# Install ArgoCD
make bootstrap-argocd

# ArgoCD will sync remaining applications from Git
```

## Commands

```bash
make help                    # Show all commands

# Instance Management
make create-instance         # Create Brev GPU instance
make stop-instance           # Stop instance (saves cost)
make start-instance          # Start stopped instance
make delete-instance         # Delete instance (DESTRUCTIVE)
make shell                   # SSH into instance

# Port Forwarding
make port-forward-argocd     # https://localhost:8080
make port-forward-dagster    # http://localhost:3000
make port-forward-minio      # http://localhost:9001
make port-forward-lakefs     # http://localhost:8000
make port-forward-marimo     # http://localhost:2718

# Secrets
make create-secrets          # Generate encrypted secrets
make edit-secret FILE=...    # Edit encrypted secret

# Validation
make lint                    # Lint Helm and Python
make validate                # Validate configurations
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     NVIDIA BREV INSTANCE                         │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    K3S + ArgoCD                            │  │
│  │  ┌─────────────┐    ┌─────────────┐    ┌──────────────┐   │  │
│  │  │   Dagster   │───▶│   LakeFS    │◀───│    MinIO     │   │  │
│  │  │  Pipelines  │    │  Versioning │    │   Storage    │   │  │
│  │  └─────────────┘    └─────────────┘    └──────────────┘   │  │
│  │         │                                     ▲           │  │
│  │         ▼                                     │           │  │
│  │  ┌─────────────┐    ┌─────────────────────────────────┐   │  │
│  │  │   Marimo    │    │      NVIDIA AI Enterprise       │   │  │
│  │  │  Notebooks  │───▶│  ┌─────────┐  ┌──────────────┐  │   │  │
│  │  └─────────────┘    │  │ NIM LLM │  │Safe Synthesize│  │   │  │
│  │                     │  └─────────┘  └──────────────┘  │   │  │
│  │                     └─────────────────────────────────────┘   │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Documentation

- [Development Plan](docs/plans/active/grand_plan/development-plan.md) - Implementation roadmap
- [Invariants](docs/invariants/INVARIANTS.md) - Architectural constraints
- [Planning Protocol](docs/plans/CLAUDE.md) - How we plan features

## Repository Structure

```
brev-data-platform/
├── k8s/                    # Kubernetes manifests (Helm)
│   ├── bootstrap/          # ArgoCD installation
│   └── apps/               # Application charts
├── dagster/                # Pipeline code
├── marimo/                 # Notebooks
├── scripts/                # Automation scripts
├── config/                 # Service configurations
└── docs/                   # Documentation
```

## Security

- All secrets are encrypted with SOPS + Age
- NGC API keys stored as Kubernetes secrets
- No plaintext credentials in repository
- Services accessible only via port-forward (no public ingress)

## License

Proprietary - Internal Use Only
