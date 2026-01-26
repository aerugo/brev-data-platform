# Phase 5: Tech Debt Cleanup

**Status**: Completed
**Type**: Application
**Started**: 2026-01-26
**Completed**: 2026-01-26
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Address remaining low-priority issues including demo pipeline error handling, environment variable consistency, and minor improvements across the codebase.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete Type Annotations
- **INV-P015**: All External Service Calls Must Have Error Handling

---

## Issues Addressed

| Issue ID | Severity | Description |
|----------|----------|-------------|
| DEMO-001 | MEDIUM | No error handling on NIM `chat_completion` calls in demo |
| DEMO-002 | MEDIUM | No error handling on MinIO operations in demo |
| DEMO-003 | LOW | Returns raw string responses without validation |
| VAL-003 | MEDIUM | LakeFS validation catches generic `Exception` |
| DEF-001 | LOW | Mixed `os.getenv()` and `EnvVar()` usage |
| DEF-002 | LOW | Jobs use "ops" in config for assets |
| MPIO-001 | LOW | No error handling on `get_object` in MinIOPolarsIOManager |
| WVIO-001 | LOW | `load_input` returns count instead of data |

---

## Implementation Steps

### Step 5.1: Add Error Handling to Demo Assets

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/demo.py`

Add proper error handling to demo assets:

```python
from brev_pipelines.resources.nim import NIMResource, NIMError
from brev_pipelines.resources.minio import MinIOResource

@dg.asset(group_name="demo")
def demo_query_nim(nim: NIMResource) -> dict[str, str | None]:
    """Query NIM LLM endpoint with error handling.

    Returns:
        Dict with 'response' on success or 'error' on failure.
    """
    try:
        response = nim.chat_completion(
            "What is the capital of France? Reply in one word.",
            temperature=0.1,
        )
        return {"response": response, "error": None}
    except NIMError as e:
        return {"response": None, "error": str(e)}


@dg.asset(group_name="demo")
def demo_minio_read(minio: MinIOResource) -> dict[str, str | int | None]:
    """Read from MinIO with error handling.

    Returns:
        Dict with bucket info or error.
    """
    try:
        client = minio.get_client()
        buckets = client.list_buckets()
        return {
            "bucket_count": len(buckets),
            "buckets": ", ".join(b.name for b in buckets),
            "error": None,
        }
    except Exception as e:
        return {"bucket_count": 0, "buckets": None, "error": str(e)}
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_demo.py -v
```

---

### Step 5.2: Fix LakeFS Validation Exception Handling

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/validation.py`

Replace generic `Exception` with specific types:

```python
from lakefs_sdk.exceptions import ApiException
from brev_pipelines.resources.lakefs import LakeFSError, LakeFSConnectionError

@dg.asset(group_name="validation")
def validate_lakefs(lakefs: LakeFSResource) -> ValidationReportDict:
    """Validate LakeFS connectivity."""
    # ...
    try:
        client = lakefs.get_client()
        # Test connection
        repos = client.repositories_api.list_repositories()
        # ...
    except LakeFSConnectionError as e:
        tests.append({
            "name": "connection",
            "passed": False,
            "error": f"Connection failed: {e}",
        })
    except ApiException as e:
        tests.append({
            "name": "api_access",
            "passed": False,
            "error": f"API error {e.status}: {e.reason}",
        })
```

---

### Step 5.3: Standardize Environment Variable Handling

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/definitions.py`

Replace `os.getenv()` with `EnvVar()` for consistency:

```python
from dagster import EnvVar

# Before:
# endpoint=os.getenv("NIM_ENDPOINT", "http://nim:8000")

# After:
resources = {
    "nim": NIMResource(
        endpoint=EnvVar("NIM_ENDPOINT").get_value() or "http://nim:8000",
        model=EnvVar("NIM_MODEL").get_value() or "meta/llama-3.1-8b-instruct",
    ),
    # ... other resources
}
```

Note: This is a stylistic change. Both approaches work, but `EnvVar` is the Dagster-native pattern.

---

### Step 5.4: Add MinIOPolarsIOManager Error Handling

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/minio_polars.py`

Add error handling to `load_input`:

```python
from minio.error import S3Error

def load_input(self, context: InputContext) -> pl.DataFrame:
    """Load a Polars DataFrame from MinIO."""
    # ...
    try:
        response = client.get_object(self.bucket, object_path)
        # ...
    except S3Error as e:
        if e.code == "NoSuchKey":
            raise FileNotFoundError(
                f"Object not found in MinIO: {self.bucket}/{object_path}"
            )
        raise RuntimeError(f"MinIO error loading {object_path}: {e}") from e
```

---

### Step 5.5: Document WeaviateIOManager load_input Behavior

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/weaviate_io.py`

Add clarifying documentation (behavior is intentional but unusual):

```python
def load_input(self, context: InputContext) -> int:
    """Get count of objects in Weaviate collection.

    Note: This returns a COUNT, not actual data. Weaviate is a vector DB
    optimized for similarity search, not bulk data retrieval. Use this
    to verify data was indexed, not to read data back.

    For actual data retrieval, query Weaviate directly with search APIs.

    Returns:
        Number of objects in the collection.
    """
    # ... existing implementation
```

---

### Step 5.6: Clean Up Jobs Config Terminology

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/jobs.py`

Update config key from "ops" to be clearer (note: "ops" works but is legacy terminology):

```python
# Document that "ops" is Dagster's config key for asset configs
speeches_trial_run = define_asset_job(
    name="speeches_trial_run",
    description=(
        "ETL trial: Process only 10 speeches for testing. "
        "Uses separate collections/paths to avoid affecting production data."
    ),
    selection=SPEECHES_ASSETS,
    config={
        # Note: Dagster uses "ops" key for asset configuration
        # even though assets are not ops. This is expected behavior.
        "ops": {
            "raw_speeches": {"config": TRIAL_RUN_CONFIG},
            "speeches_data_product": {"config": TRIAL_RUN_CONFIG},
            "weaviate_index": {"config": TRIAL_RUN_CONFIG},
        },
    },
)
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/src/brev_pipelines/assets/demo.py` | MODIFY | Add error handling |
| `dagster/src/brev_pipelines/assets/validation.py` | MODIFY | Specific exception types |
| `dagster/src/brev_pipelines/definitions.py` | MODIFY | Standardize EnvVar usage |
| `dagster/src/brev_pipelines/io_managers/minio_polars.py` | MODIFY | Add error handling |
| `dagster/src/brev_pipelines/io_managers/weaviate_io.py` | MODIFY | Improve documentation |
| `dagster/src/brev_pipelines/jobs.py` | MODIFY | Add clarifying comments |

---

## Verification

### Validation Commands

```bash
# Run all tests
cd dagster && uv run pytest tests/ -v

# Type checking
cd dagster && uv run mypy src/brev_pipelines/ --strict

# Linting
cd dagster && uv run ruff check src/brev_pipelines/
cd dagster && uv run ruff format --check src/brev_pipelines/
```

### Expected Outcomes

- Demo assets handle errors gracefully
- Consistent exception handling in validation
- Standardized environment variable pattern
- Better documentation for unusual patterns
- All tests pass

---

## Completion Criteria

- [x] Demo assets have proper error handling
- [x] Validation uses specific exception types
- [x] Environment variable handling is consistent
- [x] MinIOPolarsIOManager has error handling
- [x] WeaviateIOManager behavior is documented
- [x] Jobs config has clarifying comments
- [x] All tests pass (520 tests)
- [x] No lint errors

---

## Post-Phase Tasks

After completing all phases:

1. **Update INVARIANTS.md** - Add new invariants:
   - INV-P014: Resources Must Raise Exceptions on Failure
   - INV-P015: All External Service Calls Must Have Error Handling

2. **Update Pipeline Review Document** - Mark issues as resolved in:
   - `docs/review/pipeline-issues-2026-01-26.md`

3. **Move Plan to Completed** - Move plan directory:
   - From: `docs/plans/active/pipeline-reliability-fixes/`
   - To: `docs/plans/completed/pipeline-reliability-fixes/`
