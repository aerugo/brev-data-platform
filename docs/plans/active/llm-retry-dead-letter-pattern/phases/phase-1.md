# Phase 1: Core Infrastructure

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create the reusable retry wrapper module with typed results, error classification, backoff calculation, and validation functions for LLM responses.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete Type Annotations - All functions have full type annotations
- **INV-P005**: No Any Types - Use `LLMCallResult[T]` generic, not `dict[str, Any]`
- **INV-P006**: Modern Python 3.11+ Syntax - Use `str | None`, `list[str]`
- **INV-P007**: Pydantic v2 for Data Models - Use `model_config = ConfigDict(...)` pattern
- **INV-P010**: Test-Driven Development - Write tests before implementation
- **INV-P011**: No Bare Generics - Use `list[float]`, not `list`

---

## Implementation Steps

### Step 1.1: Write Unit Tests (TDD)

**Action**: Create

**File(s)**: `dagster/tests/unit/resources/test_llm_retry.py`

Write tests first following TDD principles. Tests should cover:
- Backoff calculation with and without jitter
- Successful LLM call (no retries needed)
- Transient failure recovery after retries
- Permanent failure with fallback
- Different error types (timeout, rate limit, validation)

```python
"""Unit tests for LLM retry wrapper.

Tests written BEFORE implementation (TDD - INV-P010).
"""
from __future__ import annotations

import time
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

from brev_pipelines.resources.llm_retry import (
    LLMCallResult,
    LLMRateLimitError,
    LLMServerError,
    LLMTimeoutError,
    RetryConfig,
    ValidationError,
    calculate_backoff,
    retry_with_backoff,
)

if TYPE_CHECKING:
    from collections.abc import Callable


class TestCalculateBackoff:
    """Tests for backoff calculation."""

    def test_first_retry_uses_base_delay(self) -> None:
        """First retry should use base delay."""
        config = RetryConfig(base_delay=1.0, jitter=0.0)
        delay = calculate_backoff(attempt=0, config=config)
        assert delay == 1.0

    def test_exponential_increase(self) -> None:
        """Delay should increase exponentially."""
        config = RetryConfig(base_delay=1.0, exponential_base=2.0, jitter=0.0)
        assert calculate_backoff(0, config) == 1.0
        assert calculate_backoff(1, config) == 2.0
        assert calculate_backoff(2, config) == 4.0
        assert calculate_backoff(3, config) == 8.0

    def test_max_delay_cap(self) -> None:
        """Delay should be capped at max_delay."""
        config = RetryConfig(base_delay=1.0, max_delay=5.0, jitter=0.0)
        delay = calculate_backoff(attempt=10, config=config)
        assert delay == 5.0

    def test_jitter_applied(self) -> None:
        """Jitter should add randomness within bounds."""
        config = RetryConfig(base_delay=10.0, jitter=0.2)
        delays = [calculate_backoff(0, config) for _ in range(100)]
        # With 20% jitter on 10s, range is 8-12
        assert all(8.0 <= d <= 12.0 for d in delays)
        # Should have some variation
        assert len(set(delays)) > 1


class TestRetryWithBackoff:
    """Tests for retry_with_backoff function."""

    def test_success_on_first_try(self) -> None:
        """Successful call returns immediately without retries."""
        call_count = 0

        def llm_call() -> str:
            nonlocal call_count
            call_count += 1
            return '{"monetary_stance": "neutral"}'

        def validate(response: str) -> dict[str, str]:
            return {"monetary_stance": "neutral"}

        def fallback() -> dict[str, str]:
            return {"monetary_stance": "neutral"}

        result = retry_with_backoff(
            fn=llm_call,
            validate_fn=validate,
            record_id="test_001",
            fallback_fn=fallback,
            config=RetryConfig(max_retries=5),
        )

        assert result.status == "success"
        assert result.attempts == 1
        assert result.fallback_used is False
        assert call_count == 1

    def test_retry_on_transient_failure(self) -> None:
        """Transient failures should be retried."""
        call_count = 0

        def llm_call() -> str:
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                return "LLM error: timeout"
            return '{"result": "ok"}'

        def validate(response: str) -> dict[str, str]:
            return {"result": "ok"}

        def fallback() -> dict[str, str]:
            return {"result": "fallback"}

        config = RetryConfig(max_retries=5, base_delay=0.01)
        result = retry_with_backoff(
            fn=llm_call,
            validate_fn=validate,
            record_id="test_002",
            fallback_fn=fallback,
            config=config,
        )

        assert result.status == "success"
        assert result.attempts == 3
        assert result.fallback_used is False

    def test_fallback_after_max_retries(self) -> None:
        """After max retries, fallback values should be used."""
        def llm_call() -> str:
            return "LLM error: service unavailable"

        def validate(response: str) -> dict[str, str]:
            return {"result": "ok"}

        def fallback() -> dict[str, str]:
            return {"result": "fallback", "is_fallback": "true"}

        config = RetryConfig(max_retries=3, base_delay=0.01)
        result = retry_with_backoff(
            fn=llm_call,
            validate_fn=validate,
            record_id="test_003",
            fallback_fn=fallback,
            config=config,
        )

        assert result.status == "failed"
        assert result.attempts == 3
        assert result.fallback_used is True
        assert result.fallback_values == {"result": "fallback", "is_fallback": "true"}
        assert result.error_type is not None

    def test_validation_error_triggers_retry(self) -> None:
        """Validation failures should trigger retry."""
        call_count = 0

        def llm_call() -> str:
            nonlocal call_count
            call_count += 1
            if call_count < 2:
                return "invalid json response"
            return '{"valid": "json"}'

        def validate(response: str) -> dict[str, str]:
            if "invalid" in response:
                raise ValidationError("Invalid JSON")
            return {"valid": "json"}

        def fallback() -> dict[str, str]:
            return {"valid": "fallback"}

        config = RetryConfig(max_retries=5, base_delay=0.01)
        result = retry_with_backoff(
            fn=llm_call,
            validate_fn=validate,
            record_id="test_004",
            fallback_fn=fallback,
            config=config,
        )

        assert result.status == "success"
        assert result.attempts == 2

    def test_error_type_classification(self) -> None:
        """Error types should be correctly classified."""
        test_cases = [
            ("LLM error: timeout exceeded", "LLMTimeoutError"),
            ("LLM error: 429 rate limit", "LLMRateLimitError"),
            ("LLM error: 503 service unavailable", "LLMServerError"),
        ]

        for error_msg, expected_type in test_cases:
            def llm_call(msg: str = error_msg) -> str:
                return msg

            def validate(response: str) -> dict[str, str]:
                return {}

            def fallback() -> dict[str, str]:
                return {}

            config = RetryConfig(max_retries=1, base_delay=0.01)
            result = retry_with_backoff(
                fn=llm_call,
                validate_fn=validate,
                record_id=f"test_{expected_type}",
                fallback_fn=fallback,
                config=config,
            )

            assert result.error_type == expected_type, f"Expected {expected_type} for '{error_msg}'"

    def test_duration_tracking(self) -> None:
        """Duration should be tracked in milliseconds."""
        def llm_call() -> str:
            time.sleep(0.05)  # 50ms
            return '{"ok": true}'

        def validate(response: str) -> dict[str, bool]:
            return {"ok": True}

        def fallback() -> dict[str, bool]:
            return {"ok": False}

        result = retry_with_backoff(
            fn=llm_call,
            validate_fn=validate,
            record_id="test_timing",
            fallback_fn=fallback,
        )

        assert result.duration_ms >= 50
        assert result.duration_ms < 200  # Reasonable upper bound


class TestLLMCallResult:
    """Tests for LLMCallResult dataclass."""

    def test_success_result(self) -> None:
        """Success result should have correct fields."""
        result: LLMCallResult[dict[str, int]] = LLMCallResult(
            record_id="test_001",
            status="success",
            response='{"count": 5}',
            parsed_data={"count": 5},
            attempts=1,
            duration_ms=100,
        )

        assert result.status == "success"
        assert result.parsed_data == {"count": 5}
        assert result.fallback_used is False
        assert result.error_type is None

    def test_failed_result(self) -> None:
        """Failed result should have error details."""
        result: LLMCallResult[dict[str, int]] = LLMCallResult(
            record_id="test_002",
            status="failed",
            error_type="LLMTimeoutError",
            error_message="Connection timed out",
            attempts=5,
            fallback_used=True,
            fallback_values={"count": 0},
            duration_ms=31000,
        )

        assert result.status == "failed"
        assert result.error_type == "LLMTimeoutError"
        assert result.fallback_used is True
        assert result.fallback_values == {"count": 0}
```

**Validation**:
```bash
# Tests should FAIL initially (no implementation yet)
cd dagster && pytest tests/unit/resources/test_llm_retry.py -v
```

---

### Step 1.2: Add Type Definitions

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/types.py`

Add TypedDict and Protocol definitions for LLM retry results.

```python
# Add to existing types.py

# =============================================================================
# LLM Retry Types
# =============================================================================

class ClassificationResult(TypedDict):
    """Validated classification result from LLM."""

    monetary_stance: int
    trade_stance: int
    tariff_mention: int
    economic_outlook: int


class SummaryResult(TypedDict):
    """Validated summary result from LLM."""

    summary: str


# Classification scale mappings
MONETARY_STANCE_SCALE: dict[str, int] = {
    "very_dovish": 1,
    "dovish": 2,
    "neutral": 3,
    "hawkish": 4,
    "very_hawkish": 5,
}

TRADE_STANCE_SCALE: dict[str, int] = {
    "very_protectionist": 1,
    "protectionist": 2,
    "neutral": 3,
    "globalist": 4,
    "very_globalist": 5,
}

OUTLOOK_SCALE: dict[str, int] = {
    "very_negative": 1,
    "negative": 2,
    "neutral": 3,
    "positive": 4,
    "very_positive": 5,
}
```

**Validation**:
```bash
cd dagster && mypy src/brev_pipelines/types.py --strict
```

---

### Step 1.3: Implement Retry Module

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/resources/llm_retry.py`

Implement the retry wrapper with all features from the tests.

```python
"""LLM retry wrapper with exponential backoff and dead letter pattern.

Provides robust error handling for LLM calls in data pipelines:
- Exponential backoff with jitter for transient failures
- Typed results with success/failure tracking
- Validation functions for structured LLM responses

Usage:
    result = retry_with_backoff(
        fn=lambda: nim.generate(prompt),
        validate_fn=validate_classification_response,
        record_id=record["reference"],
        fallback_fn=lambda: ClassificationResult(monetary_stance=3, ...),
    )

    if result.status == "success":
        data = result.parsed_data
    else:
        data = result.fallback_values
        log.warning(f"Failed: {result.error_message}")

Follows invariants:
- INV-P004: Complete type annotations
- INV-P005: No Any types (uses Generic[T])
- INV-P006: Modern Python 3.11+ syntax
- INV-P007: Pydantic v2 for RetryConfig
"""
from __future__ import annotations

import json
import random
import re
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Generic, TypeVar

from pydantic import BaseModel, ConfigDict, Field

from brev_pipelines.types import (
    MONETARY_STANCE_SCALE,
    OUTLOOK_SCALE,
    TRADE_STANCE_SCALE,
    ClassificationResult,
)

if TYPE_CHECKING:
    from dagster import DagsterLogManager

T = TypeVar("T")


# =============================================================================
# Error Types
# =============================================================================


class RetryableError(Exception):
    """Base class for errors that should trigger a retry."""

    pass


class ValidationError(RetryableError):
    """LLM response failed validation (invalid JSON, missing fields)."""

    pass


class LLMTimeoutError(RetryableError):
    """LLM request timed out."""

    pass


class LLMRateLimitError(RetryableError):
    """LLM service returned rate limit error (429)."""

    pass


class LLMServerError(RetryableError):
    """LLM service returned server error (5xx)."""

    pass


# =============================================================================
# Configuration
# =============================================================================


class RetryConfig(BaseModel):
    """Configuration for LLM call retry behavior.

    Uses Pydantic v2 syntax (INV-P007).
    """

    model_config = ConfigDict(frozen=True)

    max_retries: int = Field(default=5, ge=1, le=10)
    base_delay: float = Field(default=1.0, ge=0.0)
    max_delay: float = Field(default=60.0, ge=1.0)
    exponential_base: float = Field(default=2.0, ge=1.0)
    jitter: float = Field(default=0.2, ge=0.0, le=0.5)


# =============================================================================
# Result Type
# =============================================================================


@dataclass
class LLMCallResult(Generic[T]):
    """Result of an LLM call with full metadata.

    Generic over the parsed data type T (INV-P005: no Any).

    Attributes:
        record_id: Identifier for the record being processed
        status: "success" or "failed"
        response: Raw LLM response string (on success)
        parsed_data: Validated/parsed data (on success)
        error_type: Error class name (on failure)
        error_message: Error details (on failure)
        attempts: Number of attempts made
        fallback_used: Whether fallback values were used
        fallback_values: Fallback data (if fallback_used)
        duration_ms: Total processing time in milliseconds
    """

    record_id: str
    status: str  # "success" or "failed"

    # Success fields
    response: str | None = None
    parsed_data: T | None = None

    # Failure fields
    error_type: str | None = None
    error_message: str | None = None
    attempts: int = 0

    # Fallback info
    fallback_used: bool = False
    fallback_values: T | None = None

    # Timing
    duration_ms: int = 0


# =============================================================================
# Backoff Calculation
# =============================================================================


def calculate_backoff(attempt: int, config: RetryConfig) -> float:
    """Calculate delay with exponential backoff and jitter.

    Args:
        attempt: Zero-based attempt number (0 = first retry)
        config: Retry configuration

    Returns:
        Delay in seconds before next retry
    """
    delay = config.base_delay * (config.exponential_base**attempt)
    delay = min(delay, config.max_delay)

    # Add jitter (±config.jitter percent)
    if config.jitter > 0:
        jitter_range = delay * config.jitter
        delay += random.uniform(-jitter_range, jitter_range)

    return max(0.0, delay)


# =============================================================================
# Error Classification
# =============================================================================


def classify_llm_error(error_msg: str) -> type[RetryableError]:
    """Classify error message into specific error type.

    Args:
        error_msg: Error message from LLM response

    Returns:
        Appropriate error class
    """
    error_lower = error_msg.lower()

    if "timeout" in error_lower:
        return LLMTimeoutError
    if "429" in error_msg or "rate" in error_lower:
        return LLMRateLimitError
    if any(code in error_msg for code in ("500", "502", "503", "504")):
        return LLMServerError

    return RetryableError


# =============================================================================
# Main Retry Function
# =============================================================================


def retry_with_backoff(
    fn: Callable[[], str],
    validate_fn: Callable[[str], T],
    record_id: str,
    fallback_fn: Callable[[], T],
    config: RetryConfig | None = None,
    logger: DagsterLogManager | None = None,
) -> LLMCallResult[T]:
    """Execute LLM call with retry logic and validation.

    Args:
        fn: Function that makes the LLM call and returns raw response
        validate_fn: Function that validates/parses response, raises ValidationError on failure
        record_id: Identifier for the record being processed
        fallback_fn: Function that returns fallback values if all retries fail
        config: Retry configuration (defaults to RetryConfig())
        logger: Optional Dagster logger for debugging

    Returns:
        LLMCallResult with either parsed data or fallback values
    """
    if config is None:
        config = RetryConfig()

    start_time = time.time()
    last_error: Exception | None = None
    last_error_type: str | None = None

    for attempt in range(config.max_retries):
        try:
            # Make the LLM call
            raw_response = fn()

            # Check for error responses from NIMResource
            if raw_response.startswith("LLM error:"):
                error_msg = raw_response[len("LLM error:") :].strip()
                error_class = classify_llm_error(error_msg)
                raise error_class(error_msg)

            # Validate and parse the response
            parsed_data = validate_fn(raw_response)

            # Success!
            duration_ms = int((time.time() - start_time) * 1000)
            return LLMCallResult(
                record_id=record_id,
                status="success",
                response=raw_response,
                parsed_data=parsed_data,
                attempts=attempt + 1,
                duration_ms=duration_ms,
            )

        except RetryableError as e:
            last_error = e
            last_error_type = type(e).__name__

            if attempt < config.max_retries - 1:
                delay = calculate_backoff(attempt, config)
                if logger:
                    logger.warning(
                        f"LLM call failed for {record_id} "
                        f"(attempt {attempt + 1}/{config.max_retries}): "
                        f"{e}. Retrying in {delay:.1f}s..."
                    )
                time.sleep(delay)

        except Exception as e:
            # Non-retryable error - break immediately
            last_error = e
            last_error_type = "unexpected_error"
            break

    # All retries exhausted - use fallback
    duration_ms = int((time.time() - start_time) * 1000)
    fallback_values = fallback_fn()

    if logger:
        logger.error(
            f"LLM call failed permanently for {record_id} "
            f"after {config.max_retries} attempts: {last_error}"
        )

    return LLMCallResult(
        record_id=record_id,
        status="failed",
        error_type=last_error_type,
        error_message=str(last_error) if last_error else None,
        attempts=config.max_retries,
        fallback_used=True,
        fallback_values=fallback_values,
        duration_ms=duration_ms,
    )


# =============================================================================
# Validation Functions
# =============================================================================


def validate_classification_response(response: str) -> ClassificationResult:
    """Validate and parse classification LLM response.

    Args:
        response: Raw LLM response string

    Returns:
        Validated ClassificationResult

    Raises:
        ValidationError: If response cannot be parsed as valid classification
    """
    # Try to extract JSON from response
    json_match = re.search(r"\{[^}]+\}", response)
    if not json_match:
        raise ValidationError(f"No JSON found in response: {response[:100]}...")

    try:
        result = json.loads(json_match.group())
    except json.JSONDecodeError as e:
        raise ValidationError(f"Invalid JSON: {e}") from e

    # Validate required fields
    required_fields = ["monetary_stance", "trade_stance", "tariff_mention", "economic_outlook"]
    missing = [f for f in required_fields if f not in result]
    if missing:
        raise ValidationError(f"Missing required fields: {missing}")

    # Map string values to numeric scales
    monetary_raw = result.get("monetary_stance", "")
    monetary = MONETARY_STANCE_SCALE.get(monetary_raw)
    if monetary is None:
        raise ValidationError(f"Invalid monetary_stance: {monetary_raw}")

    trade_raw = result.get("trade_stance", "")
    trade = TRADE_STANCE_SCALE.get(trade_raw)
    if trade is None:
        raise ValidationError(f"Invalid trade_stance: {trade_raw}")

    outlook_raw = result.get("economic_outlook", "")
    outlook = OUTLOOK_SCALE.get(outlook_raw)
    if outlook is None:
        raise ValidationError(f"Invalid economic_outlook: {outlook_raw}")

    tariff = result.get("tariff_mention")
    if tariff not in (0, 1, "0", "1"):
        raise ValidationError(f"Invalid tariff_mention: {tariff}")

    return ClassificationResult(
        monetary_stance=monetary,
        trade_stance=trade,
        tariff_mention=int(tariff),
        economic_outlook=outlook,
    )


def validate_summary_response(response: str) -> str:
    """Validate summary LLM response.

    Args:
        response: Raw LLM response string

    Returns:
        Validated summary string

    Raises:
        ValidationError: If response is invalid
    """
    if response.startswith("LLM error:"):
        raise ValidationError(response)

    stripped = response.strip()
    if len(stripped) < 50:
        raise ValidationError(f"Summary too short ({len(stripped)} chars)")

    # Truncate if too long
    if len(stripped) > 1500:
        return stripped[:1500] + "..."

    return stripped
```

**Validation**:
```bash
cd dagster
# Tests should now PASS
pytest tests/unit/resources/test_llm_retry.py -v --cov=brev_pipelines.resources.llm_retry

# Type checking
mypy src/brev_pipelines/resources/llm_retry.py --strict

# Linting
ruff check src/brev_pipelines/resources/llm_retry.py
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/tests/unit/resources/test_llm_retry.py` | CREATE | Unit tests for retry logic (TDD) |
| `dagster/src/brev_pipelines/types.py` | MODIFY | Add ClassificationResult, scale mappings |
| `dagster/src/brev_pipelines/resources/llm_retry.py` | CREATE | Retry wrapper implementation |

---

## Configuration Details

### Environment Variables

None required for this phase.

### Secrets Required

None required for this phase.

---

## Verification

### Pre-flight Checks

```bash
# Ensure dev dependencies are installed
cd dagster && uv sync --all-extras

# Verify pytest is available
pytest --version
```

### Validation Commands

```bash
# Run unit tests with coverage
cd dagster
pytest tests/unit/resources/test_llm_retry.py -v --cov=brev_pipelines.resources.llm_retry --cov-report=term-missing

# Type checking (strict mode)
mypy src/brev_pipelines/resources/llm_retry.py --strict

# Linting
ruff check src/brev_pipelines/resources/llm_retry.py
ruff format src/brev_pipelines/resources/llm_retry.py --check
```

### Expected Outcomes

- All tests pass (100% coverage for `llm_retry.py`)
- No mypy errors in strict mode
- No ruff linting errors
- `calculate_backoff` returns correct values with jitter
- `retry_with_backoff` handles all error types correctly
- Validation functions parse LLM responses correctly

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Tests fail on initial run | `pytest` exits non-zero | Expected - TDD approach |
| Import errors in tests | `ImportError` in test output | Ensure `llm_retry.py` is created |
| Jitter tests flaky | Tests occasionally fail | Use wide bounds (8-12 for ±20% on 10) |
| Timing tests flaky | `duration_ms` assertions fail | Use reasonable bounds (50-200ms) |

### Rollback Plan

If this phase fails:
1. Delete `llm_retry.py` if created
2. Revert changes to `types.py`
3. Delete test file

---

## Completion Criteria

- [ ] All files created/modified as specified
- [ ] `pytest tests/unit/resources/test_llm_retry.py -v` passes (100% coverage)
- [ ] `mypy src/brev_pipelines/resources/llm_retry.py --strict` passes
- [ ] `ruff check src/brev_pipelines/resources/llm_retry.py` passes
- [ ] No bare generics or `Any` types used (INV-P005, INV-P011)
- [ ] All functions have complete type annotations (INV-P004)
