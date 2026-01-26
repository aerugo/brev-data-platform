# Phase 1: Critical Error Handling

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Fix the highest-impact error handling gaps that could cause production failures: missing Weaviate validation, unprotected NIM health check, and inconsistent NIM error handling.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete Type Annotations - All new exception classes and modified functions have full annotations
- **INV-P010**: Test-Driven Development - Write tests BEFORE implementing fixes
- **INV-P015**: (NEW) All External Service Calls Must Have Error Handling

---

## Issues Addressed

| Issue ID | Severity | Description |
|----------|----------|-------------|
| VAL-001 | HIGH | Weaviate validation completely missing from `validate_platform` |
| VAL-002 | HIGH | NIM health check has no exception handling |
| NIM-001 | HIGH | NIMResource returns error strings instead of raising exceptions |

---

## Implementation Steps

### Step 1.1: Create NIM Exception Types (TDD - RED)

**Action**: Create

**File(s)**: `dagster/tests/unit/resources/test_nim_exceptions.py`

Write tests for the new NIM exception behavior BEFORE implementing.

```python
"""Tests for NIM exception handling."""
import pytest
from unittest.mock import Mock, patch

from brev_pipelines.resources.nim import NIMResource, NIMError, NIMTimeoutError, NIMServerError


class TestNIMExceptions:
    """Test NIM resource raises appropriate exceptions."""

    def test_chat_completion_raises_timeout_error(self) -> None:
        """NIMResource should raise NIMTimeoutError on timeout."""
        nim = NIMResource(endpoint="http://test:8000")

        with patch("httpx.Client") as mock_client:
            mock_client.return_value.__enter__.return_value.post.side_effect = (
                httpx.TimeoutException("Connection timed out")
            )

            with pytest.raises(NIMTimeoutError) as exc_info:
                nim.chat_completion("test prompt")

            assert "timeout" in str(exc_info.value).lower()

    def test_chat_completion_raises_server_error_on_5xx(self) -> None:
        """NIMResource should raise NIMServerError on 5xx responses."""
        nim = NIMResource(endpoint="http://test:8000")

        with patch("httpx.Client") as mock_client:
            mock_response = Mock()
            mock_response.status_code = 503
            mock_response.text = "Service Unavailable"
            mock_client.return_value.__enter__.return_value.post.return_value = mock_response

            with pytest.raises(NIMServerError) as exc_info:
                nim.chat_completion("test prompt")

            assert "503" in str(exc_info.value)

    def test_chat_completion_raises_rate_limit_error_on_429(self) -> None:
        """NIMResource should raise NIMRateLimitError on 429."""
        nim = NIMResource(endpoint="http://test:8000")

        with patch("httpx.Client") as mock_client:
            mock_response = Mock()
            mock_response.status_code = 429
            mock_response.text = "Rate limited"
            mock_client.return_value.__enter__.return_value.post.return_value = mock_response

            with pytest.raises(NIMRateLimitError) as exc_info:
                nim.chat_completion("test prompt")

    def test_chat_completion_success_returns_string(self) -> None:
        """NIMResource should return string content on success."""
        nim = NIMResource(endpoint="http://test:8000")

        with patch("httpx.Client") as mock_client:
            mock_response = Mock()
            mock_response.status_code = 200
            mock_response.json.return_value = {
                "choices": [{"message": {"content": "test response"}}]
            }
            mock_client.return_value.__enter__.return_value.post.return_value = mock_response

            result = nim.chat_completion("test prompt")

            assert result == "test response"
            assert not result.startswith("LLM error:")  # Old behavior
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_nim_exceptions.py -v
# Expected: FAIL (tests written before implementation)
```

---

### Step 1.2: Implement NIM Exception Types (TDD - GREEN)

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/resources/nim.py`

Add exception classes and update `chat_completion` to raise them.

```python
# Add at top of file, after imports
class NIMError(Exception):
    """Base exception for NIM errors."""
    pass


class NIMTimeoutError(NIMError):
    """Raised when NIM request times out."""
    pass


class NIMServerError(NIMError):
    """Raised when NIM returns 5xx error."""

    def __init__(self, status_code: int, message: str) -> None:
        self.status_code = status_code
        super().__init__(f"NIM server error {status_code}: {message}")


class NIMRateLimitError(NIMError):
    """Raised when NIM returns 429 rate limit error."""
    pass


# Update chat_completion method:
def chat_completion(
    self,
    prompt: str,
    *,
    system_prompt: str | None = None,
    temperature: float = 0.7,
    max_tokens: int = 1024,
) -> str:
    """Execute chat completion request.

    Args:
        prompt: User prompt text.
        system_prompt: Optional system prompt.
        temperature: Sampling temperature.
        max_tokens: Maximum tokens in response.

    Returns:
        Generated text response.

    Raises:
        NIMTimeoutError: Request timed out.
        NIMServerError: Server returned 5xx error.
        NIMRateLimitError: Server returned 429 rate limit.
        NIMError: Other NIM-related errors.
    """
    messages: list[NIMChatMessage] = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})

    try:
        with httpx.Client(timeout=self.timeout) as client:
            response = client.post(
                f"{self.endpoint}/v1/chat/completions",
                json={
                    "model": self.model,
                    "messages": messages,
                    "temperature": temperature,
                    "max_tokens": max_tokens,
                },
            )
    except httpx.TimeoutException as e:
        raise NIMTimeoutError(f"NIM request timed out after {self.timeout}s: {e}") from e
    except httpx.RequestError as e:
        raise NIMError(f"NIM request failed: {e}") from e

    if response.status_code == 429:
        raise NIMRateLimitError(f"NIM rate limited: {response.text}")

    if response.status_code >= 500:
        raise NIMServerError(response.status_code, response.text)

    if response.status_code != 200:
        raise NIMError(f"NIM error {response.status_code}: {response.text}")

    data = response.json()
    return data["choices"][0]["message"]["content"]
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_nim_exceptions.py -v
# Expected: PASS
```

---

### Step 1.3: Update NIM Callers to Handle Exceptions

**Action**: Modify

**File(s)**:
- `dagster/src/brev_pipelines/assets/central_bank_speeches.py`
- `dagster/src/brev_pipelines/assets/demo.py`

The `llm_retry.py` already handles these exceptions. Update any direct NIM callers.

For `demo.py`, add basic error handling:

```python
@dg.asset(group_name="demo")
def demo_query_nim(nim: NIMResource) -> str:
    """Query NIM LLM endpoint."""
    try:
        response = nim.chat_completion(
            "What is the capital of France? Reply in one word.",
            temperature=0.1,
        )
        return response
    except NIMError as e:
        return f"NIM query failed: {e}"
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_demo.py -v
```

---

### Step 1.4: Add NIM Health Exception Handling (TDD - RED)

**Action**: Create/Modify

**File(s)**: `dagster/tests/unit/assets/test_health.py`

Write test for NIM health handling network errors.

```python
"""Tests for health assets."""
import pytest
from unittest.mock import Mock, patch

from brev_pipelines.assets.health import nim_health
from brev_pipelines.resources.nim import NIMResource, NIMError


class TestNIMHealth:
    """Test NIM health asset."""

    def test_nim_health_handles_connection_error(self) -> None:
        """nim_health should return error dict on connection failure."""
        nim = Mock(spec=NIMResource)
        nim.chat_completion.side_effect = NIMError("Connection refused")

        result = nim_health(nim)

        assert result["status"] == "unhealthy"
        assert "Connection refused" in result["error"]

    def test_nim_health_returns_healthy_on_success(self) -> None:
        """nim_health should return healthy status on success."""
        nim = Mock(spec=NIMResource)
        nim.chat_completion.return_value = "Hello! I'm working."

        result = nim_health(nim)

        assert result["status"] == "healthy"
        assert "error" not in result or result["error"] is None
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_health.py -v
# Expected: FAIL (need to implement)
```

---

### Step 1.5: Implement NIM Health Exception Handling (TDD - GREEN)

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/health.py`

Add try/except to nim_health.

```python
@dg.asset(group_name="health")
def nim_health(nim: NIMResource) -> dict[str, str | None]:
    """Check NIM LLM service health.

    Returns:
        Dict with status ('healthy' or 'unhealthy') and optional error message.
    """
    from brev_pipelines.resources.nim import NIMError

    try:
        response = nim.chat_completion(
            "Say hello in one word.",
            temperature=0.1,
            max_tokens=10,
        )
        return {"status": "healthy", "response": response, "error": None}
    except NIMError as e:
        return {"status": "unhealthy", "response": None, "error": str(e)}
    except Exception as e:
        return {"status": "unhealthy", "response": None, "error": f"Unexpected error: {e}"}
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_health.py -v
# Expected: PASS
```

---

### Step 1.6: Add Weaviate Validation (TDD - RED)

**Action**: Create

**File(s)**: `dagster/tests/unit/assets/test_validation_weaviate.py`

Write tests for Weaviate validation.

```python
"""Tests for Weaviate validation."""
import pytest
from unittest.mock import Mock

from brev_pipelines.assets.validation import validate_weaviate
from brev_pipelines.resources.weaviate import WeaviateResource


class TestWeaviateValidation:
    """Test Weaviate validation asset."""

    def test_validate_weaviate_healthy(self) -> None:
        """Should return passed when Weaviate is healthy."""
        weaviate = Mock(spec=WeaviateResource)
        weaviate.get_client.return_value.is_ready.return_value = True

        result = validate_weaviate(weaviate)

        assert result["passed"] is True
        assert result["component"] == "weaviate"

    def test_validate_weaviate_unhealthy(self) -> None:
        """Should return failed when Weaviate is not ready."""
        weaviate = Mock(spec=WeaviateResource)
        weaviate.get_client.return_value.is_ready.return_value = False

        result = validate_weaviate(weaviate)

        assert result["passed"] is False

    def test_validate_weaviate_connection_error(self) -> None:
        """Should return failed with error on connection failure."""
        weaviate = Mock(spec=WeaviateResource)
        weaviate.get_client.side_effect = Exception("Connection refused")

        result = validate_weaviate(weaviate)

        assert result["passed"] is False
        assert "Connection refused" in result["error"]
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_validation_weaviate.py -v
# Expected: FAIL (asset doesn't exist yet)
```

---

### Step 1.7: Implement Weaviate Validation (TDD - GREEN)

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/validation.py`

Add `validate_weaviate` asset and include it in `validate_platform`.

```python
@dg.asset(group_name="validation")
def validate_weaviate(weaviate: WeaviateResource) -> ValidationReportDict:
    """Validate Weaviate vector database connectivity.

    Returns:
        Validation report with connection status and any errors.
    """
    import time

    start = time.time()
    tests: list[ValidationTestResult] = []

    # Test 1: Connection
    try:
        client = weaviate.get_client()
        is_ready = client.is_ready()
        tests.append({
            "name": "connection",
            "passed": is_ready,
            "error": None if is_ready else "Weaviate not ready",
        })
    except Exception as e:
        tests.append({
            "name": "connection",
            "passed": False,
            "error": str(e),
        })
        return {
            "component": "weaviate",
            "passed": False,
            "tests": tests,
            "error": str(e),
            "duration_ms": (time.time() - start) * 1000,
        }

    # Test 2: Schema access (optional - verifies deeper connectivity)
    try:
        # Just check we can list collections
        collections = client.collections.list_all()
        tests.append({
            "name": "schema_access",
            "passed": True,
            "error": None,
        })
    except Exception as e:
        tests.append({
            "name": "schema_access",
            "passed": False,
            "error": str(e),
        })

    all_passed = all(t["passed"] for t in tests)

    return {
        "component": "weaviate",
        "passed": all_passed,
        "tests": tests,
        "error": None if all_passed else "One or more tests failed",
        "duration_ms": (time.time() - start) * 1000,
    }


# Update validate_platform to include Weaviate:
@dg.asset(
    group_name="validation",
    deps=[validate_minio, validate_lakefs, validate_nim, validate_weaviate],
)
def validate_platform(
    context: dg.AssetExecutionContext,
    validate_minio: ValidationReportDict,
    validate_lakefs: ValidationReportDict,
    validate_nim: ValidationReportDict,
    validate_weaviate: ValidationReportDict,
) -> dict[str, ValidationReportDict]:
    """Aggregate validation results from all platform components."""
    results = {
        "minio": validate_minio,
        "lakefs": validate_lakefs,
        "nim": validate_nim,
        "weaviate": validate_weaviate,
    }

    all_passed = all(r["passed"] for r in results.values())

    context.log.info(f"Platform validation: {'PASSED' if all_passed else 'FAILED'}")
    for name, result in results.items():
        status = "PASS" if result["passed"] else "FAIL"
        context.log.info(f"  {name}: {status}")

    return results
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_validation_weaviate.py -v
# Expected: PASS
```

---

### Step 1.8: Export New Exceptions

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/resources/__init__.py`

Export the new exception types.

```python
from brev_pipelines.resources.nim import (
    NIMResource,
    NIMError,
    NIMTimeoutError,
    NIMServerError,
    NIMRateLimitError,
)

__all__ = [
    "NIMResource",
    "NIMError",
    "NIMTimeoutError",
    "NIMServerError",
    "NIMRateLimitError",
    # ... other exports
]
```

**Validation**:
```bash
cd dagster && uv run python -c "from brev_pipelines.resources import NIMError"
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/src/brev_pipelines/resources/nim.py` | MODIFY | Add exception classes, update chat_completion |
| `dagster/src/brev_pipelines/assets/health.py` | MODIFY | Add exception handling to nim_health |
| `dagster/src/brev_pipelines/assets/validation.py` | MODIFY | Add validate_weaviate, update validate_platform |
| `dagster/src/brev_pipelines/assets/demo.py` | MODIFY | Add error handling to demo_query_nim |
| `dagster/tests/unit/resources/test_nim_exceptions.py` | CREATE | Tests for NIM exceptions |
| `dagster/tests/unit/assets/test_health.py` | CREATE/MODIFY | Tests for health assets |
| `dagster/tests/unit/assets/test_validation_weaviate.py` | CREATE | Tests for Weaviate validation |

---

## Configuration Details

### Environment Variables

No new environment variables required.

### Secrets Required

No new secrets required.

---

## Verification

### Pre-flight Checks

```bash
# Ensure existing tests pass before changes
cd dagster && uv run pytest tests/ -v --tb=short
```

### Validation Commands

```bash
# Run all new and modified tests
cd dagster && uv run pytest tests/unit/resources/test_nim*.py tests/unit/assets/test_health.py tests/unit/assets/test_validation*.py -v

# Type checking
cd dagster && uv run mypy src/brev_pipelines/resources/nim.py --strict

# Linting
cd dagster && uv run ruff check src/brev_pipelines/resources/nim.py src/brev_pipelines/assets/health.py src/brev_pipelines/assets/validation.py

# Full test suite (ensure no regressions)
cd dagster && uv run pytest tests/ -v
```

### Expected Outcomes

- All new tests pass
- All existing tests pass (no regressions)
- NIMResource raises exceptions instead of returning error strings
- nim_health handles errors gracefully
- validate_platform includes Weaviate

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Existing code expects error strings | Tests fail with exception instead of string | Update callers to catch exceptions |
| llm_retry.py already catches some errors | Review imports | Ensure imports updated to new exception names |
| Weaviate client API differs | Import error | Check weaviate-client version, adjust API calls |

### Rollback Plan

If this phase fails:
1. Revert changes to nim.py (return to error string pattern)
2. Remove validate_weaviate from validate_platform deps
3. Remove new test files

---

## Completion Criteria

- [ ] `NIMError`, `NIMTimeoutError`, `NIMServerError`, `NIMRateLimitError` exception classes exist
- [ ] `NIMResource.chat_completion` raises exceptions on failure
- [ ] All callers of NIMResource handle exceptions appropriately
- [ ] `nim_health` returns error dict instead of crashing on network errors
- [ ] `validate_weaviate` asset exists and tests Weaviate connectivity
- [ ] `validate_platform` includes Weaviate in validation
- [ ] All tests pass (new and existing)
- [ ] No type errors (mypy)
- [ ] No lint errors (ruff)
