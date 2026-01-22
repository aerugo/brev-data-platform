# Phase 11: Sample Pipeline & Validation

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create an end-to-end sample Dagster pipeline that demonstrates the full platform capabilities: data ingestion, NIM LLM enrichment, Safe Synthesizer integration, and LakeFS versioning. Validate the entire stack is working correctly.

---

## Invariants Enforced in This Phase

- **INV-P001**: Assets over ops - Pipeline uses `@asset` pattern
- **INV-P002**: I/O managers for storage - LakeFS I/O manager
- **INV-P003**: Type annotations on assets - Full type hints
- **INV-D002**: LakeFS for data versioning - All outputs through LakeFS
- **INV-D003**: Parquet for structured data - Output format
- **INV-N003**: Safe Synthesizer output to LakeFS - Versioned synthetic data

---

## Sample Pipeline Overview

```
┌─────────────────────┐
│   raw_customer_data │  ← Simulated raw data ingestion
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   cleaned_customers │  ← Data cleaning/validation
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  ai_enriched_data   │  ← NIM LLM adds descriptions
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  synthetic_customers│  ← Safe Synthesizer creates synthetic version
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   data_quality_report│  ← Compare original vs synthetic
└─────────────────────┘
```

---

## Files to Create

### dagster/assets/demo_pipeline.py

```python
"""End-to-end demo pipeline for brev-data-platform.

This pipeline demonstrates:
1. Data ingestion to MinIO/LakeFS
2. Data transformation
3. NIM LLM enrichment
4. Safe Synthesizer for synthetic data
5. Data quality validation
"""

from dagster import asset, AssetExecutionContext, MaterializeResult, MetadataValue
import pandas as pd
import numpy as np
from typing import Optional
import requests


@asset(
    description="Raw customer data simulating ingestion from external source",
    group_name="demo_ingestion",
    io_manager_key="lakefs_parquet_io_manager",
    metadata={"layer": "raw", "owner": "data-engineering"},
)
def raw_customer_data(context: AssetExecutionContext) -> pd.DataFrame:
    """Generate sample customer data for the demo pipeline."""
    context.log.info("Generating raw customer data...")

    np.random.seed(42)
    n_customers = 500

    df = pd.DataFrame({
        "customer_id": [f"CUST-{i:05d}" for i in range(n_customers)],
        "name": [f"Customer {i}" for i in range(n_customers)],
        "email": [f"customer{i}@example.com" for i in range(n_customers)],
        "age": np.random.randint(18, 80, n_customers),
        "income": np.random.lognormal(10.5, 0.5, n_customers).astype(int),
        "region": np.random.choice(
            ["North", "South", "East", "West", "Central"],
            n_customers
        ),
        "signup_date": pd.date_range(
            start="2020-01-01",
            periods=n_customers,
            freq="D"
        ).strftime("%Y-%m-%d").tolist(),
        "is_active": np.random.choice([True, False], n_customers, p=[0.8, 0.2]),
    })

    context.log.info(f"Generated {len(df)} customer records")

    return df


@asset(
    description="Cleaned and validated customer data",
    group_name="demo_transformation",
    io_manager_key="lakefs_parquet_io_manager",
    deps=["raw_customer_data"],
    metadata={"layer": "cleaned", "owner": "data-engineering"},
)
def cleaned_customers(
    context: AssetExecutionContext,
    raw_customer_data: pd.DataFrame,
) -> pd.DataFrame:
    """Clean and validate customer data."""
    context.log.info(f"Cleaning {len(raw_customer_data)} customer records...")

    df = raw_customer_data.copy()

    # Remove duplicates
    df = df.drop_duplicates(subset=["customer_id"])

    # Validate email format
    df = df[df["email"].str.contains("@")]

    # Cap extreme income values
    income_cap = df["income"].quantile(0.99)
    df["income"] = df["income"].clip(upper=income_cap)

    # Add derived columns
    df["income_bracket"] = pd.cut(
        df["income"],
        bins=[0, 30000, 75000, 150000, float("inf")],
        labels=["Low", "Medium", "High", "Premium"]
    )

    df["age_group"] = pd.cut(
        df["age"],
        bins=[0, 25, 40, 55, float("inf")],
        labels=["Young", "Adult", "Middle-aged", "Senior"]
    )

    context.log.info(f"Cleaned data: {len(df)} records (removed {len(raw_customer_data) - len(df)})")

    return df


@asset(
    description="Customer data enriched with AI-generated descriptions",
    group_name="demo_ai",
    io_manager_key="lakefs_parquet_io_manager",
    deps=["cleaned_customers"],
    metadata={"layer": "enriched", "owner": "data-science", "uses_gpu": True},
)
def ai_enriched_data(
    context: AssetExecutionContext,
    cleaned_customers: pd.DataFrame,
    nim_client,  # NIM resource injected
) -> pd.DataFrame:
    """Enrich customer data with AI-generated descriptions using NIM LLM."""
    context.log.info("Enriching data with NIM LLM...")

    df = cleaned_customers.copy()

    # For demo, only process a sample to save time/cost
    sample_size = min(50, len(df))
    sample_indices = df.sample(sample_size).index

    descriptions = []

    for idx, row in df.iterrows():
        if idx in sample_indices:
            try:
                prompt = f"""Generate a brief customer persona description (2-3 sentences) for:
- Age: {row['age']} ({row['age_group']})
- Region: {row['region']}
- Income bracket: {row['income_bracket']}
- Active customer: {row['is_active']}

Be concise and professional."""

                description = nim_client.generate(
                    prompt=prompt,
                    max_tokens=100,
                    temperature=0.7,
                )
                descriptions.append(description.strip())
                context.log.debug(f"Generated description for {row['customer_id']}")

            except Exception as e:
                context.log.warning(f"Failed to generate description for {row['customer_id']}: {e}")
                descriptions.append("Description unavailable")
        else:
            descriptions.append("Not enriched (sample)")

    df["ai_description"] = descriptions

    enriched_count = len([d for d in descriptions if d not in ["Not enriched (sample)", "Description unavailable"]])
    context.log.info(f"Enriched {enriched_count}/{len(df)} records with AI descriptions")

    return df


@asset(
    description="Synthetic customer data generated with differential privacy",
    group_name="demo_ai",
    io_manager_key="lakefs_parquet_io_manager",
    deps=["cleaned_customers"],
    metadata={"layer": "synthetic", "owner": "data-science", "uses_gpu": True},
)
def synthetic_customers(
    context: AssetExecutionContext,
    cleaned_customers: pd.DataFrame,
) -> pd.DataFrame:
    """Generate synthetic customer data using Safe Synthesizer.

    Note: This is a simplified version. Full Safe Synthesizer integration
    would call the actual API endpoint.
    """
    context.log.info("Generating synthetic customer data...")

    # For demo purposes, generate synthetic data using statistical methods
    # In production, this would call Safe Synthesizer API

    n_synthetic = len(cleaned_customers)
    np.random.seed(123)

    # Generate synthetic data matching original distributions
    df = pd.DataFrame({
        "customer_id": [f"SYNTH-{i:05d}" for i in range(n_synthetic)],
        "name": [f"Synthetic Customer {i}" for i in range(n_synthetic)],
        "email": [f"synth{i}@example.com" for i in range(n_synthetic)],
        "age": np.random.choice(cleaned_customers["age"], n_synthetic),
        "income": np.random.choice(cleaned_customers["income"], n_synthetic),
        "region": np.random.choice(cleaned_customers["region"], n_synthetic),
        "signup_date": np.random.choice(cleaned_customers["signup_date"], n_synthetic),
        "is_active": np.random.choice(cleaned_customers["is_active"], n_synthetic),
    })

    # Add noise to numeric columns for privacy
    df["age"] = (df["age"] + np.random.randint(-2, 3, n_synthetic)).clip(18, 80)
    df["income"] = (df["income"] * np.random.uniform(0.9, 1.1, n_synthetic)).astype(int)

    # Recompute derived columns
    df["income_bracket"] = pd.cut(
        df["income"],
        bins=[0, 30000, 75000, 150000, float("inf")],
        labels=["Low", "Medium", "High", "Premium"]
    )
    df["age_group"] = pd.cut(
        df["age"],
        bins=[0, 25, 40, 55, float("inf")],
        labels=["Young", "Adult", "Middle-aged", "Senior"]
    )

    # Mark as synthetic
    df["is_synthetic"] = True

    context.log.info(f"Generated {len(df)} synthetic customer records")

    return df


@asset(
    description="Data quality comparison report between original and synthetic data",
    group_name="demo_validation",
    io_manager_key="lakefs_parquet_io_manager",
    deps=["cleaned_customers", "synthetic_customers"],
    metadata={"layer": "reports", "owner": "data-quality"},
)
def data_quality_report(
    context: AssetExecutionContext,
    cleaned_customers: pd.DataFrame,
    synthetic_customers: pd.DataFrame,
) -> pd.DataFrame:
    """Generate data quality report comparing original and synthetic datasets."""
    context.log.info("Generating data quality report...")

    metrics = []

    # Compare distributions for numeric columns
    for col in ["age", "income"]:
        original_mean = cleaned_customers[col].mean()
        synthetic_mean = synthetic_customers[col].mean()
        original_std = cleaned_customers[col].std()
        synthetic_std = synthetic_customers[col].std()

        metrics.append({
            "metric": f"{col}_mean",
            "original": original_mean,
            "synthetic": synthetic_mean,
            "difference_pct": abs(original_mean - synthetic_mean) / original_mean * 100,
        })
        metrics.append({
            "metric": f"{col}_std",
            "original": original_std,
            "synthetic": synthetic_std,
            "difference_pct": abs(original_std - synthetic_std) / original_std * 100,
        })

    # Compare categorical distributions
    for col in ["region", "income_bracket", "age_group"]:
        original_dist = cleaned_customers[col].value_counts(normalize=True)
        synthetic_dist = synthetic_customers[col].value_counts(normalize=True)

        # Jensen-Shannon divergence would be better, but using simple diff for demo
        for category in original_dist.index:
            orig_pct = original_dist.get(category, 0)
            synth_pct = synthetic_dist.get(category, 0)
            metrics.append({
                "metric": f"{col}_{category}_pct",
                "original": orig_pct * 100,
                "synthetic": synth_pct * 100,
                "difference_pct": abs(orig_pct - synth_pct) * 100,
            })

    # Record counts
    metrics.append({
        "metric": "record_count",
        "original": len(cleaned_customers),
        "synthetic": len(synthetic_customers),
        "difference_pct": 0,
    })

    report_df = pd.DataFrame(metrics)

    # Log summary
    avg_diff = report_df["difference_pct"].mean()
    context.log.info(f"Data quality report generated. Average difference: {avg_diff:.2f}%")

    return report_df


# Collect all demo assets
demo_pipeline_assets = [
    raw_customer_data,
    cleaned_customers,
    ai_enriched_data,
    synthetic_customers,
    data_quality_report,
]
```

### Update dagster/definitions.py

```python
"""Dagster definitions for brev-data-platform."""

from dagster import Definitions, EnvVar

from assets.ingestion import raw_data_assets
from assets.transformation import transformed_data_assets
from assets.demo_pipeline import demo_pipeline_assets
from io_managers.lakefs_io_manager import lakefs_parquet_io_manager
from resources.lakefs import LakeFSResource
from resources.minio import MinIOResource
from resources.nvidia import NIMResource

defs = Definitions(
    assets=[
        *raw_data_assets,
        *transformed_data_assets,
        *demo_pipeline_assets,
    ],
    resources={
        "lakefs": LakeFSResource(
            endpoint=EnvVar("LAKEFS_ENDPOINT"),
            access_key_id=EnvVar("LAKEFS_ACCESS_KEY_ID"),
            secret_access_key=EnvVar("LAKEFS_SECRET_ACCESS_KEY"),
        ),
        "minio": MinIOResource(
            endpoint=EnvVar("MINIO_ENDPOINT"),
            access_key=EnvVar("MINIO_ACCESS_KEY"),
            secret_key=EnvVar("MINIO_SECRET_KEY"),
        ),
        "nim_client": NIMResource(
            endpoint=EnvVar("NIM_ENDPOINT"),
            api_key=EnvVar("NGC_API_KEY"),
            model="meta/llama3-8b-instruct",
        ),
        "lakefs_parquet_io_manager": lakefs_parquet_io_manager.configured({
            "repository": "main-repo",
            "branch": "main",
        }),
    },
)
```

### marimo/notebooks/demo_exploration.py

```python
"""Demo notebook for exploring the brev-data-platform data."""

import marimo

__generated_with = "0.3.0"
app = marimo.App()


@app.cell
def __():
    import marimo as mo
    import pandas as pd
    import os
    return mo, pd, os


@app.cell
def __(mo):
    mo.md("""
    # Brev Data Platform - Demo Exploration

    This notebook demonstrates how to explore data stored in LakeFS through the platform.
    """)
    return


@app.cell
def __(os):
    # Configuration from environment
    LAKEFS_ENDPOINT = os.getenv("LAKEFS_ENDPOINT", "http://localhost:8000")
    LAKEFS_ACCESS_KEY = os.getenv("LAKEFS_ACCESS_KEY_ID", "")
    LAKEFS_SECRET_KEY = os.getenv("LAKEFS_SECRET_ACCESS_KEY", "")

    print(f"LakeFS Endpoint: {LAKEFS_ENDPOINT}")
    return LAKEFS_ENDPOINT, LAKEFS_ACCESS_KEY, LAKEFS_SECRET_KEY


@app.cell
def __(pd, LAKEFS_ENDPOINT, LAKEFS_ACCESS_KEY, LAKEFS_SECRET_KEY):
    import lakefs_sdk
    from lakefs_sdk.client import LakeFSClient

    # Initialize LakeFS client
    configuration = lakefs_sdk.Configuration(
        host=LAKEFS_ENDPOINT,
        username=LAKEFS_ACCESS_KEY,
        password=LAKEFS_SECRET_KEY,
    )
    client = LakeFSClient(configuration)

    # List repositories
    repos = client.repositories_api.list_repositories()
    print("Available repositories:")
    for repo in repos.results:
        print(f"  - {repo.id}")

    return client, lakefs_sdk, LakeFSClient


@app.cell
def __(client, pd):
    # List objects in main-repo
    objects = client.objects_api.list_objects(
        repository="main-repo",
        ref="main",
        prefix="assets/"
    )

    print("Available data assets:")
    for obj in objects.results:
        print(f"  - {obj.path} ({obj.size_bytes} bytes)")
    return objects


@app.cell
def __(client, pd, mo):
    import io

    # Read the data quality report
    try:
        response = client.objects_api.get_object(
            repository="main-repo",
            ref="main",
            path="assets/data_quality_report.parquet"
        )
        report_df = pd.read_parquet(io.BytesIO(response))
        mo.md("## Data Quality Report")
    except Exception as e:
        report_df = pd.DataFrame()
        mo.md(f"Report not available: {e}")

    return report_df


@app.cell
def __(report_df, mo):
    if not report_df.empty:
        mo.ui.table(report_df)
    else:
        mo.md("No data to display. Run the Dagster pipeline first!")
    return


@app.cell
def __(mo):
    mo.md("""
    ## Next Steps

    1. Run the demo pipeline in Dagster UI
    2. Refresh this notebook to see the results
    3. Explore the LakeFS commits to see data versions
    """)
    return


if __name__ == "__main__":
    app.run()
```

---

## Validation Steps

### Step 9.1: Deploy Updated Dagster Code

```bash
# Rebuild Dagster image with new pipeline
make build-dagster
docker tag brev-data-platform/dagster:latest ghcr.io/YOUR_ORG/brev-data-platform/dagster:demo
docker push ghcr.io/YOUR_ORG/brev-data-platform/dagster:demo

# Update values and let ArgoCD sync
# Or restart the user code deployment
kubectl rollout restart deployment/brev-pipelines -n dagster
```

### Step 9.2: Run Demo Pipeline

1. Open Dagster UI: `make port-forward-dagster` → http://localhost:3000
2. Navigate to Assets
3. Find the demo pipeline assets
4. Click "Materialize all" on `raw_customer_data`
5. Watch the pipeline execute through all assets

### Step 9.3: Verify Data in LakeFS

1. Open LakeFS UI: `make port-forward-lakefs` → http://localhost:8000
2. Navigate to `main-repo` → `main` branch
3. Browse `assets/` directory
4. Verify Parquet files exist for each asset
5. Check commit history shows data writes

### Step 9.4: Verify NIM Integration

Check Dagster logs for `ai_enriched_data` asset:
- Should show NIM API calls
- Should show generated descriptions

```bash
kubectl logs -f deployment/brev-pipelines -n dagster | grep -i nim
```

### Step 9.5: Explore in Marimo

1. Open Marimo: `make port-forward-marimo` → http://localhost:2718
2. Open the demo notebook
3. Run cells to query LakeFS data
4. Verify data is accessible

### Step 9.6: Full Stack Health Check

```bash
# Run comprehensive check
echo "=== Full Stack Validation ==="

echo "1. Brev Instance:"
brev ls | grep brev-data-platform-dev

echo "2. RKE2 Cluster:"
kubectl get nodes

echo "3. All Pods:"
kubectl get pods -A | grep -v kube-system

echo "4. ArgoCD Applications:"
kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'

echo "5. MinIO Buckets:"
# (requires port-forward or mc configured)

echo "6. LakeFS Repository:"
curl -sf -u "$LAKEFS_KEY:$LAKEFS_SECRET" http://localhost:8000/api/v1/repositories/main-repo | jq .id

echo "7. NIM Health:"
curl -sf http://localhost:8001/v1/health/ready && echo "OK"

echo "8. Dagster:"
curl -sf http://localhost:3000/health && echo "OK"

echo "=== Validation Complete ==="
```

---

## Final Checklist

### Infrastructure
- [ ] Brev instance running
- [ ] RKE2 cluster healthy
- [ ] GPU available and allocated

### Storage
- [ ] MinIO accessible
- [ ] Buckets created (raw-data, data-products, lakefs)
- [ ] LakeFS accessible
- [ ] Repository main-repo exists

### Data Platform
- [ ] Dagster webserver running
- [ ] Dagster daemon running
- [ ] User code deployment healthy
- [ ] All demo assets visible in UI
- [ ] Marimo accessible

### NVIDIA AI
- [ ] NIM LLM responding to requests
- [ ] GPU utilization visible
- [ ] (Optional) Safe Synthesizer responding

### GitOps
- [ ] ArgoCD all applications synced
- [ ] CI/CD workflows passing
- [ ] Dagster images in GHCR

### Demo Pipeline
- [ ] raw_customer_data materializes
- [ ] cleaned_customers materializes
- [ ] ai_enriched_data materializes (with NIM)
- [ ] synthetic_customers materializes
- [ ] data_quality_report materializes
- [ ] All data visible in LakeFS
- [ ] Marimo notebook can query data

---

## Completion Criteria

- [ ] Demo pipeline fully implemented
- [ ] All 5 assets materialize successfully
- [ ] NIM LLM integration working (descriptions generated)
- [ ] Data visible in LakeFS with commits
- [ ] Marimo can query pipeline outputs
- [ ] Full stack health check passes
- [ ] Documentation updated with demo instructions

---

## Congratulations!

The Brev Data Platform is now fully deployed and validated. You have:

1. **Infrastructure**: GPU-enabled RKE2 cluster on Brev
2. **GitOps**: ArgoCD managing all applications
3. **Storage**: MinIO + LakeFS for versioned data lake
4. **Orchestration**: Dagster running data pipelines
5. **Notebooks**: Marimo for interactive exploration
6. **AI**: NVIDIA NIM for LLM inference
7. **CI/CD**: GitHub Actions for automation

### What's Next?

- Add real data sources to ingestion
- Build production pipelines
- Integrate Safe Synthesizer API (when available)
- Add monitoring (Prometheus/Grafana)
- Implement data quality checks
- Set up alerting
