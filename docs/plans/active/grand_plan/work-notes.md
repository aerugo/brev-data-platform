# Brev Data Platform - Work Notes

**Feature**: Full stack GPU data platform deployment
**Started**: 2026-01-21
**Branch**: `main`

---

## Session Log

### 2026-01-21 - Initial Planning

**Context Review Completed**:

- Created `.CLAUDE.md` project overview
- Created `docs/plans/CLAUDE.md` planning protocol
- Created `docs/invariants/INVARIANTS.md` with 21 invariants
- Created 8 specialized subagents in `.claude/agents/`
- Created Brev CLI skill in `.claude/skills/brev/`
- Verified Brev CLI is logged in: `brev ls` returns `Riksbank-Org`

**Applicable Invariants**:

All invariants apply to this grand plan. Key ones for early phases:

- INV-I004: Cloud-init for K3S bootstrap
- INV-S001: No plaintext secrets in Git
- INV-S002: SOPS configuration in repository root
- INV-G001: App-of-apps pattern for ArgoCD

**Key Insights**:

- Brev CLI is already authenticated (no additional setup needed)
- Current org is `Riksbank-Org`
- No existing instances in the org
- Can use `/brev` skill for instance management

**Completed**:

- [x] Created grand plan spec.md
- [x] Created grand plan development-plan.md with 10 phases
- [x] Documented all manual setup steps
- [x] Identified all required credentials and API keys

**Current Brev Status**:

```
$ brev ls
No instances in org Riksbank-Org
```

**Next Steps**:

1. Complete Phase 0 manual prerequisites checklist
2. Begin Phase 1 repository structure creation
3. Set up SOPS encryption in Phase 2

---

## Phase Progress

### Phase 0: Prerequisites & Manual Setup

**Status**: Complete ✓
**Started**: 2026-01-21
**Completed**: 2026-01-21

#### Checklist

- [x] Brev CLI logged in (Riksbank-Org)
- [x] NGC account created
- [x] NGC API Key generated (stored in .env.local)
- [x] NGC has NIM model access
- [x] GitHub repository created: https://github.com/aerugo/brev-data-platform
- [x] GitHub PAT generated (from gh auth token)
- [x] kubectl installed (v1.33.1)
- [x] helm installed (v3.17.3)
- [x] sops installed (3.11.0) via homebrew
- [x] age installed (v1.2.1) via homebrew
- [x] Age key generated at ~/.config/sops/age/keys.txt

#### Notes

All prerequisites verified and installed. Age public key: `age18vt4yspgr9qtq30n6ty20l8jpxeu5drd38sl9kdlxqvggswtsdmsyeydck`

---

### Phase 1: Repository Structure

**Status**: Complete ✓
**Started**: 2026-01-21
**Completed**: 2026-01-21

#### Notes

Created all repository structure:
- `Makefile` - 25+ commands for instance management, port-forwarding, secrets, validation
- `.gitignore` - Comprehensive exclusions
- `.env.example` - Template for environment variables
- `scripts/cloud-init/k3s-gpu.yaml` - K3S + NVIDIA GPU bootstrap
- `scripts/setup-kubeconfig.sh` - Kubeconfig setup
- `scripts/bootstrap-argocd.sh` - ArgoCD installation script
- `scripts/create-secrets.sh` - SOPS-encrypted secrets generation
- `README.md` - Project documentation
- `dagster/` - Package placeholders (assets/, io_managers/, resources/, tests/)
- `k8s/` - Kubernetes manifests directory structure
- `marimo/notebooks/` - Notebook directory
- `config/` - Configuration directories (nim/, safe-synthesizer/)

---

### Phase 2: Secrets & Encryption Setup

**Status**: Complete ✓
**Started**: 2026-01-21
**Completed**: 2026-01-21

#### Notes

Generated all encrypted secrets with SOPS + Age:
- `k8s/apps/minio/secrets.enc.yaml` - MinIO credentials
- `k8s/apps/lakefs/secrets.enc.yaml` - LakeFS credentials + MinIO access
- `k8s/apps/nvidia-ai/secrets.enc.yaml` - NGC API key + docker registry auth
- `k8s/apps/argocd-apps/secrets.enc.yaml` - GitHub repo credentials
- `k8s/apps/dagster/secrets.enc.yaml` - All service connections
- `k8s/apps/marimo/secrets.enc.yaml` - MinIO + LakeFS access

Generated credentials:
- MINIO_ROOT_PASSWORD: Random 32-char base64
- LAKEFS_ACCESS_KEY_ID: 20-char hex
- LAKEFS_SECRET_ACCESS_KEY: 32-byte base64
- GITHUB_PAT: From gh auth token

Fixed SOPS 3.11 issue requiring `--config /dev/null` for explicit `--age` flag usage.

---

### Phase 3: Brev Instance + K3S

**Status**: Pending
**Started**:
**Completed**:

#### Notes

Will use `/brev create brev-data-platform-dev -g "..."` to create instance.

---

## Key Decisions

### Decision 1: Brev CLI over Terraform

**Date**: 2026-01-21
**Context**: Needed to decide how to provision Brev instances
**Decision**: Use Brev CLI directly instead of Terraform provider
**Rationale**:
- User is already logged into Brev CLI
- Simpler setup for single-instance deployment
- Can verify and interact with instance directly
- Terraform would add complexity without significant benefit
**Alternatives Considered**:
- Terraform with Brev provider (more complex, better for multi-environment)
- Pulumi (additional learning curve)

### Decision 2: Port-forward over Ingress

**Date**: 2026-01-21
**Context**: How to access services running in K3S
**Decision**: Use kubectl port-forward for all service access
**Rationale**:
- No need for public endpoints (dev environment)
- Simpler security model (no TLS certs, DNS)
- Works immediately without additional setup
- Services accessed via Brev SSH tunnel
**Alternatives Considered**:
- K3S Traefik ingress (requires DNS, TLS)
- NodePort services (less secure)

### Decision 3: Single GPU instance

**Date**: 2026-01-21
**Context**: What GPU configuration for the Brev instance
**Decision**: Start with single A100-40GB
**Rationale**:
- Sufficient for NIM LLM inference (llama3-8b)
- Safe Synthesizer can share GPU
- Can scale up if needed
- Cost-effective for development
**Alternatives Considered**:
- Multi-GPU (overkill for dev)
- T4 (may be too small for NIM)

---

## Files Modified

### Created

- `docs/plans/active/grand_plan/spec.md` - Feature specification
- `docs/plans/active/grand_plan/development-plan.md` - 10-phase plan
- `docs/plans/active/grand_plan/work-notes.md` - This file
- `Makefile` - Build and management commands
- `.gitignore` - Git exclusions
- `.env.example` - Environment template
- `.sops.yaml` - SOPS encryption config
- `README.md` - Project documentation
- `scripts/cloud-init/k3s-gpu.yaml` - K3S bootstrap
- `scripts/setup-kubeconfig.sh` - Kubeconfig setup
- `scripts/bootstrap-argocd.sh` - ArgoCD installation
- `scripts/create-secrets.sh` - Secrets generation
- `k8s/apps/minio/secrets.enc.yaml` - Encrypted MinIO secrets
- `k8s/apps/lakefs/secrets.enc.yaml` - Encrypted LakeFS secrets
- `k8s/apps/nvidia-ai/secrets.enc.yaml` - Encrypted NVIDIA secrets
- `k8s/apps/argocd-apps/secrets.enc.yaml` - Encrypted ArgoCD secrets
- `k8s/apps/dagster/secrets.enc.yaml` - Encrypted Dagster secrets
- `k8s/apps/marimo/secrets.enc.yaml` - Encrypted Marimo secrets
- `dagster/` - Package structure (assets, io_managers, resources, tests)
- `marimo/notebooks/.gitkeep` - Placeholder
- `config/` - Configuration directories

### Modified

- `.env.local` - Added generated credentials (git-ignored)

---

## Commands Reference

Commands that will be useful during implementation:

```bash
# Brev instance management
brev create brev-data-platform-dev -g "a2-highgpu-1g:nvidia-a100-40gb:1"
brev ls
brev shell brev-data-platform-dev
brev stop brev-data-platform-dev
brev delete brev-data-platform-dev

# Kubeconfig setup
brev copy brev-data-platform-dev:/etc/rancher/k3s/k3s.yaml ./kubeconfig.yaml

# Port forwarding (after K3S is running)
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl port-forward svc/minio-console -n minio 9001:9001
kubectl port-forward svc/lakefs -n lakefs 8000:8000
kubectl port-forward svc/dagster-webserver -n dagster 3000:3000
kubectl port-forward svc/marimo -n marimo 2718:2718
kubectl port-forward svc/nim-llm -n nvidia-ai 8000:8000

# SOPS encryption
sops -e secrets.yaml > secrets.enc.yaml
sops -d secrets.enc.yaml

# Validation
make lint
make validate
helm lint k8s/apps/*/
terraform fmt -check -recursive terraform/
```

---

## Documentation Updates Required

### INVARIANTS.md Changes

- [ ] Add INV-I005: Brev instance naming convention
- [ ] Add INV-K006: Sync wave ordering for ArgoCD

### Other Documentation

- [ ] README.md - Quick start guide after implementation
- [ ] .CLAUDE.md - Update commands section after Makefile is created

---

## Post-Implementation Notes

(To be filled after implementation is complete)
