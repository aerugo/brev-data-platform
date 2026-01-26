# Phase 2: Synthesis Pipeline Hardening

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Add retry logic for Safe Synthesizer API calls and input validation for dead letter columns in the synthesis pipeline, ensuring robust handling of transient failures and data quality issues.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete Type Annotations - All new code has full annotations
- **INV-P010**: Test-Driven Development - Write tests BEFORE implementation
- **INV-P012**: LLM Calls Must Use Retry Wrapper - Extend principle to Safe Synthesizer
- **INV-P013**: Dead Letter Columns in LLM Output - Validate presence in input data

---

## Issues Addressed

| Issue ID | Severity | Description |
|----------|----------|-------------|
| SYN-001 | HIGH | Dead letter columns from input data not validated |
| SYN-002 | HIGH | No retry logic for Safe Synthesizer API calls |
| SYN-003 | MEDIUM | KAI scheduler logic has incomplete fallback path |
| SYN-004 | LOW | `synthesize_batch()` doesn't validate input DataFrame structure |

---

## Implementation Steps

### Step 2.1: Create Safe Synth Retry Tests (TDD - RED)

**Action**: Create

**File(s)**: `dagster/tests/unit/resources/test_safe_synth_retry.py`

Write tests for Safe Synthesizer retry wrapper BEFORE implementing.

```python
"""Tests for Safe Synthesizer retry wrapper."""
import pytest
from unittest.mock import Mock, patch
import time

from brev_pipelines.resources.safe_synth_retry import (
    SafeSynthRetryConfig,
    SafeSynthError,
    SafeSynthTimeoutError,
    SafeSynthServerError,
    retry_safe_synth_call,
)
from brev_pipelines.types import SafeSynthConfig


class TestSafeSynthRetryConfig:
    """Test SafeSynthRetryConfig dataclass."""

    def test_default_values(self) -> None:
        """Should have sensible defaults."""
        config = SafeSynthRetryConfig()
        assert config.max_retries == 3
        assert config.initial_delay == 10.0  # Safe Synth jobs take longer
        assert config.max_delay == 120.0
        assert config.exponential_base == 2.0
        assert config.jitter_factor == 0.2


class TestSafeSynthExceptions:
    """Test Safe Synth exception types."""

    def test_safe_synth_timeout_error(self) -> None:
        """SafeSynthTimeoutError should be catchable as SafeSynthError."""
        error = SafeSynthTimeoutError("Job timed out after 30 minutes")
        assert isinstance(error, SafeSynthError)

    def test_safe_synth_server_error_with_status(self) -> None:
        """SafeSynthServerError should include status code."""
        error = SafeSynthServerError(503, "Service unavailable")
        assert error.status_code == 503
        assert "503" in str(error)


class TestRetrySafeSynthCall:
    """Test retry_safe_synth_call function."""

    def test_succeeds_on_first_try(self) -> None:
        """Should return result immediately on success."""
        mock_fn = Mock(return_value={"synthetic": "data"})

        result = retry_safe_synth_call(mock_fn, run_id="test-001")

        assert result == {"synthetic": "data"}
        assert mock_fn.call_count == 1

    def test_retries_on_transient_failure(self) -> None:
        """Should retry on transient failures."""
        mock_fn = Mock(
            side_effect=[
                SafeSynthServerError(503, "Temporarily unavailable"),
                SafeSynthServerError(503, "Still unavailable"),
                {"synthetic": "data"},  # Success on 3rd try
            ]
        )

        with patch("time.sleep"):  # Don't actually sleep in tests
            result = retry_safe_synth_call(
                mock_fn,
                run_id="test-002",
                config=SafeSynthRetryConfig(max_retries=3),
            )

        assert result == {"synthetic": "data"}
        assert mock_fn.call_count == 3

    def test_exhausts_retries_and_raises(self) -> None:
        """Should raise after max retries exhausted."""
        mock_fn = Mock(side_effect=SafeSynthServerError(503, "Always failing"))

        with patch("time.sleep"):
            with pytest.raises(SafeSynthServerError):
                retry_safe_synth_call(
                    mock_fn,
                    run_id="test-003",
                    config=SafeSynthRetryConfig(max_retries=3),
                )

        assert mock_fn.call_count == 3

    def test_no_retry_on_validation_error(self) -> None:
        """Should not retry on validation errors (client's fault)."""
        mock_fn = Mock(side_effect=ValueError("Invalid input data"))

        with pytest.raises(ValueError):
            retry_safe_synth_call(mock_fn, run_id="test-004")

        assert mock_fn.call_count == 1  # No retries

    def test_exponential_backoff_delays(self) -> None:
        """Should use exponential backoff between retries."""
        mock_fn = Mock(
            side_effect=[
                SafeSynthTimeoutError("Timeout 1"),
                SafeSynthTimeoutError("Timeout 2"),
                {"data": "success"},
            ]
        )

        sleep_calls: list[float] = []
        with patch("time.sleep", side_effect=lambda x: sleep_calls.append(x)):
            retry_safe_synth_call(
                mock_fn,
                run_id="test-005",
                config=SafeSynthRetryConfig(
                    max_retries=3,
                    initial_delay=10.0,
                    exponential_base=2.0,
                    jitter_factor=0.0,  # No jitter for predictable test
                ),
            )

        # First retry: 10s, Second retry: 20s (10 * 2)
        assert len(sleep_calls) == 2
        assert sleep_calls[0] == 10.0
        assert sleep_calls[1] == 20.0

    def test_calls_logger_on_retry(self) -> None:
        """Should log retry attempts if logger provided."""
        mock_fn = Mock(
            side_effect=[
                SafeSynthServerError(503, "Retry me"),
                {"data": "success"},
            ]
        )
        mock_logger = Mock()

        with patch("time.sleep"):
            retry_safe_synth_call(
                mock_fn,
                run_id="test-006",
                logger=mock_logger,
            )

        # Should have logged the retry
        assert mock_logger.warning.called
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_safe_synth_retry.py -v
# Expected: FAIL (module doesn't exist yet)
```

---

### Step 2.2: Implement Safe Synth Retry Module (TDD - GREEN)

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/resources/safe_synth_retry.py`

Implement the retry wrapper for Safe Synthesizer.

```python
"""Retry wrapper for Safe Synthesizer API calls.

Provides exponential backoff with jitter for transient failures during
synthetic data generation. Safe Synthesizer jobs can take 10-30+ minutes,
so retry delays are longer than typical HTTP retries.

Usage:
    from brev_pipelines.resources.safe_synth_retry import (
        retry_safe_synth_call,
        SafeSynthRetryConfig,
    )

    result = retry_safe_synth_call(
        lambda: safe_synth.synthesize(data, run_id, config),
        run_id=run_id,
        config=SafeSynthRetryConfig(max_retries=3),
        logger=context.log,
    )
"""

from __future__ import annotations

import random
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, TypeVar

if TYPE_CHECKING:
    from dagster import DagsterLogManager

T = TypeVar("T")


# =============================================================================
# Exception Types
# =============================================================================


class SafeSynthError(Exception):
    """Base exception for Safe Synthesizer errors."""

    pass


class SafeSynthTimeoutError(SafeSynthError):
    """Raised when Safe Synthesizer job times out."""

    pass


class SafeSynthServerError(SafeSynthError):
    """Raised when Safe Synthesizer returns server error."""

    def __init__(self, status_code: int, message: str) -> None:
        self.status_code = status_code
        super().__init__(f"Safe Synthesizer error {status_code}: {message}")


class SafeSynthJobFailedError(SafeSynthError):
    """Raised when Safe Synthesizer job fails."""

    def __init__(self, job_id: str, reason: str) -> None:
        self.job_id = job_id
        self.reason = reason
        super().__init__(f"Safe Synthesizer job {job_id} failed: {reason}")


# Retryable errors - server issues that may be transient
RETRYABLE_ERRORS: tuple[type[Exception], ...] = (
    SafeSynthTimeoutError,
    SafeSynthServerError,
    ConnectionError,
    TimeoutError,
)


# =============================================================================
# Retry Configuration
# =============================================================================


@dataclass
class SafeSynthRetryConfig:
    """Configuration for Safe Synthesizer retry behavior.

    Safe Synthesizer jobs take longer than typical API calls (10-30+ minutes),
    so delays are longer to allow the service to recover.

    Attributes:
        max_retries: Maximum number of retry attempts.
        initial_delay: Initial delay in seconds before first retry.
        max_delay: Maximum delay between retries.
        exponential_base: Base for exponential backoff calculation.
        jitter_factor: Random jitter factor (0.2 = ±20%).
    """

    max_retries: int = 3
    initial_delay: float = 10.0  # Longer initial delay for heavy jobs
    max_delay: float = 120.0  # Max 2 minutes between retries
    exponential_base: float = 2.0
    jitter_factor: float = 0.2


# =============================================================================
# Retry Logic
# =============================================================================


def calculate_backoff_delay(
    attempt: int,
    config: SafeSynthRetryConfig,
) -> float:
    """Calculate delay before next retry attempt.

    Args:
        attempt: Current attempt number (1-indexed).
        config: Retry configuration.

    Returns:
        Delay in seconds with jitter applied.
    """
    # Exponential backoff: initial_delay * (base ^ (attempt - 1))
    delay = config.initial_delay * (config.exponential_base ** (attempt - 1))

    # Cap at max delay
    delay = min(delay, config.max_delay)

    # Apply jitter (±jitter_factor)
    if config.jitter_factor > 0:
        jitter = delay * config.jitter_factor
        delay = delay + random.uniform(-jitter, jitter)

    return max(0, delay)


def retry_safe_synth_call(
    fn: Callable[[], T],
    run_id: str,
    config: SafeSynthRetryConfig | None = None,
    logger: DagsterLogManager | None = None,
) -> T:
    """Execute Safe Synthesizer call with retry logic.

    Retries on transient server errors with exponential backoff.
    Does NOT retry on validation errors or other client-side issues.

    Args:
        fn: Callable that performs the Safe Synthesizer operation.
        run_id: Run ID for logging context.
        config: Retry configuration. Uses defaults if not provided.
        logger: Optional Dagster logger for status updates.

    Returns:
        Result from successful function call.

    Raises:
        SafeSynthError: If all retries exhausted.
        ValueError: If input validation fails (no retry).
        Other: Non-retryable exceptions propagate immediately.
    """
    if config is None:
        config = SafeSynthRetryConfig()

    last_error: Exception | None = None

    for attempt in range(1, config.max_retries + 1):
        try:
            return fn()

        except RETRYABLE_ERRORS as e:
            last_error = e

            if attempt < config.max_retries:
                delay = calculate_backoff_delay(attempt, config)

                if logger:
                    logger.warning(
                        f"Safe Synth attempt {attempt}/{config.max_retries} failed: {e}. "
                        f"Retrying in {delay:.1f}s..."
                    )

                time.sleep(delay)
            else:
                if logger:
                    logger.error(
                        f"Safe Synth failed after {config.max_retries} attempts. "
                        f"Last error: {e}"
                    )

        except (ValueError, TypeError, KeyError) as e:
            # Client-side errors - don't retry
            if logger:
                logger.error(f"Safe Synth validation error (not retrying): {e}")
            raise

    # All retries exhausted
    if last_error:
        raise last_error
    raise SafeSynthError(f"Safe Synth failed after {config.max_retries} attempts")


# =============================================================================
# Exports
# =============================================================================

__all__ = [
    "SafeSynthError",
    "SafeSynthTimeoutError",
    "SafeSynthServerError",
    "SafeSynthJobFailedError",
    "SafeSynthRetryConfig",
    "RETRYABLE_ERRORS",
    "calculate_backoff_delay",
    "retry_safe_synth_call",
]
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/resources/test_safe_synth_retry.py -v
# Expected: PASS
```

---

### Step 2.3: Create Input Validation Tests (TDD - RED)

**Action**: Create

**File(s)**: `dagster/tests/unit/assets/test_synthesis_input_validation.py`

Write tests for input validation in enriched_data_for_synthesis.

```python
"""Tests for synthesis pipeline input validation."""
import pytest
import polars as pl
from unittest.mock import Mock

from brev_pipelines.assets.synthetic_speeches import enriched_data_for_synthesis
from brev_pipelines.config import PipelineConfig


class TestEnrichedDataInputValidation:
    """Test input validation for enriched_data_for_synthesis."""

    @pytest.fixture
    def mock_context(self) -> Mock:
        """Create mock Dagster context."""
        context = Mock()
        context.log = Mock()
        return context

    @pytest.fixture
    def mock_lakefs(self) -> Mock:
        """Create mock LakeFS resource."""
        return Mock()

    def test_warns_on_failed_llm_records(
        self, mock_context: Mock, mock_lakefs: Mock
    ) -> None:
        """Should log warning when input contains failed LLM records."""
        # Create DataFrame with dead letter columns including failures
        df_with_failures = pl.DataFrame({
            "reference": ["BIS_001", "BIS_002", "BIS_003"],
            "summary": ["summary1", "summary2", "summary3"],
            "monetary_stance": [3, 3, 3],
            "trade_stance": [3, 3, 3],
            "economic_outlook": [3, 3, 3],
            "_llm_status_class": ["success", "failed", "success"],
            "_llm_status_summary": ["success", "success", "failed"],
        })

        # Mock LakeFS to return this DataFrame
        import io
        buffer = io.BytesIO()
        df_with_failures.write_parquet(buffer)
        mock_lakefs.get_client.return_value.objects_api.get_object.return_value = (
            buffer.getvalue()
        )

        # Call asset
        result = enriched_data_for_synthesis(
            mock_context, PipelineConfig(), mock_lakefs
        )

        # Should have logged warning about failed records
        mock_context.log.warning.assert_called()
        warning_calls = [str(c) for c in mock_context.log.warning.call_args_list]
        assert any("failed" in call.lower() for call in warning_calls)

    def test_reports_failure_statistics(
        self, mock_context: Mock, mock_lakefs: Mock
    ) -> None:
        """Should log failure statistics when dead letter columns present."""
        df_with_failures = pl.DataFrame({
            "reference": ["BIS_001", "BIS_002", "BIS_003", "BIS_004"],
            "summary": ["s1", "s2", "s3", "s4"],
            "monetary_stance": [3, 3, 3, 3],
            "trade_stance": [3, 3, 3, 3],
            "economic_outlook": [3, 3, 3, 3],
            "_llm_status_class": ["success", "failed", "success", "failed"],
            "_llm_fallback_class": [False, True, False, True],
        })

        import io
        buffer = io.BytesIO()
        df_with_failures.write_parquet(buffer)
        mock_lakefs.get_client.return_value.objects_api.get_object.return_value = (
            buffer.getvalue()
        )

        result = enriched_data_for_synthesis(
            mock_context, PipelineConfig(), mock_lakefs
        )

        # Should log statistics about failures
        info_calls = " ".join(str(c) for c in mock_context.log.info.call_args_list)
        assert "50" in info_calls or "2" in info_calls  # 50% or 2 failed

    def test_accepts_clean_data_without_warning(
        self, mock_context: Mock, mock_lakefs: Mock
    ) -> None:
        """Should not warn when all records successful."""
        df_clean = pl.DataFrame({
            "reference": ["BIS_001", "BIS_002"],
            "summary": ["s1", "s2"],
            "monetary_stance": [3, 4],
            "trade_stance": [3, 4],
            "economic_outlook": [3, 4],
            "_llm_status_class": ["success", "success"],
            "_llm_status_summary": ["success", "success"],
        })

        import io
        buffer = io.BytesIO()
        df_clean.write_parquet(buffer)
        mock_lakefs.get_client.return_value.objects_api.get_object.return_value = (
            buffer.getvalue()
        )

        result = enriched_data_for_synthesis(
            mock_context, PipelineConfig(), mock_lakefs
        )

        # Should NOT have logged warning
        if mock_context.log.warning.called:
            warning_calls = [str(c) for c in mock_context.log.warning.call_args_list]
            assert not any("failed" in call.lower() for call in warning_calls)

    def test_works_without_dead_letter_columns(
        self, mock_context: Mock, mock_lakefs: Mock
    ) -> None:
        """Should work with legacy data missing dead letter columns."""
        df_legacy = pl.DataFrame({
            "reference": ["BIS_001", "BIS_002"],
            "summary": ["s1", "s2"],
            "monetary_stance": [3, 4],
            "trade_stance": [3, 4],
            "economic_outlook": [3, 4],
            # No _llm_* columns
        })

        import io
        buffer = io.BytesIO()
        df_legacy.write_parquet(buffer)
        mock_lakefs.get_client.return_value.objects_api.get_object.return_value = (
            buffer.getvalue()
        )

        # Should not raise
        result = enriched_data_for_synthesis(
            mock_context, PipelineConfig(), mock_lakefs
        )

        assert len(result) == 2
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_synthesis_input_validation.py -v
# Expected: FAIL (validation not implemented yet)
```

---

### Step 2.4: Implement Input Validation (TDD - GREEN)

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/synthetic_speeches.py`

Add dead letter column validation to `enriched_data_for_synthesis`.

```python
@dg.asset(
    description="Load enriched speeches data product from LakeFS for synthesis",
    group_name="synthetic_speeches",
    metadata={
        "layer": "input",
        "source": "lakefs",
    },
)
def enriched_data_for_synthesis(
    context: dg.AssetExecutionContext,
    config: PipelineConfig,
    lakefs: LakeFSResource,
) -> pl.DataFrame:
    """Load enriched speeches data product from LakeFS.

    This DECOUPLES the synthetic pipeline from the ETL pipeline,
    allowing them to run independently. The ETL pipeline must complete
    first and store data in LakeFS before running synthesis.

    Validates input data quality by checking dead letter columns if present.
    Logs warnings when failed records are detected in the input.

    Args:
        context: Dagster execution context for logging.
        config: Pipeline configuration (is_trial for path selection).
        lakefs: LakeFS resource for data versioning.

    Returns:
        DataFrame with enriched speeches including summaries.
    """
    lakefs_client = lakefs.get_client()

    # Determine path based on trial mode
    if config.is_trial:
        path = "central-bank-speeches/trial/speeches.parquet"
        context.log.info("TRIAL RUN: Loading from trial-specific LakeFS path")
    else:
        path = "central-bank-speeches/speeches.parquet"

    context.log.info(f"Loading enriched speeches from lakefs://data/main/{path}")

    # Download from LakeFS
    response = lakefs_client.objects_api.get_object(
        repository="data",
        ref="main",
        path=path,
    )

    # Load as DataFrame (response is bytes directly)
    df = pl.read_parquet(io.BytesIO(response))
    context.log.info(f"Loaded {len(df)} enriched speeches from LakeFS")

    # Verify required columns exist
    required_columns = [
        "reference",
        "summary",
        "monetary_stance",
        "trade_stance",
        "economic_outlook",
    ]
    missing = [c for c in required_columns if c not in df.columns]
    if missing:
        raise ValueError(
            f"Missing required columns in LakeFS data: {missing}. "
            "Run the ETL pipeline first to generate summaries and classifications."
        )

    # Validate dead letter columns if present
    _validate_input_data_quality(df, context)

    context.log.info(f"Loaded columns: {df.columns}")

    return df


def _validate_input_data_quality(
    df: pl.DataFrame,
    context: dg.AssetExecutionContext,
) -> None:
    """Validate input data quality by checking dead letter columns.

    Logs warnings when failed records are detected. Does NOT filter
    records - the synthesis will process all records including those
    with fallback values.

    Args:
        df: Input DataFrame to validate.
        context: Dagster context for logging.
    """
    total_records = len(df)

    # Check classification dead letter columns
    class_status_col = "_llm_status_class"
    summary_status_col = "_llm_status_summary"

    failed_classification = 0
    failed_summary = 0
    total_failed = 0

    if class_status_col in df.columns:
        failed_classification = df.filter(pl.col(class_status_col) == "failed").height
        if failed_classification > 0:
            context.log.warning(
                f"Input data contains {failed_classification} records with failed "
                f"classification ({100 * failed_classification / total_records:.1f}%). "
                "These records use fallback values."
            )

    if summary_status_col in df.columns:
        failed_summary = df.filter(pl.col(summary_status_col) == "failed").height
        if failed_summary > 0:
            context.log.warning(
                f"Input data contains {failed_summary} records with failed "
                f"summaries ({100 * failed_summary / total_records:.1f}%). "
                "These records use fallback values."
            )

    # Calculate total unique failed records
    if class_status_col in df.columns or summary_status_col in df.columns:
        # Build filter for any failure
        failure_conditions = []
        if class_status_col in df.columns:
            failure_conditions.append(pl.col(class_status_col) == "failed")
        if summary_status_col in df.columns:
            failure_conditions.append(pl.col(summary_status_col) == "failed")

        if failure_conditions:
            combined_filter = failure_conditions[0]
            for cond in failure_conditions[1:]:
                combined_filter = combined_filter | cond

            total_failed = df.filter(combined_filter).height

            if total_failed > 0:
                failure_rate = 100 * total_failed / total_records
                context.log.info(
                    f"Input data quality: {total_failed}/{total_records} records "
                    f"({failure_rate:.1f}%) have at least one LLM failure"
                )

                # Warn if failure rate is high
                if failure_rate > 10:
                    context.log.warning(
                        f"High failure rate ({failure_rate:.1f}%) in input data. "
                        "Consider reprocessing failed records before synthesis."
                    )
            else:
                context.log.info(
                    f"Input data quality: All {total_records} records have successful LLM results"
                )
    else:
        context.log.info(
            "Input data does not contain dead letter columns (legacy data or pre-retry pattern)"
        )
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_synthesis_input_validation.py -v
# Expected: PASS
```

---

### Step 2.5: Integrate Retry into Synthetic Summaries Asset

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/synthetic_speeches.py`

Update `synthetic_summaries` to use retry wrapper.

```python
# Add import at top
from brev_pipelines.resources.safe_synth_retry import (
    SafeSynthRetryConfig,
    retry_safe_synth_call,
)

@dg.asset(
    description="Synthetic metadata + summaries generated by NVIDIA Safe Synthesizer",
    group_name="synthetic_speeches",
    # ... existing metadata ...
)
def synthetic_summaries(
    context: dg.AssetExecutionContext,
    enriched_data_for_synthesis: pl.DataFrame,
    safe_synth: SafeSynthesizerResource,
) -> tuple[pl.DataFrame, dict[str, Any]]:
    """Generate synthetic speech metadata + summaries using Safe Synthesizer.

    Uses retry wrapper for resilience against transient failures.
    # ... existing docstring ...
    """
    df = enriched_data_for_synthesis
    run_id = context.run_id or datetime.now(UTC).strftime("%Y%m%d%H%M%S")

    # ... existing column selection and config building code ...

    # Single synthesis call with retry wrapper
    context.log.info("Starting Safe Synthesizer with retry support...")

    def do_synthesis() -> tuple[list[dict[str, Any]], dict[str, Any]]:
        return safe_synth.synthesize(
            input_data=data_for_synthesis,
            run_id=run_id,
            config=synth_config,
        )

    synthetic_data, evaluation = retry_safe_synth_call(
        do_synthesis,
        run_id=run_id,
        config=SafeSynthRetryConfig(
            max_retries=3,
            initial_delay=30.0,  # Safe Synth jobs are slow to recover
            max_delay=300.0,  # Max 5 minutes between retries
        ),
        logger=context.log,
    )

    # ... rest of existing code ...
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_synthetic*.py -v
```

---

### Step 2.6: Add Integration Test for Retry Behavior

**Action**: Create

**File(s)**: `dagster/tests/unit/assets/test_synthetic_retry_integration.py`

Test retry integration in synthetic_summaries.

```python
"""Integration tests for synthesis retry behavior."""
import pytest
from unittest.mock import Mock, patch, call
import polars as pl

from brev_pipelines.assets.synthetic_speeches import synthetic_summaries
from brev_pipelines.resources.safe_synth_retry import SafeSynthServerError


class TestSyntheticSummariesRetry:
    """Test retry behavior in synthetic_summaries asset."""

    @pytest.fixture
    def mock_context(self) -> Mock:
        """Create mock Dagster context."""
        context = Mock()
        context.run_id = "test-run-123"
        context.log = Mock()
        return context

    @pytest.fixture
    def sample_input_df(self) -> pl.DataFrame:
        """Create sample input DataFrame."""
        return pl.DataFrame({
            "reference": ["BIS_001"],
            "date": ["2024-01-15"],
            "central_bank": ["Test Bank"],
            "speaker": ["Test Speaker"],
            "title": ["Test Speech"],
            "summary": ["This is a test summary."],
            "monetary_stance": [3],
            "trade_stance": [3],
            "economic_outlook": [3],
            "tariff_mention": [0],
            "is_governor": [True],
        })

    def test_retries_on_safe_synth_failure(
        self,
        mock_context: Mock,
        sample_input_df: pl.DataFrame,
    ) -> None:
        """Should retry when Safe Synth fails transiently."""
        mock_safe_synth = Mock()

        # Fail twice, succeed on third
        mock_safe_synth.synthesize.side_effect = [
            SafeSynthServerError(503, "Temporarily unavailable"),
            SafeSynthServerError(503, "Still unavailable"),
            (
                [{"reference": "SYNTH-000001", "summary": "Synthetic summary"}],
                {"mia_score": 0.95, "privacy_passed": True},
            ),
        ]

        with patch("time.sleep"):  # Don't sleep in tests
            result_df, evaluation = synthetic_summaries(
                mock_context,
                sample_input_df,
                mock_safe_synth,
            )

        assert mock_safe_synth.synthesize.call_count == 3
        assert mock_context.log.warning.called  # Should log retries

    def test_succeeds_on_first_try(
        self,
        mock_context: Mock,
        sample_input_df: pl.DataFrame,
    ) -> None:
        """Should return immediately on success."""
        mock_safe_synth = Mock()
        mock_safe_synth.synthesize.return_value = (
            [{"reference": "SYNTH-000001", "summary": "Synthetic"}],
            {"mia_score": 0.95},
        )

        result_df, evaluation = synthetic_summaries(
            mock_context,
            sample_input_df,
            mock_safe_synth,
        )

        assert mock_safe_synth.synthesize.call_count == 1
        assert len(result_df) == 1
```

**Validation**:
```bash
cd dagster && uv run pytest tests/unit/assets/test_synthetic_retry_integration.py -v
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/src/brev_pipelines/resources/safe_synth_retry.py` | CREATE | Retry wrapper module for Safe Synth |
| `dagster/src/brev_pipelines/assets/synthetic_speeches.py` | MODIFY | Add input validation, retry wrapper |
| `dagster/tests/unit/resources/test_safe_synth_retry.py` | CREATE | Tests for retry wrapper |
| `dagster/tests/unit/assets/test_synthesis_input_validation.py` | CREATE | Tests for input validation |
| `dagster/tests/unit/assets/test_synthetic_retry_integration.py` | CREATE | Integration tests |

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
# Ensure existing tests pass
cd dagster && uv run pytest tests/ -v --tb=short
```

### Validation Commands

```bash
# Run all new tests
cd dagster && uv run pytest tests/unit/resources/test_safe_synth_retry.py tests/unit/assets/test_synthesis*.py -v

# Type checking
cd dagster && uv run mypy src/brev_pipelines/resources/safe_synth_retry.py --strict
cd dagster && uv run mypy src/brev_pipelines/assets/synthetic_speeches.py --strict

# Linting
cd dagster && uv run ruff check src/brev_pipelines/resources/safe_synth_retry.py
cd dagster && uv run ruff check src/brev_pipelines/assets/synthetic_speeches.py

# Full test suite
cd dagster && uv run pytest tests/ -v
```

### Expected Outcomes

- Safe Synthesizer calls have retry protection
- Input data quality is validated and logged
- No regressions in existing tests
- Clear warning messages when input data has failures

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Safe Synth returns unexpected error format | Test with mock failures | Catch broader exception types |
| Input validation slows down pipeline | Profile execution time | Make validation optional via config |
| Dead letter columns have different names | Tests fail | Support multiple column naming conventions |

### Rollback Plan

If this phase fails:
1. Remove safe_synth_retry.py
2. Revert synthetic_speeches.py changes
3. Remove new test files

---

## Completion Criteria

- [ ] `SafeSynthRetryConfig` and exception types defined
- [ ] `retry_safe_synth_call` function implemented with exponential backoff
- [ ] `enriched_data_for_synthesis` validates dead letter columns
- [ ] Warnings logged when input contains failed records
- [ ] `synthetic_summaries` uses retry wrapper
- [ ] All tests pass (new and existing)
- [ ] No type errors (mypy)
- [ ] No lint errors (ruff)
