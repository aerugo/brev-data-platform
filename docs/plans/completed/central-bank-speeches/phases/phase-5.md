# Phase 5: Marimo Dashboard

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create an interactive Marimo dashboard for exploring central bank speeches using vector search, with the ability to switch between real and synthetic data products. The dashboard is delivered to users via JupyterHub through a separate repository that is included in the singleuser image.

---

## Invariants Enforced in This Phase

- **NEW INV-P004**: Synthetic Data Isolation - Dashboard distinguishes between real and synthetic data collections

---

## Dashboard Delivery to JupyterHub

### Architecture Overview

The dashboard code lives in a **separate Git repository** (`aerugo/brev-dashboards`) and is delivered to JupyterHub users through the custom singleuser image. This approach ensures:

1. **Separation of concerns**: Dashboard code is versioned independently
2. **Clean updates**: Dashboard changes don't require platform repo changes
3. **User experience**: Dashboards appear automatically at `/home/jovyan/dashboards/`

### Repository Structure

**New Repository**: `aerugo/brev-dashboards`

```
brev-dashboards/
├── central_bank_speeches/
│   ├── dashboard.py
│   ├── utils.py
│   ├── README.md
│   └── pyproject.toml
├── README.md
└── pyproject.toml
```

### Integration with JupyterHub Singleuser Image

The `aerugo/jupyterhub-singleuser` Dockerfile is updated to include the dashboards repository:

```dockerfile
# In aerugo/jupyterhub-singleuser Dockerfile
# Clone dashboards repository into user home directory
RUN git clone https://github.com/aerugo/brev-dashboards.git /home/jovyan/dashboards

# Set correct permissions
RUN chown -R jovyan:jovyan /home/jovyan/dashboards
```

### User Workflow

When a user opens JupyterHub and starts a server:

1. The singleuser pod starts with the custom image
2. `/home/jovyan/dashboards/` contains all dashboards (from image)
3. User's persistent storage (`/home/jovyan`) is mounted, but the `dashboards/` directory comes from the image
4. User navigates to `dashboards/central_bank_speeches/`
5. User runs `marimo run dashboard.py` or `marimo edit dashboard.py`

### Environment Variables Required

JupyterHub must inject these additional environment variables for the dashboard to connect to services:

| Variable | Source | Purpose |
|----------|--------|---------|
| `WEAVIATE_HOST` | Static | Weaviate service hostname |
| `WEAVIATE_PORT` | Static | Weaviate HTTP port |
| `WEAVIATE_GRPC_PORT` | Static | Weaviate gRPC port |
| `NIM_EMBEDDING_ENDPOINT` | Static | NIM embedding service URL |

These are added to the JupyterHub values.yaml in Step 5.7.

---

## Implementation Steps

### Step 5.1: Create Dashboard Directory Structure

**Action**: Create

**File(s)**: `marimo/central_bank_speeches/`

Create the directory structure for the Marimo dashboard.

```bash
mkdir -p marimo/central_bank_speeches
```

---

### Step 5.2: Create Dashboard Utilities

**Action**: Create

**File(s)**: `marimo/central_bank_speeches/utils.py`

Create helper functions for the dashboard.

```python
"""Utility functions for Central Bank Speeches dashboard."""

import os
from typing import Any

import polars as pl
import weaviate
from weaviate.classes.query import MetadataQuery

# Weaviate connection settings
WEAVIATE_HOST = os.getenv("WEAVIATE_HOST", "weaviate.weaviate.svc.cluster.local")
WEAVIATE_PORT = int(os.getenv("WEAVIATE_PORT", "8080"))
WEAVIATE_GRPC_PORT = int(os.getenv("WEAVIATE_GRPC_PORT", "50051"))

# NIM Embedding settings
NIM_EMBEDDING_ENDPOINT = os.getenv(
    "NIM_EMBEDDING_ENDPOINT",
    "http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000",
)
EMBEDDING_MODEL = "nvidia/llama-3_2-nemoretriever-300m-embed-v2"


def get_weaviate_client() -> weaviate.WeaviateClient:
    """Get a connected Weaviate client."""
    return weaviate.connect_to_custom(
        http_host=WEAVIATE_HOST,
        http_port=WEAVIATE_PORT,
        http_secure=False,
        grpc_host=WEAVIATE_HOST,
        grpc_port=WEAVIATE_GRPC_PORT,
        grpc_secure=False,
    )


def embed_query(query: str) -> list[float]:
    """Generate embedding for a search query using local NIM."""
    import requests

    payload = {
        "model": EMBEDDING_MODEL,
        "input": [query],
        "input_type": "query",  # Use "query" type for search queries
        "encoding_format": "float",
    }

    response = requests.post(
        f"{NIM_EMBEDDING_ENDPOINT}/v1/embeddings",
        json=payload,
        timeout=30,
    )
    response.raise_for_status()

    return response.json()["data"][0]["embedding"]


def vector_search(
    query: str,
    collection: str = "CentralBankSpeeches",
    limit: int = 10,
) -> list[dict[str, Any]]:
    """Perform vector similarity search on speeches.

    Args:
        query: Search query text
        collection: Weaviate collection name
        limit: Maximum results to return

    Returns:
        List of matching speeches with similarity scores
    """
    # Generate query embedding
    query_vector = embed_query(query)

    # Search in Weaviate
    client = get_weaviate_client()
    try:
        coll = client.collections.get(collection)

        results = coll.query.near_vector(
            near_vector=query_vector,
            limit=limit,
            return_metadata=MetadataQuery(distance=True, certainty=True),
        )

        output = []
        for obj in results.objects:
            item = dict(obj.properties)
            item["_distance"] = obj.metadata.distance
            item["_certainty"] = obj.metadata.certainty
            item["_similarity"] = 1 - (obj.metadata.distance or 0)  # Convert distance to similarity
            output.append(item)

        return output
    finally:
        client.close()


def get_collection_stats(collection: str) -> dict[str, Any]:
    """Get statistics about a Weaviate collection."""
    client = get_weaviate_client()
    try:
        if not client.collections.exists(collection):
            return {"exists": False, "count": 0}

        coll = client.collections.get(collection)
        response = coll.aggregate.over_all(total_count=True)

        return {
            "exists": True,
            "count": response.total_count or 0,
        }
    finally:
        client.close()


def load_data_product(use_synthetic: bool = False) -> pl.DataFrame:
    """Load the central bank speeches data product from LakeFS.

    Args:
        use_synthetic: If True, load synthetic data instead of real

    Returns:
        Polars DataFrame with speech data
    """
    import lakefs_sdk
    from lakefs_sdk.client import LakeFSClient

    # LakeFS settings
    lakefs_endpoint = os.getenv("LAKEFS_ENDPOINT", "http://lakefs.lakefs.svc.cluster.local:8000")
    lakefs_key = os.getenv("LAKEFS_ACCESS_KEY_ID", "")
    lakefs_secret = os.getenv("LAKEFS_SECRET_ACCESS_KEY", "")

    configuration = lakefs_sdk.Configuration(
        host=lakefs_endpoint,
        username=lakefs_key,
        password=lakefs_secret,
    )

    client = LakeFSClient(configuration)

    # Determine path
    if use_synthetic:
        path = "central-bank-speeches/synthetic/speeches.parquet"
    else:
        path = "central-bank-speeches/speeches.parquet"

    # Download file
    import io
    response = client.objects_api.get_object(
        repository="data",
        ref="main",
        path=path,
    )

    return pl.read_parquet(io.BytesIO(response.read()))


def get_sample_queries() -> list[str]:
    """Return sample queries for the dashboard."""
    return [
        "inflation expectations and monetary policy",
        "trade tensions and tariffs impact",
        "interest rate decisions",
        "quantitative easing programs",
        "financial stability risks",
        "cryptocurrency and digital currencies",
        "climate change economic impact",
        "labor market conditions",
        "supply chain disruptions",
        "housing market trends",
    ]
```

---

### Step 5.3: Create Main Dashboard

**Action**: Create

**File(s)**: `marimo/central_bank_speeches/dashboard.py`

Create the main Marimo dashboard.

```python
"""Central Bank Speeches Vector Search Dashboard.

Interactive dashboard for exploring central bank speeches using semantic search.
Supports switching between real and synthetic data products.

Run with: marimo run dashboard.py
"""

import marimo as mo


# --- App Definition ---

app = mo.App(title="Central Bank Speeches Explorer")


@app.cell
def header():
    mo.md("""
    # Central Bank Speeches Explorer

    Search through thousands of central bank speeches using AI-powered semantic search.
    Toggle between real and synthetic (privacy-preserving) data products.
    """)


@app.cell
def imports():
    from central_bank_speeches.utils import (
        vector_search,
        get_collection_stats,
        load_data_product,
        get_sample_queries,
    )
    import polars as pl
    return vector_search, get_collection_stats, load_data_product, get_sample_queries, pl


@app.cell
def data_source_toggle():
    """Toggle between real and synthetic data."""
    use_synthetic = mo.ui.switch(label="Use Synthetic Data", value=False)
    return use_synthetic


@app.cell
def collection_selector(use_synthetic):
    """Determine which Weaviate collection to use."""
    collection = "SyntheticSpeeches" if use_synthetic.value else "CentralBankSpeeches"
    return collection


@app.cell
def display_stats(collection, get_collection_stats):
    """Display collection statistics."""
    stats = get_collection_stats(collection)

    if stats["exists"]:
        mo.md(f"""
        **Data Source**: {collection}
        **Total Speeches**: {stats['count']:,}
        """)
    else:
        mo.callout(
            f"Collection '{collection}' not found. Run the Dagster pipeline first.",
            kind="danger",
        )
    return stats


@app.cell
def search_input(get_sample_queries):
    """Search query input."""
    sample_queries = get_sample_queries()

    query = mo.ui.text_area(
        label="Search Query",
        placeholder="Enter your search query...",
        value=sample_queries[0],
    )

    mo.md("### Search")
    mo.hstack([
        query,
        mo.md(f"_Sample queries: {', '.join(sample_queries[:3])}..._"),
    ])
    return query, sample_queries


@app.cell
def search_options():
    """Search configuration options."""
    num_results = mo.ui.slider(
        label="Number of Results",
        start=5,
        stop=50,
        value=10,
        step=5,
    )

    show_text = mo.ui.switch(label="Show Full Text", value=False)

    mo.hstack([num_results, show_text])
    return num_results, show_text


@app.cell
def search_button():
    """Search button."""
    search_btn = mo.ui.button(label="Search", kind="primary")
    return search_btn


@app.cell
def perform_search(search_btn, query, collection, num_results, vector_search):
    """Execute vector search when button is clicked."""
    search_btn  # Reactive dependency

    if not query.value.strip():
        mo.callout("Please enter a search query.", kind="info")
        results = []
    else:
        try:
            results = vector_search(
                query=query.value,
                collection=collection,
                limit=num_results.value,
            )
        except Exception as e:
            mo.callout(f"Search error: {e}", kind="danger")
            results = []

    return results


@app.cell
def display_results(results, show_text, pl):
    """Display search results."""
    if not results:
        mo.md("_No results to display._")
        return

    mo.md(f"### Results ({len(results)} found)")

    for i, result in enumerate(results, 1):
        similarity = result.get("_similarity", 0) * 100

        # Create result card
        card_content = f"""
        **{i}. {result.get('title', 'Untitled')}**

        - **Central Bank**: {result.get('central_bank', 'Unknown')}
        - **Speaker**: {result.get('speaker', 'Unknown')}
        - **Date**: {result.get('date', 'Unknown')}
        - **Tariff Mention**: {'Yes' if result.get('tariff_mention') else 'No'}
        - **Similarity**: {similarity:.1f}%
        """

        if show_text.value:
            text = result.get('text', '')[:500]
            card_content += f"\n\n**Text Preview**:\n_{text}..._"

        mo.callout(card_content, kind="neutral")


@app.cell
def data_overview(use_synthetic, load_data_product, pl):
    """Show data product overview."""
    mo.md("### Data Product Overview")

    try:
        df = load_data_product(use_synthetic=use_synthetic.value)

        # Summary statistics
        summary = {
            "Total Speeches": len(df),
            "Central Banks": df["central_bank"].n_unique(),
            "Tariff Mentions": df.filter(pl.col("tariff_mention") == 1).height,
            "Date Range": f"{df['date'].min()} to {df['date'].max()}",
        }

        for key, value in summary.items():
            mo.md(f"- **{key}**: {value}")

        # Central bank distribution
        bank_counts = df.group_by("central_bank").count().sort("count", descending=True).head(10)
        mo.md("**Top Central Banks by Speech Count:**")
        mo.ui.table(bank_counts.to_pandas())

    except Exception as e:
        mo.callout(f"Could not load data product: {e}", kind="warn")


@app.cell
def footer():
    """Dashboard footer."""
    mo.md("""
    ---
    **Central Bank Speeches Explorer** | Built with [Marimo](https://marimo.io)

    Data pipeline powered by Dagster, NIM, and Weaviate | Part of the Brev Data Platform
    """)


# --- Run ---
if __name__ == "__main__":
    app.run()
```

---

### Step 5.4: Create Dashboard README

**Action**: Create

**File(s)**: `marimo/central_bank_speeches/README.md`

Create documentation for the dashboard.

```markdown
# Central Bank Speeches Dashboard

Interactive vector search dashboard for exploring central bank speeches.

## Features

- **Semantic Search**: Search speeches by meaning, not just keywords
- **Real/Synthetic Toggle**: Switch between real and privacy-preserving synthetic data
- **Search Results**: View speeches with similarity scores
- **Data Overview**: Statistics and visualizations of the dataset

## Requirements

- Weaviate must be running with indexed speeches (Phase 3)
- Synthetic data pipeline completed (Phase 4) for synthetic toggle
- Environment variables configured for Weaviate and NIM embedding access

## Running the Dashboard

### In JupyterHub

1. Start a JupyterHub session
2. Open a terminal
3. Navigate to the dashboard directory:
   ```bash
   cd /path/to/marimo/central_bank_speeches
   ```
4. Run Marimo:
   ```bash
   marimo run dashboard.py
   ```
5. Access the dashboard at the displayed URL

### Locally (for development)

```bash
# Set environment variables
export WEAVIATE_HOST=localhost
export WEAVIATE_PORT=8080
export NGC_API_KEY=your-key

# Port forward Weaviate (if needed)
kubectl port-forward svc/weaviate -n weaviate 8080:8080

# Run dashboard
marimo run dashboard.py
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `WEAVIATE_HOST` | Weaviate service host | `weaviate.weaviate.svc.cluster.local` |
| `WEAVIATE_PORT` | Weaviate HTTP port | `8080` |
| `WEAVIATE_GRPC_PORT` | Weaviate gRPC port | `50051` |
| `NIM_EMBEDDING_ENDPOINT` | NIM embedding service endpoint | `http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000` |
| `LAKEFS_ENDPOINT` | LakeFS endpoint for data products | `http://lakefs.lakefs.svc.cluster.local:8000` |
| `LAKEFS_ACCESS_KEY_ID` | LakeFS access key | (required) |
| `LAKEFS_SECRET_ACCESS_KEY` | LakeFS secret key | (required) |

## Data Collections

- **CentralBankSpeeches**: Real speeches with embeddings
- **SyntheticSpeeches**: Privacy-preserving synthetic version

## Search Tips

- Use natural language queries for best results
- Semantic search finds conceptually similar speeches
- Try sample queries like "inflation expectations" or "trade tensions"
- Toggle synthetic data to explore privacy-preserving alternative
```

---

### Step 5.5: Create pyproject.toml for Dashboard

**Action**: Create

**File(s)**: `marimo/central_bank_speeches/pyproject.toml`

Create minimal project file for dependencies.

```toml
[project]
name = "central-bank-speeches-dashboard"
version = "0.1.0"
description = "Interactive dashboard for central bank speeches exploration"
requires-python = ">=3.10"
dependencies = [
    "marimo>=0.9.0",
    "polars>=1.0.0",
    "weaviate-client>=4.9.0",
    "requests>=2.31.0",
    "lakefs-sdk>=1.0.0",
]
```

---

### Step 5.6: Create brev-dashboards Repository

**Action**: Create (External Repository)

**Repository**: `github.com/aerugo/brev-dashboards`

Create a new Git repository for dashboards. This repository will be cloned into the JupyterHub singleuser image.

**Repository Structure**:
```
brev-dashboards/
├── central_bank_speeches/
│   ├── dashboard.py          # Main Marimo dashboard (from Step 5.3)
│   ├── utils.py              # Helper functions (from Step 5.2)
│   ├── README.md             # Dashboard documentation (from Step 5.4)
│   └── pyproject.toml        # Dependencies (from Step 5.5)
├── README.md                 # Repository overview
└── pyproject.toml            # Root project file
```

**Root README.md**:
```markdown
# Brev Dashboards

Interactive Marimo dashboards for the Brev Data Platform.

## Available Dashboards

| Dashboard | Description | Run Command |
|-----------|-------------|-------------|
| [Central Bank Speeches](central_bank_speeches/) | Vector search for central bank speeches | `marimo run central_bank_speeches/dashboard.py` |

## Usage in JupyterHub

These dashboards are pre-installed at `/home/jovyan/dashboards/` in JupyterHub.

1. Start a JupyterHub session
2. Open a terminal
3. Run the dashboard:
   ```bash
   cd ~/dashboards
   marimo run central_bank_speeches/dashboard.py
   ```
4. Access the dashboard at the displayed URL

## Development

For local development:

1. Clone this repository
2. Port-forward required services:
   ```bash
   kubectl port-forward svc/weaviate -n weaviate 8080:8080
   kubectl port-forward svc/nvidia-nim-embedding -n nvidia-nim 8000:8000
   ```
3. Set environment variables:
   ```bash
   export WEAVIATE_HOST=localhost
   export NIM_EMBEDDING_ENDPOINT=http://localhost:8000
   ```
4. Run the dashboard:
   ```bash
   marimo run central_bank_speeches/dashboard.py
   ```
```

**Root pyproject.toml**:
```toml
[project]
name = "brev-dashboards"
version = "0.1.0"
description = "Interactive Marimo dashboards for Brev Data Platform"
requires-python = ">=3.10"

[project.optional-dependencies]
all = [
    "marimo>=0.9.0",
    "polars>=1.0.0",
    "weaviate-client>=4.9.0",
    "requests>=2.31.0",
    "lakefs-sdk>=1.0.0",
]
```

---

### Step 5.7: Update JupyterHub Configuration

**Action**: Modify

**File(s)**: `k8s/apps/jupyterhub/values.yaml`

Add Weaviate and NIM embedding environment variables to the JupyterHub singleuser configuration.

**Add to `singleuser.extraEnv`**:
```yaml
      # Weaviate connection for vector search dashboards
      WEAVIATE_HOST:
        value: "weaviate.weaviate.svc.cluster.local"
      WEAVIATE_PORT:
        value: "8080"
      WEAVIATE_GRPC_PORT:
        value: "50051"
      # NIM Embedding service for generating query embeddings
      NIM_EMBEDDING_ENDPOINT:
        value: "http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000"
```

**Validation**:
```bash
# Verify values.yaml is valid
helm lint k8s/apps/jupyterhub/

# After sync, verify env vars in pod
kubectl exec -n jupyterhub <singleuser-pod> -- env | grep -E "(WEAVIATE|NIM)"
```

---

### Step 5.8: Update JupyterHub Singleuser Image

**Action**: Modify (External Repository)

**Repository**: `github.com/aerugo/jupyterhub-singleuser`

Update the Dockerfile to include the brev-dashboards repository.

**Add to Dockerfile**:
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

**Note**: After updating the Dockerfile:
1. Build and push new image: `docker build -t ghcr.io/aerugo/jupyterhub-singleuser:latest . && docker push ghcr.io/aerugo/jupyterhub-singleuser:latest`
2. JupyterHub will pull the new image on next pod spawn (pullPolicy: Always)

---

### Step 5.9: Verify Dashboard Delivery

**Action**: Validate

After Steps 5.6-5.8 are complete, verify the dashboard is accessible in JupyterHub.

**Verification Steps**:
```bash
# 1. Start a JupyterHub session
#    - Access JupyterHub via make port-forward-jupyterhub
#    - Login with any username/password
#    - Start a server with "Standard (CPU only)" profile

# 2. Open terminal in JupyterHub and verify dashboards exist
ls -la ~/dashboards/
ls -la ~/dashboards/central_bank_speeches/

# 3. Verify environment variables are set
env | grep WEAVIATE
env | grep NIM_EMBEDDING

# 4. Run the dashboard
cd ~/dashboards
marimo run central_bank_speeches/dashboard.py

# 5. Access dashboard URL shown in terminal output
```

**Expected Outcomes**:
- `/home/jovyan/dashboards/` directory exists
- `central_bank_speeches/dashboard.py` is present
- Environment variables `WEAVIATE_HOST`, `NIM_EMBEDDING_ENDPOINT` are set
- Dashboard launches successfully
- Search functionality works (connects to Weaviate and NIM)

---

## Files

### In `brev-data-platform` Repository

| File | Action | Purpose |
|------|--------|---------|
| `k8s/apps/jupyterhub/values.yaml` | MODIFY | Add Weaviate and NIM env vars |

### In New `brev-dashboards` Repository

| File | Action | Purpose |
|------|--------|---------|
| `central_bank_speeches/dashboard.py` | CREATE | Main Marimo dashboard |
| `central_bank_speeches/utils.py` | CREATE | Helper functions |
| `central_bank_speeches/README.md` | CREATE | Dashboard documentation |
| `central_bank_speeches/pyproject.toml` | CREATE | Dependencies |
| `README.md` | CREATE | Repository overview |
| `pyproject.toml` | CREATE | Root project file |

### In `jupyterhub-singleuser` Repository

| File | Action | Purpose |
|------|--------|---------|
| `Dockerfile` | MODIFY | Add dashboard clone and dependencies |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `WEAVIATE_HOST` | `weaviate.weaviate.svc.cluster.local` | Weaviate connection |
| `WEAVIATE_PORT` | `8080` | Weaviate HTTP port |
| `NIM_EMBEDDING_ENDPOINT` | Service URL | NIM embedding service |
| `LAKEFS_ENDPOINT` | `http://lakefs.lakefs.svc.cluster.local:8000` | Data product access |

---

## Verification

### Pre-flight Checks

```bash
# Verify Weaviate collections exist
kubectl run -n weaviate curl-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s http://weaviate.weaviate.svc.cluster.local:8080/v1/schema | head -50

# Verify JupyterHub is running
kubectl get pods -n jupyterhub
```

### Validation Commands

```bash
# Test utils module
cd marimo/central_bank_speeches
python -c "from utils import get_sample_queries; print(get_sample_queries())"

# Run dashboard locally (with port forwarding)
# Terminal 1:
kubectl port-forward svc/weaviate -n weaviate 8080:8080

# Terminal 2: Port forward NIM embedding
kubectl port-forward svc/nvidia-nim-embedding -n nvidia-nim 8000:8000

# Terminal 3:
export WEAVIATE_HOST=localhost
export NIM_EMBEDDING_ENDPOINT=http://localhost:8000
marimo run dashboard.py

# In JupyterHub:
# 1. Open terminal
# 2. cd to marimo/central_bank_speeches
# 3. marimo run dashboard.py
```

### Expected Outcomes

- Dashboard loads without errors
- Search input accepts queries
- Vector search returns relevant results
- Real/synthetic toggle switches collections
- Data overview shows statistics
- Similarity scores display correctly

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Weaviate connection failed | Connection error | Verify Weaviate is running |
| NIM embedding error | Connection error | Check NIM embedding pod is running |
| Collection not found | Empty results | Run Dagster pipeline first |
| Slow search | Long response time | Reduce result limit |
| Memory issues | JupyterHub OOM | Use smaller data samples |

### Rollback Plan

If this phase fails:
1. Remove dashboard files
2. Investigate errors
3. Test utilities independently
4. Retry with simpler dashboard

---

## Future Enhancements

1. **UMAP Visualization**: Add embedding space visualization
2. **Filters**: Filter by central bank, date range, tariff mention
3. **Export**: Export search results to CSV/JSON
4. **Comparison**: Side-by-side real vs synthetic results
5. **Dedicated Deployment**: Deploy dashboard as standalone service

---

## Completion Criteria

### Dashboard Code (brev-dashboards repository)
- [ ] `brev-dashboards` repository created at `github.com/aerugo/brev-dashboards`
- [ ] `central_bank_speeches/utils.py` with helper functions
- [ ] `central_bank_speeches/dashboard.py` main Marimo app
- [ ] `central_bank_speeches/README.md` documentation
- [ ] `central_bank_speeches/pyproject.toml` dependencies
- [ ] Root `README.md` and `pyproject.toml` created

### JupyterHub Integration
- [ ] `k8s/apps/jupyterhub/values.yaml` updated with WEAVIATE_* and NIM_EMBEDDING_ENDPOINT env vars
- [ ] `jupyterhub-singleuser` Dockerfile updated to clone brev-dashboards
- [ ] New singleuser image built and pushed to ghcr.io
- [ ] `/home/jovyan/dashboards/` directory exists in JupyterHub pods
- [ ] Environment variables accessible in JupyterHub session

### Functional Verification
- [ ] Dashboard runs in JupyterHub via `marimo run dashboard.py`
- [ ] Search returns relevant results (connects to Weaviate)
- [ ] Embeddings generated via local NIM (not external API)
- [ ] Real/synthetic toggle switches between collections
- [ ] Data overview displays statistics from LakeFS
- [ ] NEW INV-P004 verified (data isolation)
