# Marimo Dashboards

Interactive Marimo dashboards for the Brev Data Platform.

## Available Dashboards

| Dashboard | Description | Run Command |
|-----------|-------------|-------------|
| [Central Bank Speeches](central_bank_speeches/) | Vector search for central bank speeches | `marimo run central_bank_speeches/dashboard.py` |

## Deployment to JupyterHub

These dashboards are designed to be deployed to JupyterHub users through a separate repository. Follow these steps:

### Step 1: Create brev-dashboards Repository

Create a new GitHub repository `aerugo/brev-dashboards` with this structure:

```
brev-dashboards/
├── central_bank_speeches/
│   ├── dashboard.py        # Copy from marimo/central_bank_speeches/
│   ├── utils.py            # Copy from marimo/central_bank_speeches/
│   ├── README.md           # Copy from marimo/central_bank_speeches/
│   └── pyproject.toml      # Copy from marimo/central_bank_speeches/
├── README.md               # Repository overview
└── pyproject.toml          # Root dependencies
```

### Step 2: Update JupyterHub Singleuser Image

Add to the `aerugo/jupyterhub-singleuser` Dockerfile:

```dockerfile
# Clone Brev Dashboards repository
# Dashboards are available at /home/jovyan/dashboards/
RUN git clone --depth 1 https://github.com/aerugo/brev-dashboards.git /home/jovyan/dashboards \
    && chown -R jovyan:jovyan /home/jovyan/dashboards

# Install dashboard dependencies
RUN pip install --no-cache-dir \
    weaviate-client>=4.9.0 \
    requests>=2.31.0 \
    lakefs-sdk>=1.0.0
```

### Step 3: Rebuild and Push Image

```bash
cd /path/to/jupyterhub-singleuser
docker build -t ghcr.io/aerugo/jupyterhub-singleuser:latest .
docker push ghcr.io/aerugo/jupyterhub-singleuser:latest
```

### Step 4: Verify in JupyterHub

1. Start a JupyterHub session
2. Open terminal
3. Check dashboards exist:
   ```bash
   ls -la ~/dashboards/
   ls -la ~/dashboards/central_bank_speeches/
   ```
4. Run a dashboard:
   ```bash
   cd ~/dashboards
   marimo run central_bank_speeches/dashboard.py
   ```

## Local Development

For developing dashboards locally:

```bash
# Set environment variables
export WEAVIATE_HOST=localhost
export WEAVIATE_PORT=8080
export WEAVIATE_GRPC_PORT=50051
export NIM_EMBEDDING_ENDPOINT=http://localhost:8000
export LAKEFS_ENDPOINT=http://localhost:8001
export LAKEFS_ACCESS_KEY_ID=your-key
export LAKEFS_SECRET_ACCESS_KEY=your-secret

# Port forward services
kubectl port-forward svc/weaviate -n weaviate 8080:8080 &
kubectl port-forward svc/nvidia-nim-embedding -n nvidia-nim 8000:8000 &
kubectl port-forward svc/lakefs -n lakefs 8001:8000 &

# Run dashboard
cd central_bank_speeches
marimo run dashboard.py

# Or edit interactively
marimo edit dashboard.py
```

## Adding New Dashboards

1. Create a new directory under `marimo/`
2. Add `dashboard.py`, `utils.py`, `README.md`, `pyproject.toml`
3. Update this README with the new dashboard
4. Copy files to `brev-dashboards` repository
5. Rebuild JupyterHub singleuser image if adding new dependencies

## Environment Variables

JupyterHub injects these environment variables automatically:

| Variable | Purpose |
|----------|---------|
| `WEAVIATE_HOST` | Weaviate service hostname |
| `WEAVIATE_PORT` | Weaviate HTTP port |
| `WEAVIATE_GRPC_PORT` | Weaviate gRPC port |
| `NIM_EMBEDDING_ENDPOINT` | NIM embedding service URL |
| `LAKEFS_ENDPOINT` | LakeFS service URL |
| `LAKEFS_ACCESS_KEY_ID` | LakeFS access credentials |
| `LAKEFS_SECRET_ACCESS_KEY` | LakeFS secret credentials |
| `MINIO_ENDPOINT` | MinIO service URL |
| `MINIO_ACCESS_KEY` | MinIO access credentials |
| `MINIO_SECRET_KEY` | MinIO secret credentials |
