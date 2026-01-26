# Phase 2: Asset Updates

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Update `speech_classification` and `speech_summaries` assets to use the retry wrapper, adding dead letter columns to output DataFrames for failure tracking.

---

## Invariants Enforced in This Phase

- **INV-P001**: Assets Over Ops - Continue using `@asset` pattern
- **INV-P002**: I/O Managers for Storage - Continue using existing I/O managers
- **INV-P004**: Complete Type Annotations - All modified functions fully typed
- **INV-P005**: No Any Types - Use TypedDict for row processing
- **INV-P010**: Test-Driven Development - Write/update tests for asset retry behavior

---

## Implementation Steps

### Step 2.1: Write Asset Tests (TDD)

**Action**: Create/Modify

**File(s)**: `dagster/tests/unit/assets/test_central_bank_speeches.py`

Add tests for retry behavior in classification and summary assets.

```python
"""Tests for central bank speeches assets with retry behavior."""
from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import polars as pl
import pytest
from dagster import build_asset_context

if TYPE_CHECKING:
    from dagster import AssetExecutionContext


class TestSpeechClassificationRetry:
    """Tests for speech_classification retry behavior."""

    @pytest.fixture
    def sample_cleaned_speeches(self) -> pl.DataFrame:
        """Sample input DataFrame."""
        return pl.DataFrame({
            "reference": ["BIS_2024_001", "BIS_2024_002", "BIS_2024_003"],
            "date": ["2024-01-15", "2024-01-20", "2024-02-01"],
            "central_bank": ["FED", "ECB", "BOE"],
            "speaker": ["Powell", "Lagarde", "Bailey"],
            "title": ["Rate Decision", "Policy Update", "Inflation Report"],
            "text": ["Federal Reserve text..."] * 3,
        })

    @pytest.fixture
    def mock_nim_resource(self) -> MagicMock:
        """Mock NIM resource."""
        nim = MagicMock()
        nim.generate.return_value = (
            '{"monetary_stance": "neutral", "trade_stance": "neutral", '
            '"tariff_mention": 0, "economic_outlook": "neutral"}'
        )
        return nim

    def test_successful_classification(
        self,
        sample_cleaned_speeches: pl.DataFrame,
        mock_nim_resource: MagicMock,
    ) -> None:
        """All records classified successfully."""
        from brev_pipelines.assets.central_bank_speeches import speech_classification

        context = build_asset_context()
        mock_minio = MagicMock()
        mock_checkpoint_mgr = MagicMock()

        with patch(
            "brev_pipelines.assets.central_bank_speeches.LLMCheckpointManager",
            return_value=mock_checkpoint_mgr,
        ):
            result = speech_classification(
                context=context,
                cleaned_speeches=sample_cleaned_speeches,
                nim_reasoning=mock_nim_resource,
                minio=mock_minio,
            )

        # Verify dead letter columns exist
        assert "_llm_status" in result.columns
        assert "_llm_error" in result.columns
        assert "_llm_attempts" in result.columns
        assert "_llm_fallback_used" in result.columns

        # All should be successful
        assert result.filter(pl.col("_llm_status") == "success").height == 3

    def test_transient_failure_recovery(
        self,
        sample_cleaned_speeches: pl.DataFrame,
    ) -> None:
        """Transient failures recover after retries."""
        from brev_pipelines.assets.central_bank_speeches import speech_classification

        context = build_asset_context()
        mock_minio = MagicMock()
        mock_checkpoint_mgr = MagicMock()

        # First 2 calls fail, third succeeds
        call_count = 0
        def mock_generate(*args, **kwargs) -> str:
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                return "LLM error: timeout"
            return (
                '{"monetary_stance": "neutral", "trade_stance": "neutral", '
                '"tariff_mention": 0, "economic_outlook": "neutral"}'
            )

        mock_nim = MagicMock()
        mock_nim.generate.side_effect = mock_generate

        with patch(
            "brev_pipelines.assets.central_bank_speeches.LLMCheckpointManager",
            return_value=mock_checkpoint_mgr,
        ), patch(
            "brev_pipelines.resources.llm_retry.RetryConfig",
        ) as mock_config:
            mock_config.return_value.max_retries = 5
            mock_config.return_value.base_delay = 0.01

            result = speech_classification(
                context=context,
                cleaned_speeches=sample_cleaned_speeches.head(1),
                nim_reasoning=mock_nim,
                minio=mock_minio,
            )

        # Should succeed after retries
        assert result["_llm_status"][0] == "success"
        assert result["_llm_attempts"][0] > 1

    def test_permanent_failure_uses_fallback(
        self,
        sample_cleaned_speeches: pl.DataFrame,
    ) -> None:
        """Permanent failures use fallback values."""
        from brev_pipelines.assets.central_bank_speeches import speech_classification

        context = build_asset_context()
        mock_minio = MagicMock()
        mock_checkpoint_mgr = MagicMock()

        # Always fail
        mock_nim = MagicMock()
        mock_nim.generate.return_value = "LLM error: service unavailable"

        with patch(
            "brev_pipelines.assets.central_bank_speeches.LLMCheckpointManager",
            return_value=mock_checkpoint_mgr,
        ), patch(
            "brev_pipelines.resources.llm_retry.RetryConfig",
        ) as mock_config:
            mock_config.return_value.max_retries = 2
            mock_config.return_value.base_delay = 0.01

            result = speech_classification(
                context=context,
                cleaned_speeches=sample_cleaned_speeches.head(1),
                nim_reasoning=mock_nim,
                minio=mock_minio,
            )

        # Should fail with fallback
        assert result["_llm_status"][0] == "failed"
        assert result["_llm_fallback_used"][0] is True
        # Fallback values are neutral (3, 3, 0, 3)
        assert result["monetary_stance"][0] == 3
        assert result["trade_stance"][0] == 3
        assert result["tariff_mention"][0] == 0
        assert result["economic_outlook"][0] == 3

    def test_dead_letter_columns_schema(
        self,
        sample_cleaned_speeches: pl.DataFrame,
        mock_nim_resource: MagicMock,
    ) -> None:
        """Output DataFrame has correct dead letter column types."""
        from brev_pipelines.assets.central_bank_speeches import speech_classification

        context = build_asset_context()
        mock_minio = MagicMock()
        mock_checkpoint_mgr = MagicMock()

        with patch(
            "brev_pipelines.assets.central_bank_speeches.LLMCheckpointManager",
            return_value=mock_checkpoint_mgr,
        ):
            result = speech_classification(
                context=context,
                cleaned_speeches=sample_cleaned_speeches,
                nim_reasoning=mock_nim_resource,
                minio=mock_minio,
            )

        # Check column types
        assert result.schema["_llm_status"] == pl.Utf8
        assert result.schema["_llm_error"] == pl.Utf8
        assert result.schema["_llm_attempts"] == pl.Int64
        assert result.schema["_llm_fallback_used"] == pl.Boolean


class TestSpeechSummariesRetry:
    """Tests for speech_summaries retry behavior."""

    @pytest.fixture
    def sample_classification_df(self) -> pl.DataFrame:
        """Sample input with classifications."""
        return pl.DataFrame({
            "reference": ["BIS_2024_001"],
            "date": ["2024-01-15"],
            "central_bank": ["FED"],
            "speaker": ["Powell"],
            "title": ["Rate Decision"],
            "text": ["Federal Reserve text..." * 100],
            "monetary_stance": [3],
            "trade_stance": [3],
            "tariff_mention": [0],
            "economic_outlook": [3],
        })

    def test_successful_summary(
        self,
        sample_classification_df: pl.DataFrame,
    ) -> None:
        """Summary generated successfully."""
        from brev_pipelines.assets.central_bank_speeches import speech_summaries

        context = build_asset_context()
        mock_minio = MagicMock()
        mock_checkpoint_mgr = MagicMock()

        mock_nim = MagicMock()
        mock_nim.generate.return_value = "This is a comprehensive summary of the speech discussing monetary policy and economic outlook. " * 3

        with patch(
            "brev_pipelines.assets.central_bank_speeches.LLMCheckpointManager",
            return_value=mock_checkpoint_mgr,
        ):
            result = speech_summaries(
                context=context,
                speech_classification=sample_classification_df,
                nim_reasoning=mock_nim,
                minio=mock_minio,
            )

        assert "_llm_status" in result.columns
        assert result["_llm_status"][0] == "success"
        assert len(result["summary"][0]) > 50
```

**Validation**:
```bash
cd dagster && pytest tests/unit/assets/test_central_bank_speeches.py -v
```

---

### Step 2.2: Update speech_classification Asset

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

Update the `speech_classification` asset to use the retry wrapper.

**Current implementation** (lines ~462-473):
```python
# Silent fallback - problematic
monetary, trade, tariff, outlook = 3, 3, 0, 3
try:
    json_match = re.search(r"\{[^}]+\}", response)
    if json_match:
        result = json.loads(json_match.group())
        monetary = MONETARY_STANCE_SCALE.get(result.get("monetary_stance", "neutral"), 3)
        # ...
except Exception:
    pass  # Keep defaults - no visibility into failure
```

**Updated implementation**:

```python
from brev_pipelines.resources.llm_retry import (
    LLMCallResult,
    RetryConfig,
    retry_with_backoff,
    validate_classification_response,
)
from brev_pipelines.types import ClassificationResult


@dg.asset(
    deps=[cleaned_speeches],
    io_manager_key="minio_parquet_io_manager",
    kinds={"llm", "polars"},
    compute_kind="nim",
)
def speech_classification(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_reasoning: NIMResource,
    minio: MinIOResource,
) -> pl.DataFrame:
    """Classify speeches with retry logic and failure tracking.

    Output DataFrame includes dead letter columns:
    - _llm_status: "success" or "failed"
    - _llm_error: Error message if failed
    - _llm_attempts: Number of LLM call attempts
    - _llm_fallback_used: Whether fallback values were used
    """
    df = cleaned_speeches

    # Setup checkpoint manager
    checkpoint_mgr = LLMCheckpointManager(
        minio=minio,
        asset_name="speech_classification",
        run_id=context.run_id,
        checkpoint_interval=10,
    )

    # Retry configuration
    retry_config = RetryConfig(
        max_retries=5,
        base_delay=1.0,
        exponential_base=2.0,
    )

    # Track failures for summary
    failures: list[dict[str, str | int]] = []

    def classify_speech(row: dict[str, str | int | float | None]) -> dict[str, str | int | float | bool | None]:
        """Process one speech with retry logic."""
        reference = str(row["reference"])
        text = str(row.get("text", ""))[:8000]
        title = str(row.get("title", ""))
        speaker = str(row.get("speaker", ""))
        central_bank = str(row.get("central_bank", ""))

        prompt = f"""Analyze this central bank speech and classify it.

Speech Title: {title}
Speaker: {speaker}
Central Bank: {central_bank}

Text (truncated):
{text}

Return a JSON object with exactly these fields:
- monetary_stance: one of "very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"
- trade_stance: one of "very_protectionist", "protectionist", "neutral", "globalist", "very_globalist"
- tariff_mention: 0 if no tariff discussion, 1 if tariffs mentioned
- economic_outlook: one of "very_negative", "negative", "neutral", "positive", "very_positive"

Return ONLY the JSON object, no other text.
"""

        def get_fallback() -> ClassificationResult:
            return ClassificationResult(
                monetary_stance=3,  # neutral
                trade_stance=3,
                tariff_mention=0,
                economic_outlook=3,
            )

        # Execute with retry
        result: LLMCallResult[ClassificationResult] = retry_with_backoff(
            fn=lambda: nim_reasoning.generate(prompt, max_tokens=200, temperature=0.1),
            validate_fn=validate_classification_response,
            record_id=reference,
            fallback_fn=get_fallback,
            config=retry_config,
            logger=context.log,
        )

        # Get values (either parsed or fallback)
        values = result.parsed_data if result.status == "success" else result.fallback_values
        assert values is not None  # Either parsed_data or fallback_values will be set

        # Track failure if applicable
        if result.status == "failed":
            failures.append({
                "reference": reference,
                "error_type": result.error_type or "unknown",
                "error_message": result.error_message or "",
                "attempts": result.attempts,
            })

        return {
            "reference": reference,
            "monetary_stance": values["monetary_stance"],
            "trade_stance": values["trade_stance"],
            "tariff_mention": values["tariff_mention"],
            "economic_outlook": values["economic_outlook"],
            "_llm_status": result.status,
            "_llm_error": result.error_message,
            "_llm_attempts": result.attempts,
            "_llm_fallback_used": result.fallback_used,
        }

    # Process with checkpointing
    results_df = process_with_checkpoint(
        df=df,
        id_column="reference",
        process_fn=classify_speech,
        checkpoint_manager=checkpoint_mgr,
        batch_size=10,
        logger=context.log,
    )

    # Log summary (Phase 3 will add metadata)
    total = len(results_df)
    failed = len(failures)
    success_count = total - failed

    context.log.info(f"Classification complete:")
    context.log.info(f"  Total processed: {total}")
    context.log.info(f"  Successful: {success_count} ({100*success_count/total:.1f}%)")
    context.log.info(f"  Failed (using fallback): {failed} ({100*failed/total:.1f}%)")

    if failures:
        context.log.warning(f"  Failed references: {[f['reference'] for f in failures[:10]]}...")

    checkpoint_mgr.cleanup()
    return results_df
```

**Validation**:
```bash
cd dagster && pytest tests/unit/assets/test_central_bank_speeches.py::TestSpeechClassificationRetry -v
```

---

### Step 2.3: Update speech_summaries Asset

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

Update the `speech_summaries` asset similarly.

**Current implementation** (lines ~616-623):
```python
summary = nim_reasoning.generate(prompt, max_tokens=400, temperature=0.2)

# Check for LLM error string
if summary.startswith("LLM error:"):
    summary = f"• Topic: {title[:100]}\n• Speaker: {speaker}\n• Bank: {central_bank}"
```

**Updated implementation**:

```python
from brev_pipelines.resources.llm_retry import (
    retry_with_backoff,
    validate_summary_response,
)


@dg.asset(
    deps=[speech_classification],
    io_manager_key="minio_parquet_io_manager",
    kinds={"llm", "polars"},
    compute_kind="nim",
)
def speech_summaries(
    context: dg.AssetExecutionContext,
    speech_classification: pl.DataFrame,
    nim_reasoning: NIMResource,
    minio: MinIOResource,
) -> pl.DataFrame:
    """Generate summaries with retry logic and failure tracking.

    Output DataFrame includes dead letter columns for summary generation.
    """
    df = speech_classification

    checkpoint_mgr = LLMCheckpointManager(
        minio=minio,
        asset_name="speech_summaries",
        run_id=context.run_id,
        checkpoint_interval=10,
    )

    retry_config = RetryConfig(
        max_retries=5,
        base_delay=1.0,
        exponential_base=2.0,
    )

    failures: list[dict[str, str | int]] = []

    def summarize_speech(row: dict[str, str | int | float | None]) -> dict[str, str | int | float | bool | None]:
        """Generate summary with retry logic."""
        reference = str(row["reference"])
        text = str(row.get("text", ""))[:6000]
        title = str(row.get("title", ""))
        speaker = str(row.get("speaker", ""))
        central_bank = str(row.get("central_bank", ""))

        prompt = f"""Summarize this central bank speech in 3-5 bullet points.

Title: {title}
Speaker: {speaker}
Central Bank: {central_bank}

Text:
{text}

Provide a concise summary covering the main points, policy signals, and economic outlook.
"""

        def get_fallback() -> str:
            return f"• Topic: {title[:100]}\n• Speaker: {speaker}\n• Bank: {central_bank}"

        result = retry_with_backoff(
            fn=lambda: nim_reasoning.generate(prompt, max_tokens=400, temperature=0.2),
            validate_fn=validate_summary_response,
            record_id=reference,
            fallback_fn=get_fallback,
            config=retry_config,
            logger=context.log,
        )

        summary = result.parsed_data if result.status == "success" else result.fallback_values
        assert summary is not None

        if result.status == "failed":
            failures.append({
                "reference": reference,
                "error_type": result.error_type or "unknown",
                "error_message": result.error_message or "",
                "attempts": result.attempts,
            })

        return {
            "reference": reference,
            "summary": summary,
            "_llm_status": result.status,
            "_llm_error": result.error_message,
            "_llm_attempts": result.attempts,
            "_llm_fallback_used": result.fallback_used,
        }

    results_df = process_with_checkpoint(
        df=df,
        id_column="reference",
        process_fn=summarize_speech,
        checkpoint_manager=checkpoint_mgr,
        batch_size=10,
        logger=context.log,
    )

    # Merge summaries with classification data
    final_df = df.join(
        results_df.select([
            "reference", "summary",
            "_llm_status", "_llm_error", "_llm_attempts", "_llm_fallback_used"
        ]),
        on="reference",
        how="left",
    )

    total = len(final_df)
    failed = len(failures)
    context.log.info(f"Summaries complete: {total - failed}/{total} successful")

    checkpoint_mgr.cleanup()
    return final_df
```

**Validation**:
```bash
cd dagster && pytest tests/unit/assets/test_central_bank_speeches.py::TestSpeechSummariesRetry -v
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/tests/unit/assets/test_central_bank_speeches.py` | CREATE/MODIFY | Tests for retry behavior |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | MODIFY | Add retry wrapper to assets |

---

## Configuration Details

### Environment Variables

None changed.

### Secrets Required

None changed.

---

## Verification

### Pre-flight Checks

```bash
# Ensure Phase 1 is complete
cd dagster
python -c "from brev_pipelines.resources.llm_retry import retry_with_backoff; print('OK')"
```

### Validation Commands

```bash
# Unit tests
cd dagster
pytest tests/unit/assets/test_central_bank_speeches.py -v --cov=brev_pipelines.assets.central_bank_speeches

# Type checking
mypy src/brev_pipelines/assets/central_bank_speeches.py --strict

# Linting
ruff check src/brev_pipelines/assets/central_bank_speeches.py
```

### Expected Outcomes

- All tests pass
- `speech_classification` output has 4 dead letter columns
- `speech_summaries` output has 4 dead letter columns
- Transient failures are retried
- Permanent failures use fallback values
- Checkpoint functionality still works

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Checkpoint format changed | Checkpoint load fails | Clear old checkpoints, re-run |
| DataFrame schema mismatch | Polars schema error | Ensure all columns typed correctly |
| Memory issues with failures list | OOM on large datasets | Use streaming or batch summaries |

### Rollback Plan

If this phase fails:
1. Revert changes to `central_bank_speeches.py`
2. Delete new test files
3. Phase 1 code remains intact (reusable)

---

## Completion Criteria

- [ ] All tests in `test_central_bank_speeches.py` pass
- [ ] `speech_classification` uses retry wrapper
- [ ] `speech_summaries` uses retry wrapper
- [ ] Output DataFrames include `_llm_status`, `_llm_error`, `_llm_attempts`, `_llm_fallback_used`
- [ ] Existing checkpoint functionality works
- [ ] Type annotations complete (mypy strict passes)
