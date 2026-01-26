# Phase 3: Resource Consistency

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Standardize error handling across all resources to raise typed exceptions instead of returning error strings or None values, ensuring consistent and predictable error behavior.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete Type Annotations - All exception classes have full annotations
- **INV-P010**: Test-Driven Development - Write tests BEFORE implementation
- **INV-P014**: (NEW) Resources Must Raise Exceptions on Failure

---

## Issues Addressed

| Issue ID | Severity | Description |
|----------|----------|-------------|
| NIM-002 | MEDIUM | Different error handling between `chat_completion` and `embed_texts` |
| NIM-003 | MEDIUM | Timeout not configurable per-call |
| LAKE-001 | MEDIUM | LakeFSResource returns None on failure vs raising exceptions |
| SAFE-001 | MEDIUM | SafeSynthesizerResource has mixed error patterns |
| WEAV-001 | MEDIUM | WeaviateResource has no error handling on connection failures |

---

## Implementation Steps

### Step 3.1: Standardize LakeFSResource Exceptions

**Action**: Modify

**File(s)**:
- `dagster/tests/unit/resources/test_lakefs_exceptions.py` (CREATE)
- `dagster/src/brev_pipelines/resources/lakefs.py`

Create exception types and update LakeFSResource to raise them.

```python
# lakefs.py - Add exception types
class LakeFSError(Exception):
    """Base exception for LakeFS errors."""
    pass


class LakeFSConnectionError(LakeFSError):
    """Raised when LakeFS connection fails."""
    pass


class LakeFSNotFoundError(LakeFSError):
    """Raised when requested object/branch/repo not found."""
    pass
```

Update methods to raise exceptions instead of returning None:

```python
def get_object(self, repository: str, ref: str, path: str) -> bytes:
    """Get object from LakeFS.

    Raises:
        LakeFSNotFoundError: Object not found.
        LakeFSError: Other LakeFS errors.
    """
    try:
        return self.get_client().objects_api.get_object(
            repository=repository,
            ref=ref,
            path=path,
        )
    except Exception as e:
        if "not found" in str(e).lower():
            raise LakeFSNotFoundError(f"Object not found: {path}") from e
        raise LakeFSError(f"LakeFS error: {e}") from e
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_lakefs*.py -v
```

---

### Step 3.2: Standardize WeaviateResource Exceptions

**Action**: Modify

**File(s)**:
- `dagster/tests/unit/resources/test_weaviate_exceptions.py` (CREATE)
- `dagster/src/brev_pipelines/resources/weaviate.py`

Add exception handling for connection and operation failures.

```python
# weaviate.py - Add exception types
class WeaviateError(Exception):
    """Base exception for Weaviate errors."""
    pass


class WeaviateConnectionError(WeaviateError):
    """Raised when Weaviate connection fails."""
    pass


class WeaviateCollectionError(WeaviateError):
    """Raised when collection operation fails."""
    pass
```

Update `get_client` to handle connection errors:

```python
def get_client(self) -> WeaviateClient:
    """Get Weaviate client, raising on connection failure.

    Raises:
        WeaviateConnectionError: Cannot connect to Weaviate.
    """
    if self._client is None:
        try:
            self._client = weaviate.connect_to_custom(
                http_host=self.host,
                http_port=self.port,
                grpc_host=self.grpc_host,
                grpc_port=self.grpc_port,
                skip_init_checks=False,
            )
        except Exception as e:
            raise WeaviateConnectionError(
                f"Failed to connect to Weaviate at {self.host}:{self.port}: {e}"
            ) from e
    return self._client
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_weaviate*.py -v
```

---

### Step 3.3: Standardize SafeSynthesizerResource Exceptions

**Action**: Modify

**File(s)**:
- `dagster/src/brev_pipelines/resources/safe_synth.py`

Integrate with exceptions from Phase 2's `safe_synth_retry.py`:

```python
from brev_pipelines.resources.safe_synth_retry import (
    SafeSynthError,
    SafeSynthTimeoutError,
    SafeSynthServerError,
    SafeSynthJobFailedError,
)
```

Update `synthesize` method to raise typed exceptions:

```python
def synthesize(
    self,
    input_data: list[dict[str, Any]],
    run_id: str,
    config: SafeSynthConfig | None = None,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Run Safe Synthesizer job.

    Raises:
        SafeSynthJobFailedError: Job failed.
        SafeSynthTimeoutError: Job timed out.
        SafeSynthError: Other errors.
    """
    # ... existing code ...

    # Replace error returns with raises
    if job_status["state"] == "failed":
        raise SafeSynthJobFailedError(
            job_id=job_id,
            reason=job_status.get("error", "Unknown failure"),
        )
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_safe_synth*.py -v
```

---

### Step 3.4: Update All Callers

**Action**: Modify

**File(s)**: Various asset files that call these resources

Update callers to handle new exception types:

```python
# Example in synthetic_speeches.py
from brev_pipelines.resources.lakefs import LakeFSError, LakeFSNotFoundError

try:
    response = lakefs_client.objects_api.get_object(...)
except LakeFSNotFoundError:
    raise ValueError(
        f"Enriched data not found at {path}. "
        "Run the ETL pipeline first."
    )
except LakeFSError as e:
    raise RuntimeError(f"Failed to load data from LakeFS: {e}")
```

---

### Step 3.5: Export All Exception Types

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/resources/__init__.py`

Export all new exception types for easy importing:

```python
from brev_pipelines.resources.lakefs import (
    LakeFSResource,
    LakeFSError,
    LakeFSConnectionError,
    LakeFSNotFoundError,
)
from brev_pipelines.resources.weaviate import (
    WeaviateResource,
    WeaviateError,
    WeaviateConnectionError,
    WeaviateCollectionError,
)
from brev_pipelines.resources.safe_synth import SafeSynthesizerResource
from brev_pipelines.resources.safe_synth_retry import (
    SafeSynthError,
    SafeSynthTimeoutError,
    SafeSynthServerError,
    SafeSynthJobFailedError,
)

__all__ = [
    # ... existing exports ...
    "LakeFSError",
    "LakeFSConnectionError",
    "LakeFSNotFoundError",
    "WeaviateError",
    "WeaviateConnectionError",
    "WeaviateCollectionError",
    "SafeSynthError",
    "SafeSynthTimeoutError",
    "SafeSynthServerError",
    "SafeSynthJobFailedError",
]
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/src/brev_pipelines/resources/lakefs.py` | MODIFY | Add exception types |
| `dagster/src/brev_pipelines/resources/weaviate.py` | MODIFY | Add exception types |
| `dagster/src/brev_pipelines/resources/safe_synth.py` | MODIFY | Use exception types |
| `dagster/src/brev_pipelines/resources/__init__.py` | MODIFY | Export exceptions |
| `dagster/tests/unit/resources/test_lakefs_exceptions.py` | CREATE | Exception tests |
| `dagster/tests/unit/resources/test_weaviate_exceptions.py` | CREATE | Exception tests |

---

## Verification

### Validation Commands

```bash
# Run all resource tests
cd dagster && uv run pytest tests/unit/resources/ -v

# Type checking
cd dagster && uv run mypy src/brev_pipelines/resources/ --strict

# Full test suite (ensure no regressions)
cd dagster && uv run pytest tests/ -v
```

### Expected Outcomes

- All resources raise typed exceptions on failure
- No methods return None or error strings on failure
- Clear, actionable error messages
- All callers handle exceptions appropriately

---

## Completion Criteria

- [ ] LakeFSResource raises `LakeFSError` subtypes on failure
- [ ] WeaviateResource raises `WeaviateError` subtypes on failure
- [ ] SafeSynthesizerResource uses exception types from retry module
- [ ] All exception types exported from `__init__.py`
- [ ] All callers updated to handle exceptions
- [ ] All tests pass
- [ ] No type errors (mypy)
