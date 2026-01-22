# Central Bank Speeches Dashboard

Interactive vector search dashboard for exploring central bank speeches using semantic search.

## Features

- **Semantic Search**: Search speeches by meaning using AI embeddings (local NIM)
- **Real/Synthetic Toggle**: Switch between real and privacy-preserving synthetic data
- **Search Results**: View speeches with similarity scores and metadata
- **Data Overview**: Statistics and visualizations of the dataset

## Prerequisites

Before running this dashboard, ensure:

1. **Weaviate** is running with indexed speeches (Phase 3 pipeline completed)
2. **NIM Embedding** service is running for query embeddings
3. **LakeFS** has the data products stored
4. For synthetic data toggle: Phase 4 pipeline completed

## Running the Dashboard

### In JupyterHub

1. Start a JupyterHub session
2. Open a terminal
3. Navigate to the dashboard directory:
   ```bash
   cd ~/dashboards/central_bank_speeches
   ```
4. Run Marimo:
   ```bash
   marimo run dashboard.py
   ```
5. Access the dashboard at the displayed URL (typically `http://localhost:2718`)

### Local Development

```bash
# Set environment variables
export WEAVIATE_HOST=localhost
export WEAVIATE_PORT=8080
export WEAVIATE_GRPC_PORT=50051
export NIM_EMBEDDING_ENDPOINT=http://localhost:8000
export LAKEFS_ENDPOINT=http://localhost:8001
export LAKEFS_ACCESS_KEY_ID=your-key
export LAKEFS_SECRET_ACCESS_KEY=your-secret

# Port forward services (if needed)
kubectl port-forward svc/weaviate -n weaviate 8080:8080 &
kubectl port-forward svc/nvidia-nim-embedding -n nvidia-nim 8000:8000 &
kubectl port-forward svc/lakefs -n lakefs 8001:8000 &

# Run dashboard
marimo run dashboard.py

# Or edit interactively
marimo edit dashboard.py
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WEAVIATE_HOST` | Weaviate service host | `weaviate.weaviate.svc.cluster.local` |
| `WEAVIATE_PORT` | Weaviate HTTP port | `8080` |
| `WEAVIATE_GRPC_PORT` | Weaviate gRPC port | `50051` |
| `NIM_EMBEDDING_ENDPOINT` | NIM embedding service URL | `http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000` |
| `LAKEFS_ENDPOINT` | LakeFS endpoint | `http://lakefs.lakefs.svc.cluster.local:8000` |
| `LAKEFS_ACCESS_KEY_ID` | LakeFS access key | (required) |
| `LAKEFS_SECRET_ACCESS_KEY` | LakeFS secret key | (required) |

## Weaviate Collections

| Collection | Description |
|------------|-------------|
| `CentralBankSpeeches` | Real speeches with embeddings |
| `SyntheticSpeeches` | Privacy-preserving synthetic version (from Safe Synthesizer) |

## Search Tips

- Use **natural language queries** for best results (e.g., "inflation expectations and monetary policy")
- Semantic search finds **conceptually similar** speeches, not just keyword matches
- Toggle **synthetic data** to explore the privacy-preserving alternative
- Increase **result count** to see more matches

## Files

| File | Purpose |
|------|---------|
| `dashboard.py` | Main Marimo application |
| `utils.py` | Helper functions for Weaviate, NIM, and LakeFS |
| `pyproject.toml` | Python dependencies |
| `README.md` | This documentation |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Collection not found" | Run the Dagster pipeline to index speeches first |
| "Search error" | Check if Weaviate and NIM embedding services are running |
| "Could not load data product" | Verify LakeFS credentials and data product exists |
| Slow searches | Reduce result count or check service health |

## Data Pipeline

This dashboard consumes data from the following Dagster assets:

```
raw_speeches → cleaned_speeches → speech_embeddings → weaviate_index
                                ↘ tariff_classification → enriched_speeches → speeches_data_product
```

For synthetic data:
```
enriched_speeches → synthetic_speeches → synthetic_embeddings → synthetic_weaviate_index
```
