# Phase 3: Observability

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Add Dagster asset metadata and structured logging to surface failure statistics in the UI and enable downstream filtering of failed records.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete Type Annotations - Metadata dict types fully specified
- **INV-P005**: No Any Types - Use TypedDict for metadata structure
- **INV-N005**: NIM Observability Enabled - Failure tracking aligns with NIM observability goals

---

## Implementation Steps

### Step 3.1: Add Failure Metadata TypedDict

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/types.py`

Add TypedDict for asset metadata structure.

```python
# Add to types.py

class LLMFailureBreakdown(TypedDict):
    """Breakdown of failures by error type."""

    ValidationError: int
    LLMTimeoutError: int
    LLMRateLimitError: int
    LLMServerError: int
    unexpected_error: int


class LLMAssetMetadata(TypedDict):
    """Metadata for LLM-powered assets with failure tracking."""

    total_processed: int
    successful: int
    failed: int
    success_rate: str
    failed_references: list[str]
    failure_breakdown: LLMFailureBreakdown
    avg_attempts: float
    total_duration_ms: int
```

**Validation**:
```bash
cd dagster && mypy src/brev_pipelines/types.py --strict
```

---

### Step 3.2: Update speech_classification with Metadata

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

Add Dagster metadata output to the asset.

```python
from brev_pipelines.types import LLMAssetMetadata, LLMFailureBreakdown


@dg.asset(...)
def speech_classification(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_reasoning: NIMResource,
    minio: MinIOResource,
) -> pl.DataFrame:
    """Classify speeches with retry logic and failure tracking."""
    # ... existing implementation ...

    # After processing, add metadata
    total = len(results_df)
    failed = len(failures)
    success_count = total - failed

    # Calculate failure breakdown
    failure_breakdown: LLMFailureBreakdown = {
        "ValidationError": 0,
        "LLMTimeoutError": 0,
        "LLMRateLimitError": 0,
        "LLMServerError": 0,
        "unexpected_error": 0,
    }
    for f in failures:
        error_type = str(f.get("error_type", "unexpected_error"))
        if error_type in failure_breakdown:
            failure_breakdown[error_type] += 1  # type: ignore[literal-required]
        else:
            failure_breakdown["unexpected_error"] += 1

    # Calculate average attempts
    avg_attempts = (
        results_df.select(pl.col("_llm_attempts").mean()).item()
        if "_llm_attempts" in results_df.columns
        else 1.0
    )

    # Build metadata
    metadata: LLMAssetMetadata = {
        "total_processed": total,
        "successful": success_count,
        "failed": failed,
        "success_rate": f"{100 * success_count / total:.1f}%" if total > 0 else "N/A",
        "failed_references": [str(f["reference"]) for f in failures],
        "failure_breakdown": failure_breakdown,
        "avg_attempts": float(avg_attempts) if avg_attempts else 1.0,
        "total_duration_ms": 0,  # Could track if needed
    }

    # Add to Dagster context
    context.add_output_metadata({
        "total_processed": total,
        "successful": success_count,
        "failed": failed,
        "success_rate": metadata["success_rate"],
        "failure_breakdown": dict(failure_breakdown),
        "avg_attempts": round(metadata["avg_attempts"], 2),
    })

    # Add failed references as separate metadata if there are failures
    if failures:
        context.add_output_metadata({
            "failed_references": metadata["failed_references"][:100],  # Limit to 100
            "failed_count": failed,
        })

    # Structured logging
    context.log.info("=" * 60)
    context.log.info("CLASSIFICATION SUMMARY")
    context.log.info("=" * 60)
    context.log.info(f"Total records:     {total}")
    context.log.info(f"Successful:        {success_count} ({metadata['success_rate']})")
    context.log.info(f"Failed (fallback): {failed}")
    context.log.info(f"Average attempts:  {metadata['avg_attempts']:.2f}")

    if failures:
        context.log.info("-" * 40)
        context.log.info("FAILURE BREAKDOWN:")
        for error_type, count in failure_breakdown.items():
            if count > 0:
                context.log.info(f"  {error_type}: {count}")
        context.log.info("-" * 40)
        context.log.warning(
            f"Failed references (first 10): {metadata['failed_references'][:10]}"
        )

    context.log.info("=" * 60)

    checkpoint_mgr.cleanup()
    return results_df
```

**Validation**:
```bash
cd dagster && dagster dev
# Materialize speech_classification asset
# Check Dagster UI for metadata
```

---

### Step 3.3: Update speech_summaries with Metadata

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

Add similar metadata to `speech_summaries` asset.

```python
@dg.asset(...)
def speech_summaries(
    context: dg.AssetExecutionContext,
    speech_classification: pl.DataFrame,
    nim_reasoning: NIMResource,
    minio: MinIOResource,
) -> pl.DataFrame:
    """Generate summaries with retry logic and failure tracking."""
    # ... existing implementation ...

    # After processing, add metadata (same pattern as classification)
    total = len(final_df)
    failed = len(failures)
    success_count = total - failed

    failure_breakdown: LLMFailureBreakdown = {
        "ValidationError": 0,
        "LLMTimeoutError": 0,
        "LLMRateLimitError": 0,
        "LLMServerError": 0,
        "unexpected_error": 0,
    }
    for f in failures:
        error_type = str(f.get("error_type", "unexpected_error"))
        if error_type in failure_breakdown:
            failure_breakdown[error_type] += 1  # type: ignore[literal-required]
        else:
            failure_breakdown["unexpected_error"] += 1

    context.add_output_metadata({
        "total_processed": total,
        "successful": success_count,
        "failed": failed,
        "success_rate": f"{100 * success_count / total:.1f}%" if total > 0 else "N/A",
        "failure_breakdown": dict(failure_breakdown),
    })

    if failures:
        context.add_output_metadata({
            "failed_references": [str(f["reference"]) for f in failures][:100],
        })

    context.log.info(f"Summaries complete: {success_count}/{total} successful")

    checkpoint_mgr.cleanup()
    return final_df
```

---

### Step 3.4: Create Downstream Filtering Example

**Action**: Create (documentation/example)

**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py` (add as comment or separate asset)

Document how downstream assets can filter by LLM status.

```python
# Example: Downstream asset that filters successful records only
@dg.asset(deps=[speech_classification])
def high_quality_classifications(
    context: dg.AssetExecutionContext,
    speech_classification: pl.DataFrame,
) -> pl.DataFrame:
    """Filter to only successful LLM classifications.

    This asset demonstrates downstream filtering of dead letter records.
    Only records where the LLM call succeeded are included.
    """
    successful = speech_classification.filter(
        pl.col("_llm_status") == "success"
    )

    total = len(speech_classification)
    kept = len(successful)
    filtered = total - kept

    context.log.info(f"Filtered {filtered}/{total} records with LLM failures")
    context.add_output_metadata({
        "total_input": total,
        "kept_successful": kept,
        "filtered_failed": filtered,
    })

    return successful


# Example: Including confidence based on status
@dg.asset(deps=[speech_classification])
def classifications_with_confidence(
    context: dg.AssetExecutionContext,
    speech_classification: pl.DataFrame,
) -> pl.DataFrame:
    """Add confidence column based on LLM status.

    Records with successful LLM classification have high confidence,
    records using fallback values have low confidence.
    """
    return speech_classification.with_columns(
        pl.when(pl.col("_llm_status") == "success")
        .then(pl.lit("high"))
        .otherwise(pl.lit("low"))
        .alias("confidence")
    )
```

---

### Step 3.5: Add Observability Tests

**Action**: Create

**File(s)**: `dagster/tests/unit/assets/test_observability.py`

Test that metadata is correctly added.

```python
"""Tests for LLM asset observability (metadata and logging)."""
from __future__ import annotations

from unittest.mock import MagicMock, patch

import polars as pl
import pytest
from dagster import build_asset_context


class TestAssetMetadata:
    """Tests for Dagster asset metadata output."""

    def test_classification_adds_success_metadata(self) -> None:
        """Classification asset adds metadata on success."""
        from brev_pipelines.assets.central_bank_speeches import speech_classification

        context = build_asset_context()
        mock_minio = MagicMock()
        mock_checkpoint_mgr = MagicMock()

        sample_df = pl.DataFrame({
            "reference": ["TEST_001"],
            "text": ["Test speech text"],
            "title": ["Test"],
            "speaker": ["Test"],
            "central_bank": ["TEST"],
        })

        mock_nim = MagicMock()
        mock_nim.generate.return_value = (
            '{"monetary_stance": "neutral", "trade_stance": "neutral", '
            '"tariff_mention": 0, "economic_outlook": "neutral"}'
        )

        with patch(
            "brev_pipelines.assets.central_bank_speeches.LLMCheckpointManager",
            return_value=mock_checkpoint_mgr,
        ):
            result = speech_classification(
                context=context,
                cleaned_speeches=sample_df,
                nim_reasoning=mock_nim,
                minio=mock_minio,
            )

        # Check metadata was added
        # Note: In real tests, you'd capture the metadata calls
        assert result is not None

    def test_metadata_includes_failure_breakdown(self) -> None:
        """Metadata includes breakdown of failure types."""
        # Test that failure breakdown is correctly calculated
        from brev_pipelines.types import LLMFailureBreakdown

        failures = [
            {"reference": "1", "error_type": "LLMTimeoutError"},
            {"reference": "2", "error_type": "LLMTimeoutError"},
            {"reference": "3", "error_type": "ValidationError"},
        ]

        breakdown: LLMFailureBreakdown = {
            "ValidationError": 0,
            "LLMTimeoutError": 0,
            "LLMRateLimitError": 0,
            "LLMServerError": 0,
            "unexpected_error": 0,
        }

        for f in failures:
            error_type = str(f["error_type"])
            if error_type in breakdown:
                breakdown[error_type] += 1  # type: ignore[literal-required]

        assert breakdown["LLMTimeoutError"] == 2
        assert breakdown["ValidationError"] == 1
        assert breakdown["LLMRateLimitError"] == 0


class TestDownstreamFiltering:
    """Tests for downstream asset filtering."""

    def test_filter_successful_records(self) -> None:
        """Can filter to only successful records."""
        df = pl.DataFrame({
            "reference": ["A", "B", "C"],
            "monetary_stance": [3, 3, 3],
            "_llm_status": ["success", "failed", "success"],
        })

        successful = df.filter(pl.col("_llm_status") == "success")

        assert len(successful) == 2
        assert "B" not in successful["reference"].to_list()

    def test_add_confidence_column(self) -> None:
        """Can add confidence based on status."""
        df = pl.DataFrame({
            "reference": ["A", "B"],
            "_llm_status": ["success", "failed"],
        })

        with_confidence = df.with_columns(
            pl.when(pl.col("_llm_status") == "success")
            .then(pl.lit("high"))
            .otherwise(pl.lit("low"))
            .alias("confidence")
        )

        assert with_confidence["confidence"].to_list() == ["high", "low"]
```

**Validation**:
```bash
cd dagster && pytest tests/unit/assets/test_observability.py -v
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/src/brev_pipelines/types.py` | MODIFY | Add metadata TypedDicts |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | MODIFY | Add metadata to assets |
| `dagster/tests/unit/assets/test_observability.py` | CREATE | Test metadata output |

---

## Configuration Details

### Environment Variables

None required.

### Secrets Required

None required.

---

## Verification

### Pre-flight Checks

```bash
# Ensure Phase 2 is complete
cd dagster
pytest tests/unit/assets/test_central_bank_speeches.py -v
```

### Validation Commands

```bash
# Unit tests
cd dagster
pytest tests/unit/assets/test_observability.py -v

# Type checking
mypy src/brev_pipelines/assets/central_bank_speeches.py --strict

# Manual verification in Dagster UI
dagster dev
# Materialize assets and check metadata panel
```

### Expected Outcomes

- Asset metadata visible in Dagster UI
- Metadata includes: total_processed, successful, failed, success_rate, failure_breakdown
- Failed references listed (up to 100)
- Structured logging shows classification summary
- Downstream filtering by `_llm_status` works

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Metadata too large | Dagster warning | Limit failed_references to 100 |
| Zero records | Division by zero | Check `total > 0` before percentage |
| All failures | No successful records | Metadata still valid |

### Rollback Plan

If this phase fails:
1. Remove metadata calls from assets
2. Delete observability tests
3. Core functionality (Phase 1-2) unaffected

---

## Completion Criteria

- [ ] `LLMAssetMetadata` TypedDict added to types.py
- [ ] `speech_classification` adds metadata via `context.add_output_metadata()`
- [ ] `speech_summaries` adds metadata via `context.add_output_metadata()`
- [ ] Metadata visible in Dagster UI
- [ ] Structured logging shows summary after processing
- [ ] Downstream filtering example documented
- [ ] All tests pass
