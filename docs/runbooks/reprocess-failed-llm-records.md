# Reprocessing Failed LLM Records

## Overview

When LLM-powered assets (`speech_classification`, `speech_summaries`) have failures
that exceed acceptable thresholds, operators can selectively reprocess failed records.

## Prerequisites

- Access to Dagster UI or CLI
- Access to MinIO/LakeFS for data inspection
- Understanding of dead letter columns (`_llm_status`, `_llm_error`, etc.)

## Identifying Failed Records

### Via Dagster UI

1. Navigate to Assets > speech_classification (or speech_summaries)
2. Click on the latest materialization
3. Check the Metadata panel:
   - `failed`: Number of failed records
   - `failed_references`: List of record IDs that failed
   - `failure_breakdown`: Count by error type

### Via Data Inspection

```python
import polars as pl

# Read the output parquet
df = pl.read_parquet("s3://data-products/central-bank-speeches/classification.parquet")

# Filter failed records
failed = df.filter(pl.col("_llm_status") == "failed")
print(f"Failed records: {len(failed)}")
print(failed.select(["reference", "_llm_error", "_llm_attempts"]))
```

## Reprocessing Options

### Option A: Full Re-run

If failure rate is high (>20%), consider a full re-run:

1. Clear checkpoint files:
   ```bash
   mc rm --recursive minio/checkpoints/speech_classification/
   ```

2. Rematerialize the asset in Dagster UI

3. Monitor for improved success rate

### Option B: Selective Reprocessing via Checkpoint

The checkpoint system already supports partial reprocessing:

1. Identify failed record IDs from metadata
2. Remove those records from the checkpoint (see script below)
3. Rematerialize - only cleared records will be reprocessed

### Option C: Create Filtered Input (Future Enhancement)

For targeted reprocessing, create a job that:
1. Reads the failed record IDs
2. Filters input data to only those records
3. Processes just the failed subset
4. Merges results back

## Selective Reprocessing Script

```python
"""Script to clear specific records from checkpoint for reprocessing."""
import io
import json

from minio import Minio


def clear_failed_from_checkpoint(
    minio_client: Minio,
    asset_name: str,
    run_id: str,
    failed_references: list[str],
) -> int:
    """Remove failed records from checkpoint to enable reprocessing.

    Args:
        minio_client: MinIO client
        asset_name: Name of the asset (e.g., "speech_classification")
        run_id: Dagster run ID
        failed_references: List of record IDs to clear

    Returns:
        Number of records cleared
    """
    checkpoint_path = f"checkpoints/{asset_name}/{run_id}/checkpoint.json"

    try:
        response = minio_client.get_object("checkpoints", checkpoint_path)
        checkpoint = json.loads(response.read().decode())
    except Exception:
        print(f"No checkpoint found at {checkpoint_path}")
        return 0

    # Remove failed references from processed set
    processed = set(checkpoint.get("processed_ids", []))
    initial_count = len(processed)

    for ref in failed_references:
        processed.discard(ref)

    checkpoint["processed_ids"] = list(processed)

    # Write updated checkpoint
    checkpoint_bytes = json.dumps(checkpoint).encode()
    minio_client.put_object(
        "checkpoints",
        checkpoint_path,
        data=io.BytesIO(checkpoint_bytes),
        length=len(checkpoint_bytes),
    )

    cleared = initial_count - len(processed)
    print(f"Cleared {cleared} records from checkpoint")
    return cleared


# Usage
if __name__ == "__main__":
    client = Minio(
        "minio.minio.svc.cluster.local:9000",
        access_key="...",
        secret_key="...",
        secure=False,
    )

    # Get failed references from Dagster metadata or data inspection
    failed_refs = ["BIS_2024_042", "ECB_2024_189"]

    clear_failed_from_checkpoint(
        minio_client=client,
        asset_name="speech_classification",
        run_id="<run-id-from-dagster>",
        failed_references=failed_refs,
    )
```

## When to Reprocess

| Failure Rate | Action |
|--------------|--------|
| < 1% | Acceptable - review failed records manually |
| 1-5% | Monitor - investigate error types |
| 5-20% | Investigate - check NIM service health, then reprocess |
| > 20% | Critical - pause, fix root cause, full re-run |

## Root Cause Investigation

Before reprocessing, investigate why failures occurred:

1. **Check NIM service health**:
   ```bash
   kubectl get pods -n nvidia-nim
   kubectl logs -n nvidia-nim deployment/nim-llm --tail=100
   ```

2. **Check failure breakdown**:
   - High `LLMTimeoutError`: NIM overloaded or network issues
   - High `LLMRateLimitError`: Adjust rate limiting or add delays
   - High `ValidationError`: Prompt may need adjustment
   - High `LLMServerError`: NIM service issues

3. **Check resource usage**:
   ```bash
   kubectl top pods -n nvidia-nim
   ```
