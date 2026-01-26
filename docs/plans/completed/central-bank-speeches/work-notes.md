# Central Bank Speeches AI Data Product - Work Notes

**Feature**: End-to-end AI data product pipeline with vector search, synthetic data, and interactive dashboard
**Started**: 2026-01-22
**Branch**: `feature/central-bank-speeches`

---

## Session Log

### 2026-01-22 - Initial Planning

**Context Review Completed**:

- Read `docs/invariants/INVARIANTS.md` - identified 16 applicable invariants
- Read `docs/plans/CLAUDE.md` - understood planning protocol
- Read `.claude/agents/` - understood patterns for Dagster, Helm, ArgoCD
- Analyzed `dagster/src/brev_pipelines/` - understood asset patterns
- Analyzed `k8s/apps/nvidia-nim/values.yaml` - understood GPU configuration
- Analyzed `k8s/apps/nvidia-safe-synth/values.yaml` - understood synthetic data setup

**Applicable Invariants**:

| ID | Name | How It Applies |
|----|------|----------------|
| INV-I003 | H200 141GB GPU Required | Safe Synthesizer needs exclusive 80GB, must scale down NIM |
| INV-K001 | Namespace Per Application | Weaviate gets `weaviate` namespace |
| INV-K002 | Resource Limits on All Pods | All new pods need requests/limits |
| INV-K005 | No latest Tags | Pin Weaviate image version |
| INV-S001 | No Plaintext Secrets | Kaggle creds encrypted with SOPS |
| INV-D001 | Standard Bucket Structure | Use raw-data, data-products buckets |
| INV-D002 | LakeFS for Data Versioning | All outputs versioned in LakeFS |
| INV-D003 | Parquet for Structured Data | Store DataFrames as Parquet |
| INV-P001 | Assets Over Ops | Use @asset decorator |
| INV-P002 | I/O Managers for Storage | Create LakeFS/Weaviate I/O managers |
| INV-P003 | Type Annotations | Full typing on all assets |
| INV-N001 | NIM Requires GPU | Use NVIDIA API for embeddings (no GPU conflict) |
| INV-N003 | Safe Synth to LakeFS | Synthetic data versioned |
| INV-N004 | NIM Observability | Enable metrics for new usage |
| INV-G001 | App-of-Apps | Weaviate via argocd-apps |
| INV-G004 | Sync Waves | Weaviate before Dagster usage |

**Key Insights**:

1. **GPU Contention**: NIM LLM uses 70GB, Safe Synthesizer needs 80GB exclusive. Cannot run simultaneously - need manual scale down/up procedure.

2. **Embedding Strategy**: Instead of deploying second NIM for embeddings, use NVIDIA API (`integrate.api.nvidia.com`). Same NGC credentials, no GPU needed.

3. **Weaviate Sizing**: ~10K speeches, 1024-dim embeddings = ~40MB vectors + metadata. Single-node Weaviate with 20Gi PVC is plenty.

4. **I/O Manager Gap**: Current codebase has empty `io_managers/` directory. This feature introduces first proper I/O managers for LakeFS + Weaviate.

5. **Polars Alignment**: KaggleHub loader uses Polars. Continue with Polars throughout for consistency.

**Completed**:

- [x] Read project context and invariants
- [x] Analyzed existing demo pipeline patterns
- [x] Analyzed NIM configuration and GPU allocation
- [x] Created feature specification (spec.md)
- [x] Created development plan (development-plan.md)
- [x] Created work notes (this file)

**Decisions Made**:

1. **Embeddings**: Use NVIDIA API, not local NIM deployment
2. **Weaviate**: Single-node deployment in dedicated namespace
3. **DataFrames**: Use Polars throughout
4. **Dashboard**: Run in JupyterHub initially
5. **GPU Switching**: Manual kubectl scale for Safe Synthesizer

**Next Steps**:

1. Create Phase 1 detailed plan (Weaviate infrastructure)
2. Create Phase 2 detailed plan (Resources and dependencies)
3. Create Phase 3 detailed plan (ETL pipeline)
4. Create Phase 4 detailed plan (Synthetic data)
5. Create Phase 5 detailed plan (Dashboard)
6. Begin implementation with Phase 1

---

## Phase Progress

### Phase 1: Weaviate Infrastructure

**Status**: Pending
**Started**:
**Completed**:

#### Notes

- Will use official Weaviate Helm chart as base
- Need to configure for single-node development mode
- PVC for persistent vector storage
- ClusterIP service (internal only)

---

### Phase 2: Embedding & Resource Setup

**Status**: Pending
**Started**:
**Completed**:

#### Notes

- NVIDIA embedding API uses OpenAI-compatible format
- Model: `nvidia/nv-embedqa-e5-v5` (1024 dimensions)
- Weaviate client v4 uses new class-based API

---

### Phase 3: Central Bank Speeches ETL

**Status**: Pending
**Started**:
**Completed**:

#### Notes

- 7 assets in pipeline
- First real I/O managers for the project
- Batch embedding generation for efficiency

---

### Phase 4: Synthetic Data Pipeline

**Status**: Pending
**Started**:
**Completed**:

#### Notes

- Requires exclusive GPU access
- Need clear procedure for NIM ↔ Safe Synth switching
- MIA/AIA reports for privacy validation

---

### Phase 5: Marimo Dashboard

**Status**: Pending
**Started**:
**Completed**:

#### Notes

- Run in JupyterHub initially
- Consider dedicated deployment later
- Need UMAP for embedding visualization

---

## Key Decisions

### Decision 1: NVIDIA API for Embeddings

**Date**: 2026-01-22
**Context**: Need to generate embeddings for ~10K speeches without disrupting NIM LLM
**Decision**: Use NVIDIA API endpoint instead of local NIM embedding model
**Rationale**:
- No additional GPU resources needed
- Same NGC credentials already configured
- Simplifies deployment (no second NIM)
- API is reliable and fast for batch operations
**Alternatives Considered**:
- Local NIM embedding model (rejected: GPU contention with LLM)
- Open source embedding model in Python (rejected: slower, less accurate)

### Decision 2: Polars Over Pandas

**Date**: 2026-01-22
**Context**: Need DataFrame operations for speech data processing
**Decision**: Use Polars throughout the pipeline
**Rationale**:
- KaggleHub example uses Polars
- Better performance for large text data
- Lazy evaluation for memory efficiency
- Better type system
**Alternatives Considered**:
- Pandas (rejected: slower, more memory, less typed)
- DuckDB (considered: good option, but Polars integrates better with I/O managers)

### Decision 3: Manual GPU Switching

**Date**: 2026-01-22
**Context**: Safe Synthesizer needs exclusive GPU access
**Decision**: Use manual kubectl scale commands for switching
**Rationale**:
- Clear visibility into GPU allocation
- Safer than automated switching
- Easy to debug if issues occur
- Can automate later if needed
**Alternatives Considered**:
- Automated Dagster sensor (rejected: complex, harder to debug)
- Job-based scaling (rejected: ArgoCD sync issues)

---

## Files Modified

### Created

- `docs/plans/active/central-bank-speeches/spec.md` - Feature specification
- `docs/plans/active/central-bank-speeches/development-plan.md` - Implementation plan
- `docs/plans/active/central-bank-speeches/work-notes.md` - This file
- `docs/plans/active/central-bank-speeches/phases/` - Directory for phase plans

### Modified

- (none yet)

---

## Commands Reference

Commands that will be useful during implementation:

```bash
# Helm validation
helm lint k8s/apps/weaviate/
helm template weaviate k8s/apps/weaviate/ -f k8s/apps/weaviate/values.yaml

# Weaviate status
kubectl get pods -n weaviate
kubectl logs -n weaviate deployment/weaviate

# Dagster development
dagster dev -m brev_pipelines
pytest dagster/ -v

# NIM ↔ Safe Synthesizer switching
kubectl scale deployment nvidia-nim-llm --replicas=0 -n nvidia-nim
kubectl scale deployment nvidia-safe-synth --replicas=1 -n nvidia-ai
# Wait for Safe Synth ready, run pipeline, then reverse:
kubectl scale deployment nvidia-safe-synth --replicas=0 -n nvidia-ai
kubectl scale deployment nvidia-nim-llm --replicas=1 -n nvidia-nim

# Weaviate queries (from within cluster)
curl http://weaviate.weaviate.svc.cluster.local:8080/v1/.well-known/ready
```

---

## Documentation Updates Required

### INVARIANTS.md Changes

- [ ] Add INV-D004: Weaviate Collections for Vector Data
- [ ] Add INV-P004: Synthetic Data Isolation

### Other Documentation

- [ ] `.CLAUDE.md` - Add Weaviate patterns
- [ ] `README.md` - Add central bank speeches example
- [ ] `k8s/apps/weaviate/README.md` - Deployment documentation
- [ ] `dagster/README.md` - Pipeline documentation
- [ ] `marimo/README.md` - Dashboard documentation

---

## Post-Implementation Notes

*(To be filled after implementation)*
