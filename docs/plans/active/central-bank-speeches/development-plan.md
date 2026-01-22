# Central Bank Speeches AI Data Product - Development Plan

**Status**: In Progress
**Created**: 2026-01-22
**Branch**: `feature/central-bank-speeches`
**Spec**: [spec.md](spec.md)

## Summary

Implement an end-to-end AI data product pipeline using the Kaggle "central-bank-speeches" dataset that demonstrates embedding generation, LLM classification, vector search via Weaviate, synthetic data generation, and interactive visualization in a Marimo dashboard.

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md`:

- **INV-I003**: H200 141GB GPU Required - Safe Synthesizer requires exclusive GPU (80GB), must scale down NIM before running
- **INV-K001**: Namespace Per Application - Weaviate gets dedicated `weaviate` namespace
- **INV-K002**: Resource Limits on All Pods - All Weaviate/new pods have requests and limits
- **INV-K005**: No Hardcoded Image Tags as `latest` - Pin Weaviate and all images to specific versions
- **INV-S001**: No Plaintext Secrets in Git - Kaggle credentials encrypted with SOPS
- **INV-D001**: Standard Bucket Structure - Use `raw-data` for Kaggle ingest, `data-products` for outputs
- **INV-D002**: LakeFS for Data Versioning - All data products versioned in LakeFS
- **INV-D003**: Parquet for Structured Data - Store DataFrame as Parquet in LakeFS
- **INV-P001**: Assets Over Ops - Use Dagster assets for all pipeline components
- **INV-P002**: I/O Managers for Storage - Implement LakeFS/Weaviate I/O managers
- **INV-P003**: Type Annotations on Assets - Full type annotations on all assets
- **INV-N001**: NIM Requires GPU Node - Both LLM and embedding NIM require GPU (managed via KAI)
- **INV-N003**: Safe Synthesizer Output to LakeFS - Synthetic data and reports versioned
- **INV-N004**: NIM Observability Enabled - Ensure metrics/logging enabled for new NIM usage
- **INV-G001**: App-of-Apps Pattern for ArgoCD - Weaviate added via app-of-apps
- **INV-G004**: Sync Waves for Dependencies - Weaviate deploys before Dagster needs it

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-D004**: Weaviate Collections for Vector Data - Vector embeddings stored in Weaviate with proper schema, cross-referenced to LakeFS data products
- **NEW INV-P004**: Synthetic Data Isolation - Synthetic data products use separate Weaviate collections and LakeFS branches

## Current State Analysis

The platform currently has:
- ✅ Working Dagster deployment with demo assets
- ✅ NIM LLM (Llama 3.1 8B) for text generation
- ✅ MinIO object storage with standard buckets
- ✅ LakeFS for data versioning (empty, ready for use)
- ✅ Safe Synthesizer configured (disabled, ready to scale up)
- ✅ JupyterHub with Marimo pre-installed
- ✅ KAI Scheduler for GPU sharing
- ❌ No vector database (Weaviate needed)
- ❌ No embedding model (will deploy NIM llama-3.2-nemoretriever-300m-embed-v2)
- ❌ No real data pipelines (only demo assets)
- ❌ No I/O managers implemented
- ❌ No Marimo dashboards deployed

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `dagster/pyproject.toml` | Basic dependencies | Add kagglehub, weaviate-client, polars |
| `dagster/src/brev_pipelines/definitions.py` | Demo assets only | Add speech assets, resources, IO managers |
| `k8s/apps/argocd-apps/templates/` | Existing apps | Add Weaviate Application |
| `.env.example` | Existing vars | Add Kaggle credentials, NVIDIA API key |
| `scripts/create-secrets.sh` | Existing secrets | Add Kaggle secret creation |

### Files to Create

| File | Purpose |
|------|---------|
| `k8s/apps/weaviate/` | Weaviate Helm chart |
| `k8s/apps/weaviate/Chart.yaml` | Chart metadata |
| `k8s/apps/weaviate/values.yaml` | Weaviate configuration |
| `k8s/apps/weaviate/templates/` | Helm templates |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | Main ETL pipeline |
| `dagster/src/brev_pipelines/assets/synthetic_speeches.py` | Synthetic data pipeline |
| `dagster/src/brev_pipelines/resources/weaviate.py` | Weaviate resource |
| `k8s/apps/nvidia-nim-embedding/` | NIM embedding model Helm chart |
| `dagster/src/brev_pipelines/resources/nim_embedding.py` | NIM embedding resource |
| `dagster/src/brev_pipelines/resources/safe_synth.py` | Safe Synthesizer resource |
| `dagster/src/brev_pipelines/io_managers/lakefs_polars.py` | LakeFS I/O manager |
| `dagster/src/brev_pipelines/io_managers/weaviate_io.py` | Weaviate I/O manager |
| `k8s/apps/weaviate/secrets/kaggle.enc.yaml` | Encrypted Kaggle credentials |

**External repositories to create/modify:**

| Repository | File | Purpose |
|------------|------|---------|
| `aerugo/brev-dashboards` (new) | `central_bank_speeches/dashboard.py` | Interactive dashboard |
| `aerugo/brev-dashboards` (new) | `central_bank_speeches/utils.py` | Dashboard helper functions |
| `aerugo/jupyterhub-singleuser` | `Dockerfile` | Add dashboard clone |

## Solution Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CENTRAL BANK SPEECHES                              │
│                            DATA PRODUCT FLOW                                 │
└─────────────────────────────────────────────────────────────────────────────┘

╔═══════════════════════════════════════════════════════════════════════════╗
║ PHASE 3: DAGSTER ETL PIPELINE                                              ║
╠═══════════════════════════════════════════════════════════════════════════╣
║                                                                            ║
║  ┌──────────┐     ┌──────────────┐     ┌─────────────────┐                ║
║  │  Kaggle  │────▶│  raw_speeches │────▶│ versioned_      │                ║
║  │  Dataset │     │   (MinIO)     │     │ speeches        │                ║
║  └──────────┘     └──────────────┘     │ (LakeFS main)   │                ║
║                                         └────────┬────────┘                ║
║                                                  │                         ║
║                          ┌───────────────────────┼───────────────────┐     ║
║                          ▼                       ▼                   ▼     ║
║              ┌───────────────────┐    ┌─────────────────┐  ┌────────────┐ ║
║              │ speech_embeddings │    │ tariff_         │  │ enriched_  │ ║
║              │ (NIM Embedding)   │    │ classification  │  │ speeches   │ ║
║              │ 1024-dim vectors  │    │ (NIM LLM)       │  │            │ ║
║              └─────────┬─────────┘    └────────┬────────┘  └─────┬──────┘ ║
║                        │                       │                  │        ║
║                        └───────────────────────┴──────────────────┘        ║
║                                                │                           ║
║                                                ▼                           ║
║                      ┌─────────────────────────────────────────┐           ║
║                      │          speeches_data_product           │           ║
║                      │         (LakeFS, Parquet format)         │           ║
║                      └─────────────────────┬───────────────────┘           ║
║                                            │                               ║
╚════════════════════════════════════════════╪═══════════════════════════════╝
                                             │
╔════════════════════════════════════════════╪═══════════════════════════════╗
║ PHASE 1: WEAVIATE INFRASTRUCTURE           │                               ║
╠════════════════════════════════════════════╪═══════════════════════════════╣
║                                            ▼                               ║
║                      ┌─────────────────────────────────────────┐           ║
║                      │            weaviate_index               │           ║
║                      │       (Vector DB, searchable)           │           ║
║                      │    Collection: CentralBankSpeeches      │           ║
║                      └─────────────────────┬───────────────────┘           ║
║                                            │                               ║
╚════════════════════════════════════════════╪═══════════════════════════════╝
                                             │
╔════════════════════════════════════════════╪═══════════════════════════════╗
║ PHASE 4: SYNTHETIC DATA PIPELINE           │                               ║
╠════════════════════════════════════════════╪═══════════════════════════════╣
║                                            │                               ║
║  ┌─────────────────────────────────────────┴───────────────────────────┐   ║
║  │                                                                      │   ║
║  │  ┌─────────────────┐    ┌────────────────┐    ┌──────────────────┐  │   ║
║  │  │ synthetic_      │───▶│ synthetic_     │───▶│ synthetic_       │  │   ║
║  │  │ speeches        │    │ embeddings     │    │ weaviate         │  │   ║
║  │  │ (Safe Synth)    │    │ (NIM Embedding)│    │ (Separate coll)  │  │   ║
║  │  └────────┬────────┘    └────────────────┘    └──────────────────┘  │   ║
║  │           │                                                          │   ║
║  │           ▼                                                          │   ║
║  │  ┌─────────────────┐                                                 │   ║
║  │  │ validation_     │  MIA/AIA reports → LakeFS                       │   ║
║  │  │ report          │                                                 │   ║
║  │  └─────────────────┘                                                 │   ║
║  └──────────────────────────────────────────────────────────────────────┘   ║
║                                                                             ║
╚═════════════════════════════════════════════════════════════════════════════╝

╔═════════════════════════════════════════════════════════════════════════════╗
║ PHASE 5: MARIMO DASHBOARD                                                   ║
╠═════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║    ┌────────────────────────────────────────────────────────────────┐       ║
║    │                     MARIMO DASHBOARD                           │       ║
║    │                                                                 │       ║
║    │   ┌─────────────┐  ┌──────────────────┐  ┌───────────────┐    │       ║
║    │   │ Data Source │  │  Search Query    │  │   Results     │    │       ║
║    │   │ Toggle:     │  │  Input:          │  │   Display:    │    │       ║
║    │   │ ○ Real      │  │  [____________]  │  │   • Result 1  │    │       ║
║    │   │ ● Synthetic │  │                  │  │   • Result 2  │    │       ║
║    │   └─────────────┘  └──────────────────┘  │   • Result 3  │    │       ║
║    │                                          └───────────────┘    │       ║
║    │                                                                │       ║
║    │   ┌──────────────────────────────────────────────────────┐    │       ║
║    │   │           Embedding Visualization (UMAP)             │    │       ║
║    │   │                    [scatter plot]                    │    │       ║
║    │   └──────────────────────────────────────────────────────┘    │       ║
║    │                                                                │       ║
║    └────────────────────────────────────────────────────────────────┘       ║
║                                                                             ║
╚═════════════════════════════════════════════════════════════════════════════╝
```

### Key Design Decisions

1. **Local NIM for Embeddings**: Deploy `llama-3_2-nemoretriever-300m-embed-v2` from NVIDIA NIM registry as a local embedding service. This 300M parameter model has a small footprint (~1GB GPU memory) and can share the GPU with the LLM NIM via KAI Scheduler fractional allocation. No external API dependencies.

2. **Weaviate Single-Node**: Deploy Weaviate as a single-node instance for development. This is sufficient for the dataset size (~10K speeches) and can be scaled later.

3. **Polars over Pandas**: Use Polars for DataFrame operations. It's faster, more memory efficient, and better typed. Already used in the Kaggle loader example.

4. **LakeFS I/O Manager**: Implement a proper I/O manager for LakeFS following INV-P002 instead of direct storage calls. This enables automatic versioning and lineage tracking.

5. **Separate Weaviate Collections**: Real and synthetic data use separate collections (`CentralBankSpeeches` and `SyntheticSpeeches`) to maintain data isolation per NEW INV-P004.

6. **KAI Priority-Based GPU Switching**: For Safe Synthesizer, use KAI Scheduler priority-based preemption. Safe Synth runs as a high-priority batch job that preempts NIM pods, which auto-recover after the job completes. No manual kubectl scaling required.

7. **Dashboard in JupyterHub**: Run Marimo dashboard within JupyterHub initially. This leverages existing infrastructure and allows iterative development.

## Phase Overview

| Phase | Description | Type | Deliverables |
|-------|-------------|------|--------------|
| 1 | Weaviate Infrastructure | Kubernetes | Helm chart, ArgoCD app, deployed instance |
| 2 | NIM Embedding & Resources | Infrastructure + App | NIM embedding Helm chart, Dagster resources |
| 3 | Central Bank Speeches ETL | Application | Dagster assets, I/O managers, full pipeline |
| 4 | Synthetic Data Pipeline | Application | Safe Synth integration, KAI preemption, validation |
| 5 | Marimo Dashboard | Application | Interactive dashboard with vector search |

---

## Phase 1: Weaviate Infrastructure

**Goal**: Deploy Weaviate vector database to Kubernetes cluster (managed by ArgoCD, auto-included in `make setup`)
**Type**: Kubernetes
**Detailed Plan**: [phases/phase-1.md](phases/phase-1.md)

**Integration**: Weaviate is added to the ArgoCD app-of-apps pattern. Once the Helm chart is in the repo, it's automatically deployed by `make setup` on fresh clusters - no script modifications needed.

### Deliverables

1. `k8s/apps/weaviate/Chart.yaml` - Helm chart metadata with Weaviate dependency
2. `k8s/apps/weaviate/values.yaml` - Weaviate configuration with persistence enabled
3. `k8s/apps/argocd-apps/templates/weaviate.yaml` - ArgoCD Application (app-of-apps)

### Validation Approach

1. `helm lint k8s/apps/weaviate/` passes
2. `helm template weaviate k8s/apps/weaviate/` renders valid YAML
3. ArgoCD syncs Weaviate application automatically
4. `kubectl get pods -n weaviate` shows running pod
5. `kubectl get pvc -n weaviate` shows bound 20Gi PVC
6. Weaviate health check at `/v1/.well-known/ready` returns 200

### Success Criteria

- [ ] Helm lint passes
- [ ] Weaviate pod running in `weaviate` namespace
- [ ] **PVC bound with 20Gi persistent storage**
- [ ] Health endpoint accessible from within cluster
- [ ] Included in `make setup` (no additional steps for fresh deploy)

---

## Phase 2: NIM Embedding & Resource Setup

**Goal**: Deploy NIM embedding model and create Dagster resources for embeddings and Weaviate
**Type**: Infrastructure + Application
**Detailed Plan**: [phases/phase-2.md](phases/phase-2.md)

**Integration**: NIM embedding is added to ArgoCD app-of-apps pattern. Automatically deployed alongside other NVIDIA AI services on `make setup`.

### Deliverables

1. `k8s/apps/nvidia-nim-embedding/` - Helm chart for NIM embedding model
2. `k8s/apps/argocd-apps/templates/nvidia-nim-embedding.yaml` - ArgoCD Application (app-of-apps)
3. `dagster/src/brev_pipelines/resources/nim_embedding.py` - NIM embedding resource
4. `dagster/src/brev_pipelines/resources/weaviate.py` - Weaviate client resource
5. `dagster/pyproject.toml` - Updated dependencies
6. `dagster/tests/test_resources.py` - Resource tests
7. Updated secrets with Kaggle credentials

### Validation Approach

1. NIM embedding pod running in `nvidia-nim` namespace
2. `pytest dagster/tests/test_resources.py` passes
3. `ruff check dagster/` passes
4. `mypy dagster/` passes
5. Resources initialize correctly in local Dagster

### Success Criteria

- [ ] NIM embedding model deployed and healthy
- [ ] NIM embedding resource generates embeddings via local endpoint
- [ ] Weaviate resource connects and creates collections
- [ ] All tests pass
- [ ] Type checking passes

---

## Phase 3: Central Bank Speeches ETL Pipeline

**Goal**: Implement full Dagster pipeline from Kaggle to Weaviate
**Type**: Application
**Detailed Plan**: [phases/phase-3.md](phases/phase-3.md)

### Deliverables

1. `dagster/src/brev_pipelines/assets/central_bank_speeches.py` - Main pipeline assets
2. `dagster/src/brev_pipelines/io_managers/lakefs_polars.py` - LakeFS I/O manager
3. `dagster/src/brev_pipelines/io_managers/weaviate_io.py` - Weaviate I/O manager
4. `dagster/tests/test_central_bank_speeches.py` - Pipeline tests
5. Updated `definitions.py` with new assets

### Validation Approach

1. `pytest dagster/tests/` all pass
2. `dagster dev` shows assets in UI
3. Materialize `raw_speeches` successfully
4. Full pipeline materializes without errors
5. Data visible in MinIO, LakeFS, and Weaviate

### Success Criteria

- [ ] All 7 assets materialize successfully
- [ ] Data versioned in LakeFS with commits
- [ ] Embeddings stored correctly (1024 dimensions)
- [ ] Tariff classification produces valid 0/1 labels
- [ ] Vector search works in Weaviate

---

## Phase 4: Synthetic Data Pipeline

**Goal**: Generate synthetic twin using NVIDIA Safe Synthesizer
**Type**: Application
**Detailed Plan**: [phases/phase-4.md](phases/phase-4.md)

### Deliverables

1. `dagster/src/brev_pipelines/resources/safe_synth.py` - Safe Synthesizer resource
2. `dagster/src/brev_pipelines/assets/synthetic_speeches.py` - Synthetic pipeline assets
3. `dagster/tests/test_synthetic_speeches.py` - Pipeline tests
4. Documentation for GPU switching procedure

### Validation Approach

1. Safe Synthesizer scales up successfully
2. NIM scales down without data loss
3. Synthetic generation job completes
4. MIA/AIA reports generated and stored
5. Synthetic embeddings in separate Weaviate collection

### Success Criteria

- [ ] Synthetic data generated with privacy guarantees
- [ ] Validation reports in LakeFS
- [ ] Separate Weaviate collection created
- [ ] Vector search works on synthetic data
- [ ] GPU restored to NIM after completion

---

## Phase 5: Marimo Dashboard

**Goal**: Create interactive dashboard for vector search exploration, delivered to users via JupyterHub
**Type**: Application
**Detailed Plan**: [phases/phase-5.md](phases/phase-5.md)

**Architecture**: Dashboard code lives in a **separate repository** (`aerugo/brev-dashboards`) and is cloned into the JupyterHub singleuser image. Users see dashboards at `/home/jovyan/dashboards/` when they start a JupyterHub session.

### Deliverables

**In `aerugo/brev-dashboards` repository (new)**:
1. `central_bank_speeches/dashboard.py` - Main dashboard
2. `central_bank_speeches/utils.py` - Helper functions
3. `central_bank_speeches/README.md` - Dashboard documentation

**In `brev-data-platform` repository**:
4. `k8s/apps/jupyterhub/values.yaml` - Updated with WEAVIATE_* and NIM_EMBEDDING_ENDPOINT env vars

**In `aerugo/jupyterhub-singleuser` repository**:
5. `Dockerfile` - Updated to clone brev-dashboards and install dependencies

### Validation Approach

1. Dashboard code committed to `aerugo/brev-dashboards`
2. JupyterHub image rebuilt with dashboards included
3. `marimo run dashboard.py` starts without errors in JupyterHub
4. Data source toggle works (real/synthetic collections)
5. Vector search returns relevant results (connects to Weaviate)
6. Environment variables accessible (`WEAVIATE_HOST`, `NIM_EMBEDDING_ENDPOINT`)

### Success Criteria

- [ ] `aerugo/brev-dashboards` repository created
- [ ] JupyterHub singleuser image updated with dashboards
- [ ] Dashboard runs in JupyterHub at `~/dashboards/central_bank_speeches/`
- [ ] Toggle between real/synthetic data works
- [ ] Vector search produces relevant results via local NIM embedding
- [ ] Results display speech details with similarity scores

---

## Validation Strategy

### Infrastructure Validation

```bash
# Helm charts
helm lint k8s/apps/weaviate/
helm template weaviate k8s/apps/weaviate/

# Kubernetes resources
kubectl get pods -n weaviate
kubectl logs -n weaviate deployment/weaviate
```

### Application Validation

```bash
# Dagster tests
pytest dagster/ -v --cov=brev_pipelines

# Type checking
mypy dagster/src/

# Linting
ruff check dagster/

# Local execution
dagster dev -m brev_pipelines
```

### Integration Validation

```bash
# ArgoCD sync status
kubectl get applications -n argocd

# End-to-end data flow
# 1. Materialize raw_speeches
# 2. Check MinIO: raw-data/speeches/
# 3. Check LakeFS: data/main/speeches/
# 4. Check Weaviate: query CentralBankSpeeches collection
```

---

## Documentation Updates

After implementation is complete:

- [ ] `docs/invariants/INVARIANTS.md` - Add INV-D004 (Weaviate Collections), INV-P004 (Synthetic Data Isolation)
- [ ] `.CLAUDE.md` - Update with Weaviate patterns
- [ ] `README.md` - Add central bank speeches example
- [ ] `k8s/apps/weaviate/README.md` - Weaviate deployment docs
- [ ] `dagster/README.md` - Pipeline documentation

---

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Pending | | | Weaviate infrastructure |
| Phase 2 | Pending | | | Resources and dependencies |
| Phase 3 | Pending | | | Main ETL pipeline |
| Phase 4 | Pending | | | Synthetic data generation |
| Phase 5 | Pending | | | Marimo dashboard |
