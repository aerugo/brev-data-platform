# Feature: Central Bank Speeches AI Data Product

**Status**: Approved
**Created**: 2026-01-22
**Category**: Application | Infrastructure | Integration

## Goal

Build an end-to-end AI-powered data product pipeline that ingests the Kaggle "central-bank-speeches" dataset, generates embeddings, classifies tariff mentions, enables vector search via Weaviate, creates a synthetic twin using NVIDIA Safe Synthesizer, and presents results in an interactive Marimo dashboard.

## Background

This project demonstrates the full capability of the Brev Data Platform by creating a real-world data product that:
1. Showcases the Dagster orchestration with LakeFS data versioning
2. Demonstrates NIM LLM capabilities for text classification
3. Introduces NIM embedding models for semantic search
4. Adds Weaviate as a vector database for similarity search
5. Uses NVIDIA Safe Synthesizer to create privacy-preserving synthetic data
6. Provides an interactive Marimo dashboard for exploration

The central bank speeches dataset contains thousands of speeches from major central banks, making it ideal for demonstrating:
- Text embedding and semantic search
- Binary classification (tariff mentions)
- Synthetic data generation for sensitive financial text
- Interactive data exploration

## Acceptance Criteria

- [ ] AC1: Dagster pipeline successfully ingests the Kaggle dataset and stores it in MinIO/LakeFS
- [ ] AC2: Speech embeddings are generated using a NIM embedding model (nvidia/nv-embedqa-e5-v5 or similar)
- [ ] AC3: Tariff classification uses NIM LLM and produces binary 0/1 labels stored in the data product
- [ ] AC4: Final data product (Polars DataFrame) is versioned in LakeFS with commit history
- [ ] AC5: Weaviate cluster is deployed and accessible within the Kubernetes cluster
- [ ] AC6: Speech text and embeddings are stored in Weaviate with proper schema
- [ ] AC7: Vector similarity search works correctly via Weaviate GraphQL API
- [ ] AC8: Synthetic twin is generated using NVIDIA Safe Synthesizer
- [ ] AC9: Synthetic data has separate Weaviate collection with its own embeddings
- [ ] AC10: Marimo dashboard allows switching between real and synthetic data
- [ ] AC11: Dashboard provides interactive vector search interface
- [ ] AC12: All data flows are tracked in Dagster asset lineage

## Technical Requirements

### Infrastructure Changes (Terraform)

- No Terraform changes required (all Kubernetes-based)

### Kubernetes Changes (Helm)

#### Weaviate Helm Chart (NEW)
- New chart at `k8s/apps/weaviate/`
- Single-node deployment suitable for development
- Persistent storage for vector index
- Resource limits following INV-K002
- ClusterIP service for internal access

#### NIM Embedding Model Configuration
- Option A: Second NIM deployment for embedding model
- Option B: Use NVIDIA API endpoint for embeddings (simpler, no GPU contention)
- Recommended: Option B for initial implementation, Option A as enhancement

### Application Changes

#### Dagster Pipeline (`dagster/src/brev_pipelines/assets/central_bank_speeches.py`)

```
Pipeline 1: Central Bank Speeches ETL
├── raw_speeches           # Ingest from Kaggle → MinIO
├── versioned_speeches     # Version in LakeFS
├── speech_embeddings      # Generate embeddings via NIM
├── tariff_classification  # Binary classification via NIM LLM
├── enriched_speeches      # Combined data product
├── weaviate_index         # Index in Weaviate
└── speeches_data_product  # Final versioned output

Pipeline 2: Synthetic Data Generation
├── synthetic_speeches     # Safe Synthesizer output
├── synthetic_embeddings   # Re-embed synthetic text
├── synthetic_weaviate     # Separate Weaviate collection
└── synthetic_validation   # MIA/AIA reports to LakeFS
```

#### New Resources (`dagster/src/brev_pipelines/resources/`)
- `weaviate.py` - Weaviate client resource
- `nim_embedding.py` - NIM embedding model resource (or extend NIMResource)
- `safe_synth.py` - Safe Synthesizer resource

#### I/O Managers (`dagster/src/brev_pipelines/io_managers/`)
- `lakefs_polars.py` - LakeFS I/O manager for Polars DataFrames
- `weaviate_io.py` - Weaviate I/O manager for vector storage

#### Marimo Dashboard (`marimo/central_bank_speeches/`)
- `dashboard.py` - Main interactive dashboard
- Search interface for vector queries
- Toggle between real/synthetic data
- Visualization of search results and embeddings

### GitOps Changes

- ArgoCD Application for Weaviate deployment
- Sync wave configuration (Weaviate deploys before Dagster uses it)

## Dependencies

### External Dependencies
- KaggleHub Python package (`kagglehub[polars-datasets]`)
- Weaviate Python client (`weaviate-client>=4.0`)
- Polars for DataFrame operations
- Marimo for dashboard

### Platform Dependencies
- Existing MinIO deployment (INV-D001)
- Existing LakeFS deployment (INV-D002)
- Existing NIM LLM deployment
- KAI Scheduler for GPU workloads (INV-I003)

### Service Dependencies
- NIM must be healthy for embedding and classification
- Safe Synthesizer requires exclusive GPU access (scale down NIM)

## Out of Scope

- Production-grade Weaviate clustering (single-node sufficient for demo)
- Multi-tenant data isolation in Weaviate
- Authentication/authorization for Weaviate API
- Real-time streaming updates to Weaviate
- Advanced dashboard features (export, sharing, collaboration)
- Automated Safe Synthesizer GPU switching (manual scale up/down)

## Security Considerations

- **Kaggle API credentials**: Store in Kubernetes secret (SOPS encrypted)
- **Weaviate authentication**: Disabled for development (internal-only access)
- **Synthetic data validation**: MIA/AIA reports ensure privacy protection
- **No external network exposure**: All services ClusterIP only
- **NGC API key**: Already managed per INV-S003

## Resource Requirements

### GPU Requirements
- NIM LLM (existing): 70GB VRAM allocation
- NIM Embedding: Use NVIDIA API (no additional GPU) OR dedicated deployment
- Safe Synthesizer: 80GB VRAM (exclusive, requires NIM scale-down)

### Memory/CPU Requirements
- Weaviate: 2GB RAM, 1 CPU (base), scales with data
- Dagster pipeline: 4GB RAM for embedding batch processing
- Marimo dashboard: Runs in JupyterHub (existing allocation)

### Storage Requirements
- Weaviate PVC: 20Gi for vector index
- LakeFS: Existing allocation sufficient
- Safe Synthesizer: Existing PVC allocation

## Open Questions

- [x] Q1: Should embeddings use local NIM or NVIDIA API? **Decision: NVIDIA API for simplicity**
- [x] Q2: Weaviate single-node vs cluster? **Decision: Single-node for dev**
- [x] Q3: How to handle Safe Synthesizer GPU contention? **Decision: Manual scale up/down via kubectl**
- [ ] Q4: Should Marimo dashboard run as dedicated service or within JupyterHub? **TBD in Phase 5**

## Data Product Schema

### Central Bank Speeches Data Product

```python
# Polars DataFrame schema
{
    "speech_id": pl.Utf8,           # Unique identifier
    "date": pl.Date,                # Speech date
    "central_bank": pl.Utf8,        # Issuing institution
    "speaker": pl.Utf8,             # Speaker name/title
    "title": pl.Utf8,               # Speech title
    "text": pl.Utf8,                # Full speech text
    "embedding": pl.List(pl.Float64), # 1024-dim vector (optional, stored in Weaviate)
    "tariff_mention": pl.Int8,      # 0 or 1
    "tariff_confidence": pl.Float64, # LLM confidence score
    "processed_at": pl.Datetime,    # Processing timestamp
}
```

### Weaviate Schema

```python
# Collection: CentralBankSpeeches
{
    "speech_id": "text",            # Cross-reference to data product
    "title": "text",                # Searchable
    "text": "text",                 # Main content for embedding
    "central_bank": "text",         # Filterable
    "speaker": "text",              # Filterable
    "date": "date",                 # Filterable
    "tariff_mention": "boolean",    # Filterable
}

# Collection: SyntheticSpeeches (same schema, separate collection)
```
