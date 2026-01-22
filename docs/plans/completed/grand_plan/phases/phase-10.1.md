# Phase 10.1: Dagster Pipelines Repository

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create a separate repository for Dagster pipeline code (assets, resources, I/O managers) with its own Docker image build pipeline. This separates application code from infrastructure, enabling independent release cycles and cleaner CI/CD.

---

## Rationale

The current setup uses a ConfigMap-based approach which has limitations:
- Cannot add Python dependencies beyond the base Dagster image
- Large code files in ConfigMaps are awkward to manage
- No proper Python project structure (tests, linting, typing)

A separate repository enables:
- Custom Docker image with all required dependencies
- Proper Python project with pytest, ruff, mypy
- Independent CI/CD for pipeline code
- Clear separation: infrastructure vs application

---

## Repository Structure

```
brev-dagster-pipelines/
├── .github/
│   └── workflows/
│       └── build.yml              # Build and push Docker image to GHCR
├── src/
│   └── brev_pipelines/
│       ├── __init__.py
│       ├── definitions.py         # Main Dagster Definitions
│       ├── assets/
│       │   ├── __init__.py
│       │   ├── demo.py            # Demo pipeline assets
│       │   └── health.py          # Health check assets
│       ├── resources/
│       │   ├── __init__.py
│       │   ├── minio.py           # MinIO resource
│       │   ├── lakefs.py          # LakeFS resource
│       │   └── nim.py             # NIM LLM resource
│       └── io_managers/
│           ├── __init__.py
│           └── minio.py           # MinIO I/O manager
├── tests/
│   ├── __init__.py
│   ├── test_assets.py
│   └── test_resources.py
├── Dockerfile
├── pyproject.toml
├── requirements.txt
├── README.md
└── .gitignore
```

---

## Files to Create

### Dockerfile

```dockerfile
FROM python:3.11-slim

WORKDIR /opt/dagster/app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY src/ ./src/
COPY pyproject.toml .

# Install the package
RUN pip install --no-cache-dir -e .

# Set Dagster home
ENV DAGSTER_HOME=/opt/dagster/dagster_home
RUN mkdir -p $DAGSTER_HOME

# Expose gRPC port
EXPOSE 4000

# Run Dagster code server
CMD ["dagster", "api", "grpc", "-h", "0.0.0.0", "-p", "4000", "-m", "brev_pipelines.definitions"]
```

### requirements.txt

```
# Dagster core
dagster>=1.6.0,<2.0.0
dagster-postgres>=0.22.0
dagster-k8s>=0.22.0

# Data processing
pandas>=2.0.0
numpy>=1.24.0
pyarrow>=14.0.0

# Storage clients
minio>=7.2.0
lakefs-sdk>=1.0.0
boto3>=1.34.0
s3fs>=2024.1.0

# HTTP client
requests>=2.31.0
httpx>=0.26.0

# Utilities
pydantic>=2.0.0
python-dotenv>=1.0.0
```

### pyproject.toml

```toml
[build-system]
requires = ["setuptools>=61.0", "wheel"]
build-backend = "setuptools.build_meta"

[project]
name = "brev-pipelines"
version = "0.1.0"
description = "Dagster pipelines for Brev Data Platform"
readme = "README.md"
requires-python = ">=3.11"
dependencies = [
    "dagster>=1.6.0,<2.0.0",
    "pandas>=2.0.0",
    "minio>=7.2.0",
    "lakefs-sdk>=1.0.0",
    "requests>=2.31.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=7.0.0",
    "pytest-cov>=4.0.0",
    "ruff>=0.1.0",
    "mypy>=1.0.0",
    "dagster-webserver>=1.6.0",
]

[tool.setuptools.packages.find]
where = ["src"]

[tool.ruff]
line-length = 100
target-version = "py311"

[tool.ruff.lint]
select = ["E", "F", "I", "W"]
ignore = ["E501"]

[tool.mypy]
python_version = "3.11"
ignore_missing_imports = true
```

### src/brev_pipelines/__init__.py

```python
"""Brev Data Platform - Dagster Pipelines."""

__version__ = "0.1.0"
```

### src/brev_pipelines/definitions.py

```python
"""Dagster definitions for Brev Data Platform."""

import os
from dagster import Definitions, EnvVar

from brev_pipelines.assets.demo import demo_assets
from brev_pipelines.assets.health import health_assets
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.nim import NIMResource

defs = Definitions(
    assets=[
        *demo_assets,
        *health_assets,
    ],
    resources={
        "minio": MinIOResource(
            endpoint=os.getenv("MINIO_ENDPOINT", "minio.minio.svc.cluster.local:9000"),
            access_key=EnvVar("MINIO_ACCESS_KEY"),
            secret_key=EnvVar("MINIO_SECRET_KEY"),
            secure=False,
        ),
        "lakefs": LakeFSResource(
            endpoint=os.getenv("LAKEFS_ENDPOINT", "lakefs.lakefs.svc.cluster.local:8000"),
            access_key=EnvVar("LAKEFS_ACCESS_KEY_ID"),
            secret_key=EnvVar("LAKEFS_SECRET_ACCESS_KEY"),
        ),
        "nim": NIMResource(
            endpoint=os.getenv("NIM_ENDPOINT", "http://nvidia-nim-llm.nvidia-nim.svc.cluster.local:8000"),
        ),
    },
)
```

### src/brev_pipelines/resources/minio.py

```python
"""MinIO resource for Dagster."""

from dagster import ConfigurableResource
from minio import Minio
from pydantic import Field


class MinIOResource(ConfigurableResource):
    """MinIO S3-compatible storage resource."""

    endpoint: str = Field(description="MinIO endpoint (host:port)")
    access_key: str = Field(description="Access key")
    secret_key: str = Field(description="Secret key")
    secure: bool = Field(default=False, description="Use HTTPS")

    def get_client(self) -> Minio:
        """Get MinIO client instance."""
        return Minio(
            self.endpoint,
            access_key=self.access_key,
            secret_key=self.secret_key,
            secure=self.secure,
        )

    def ensure_bucket(self, bucket: str) -> None:
        """Ensure bucket exists, create if not."""
        client = self.get_client()
        if not client.bucket_exists(bucket):
            client.make_bucket(bucket)
```

### src/brev_pipelines/resources/lakefs.py

```python
"""LakeFS resource for Dagster."""

from dagster import ConfigurableResource
from pydantic import Field


class LakeFSResource(ConfigurableResource):
    """LakeFS data versioning resource."""

    endpoint: str = Field(description="LakeFS endpoint (host:port)")
    access_key: str = Field(description="Access key ID")
    secret_key: str = Field(description="Secret access key")

    def get_client(self):
        """Get LakeFS client instance."""
        import lakefs_sdk
        from lakefs_sdk.client import LakeFSClient

        config = lakefs_sdk.Configuration(
            host=f"http://{self.endpoint}",
            username=self.access_key,
            password=self.secret_key,
        )
        return LakeFSClient(config)

    def list_repositories(self) -> list[str]:
        """List all repositories."""
        client = self.get_client()
        repos = client.repositories_api.list_repositories()
        return [repo.id for repo in repos.results]
```

### src/brev_pipelines/resources/nim.py

```python
"""NVIDIA NIM LLM resource for Dagster."""

import requests
from dagster import ConfigurableResource
from pydantic import Field


class NIMResource(ConfigurableResource):
    """NVIDIA NIM LLM inference resource."""

    endpoint: str = Field(description="NIM endpoint URL")
    model: str = Field(default="meta/llama3-8b-instruct", description="Model name")
    timeout: int = Field(default=30, description="Request timeout in seconds")

    def generate(self, prompt: str, max_tokens: int = 100, temperature: float = 0.7) -> str:
        """Generate text using NIM LLM."""
        try:
            response = requests.post(
                f"{self.endpoint}/v1/completions",
                json={
                    "model": self.model,
                    "prompt": prompt,
                    "max_tokens": max_tokens,
                    "temperature": temperature,
                },
                timeout=self.timeout,
            )
            response.raise_for_status()
            return response.json()["choices"][0]["text"].strip()
        except Exception as e:
            return f"LLM error: {e}"

    def health_check(self) -> bool:
        """Check if NIM is healthy."""
        try:
            response = requests.get(f"{self.endpoint}/v1/health/ready", timeout=5)
            return response.status_code == 200
        except Exception:
            return False
```

### src/brev_pipelines/assets/demo.py

```python
"""Demo pipeline assets for Brev Data Platform."""

import json
import random
from typing import Any

import dagster as dg
import pandas as pd

from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource


@dg.asset(
    description="Raw sample data for demo pipeline",
    group_name="demo",
    metadata={"layer": "raw"},
)
def raw_sample_data(context: dg.AssetExecutionContext) -> pd.DataFrame:
    """Generate sample customer data."""
    random.seed(42)

    regions = ["North", "South", "East", "West", "Central"]
    categories = ["Premium", "Standard", "Basic"]

    data = []
    for i in range(100):
        data.append({
            "id": f"CUST-{i:04d}",
            "name": f"Customer {i}",
            "age": random.randint(18, 75),
            "region": random.choice(regions),
            "category": random.choice(categories),
            "spend": round(random.uniform(100, 10000), 2),
            "active": random.random() > 0.2,
        })

    df = pd.DataFrame(data)
    context.log.info(f"Generated {len(df)} sample records")
    return df


@dg.asset(
    description="Cleaned and validated data",
    group_name="demo",
    metadata={"layer": "cleaned"},
)
def cleaned_data(
    context: dg.AssetExecutionContext,
    raw_sample_data: pd.DataFrame,
) -> pd.DataFrame:
    """Clean and validate sample data."""
    df = raw_sample_data.copy()

    # Normalize region names
    df["region"] = df["region"].str.title()

    # Cap extreme spend values
    df["spend"] = df["spend"].clip(upper=9000)

    # Add tier classification
    df["tier"] = pd.cut(
        df["spend"],
        bins=[0, 1000, 5000, float("inf")],
        labels=["Low Value", "Medium Value", "High Value"],
    )

    context.log.info(f"Cleaned {len(df)} records")
    return df


@dg.asset(
    description="Data enriched with NIM LLM descriptions",
    group_name="demo",
    metadata={"layer": "enriched", "uses_gpu": "true"},
)
def nim_enriched_data(
    context: dg.AssetExecutionContext,
    cleaned_data: pd.DataFrame,
    nim: NIMResource,
) -> pd.DataFrame:
    """Enrich data with AI-generated profiles using NIM LLM."""
    df = cleaned_data.copy()

    # Only enrich a sample to save time/cost
    sample_size = min(10, len(df))
    sample_indices = df.sample(sample_size, random_state=42).index

    profiles = []
    for idx, row in df.iterrows():
        if idx in sample_indices:
            prompt = f"""Generate a brief customer profile (1 sentence) for:
- Age: {row['age']}, Region: {row['region']}, Category: {row['category']}, Tier: {row['tier']}
Be concise."""
            context.log.info(f"Calling NIM for {row['id']}...")
            profile = nim.generate(prompt, max_tokens=50)
            profiles.append(profile)
        else:
            profiles.append("Not enriched (sample limit)")

    df["ai_profile"] = profiles
    enriched_count = sum(1 for p in profiles if "error" not in p.lower() and "Not enriched" not in p)
    context.log.info(f"Enriched {enriched_count}/{len(df)} records")
    return df


@dg.asset(
    description="Summary statistics stored in MinIO",
    group_name="demo",
    metadata={"layer": "output", "destination": "minio"},
)
def data_summary(
    context: dg.AssetExecutionContext,
    nim_enriched_data: pd.DataFrame,
    minio: MinIOResource,
) -> dict[str, Any]:
    """Generate summary and store in MinIO."""
    df = nim_enriched_data

    summary = {
        "total_records": len(df),
        "region_distribution": df["region"].value_counts().to_dict(),
        "tier_distribution": df["tier"].value_counts().to_dict(),
        "average_spend": round(df["spend"].mean(), 2),
        "enriched_count": sum(1 for p in df["ai_profile"] if "Not enriched" not in p),
    }

    # Store in MinIO
    bucket = "data-products"
    minio.ensure_bucket(bucket)

    client = minio.get_client()
    data = json.dumps(summary, indent=2).encode()

    import io
    client.put_object(
        bucket,
        "demo/summary.json",
        io.BytesIO(data),
        len(data),
        content_type="application/json",
    )
    context.log.info(f"Stored summary to {bucket}/demo/summary.json")

    return summary


# Export all demo assets
demo_assets = [
    raw_sample_data,
    cleaned_data,
    nim_enriched_data,
    data_summary,
]
```

### src/brev_pipelines/assets/health.py

```python
"""Health check assets for platform validation."""

import dagster as dg

from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.nim import NIMResource


@dg.asset(
    description="Platform health check",
    group_name="health",
)
def platform_health(
    context: dg.AssetExecutionContext,
    minio: MinIOResource,
    lakefs: LakeFSResource,
    nim: NIMResource,
) -> dict[str, str]:
    """Check health of all platform services."""
    health = {}

    # Check MinIO
    try:
        client = minio.get_client()
        client.list_buckets()
        health["minio"] = "healthy"
    except Exception as e:
        health["minio"] = f"error: {str(e)[:50]}"

    # Check LakeFS
    try:
        repos = lakefs.list_repositories()
        health["lakefs"] = f"healthy ({len(repos)} repos)"
    except Exception as e:
        health["lakefs"] = f"error: {str(e)[:50]}"

    # Check NIM
    health["nim"] = "healthy" if nim.health_check() else "unavailable"

    context.log.info(f"Platform health: {health}")
    return health


health_assets = [platform_health]
```

### .github/workflows/build.yml

```yaml
name: Build and Push

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  lint-test:
    name: Lint and Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: "pip"

      - name: Install dependencies
        run: |
          pip install -e ".[dev]"

      - name: Lint with Ruff
        run: ruff check src/ tests/

      - name: Type check with MyPy
        run: mypy src/ --ignore-missing-imports

      - name: Run tests
        run: pytest tests/ -v

  build-push:
    name: Build and Push Image
    runs-on: ubuntu-latest
    needs: lint-test
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=
            type=raw,value=latest

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### tests/test_assets.py

```python
"""Tests for demo assets."""

import pandas as pd
from brev_pipelines.assets.demo import raw_sample_data, cleaned_data


def test_raw_sample_data_shape():
    """Test raw sample data generates expected records."""
    # Create a mock context
    class MockContext:
        def log(self):
            pass
        log = type('log', (), {'info': lambda self, x: None})()

    df = raw_sample_data(MockContext())
    assert len(df) == 100
    assert "id" in df.columns
    assert "region" in df.columns


def test_cleaned_data_adds_tier():
    """Test cleaned data adds tier column."""
    class MockContext:
        log = type('log', (), {'info': lambda self, x: None})()

    raw_df = pd.DataFrame({
        "id": ["CUST-0001"],
        "name": ["Test"],
        "age": [30],
        "region": ["north"],
        "category": ["Premium"],
        "spend": [5000.0],
        "active": [True],
    })

    df = cleaned_data(MockContext(), raw_df)
    assert "tier" in df.columns
    assert df["region"].iloc[0] == "North"  # Title case
```

### README.md

```markdown
# Brev Dagster Pipelines

Dagster pipeline code for Brev Data Platform.

## Overview

This repository contains the Dagster assets, resources, and I/O managers for the Brev Data Platform.

## Structure

```
src/brev_pipelines/
├── definitions.py      # Main Dagster Definitions
├── assets/             # Dagster assets
├── resources/          # External service resources
└── io_managers/        # Custom I/O managers
```

## Development

```bash
# Install dependencies
pip install -e ".[dev]"

# Run linting
ruff check src/ tests/

# Run tests
pytest tests/ -v

# Run Dagster locally
dagster dev -m brev_pipelines.definitions
```

## Docker

```bash
# Build image
docker build -t brev-dagster-pipelines .

# Run locally
docker run -p 4000:4000 brev-dagster-pipelines
```

## CI/CD

On push to main:
1. Runs linting and tests
2. Builds Docker image
3. Pushes to ghcr.io/aerugo/brev-dagster-pipelines

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MINIO_ENDPOINT` | MinIO host:port |
| `MINIO_ACCESS_KEY` | MinIO access key |
| `MINIO_SECRET_KEY` | MinIO secret key |
| `LAKEFS_ENDPOINT` | LakeFS host:port |
| `LAKEFS_ACCESS_KEY_ID` | LakeFS access key |
| `LAKEFS_SECRET_ACCESS_KEY` | LakeFS secret key |
| `NIM_ENDPOINT` | NIM LLM endpoint URL |
```

---

## Changes to brev-data-platform

### Update k8s/apps/dagster/values.yaml

Replace ConfigMap-based user code with the custom image:

```yaml
dagster:
  # ... existing config ...

  # User code deployments with custom image
  dagster-user-deployments:
    enabled: true
    enableSubchart: true
    deployments:
      - name: "brev-pipelines"
        image:
          repository: "ghcr.io/aerugo/brev-dagster-pipelines"
          tag: "latest"  # Or specific SHA
          pullPolicy: Always
        dagsterApiGrpcArgs:
          - "--module-name"
          - "brev_pipelines.definitions"
        port: 4000
        resources:
          requests:
            memory: 512Mi
            cpu: 250m
          limits:
            memory: 1Gi
            cpu: 1000m
        env:
          - name: MINIO_ENDPOINT
            value: "minio.minio.svc.cluster.local:9000"
          - name: MINIO_ACCESS_KEY
            valueFrom:
              secretKeyRef:
                name: dagster-env-secrets
                key: minio_access_key
          - name: MINIO_SECRET_KEY
            valueFrom:
              secretKeyRef:
                name: dagster-env-secrets
                key: minio_secret_key
          - name: LAKEFS_ENDPOINT
            value: "lakefs.lakefs.svc.cluster.local:8000"
          - name: LAKEFS_ACCESS_KEY_ID
            valueFrom:
              secretKeyRef:
                name: dagster-env-secrets
                key: lakefs_access_key_id
          - name: LAKEFS_SECRET_ACCESS_KEY
            valueFrom:
              secretKeyRef:
                name: dagster-env-secrets
                key: lakefs_secret_access_key
          - name: NIM_ENDPOINT
            value: "http://nvidia-nim-llm.nvidia-nim.svc.cluster.local:8000"
```

### Remove k8s/apps/dagster/templates/user-code-configmap.yaml

This file is no longer needed - delete it.

### Add submodule

```bash
cd /path/to/brev-data-platform
git submodule add https://github.com/aerugo/brev-dagster-pipelines.git dagster
```

---

## Implementation Steps

### Step 10.1.1: Create GitHub Repository

```bash
# Create new repo on GitHub
gh repo create aerugo/brev-dagster-pipelines --public --description "Dagster pipelines for Brev Data Platform"

# Clone locally
git clone https://github.com/aerugo/brev-dagster-pipelines.git
cd brev-dagster-pipelines
```

### Step 10.1.2: Create Project Structure

```bash
# Create directories
mkdir -p src/brev_pipelines/{assets,resources,io_managers}
mkdir -p tests
mkdir -p .github/workflows

# Create all files as specified above
```

### Step 10.1.3: Initial Commit and Push

```bash
git add .
git commit -m "Initial commit: Dagster pipeline structure"
git push origin main
```

### Step 10.1.4: Enable GHCR Permissions

```bash
gh api repos/aerugo/brev-dagster-pipelines/actions/permissions/workflow \
  -X PUT \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true
```

### Step 10.1.5: Verify Image Build

```bash
# Check workflow runs
gh run list --repo aerugo/brev-dagster-pipelines

# Verify image exists
docker pull ghcr.io/aerugo/brev-dagster-pipelines:latest
```

### Step 10.1.6: Update brev-data-platform

```bash
cd /path/to/brev-data-platform

# Remove old dagster directory content
rm -rf dagster/*

# Add as submodule
git submodule add https://github.com/aerugo/brev-dagster-pipelines.git dagster

# Update Helm values to use custom image
# Edit k8s/apps/dagster/values.yaml

# Remove ConfigMap template
rm k8s/apps/dagster/templates/user-code-configmap.yaml

# Commit changes
git add .
git commit -m "Switch Dagster to custom image from brev-dagster-pipelines repo"
git push origin main
```

### Step 10.1.7: Verify Deployment

```bash
# Wait for ArgoCD sync
kubectl get applications dagster -n argocd

# Check new deployment
kubectl get pods -n dagster

# Verify user code is running
kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster
```

---

## Completion Criteria

- [ ] Repository `aerugo/brev-dagster-pipelines` created
- [ ] All source files committed (assets, resources, tests)
- [ ] Dockerfile builds successfully
- [ ] GitHub Actions workflow passes (lint, test, build)
- [ ] Docker image pushed to GHCR
- [ ] Submodule added to brev-data-platform
- [ ] Helm values updated to use custom image
- [ ] ConfigMap template removed
- [ ] ArgoCD syncs successfully
- [ ] Dagster UI shows assets from new image
- [ ] `platform_health` asset runs successfully

---

## Next Phase

Once the Dagster repository is set up, proceed to [Phase 11: Sample Pipeline & Validation](phase-11.md) for end-to-end testing.
