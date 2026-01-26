# Phase 4: Type System & IO Manager Fixes

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Fix type system violations (particularly `dict[str, Any]` usage) and IO manager edge cases to ensure strict typing compliance and robust data persistence.

---

## Invariants Enforced in This Phase

- **INV-P005**: No Any Types - Use TypedDict for structured dicts
- **INV-P006**: Modern Python 3.11+ Syntax
- **INV-P010**: Test-Driven Development

---

## Issues Addressed

| Issue ID | Severity | Description |
|----------|----------|-------------|
| CKPT-001 | MEDIUM | LLMCheckpointManager uses `dict[str, Any]` |
| CKPT-002 | MEDIUM | Bare `except Exception` hides errors |
| CKPT-003 | LOW | Recursive load pattern inefficient |
| LFIO-001 | LOW | Import inside method in LakeFSPolarsIOManager |
| LFIO-002 | MEDIUM | `allow_empty=False` could cause commit failures |

---

## Implementation Steps

### Step 4.1: Create CheckpointResult TypedDict

**Action**: Modify

**File(s)**:
- `dagster/src/brev_pipelines/types.py`
- `dagster/tests/unit/types/test_checkpoint_types.py` (CREATE)

Add TypedDict for checkpoint data:

```python
# types.py
class LLMCheckpointRecord(TypedDict):
    """Single record in LLM checkpoint.

    Represents one processed row with its result data.
    """
    reference: str  # Record identifier
    # Result fields vary by asset - use specific subtypes


class ClassificationCheckpointRecord(TypedDict):
    """Checkpoint record for classification results."""
    reference: str
    monetary_stance: int
    trade_stance: int
    tariff_mention: int
    economic_outlook: int
    _llm_status: str
    _llm_error: str | None
    _llm_attempts: int
    _llm_fallback_used: bool


class SummaryCheckpointRecord(TypedDict):
    """Checkpoint record for summary results."""
    reference: str
    summary: str
    _llm_status: str
    _llm_error: str | None
    _llm_attempts: int
    _llm_fallback_used: bool


class EmbeddingCheckpointRecord(TypedDict):
    """Checkpoint record for embedding results."""
    reference: str
    embedding: list[float]
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/types/ -v
cd dagster && uv run mypy src/brev_pipelines/types.py --strict
```

---

### Step 4.2: Update LLMCheckpointManager Type Signatures

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/checkpoint.py`

Replace `dict[str, Any]` with TypeVar and proper typing:

```python
from typing import TYPE_CHECKING, TypeVar

from brev_pipelines.types import (
    ClassificationCheckpointRecord,
    SummaryCheckpointRecord,
    EmbeddingCheckpointRecord,
)

# TypeVar for checkpoint record types
T = TypeVar(
    "T",
    ClassificationCheckpointRecord,
    SummaryCheckpointRecord,
    EmbeddingCheckpointRecord,
)


class LLMCheckpointManager(BaseModel, Generic[T]):
    """Manages checkpoints for LLM processing with partial result persistence.

    Type parameter T specifies the checkpoint record type.
    """
    # ... existing fields ...

    # Update internal state type
    _accumulated_results: list[T] = PrivateAttr(default_factory=list)

    def save_batch(self, results: list[T], force: bool = False) -> None:
        """Accumulate results and save checkpoint when interval is reached."""
        self._accumulated_results.extend(results)
        # ...
```

**Validation**:
```bash
cd dagster && uv run mypy src/brev_pipelines/io_managers/checkpoint.py --strict
```

---

### Step 4.3: Fix Bare Exception Handling

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/checkpoint.py`

Replace bare `except Exception` with specific exception types:

```python
from minio.error import S3Error

def load(self) -> pl.DataFrame | None:
    """Load existing checkpoint if available."""
    self.minio.ensure_bucket(self.bucket)
    client = self.minio.get_client()

    try:
        response = client.get_object(self.bucket, self.checkpoint_path)
        try:
            data = response.read()
        finally:
            response.close()
            response.release_conn()

        df = pl.read_parquet(io.BytesIO(data))
        self._total_saved = len(df)
        return df

    except S3Error as e:
        if e.code == "NoSuchKey":
            # No checkpoint exists - this is expected on first run
            return None
        # Re-raise other S3 errors (permissions, network, etc.)
        raise

    except Exception as e:
        # Log unexpected errors but don't hide them
        raise RuntimeError(f"Failed to load checkpoint: {e}") from e
```

---

### Step 4.4: Fix LakeFSPolarsIOManager Empty Commit

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/lakefs_polars.py`

Handle the case where data hasn't changed:

```python
def handle_output(self, context: OutputContext, obj: pl.DataFrame) -> None:
    """Store a Polars DataFrame to LakeFS as Parquet."""
    # ... existing upload code ...

    # Create commit - handle empty case gracefully
    from lakefs_sdk.models import CommitCreation
    from lakefs_sdk.exceptions import ApiException

    try:
        lakefs_client.commits_api.commit(
            repository=self.repository,
            branch=self.branch,
            commit_creation=CommitCreation(
                message=commit_message,
                metadata={...},
                date=None,
                allow_empty=False,
            ),
        )
    except ApiException as e:
        # LakeFS returns 400 when there are no changes to commit
        if e.status == 400 and "no changes" in str(e.body).lower():
            context.log.info(
                f"No changes to commit for {asset_key} (data unchanged)"
            )
        else:
            raise
```

---

### Step 4.5: Move Import to Module Level

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/lakefs_polars.py`

Move `CommitCreation` import to top of file:

```python
# At top of file, after other imports
from lakefs_sdk.models import CommitCreation  # type: ignore[attr-defined]


# Remove inline imports in handle_output method
```

---

### Step 4.6: Optimize Checkpoint Flush Pattern

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/checkpoint.py`

Avoid recursive load in `_flush_checkpoint`:

```python
def _flush_checkpoint(self) -> None:
    """Write accumulated results to checkpoint file."""
    if not self._accumulated_results:
        return

    self.minio.ensure_bucket(self.bucket)
    client = self.minio.get_client()

    # Load existing checkpoint data directly (don't use self.load())
    existing_data: list[dict[str, Any]] = []
    try:
        response = client.get_object(self.bucket, self.checkpoint_path)
        try:
            data = response.read()
        finally:
            response.close()
            response.release_conn()
        existing_df = pl.read_parquet(io.BytesIO(data))
        existing_data = existing_df.to_dicts()
    except S3Error as e:
        if e.code != "NoSuchKey":
            raise

    # Combine existing + new
    all_data = existing_data + list(self._accumulated_results)

    # Create DataFrame and serialize
    combined_df = pl.DataFrame(all_data)

    buffer = io.BytesIO()
    combined_df.write_parquet(buffer)
    parquet_bytes = buffer.getvalue()

    # Upload to MinIO
    client.put_object(
        bucket_name=self.bucket,
        object_name=self.checkpoint_path,
        data=io.BytesIO(parquet_bytes),
        length=len(parquet_bytes),
        content_type="application/octet-stream",
    )

    self._total_saved = len(combined_df)
    self._accumulated_results = []
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/src/brev_pipelines/types.py` | MODIFY | Add checkpoint TypedDicts |
| `dagster/src/brev_pipelines/io_managers/checkpoint.py` | MODIFY | Fix types, exceptions, optimize |
| `dagster/src/brev_pipelines/io_managers/lakefs_polars.py` | MODIFY | Fix import, empty commit |
| `dagster/tests/unit/io_managers/test_checkpoint.py` | MODIFY | Add tests for fixes |

---

## Verification

### Validation Commands

```bash
# Type checking - strict mode
cd dagster && uv run mypy src/brev_pipelines/io_managers/ --strict
cd dagster && uv run mypy src/brev_pipelines/types.py --strict

# Run IO manager tests
cd dagster && uv run pytest tests/unit/io_managers/ -v

# Full test suite
cd dagster && uv run pytest tests/ -v
```

### Expected Outcomes

- No `dict[str, Any]` in checkpoint.py
- Specific exception handling (no bare `except Exception`)
- LakeFS handles unchanged data gracefully
- All imports at module level
- mypy strict mode passes

---

## Completion Criteria

- [ ] Checkpoint TypedDict types defined in types.py
- [ ] LLMCheckpointManager uses TypedDict instead of `dict[str, Any]`
- [ ] Bare `except Exception` replaced with specific types
- [ ] `_flush_checkpoint` doesn't call `load()` recursively
- [ ] LakeFSPolarsIOManager handles empty commits
- [ ] All imports at module level
- [ ] mypy strict mode passes
- [ ] All tests pass
