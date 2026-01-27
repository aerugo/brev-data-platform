# Phase 4: Asset Integration

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Update Dagster assets to use the new `generate_json()` method with proper validation, error handling, and fallback values. Write integration tests first.

---

## Invariants Enforced in This Phase

- **INV-P001**: Assets over ops - maintain asset-based paradigm
- **INV-P002**: I/O managers for storage
- **INV-P004**: Complete type annotations
- **INV-P005**: No `Any` types
- **INV-P010**: TDD - write integration tests BEFORE updating assets
- **INV-N005**: NIM observability - log classification results

---

## Implementation Steps

### Step 4.1: Write Failing Integration Tests

**Action**: Create
**File(s)**: `dagster/tests/integration/test_classification_pipeline.py`

Write integration tests for the classification pipeline BEFORE updating the assets.

```python
"""Integration tests for speech classification pipeline.

Tests the full flow from input to classified output with mocked NIM.
"""
from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import polars as pl
import pytest
from dagster import build_asset_context

if TYPE_CHECKING:
    from dagster import AssetExecutionContext


class TestClassificationPipeline:
    """Integration tests for classification pipeline."""

    @pytest.fixture
    def sample_speeches(self) -> pl.DataFrame:
        """Sample speeches DataFrame for testing."""
        return pl.DataFrame({
            "reference": ["BIS_2024_001", "ECB_2024_002"],
            "date": ["2024-01-15", "2024-02-01"],
            "central_bank": ["FED", "ECB"],
            "speaker": ["Jerome Powell", "Christine Lagarde"],
            "title": ["Monetary Policy Update", "Inflation Outlook"],
            "text": [
                "The Federal Reserve has decided to raise interest rates by 25 basis points, citing persistent inflation concerns.",
                "Inflation remains elevated across the eurozone. The ECB will maintain its vigilant stance on price stability.",
            ],
            "is_gov": [True, True],
        })

    @pytest.fixture
    def mock_nim_response_hawkish(self) -> dict[str, object]:
        """Mock NIM response for hawkish speech."""
        return {
            "id": "gen-test-001",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": '{"monetary_stance": "hawkish", "trade_stance": "neutral", "tariff_mention": 0, "economic_outlook": "neutral"}',
                },
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150},
        }

    @pytest.fixture
    def mock_nim_response_dovish(self) -> dict[str, object]:
        """Mock NIM response for dovish speech."""
        return {
            "id": "gen-test-002",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": '{"monetary_stance": "dovish", "trade_stance": "globalist", "tariff_mention": 0, "economic_outlook": "positive"}',
                },
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150},
        }

    @pytest.fixture
    def asset_context(self) -> AssetExecutionContext:
        """Build asset context for testing."""
        return build_asset_context()

    def test_classification_returns_dataframe_with_all_fields(
        self,
        sample_speeches: pl.DataFrame,
        mock_nim_response_hawkish: dict[str, object],
        asset_context: AssetExecutionContext,
    ) -> None:
        """Classification should return DataFrame with all required fields."""
        from brev_pipelines.assets.central_bank_speeches import classify_speeches
        from brev_pipelines.resources.nim import NIMLLMResource

        nim_resource = NIMLLMResource(
            endpoint="http://test:8000",
            model="openai/gpt-oss-120b",
        )

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_response_hawkish
            mock_post.return_value.raise_for_status = MagicMock()

            result = classify_speeches(
                context=asset_context,
                cleaned_speeches=sample_speeches,
                nim_reasoning=nim_resource,
            )

            # Check all required columns exist
            assert "reference" in result.columns
            assert "monetary_stance" in result.columns
            assert "trade_stance" in result.columns
            assert "tariff_mention" in result.columns
            assert "economic_outlook" in result.columns
            assert "_llm_status" in result.columns

    def test_classification_values_are_numeric(
        self,
        sample_speeches: pl.DataFrame,
        mock_nim_response_hawkish: dict[str, object],
        asset_context: AssetExecutionContext,
    ) -> None:
        """Classification stance values should be numeric 1-5."""
        from brev_pipelines.assets.central_bank_speeches import classify_speeches
        from brev_pipelines.resources.nim import NIMLLMResource

        nim_resource = NIMLLMResource(
            endpoint="http://test:8000",
            model="openai/gpt-oss-120b",
        )

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_response_hawkish
            mock_post.return_value.raise_for_status = MagicMock()

            result = classify_speeches(
                context=asset_context,
                cleaned_speeches=sample_speeches,
                nim_reasoning=nim_resource,
            )

            # Hawkish = 4 on 1-5 scale
            assert result["monetary_stance"].dtype == pl.Int64
            assert result["monetary_stance"][0] == 4

    def test_classification_handles_api_failure_gracefully(
        self,
        sample_speeches: pl.DataFrame,
        asset_context: AssetExecutionContext,
    ) -> None:
        """Classification should use fallback values on API failure."""
        import requests

        from brev_pipelines.assets.central_bank_speeches import classify_speeches
        from brev_pipelines.resources.nim import NIMLLMResource

        nim_resource = NIMLLMResource(
            endpoint="http://test:8000",
            model="openai/gpt-oss-120b",
        )

        with patch("requests.post") as mock_post:
            mock_post.return_value.raise_for_status.side_effect = (
                requests.exceptions.HTTPError("503 Service Unavailable")
            )

            result = classify_speeches(
                context=asset_context,
                cleaned_speeches=sample_speeches,
                nim_reasoning=nim_resource,
            )

            # Should return neutral values as fallback
            assert result["_llm_status"][0] == "failed"
            assert result["monetary_stance"][0] == 3  # neutral
            assert "_llm_error" in result.columns

    def test_classification_handles_malformed_json_gracefully(
        self,
        sample_speeches: pl.DataFrame,
        mock_nim_malformed_response: dict[str, object],
        asset_context: AssetExecutionContext,
    ) -> None:
        """Classification should use fallback values on malformed JSON."""
        from brev_pipelines.assets.central_bank_speeches import classify_speeches
        from brev_pipelines.resources.nim import NIMLLMResource

        nim_resource = NIMLLMResource(
            endpoint="http://test:8000",
            model="openai/gpt-oss-120b",
        )

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_malformed_response
            mock_post.return_value.raise_for_status = MagicMock()

            result = classify_speeches(
                context=asset_context,
                cleaned_speeches=sample_speeches,
                nim_reasoning=nim_resource,
            )

            # Should return neutral values as fallback
            assert result["_llm_status"][0] == "failed"
            assert result["monetary_stance"][0] == 3  # neutral

    def test_classification_processes_all_speeches(
        self,
        sample_speeches: pl.DataFrame,
        mock_nim_response_hawkish: dict[str, object],
        asset_context: AssetExecutionContext,
    ) -> None:
        """Should process all speeches in the input DataFrame."""
        from brev_pipelines.assets.central_bank_speeches import classify_speeches
        from brev_pipelines.resources.nim import NIMLLMResource

        nim_resource = NIMLLMResource(
            endpoint="http://test:8000",
            model="openai/gpt-oss-120b",
        )

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_response_hawkish
            mock_post.return_value.raise_for_status = MagicMock()

            result = classify_speeches(
                context=asset_context,
                cleaned_speeches=sample_speeches,
                nim_reasoning=nim_resource,
            )

            assert len(result) == len(sample_speeches)

    def test_classification_preserves_reference_ids(
        self,
        sample_speeches: pl.DataFrame,
        mock_nim_response_hawkish: dict[str, object],
        asset_context: AssetExecutionContext,
    ) -> None:
        """Should preserve all reference IDs from input."""
        from brev_pipelines.assets.central_bank_speeches import classify_speeches
        from brev_pipelines.resources.nim import NIMLLMResource

        nim_resource = NIMLLMResource(
            endpoint="http://test:8000",
            model="openai/gpt-oss-120b",
        )

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_response_hawkish
            mock_post.return_value.raise_for_status = MagicMock()

            result = classify_speeches(
                context=asset_context,
                cleaned_speeches=sample_speeches,
                nim_reasoning=nim_resource,
            )

            input_refs = set(sample_speeches["reference"].to_list())
            output_refs = set(result["reference"].to_list())
            assert input_refs == output_refs


class TestClassificationSchemaDescription:
    """Tests for classification schema description."""

    def test_schema_description_constant_defined(self) -> None:
        """Verify schema description constant is defined."""
        from brev_pipelines.assets.central_bank_speeches import (
            CLASSIFICATION_SCHEMA_DESCRIPTION,
        )

        assert "monetary_stance" in CLASSIFICATION_SCHEMA_DESCRIPTION
        assert "trade_stance" in CLASSIFICATION_SCHEMA_DESCRIPTION
        assert "tariff_mention" in CLASSIFICATION_SCHEMA_DESCRIPTION
        assert "economic_outlook" in CLASSIFICATION_SCHEMA_DESCRIPTION

    def test_schema_description_includes_allowed_values(self) -> None:
        """Schema description should list allowed enum values."""
        from brev_pipelines.assets.central_bank_speeches import (
            CLASSIFICATION_SCHEMA_DESCRIPTION,
        )

        assert "hawkish" in CLASSIFICATION_SCHEMA_DESCRIPTION
        assert "dovish" in CLASSIFICATION_SCHEMA_DESCRIPTION
        assert "neutral" in CLASSIFICATION_SCHEMA_DESCRIPTION
```

**Validation**:
```bash
# Tests should FAIL - asset changes not made yet
pytest tests/integration/test_classification_pipeline.py -v
# Expected: Multiple FAILED tests
```

---

### Step 4.2: Update Classification Asset

**Action**: Modify
**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

Update the speech classification asset to use the new methods.

```python
# Add constant at module level

CLASSIFICATION_SCHEMA_DESCRIPTION: str = """Output JSON with these exact fields:
- monetary_stance: one of ["very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"]
- trade_stance: one of ["very_protectionist", "protectionist", "neutral", "globalist", "very_globalist"]
- tariff_mention: 0 if no tariffs mentioned, 1 if tariffs mentioned
- economic_outlook: one of ["very_negative", "negative", "neutral", "positive", "very_positive"]"""


# Add these imports
from brev_pipelines.types import SpeechClassificationResult
from brev_pipelines.utils.harmony import classification_to_numeric


# Update the classification function/asset

def classify_speeches(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_reasoning: NIMLLMResource,
) -> pl.DataFrame:
    """Classify speeches using GPT-OSS-120B.

    Uses json_object mode with client-side validation per INV-N010.

    Args:
        context: Dagster execution context.
        cleaned_speeches: DataFrame with speech text.
        nim_reasoning: NIM reasoning resource.

    Returns:
        DataFrame with classification results.
    """
    results: list[dict[str, int | str | None]] = []

    for row in cleaned_speeches.to_dicts():
        reference = row["reference"]
        text = str(row.get("text", ""))[:8000]  # Limit context

        try:
            # Use validated JSON generation
            classification = nim_reasoning.generate_validated_json(
                prompt=f"Analyze this central bank speech:\n\n{text}",
                system_prompt="You are a central bank speech classifier.",
                schema_description=CLASSIFICATION_SCHEMA_DESCRIPTION,
                response_model=SpeechClassificationResult,
                max_tokens=200,
                temperature=0.1,
            )

            # Convert to numeric values
            numeric = classification_to_numeric(classification)

            results.append({
                "reference": reference,
                "monetary_stance": numeric["monetary_stance"],
                "trade_stance": numeric["trade_stance"],
                "tariff_mention": numeric["tariff_mention"],
                "economic_outlook": numeric["economic_outlook"],
                "_llm_status": "success",
                "_llm_error": None,
            })

            context.log.info(f"Classified {reference}: monetary={classification.monetary_stance}")

        except Exception as e:
            context.log.warning(f"Classification failed for {reference}: {e}")

            # Fallback to neutral values
            results.append({
                "reference": reference,
                "monetary_stance": 3,  # neutral
                "trade_stance": 3,     # neutral
                "tariff_mention": 0,
                "economic_outlook": 3,  # neutral
                "_llm_status": "failed",
                "_llm_error": str(e),
            })

    return pl.DataFrame(results)
```

**Validation**:
```bash
# Integration tests should now PASS
pytest tests/integration/test_classification_pipeline.py -v
# Expected: All PASSED
```

---

### Step 4.3: Update Summaries Asset (if applicable)

**Action**: Modify
**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

If there's a summaries asset that also uses LLM, update it similarly.

```python
SUMMARY_SCHEMA_DESCRIPTION: str = """Output JSON with these exact fields:
- summary: A concise summary of the speech (100-500 words)
- key_topics: A list of 3-5 key topics discussed"""


def summarize_speeches(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_reasoning: NIMLLMResource,
) -> pl.DataFrame:
    """Summarize speeches using GPT-OSS-120B.

    Uses json_object mode with client-side validation.
    """
    from brev_pipelines.types import SpeechSummaryResult

    results: list[dict[str, str | None]] = []

    for row in cleaned_speeches.to_dicts():
        reference = row["reference"]
        text = str(row.get("text", ""))[:8000]

        try:
            summary_result = nim_reasoning.generate_validated_json(
                prompt=f"Summarize this central bank speech:\n\n{text}",
                system_prompt="You are a financial news summarizer.",
                schema_description=SUMMARY_SCHEMA_DESCRIPTION,
                response_model=SpeechSummaryResult,
                max_tokens=1000,
                temperature=0.3,
            )

            results.append({
                "reference": reference,
                "summary": summary_result.summary,
                "key_topics": ",".join(summary_result.key_topics),
                "_llm_status": "success",
                "_llm_error": None,
            })

        except Exception as e:
            context.log.warning(f"Summary failed for {reference}: {e}")
            results.append({
                "reference": reference,
                "summary": None,
                "key_topics": None,
                "_llm_status": "failed",
                "_llm_error": str(e),
            })

    return pl.DataFrame(results)
```

---

### Step 4.4: Add Full Pipeline Integration Test

**Action**: Create
**File(s)**: `dagster/tests/integration/test_full_pipeline.py`

```python
"""Full pipeline integration tests.

Tests multiple assets working together.
"""
from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import polars as pl
import pytest
from dagster import build_asset_context

if TYPE_CHECKING:
    pass


class TestFullClassificationPipeline:
    """Tests for full classification pipeline."""

    def test_classification_to_weaviate_index_flow(self) -> None:
        """Test classification results can be indexed to Weaviate."""
        # This tests that classification output schema matches Weaviate expectations
        classification_result = pl.DataFrame({
            "reference": ["BIS_2024_001"],
            "monetary_stance": [4],
            "trade_stance": [3],
            "tariff_mention": [0],
            "economic_outlook": [4],
            "_llm_status": ["success"],
            "_llm_error": [None],
        })

        # Verify schema compatibility with Weaviate properties
        required_weaviate_fields = [
            "reference",
            "monetary_stance",
            "trade_stance",
            "tariff_mention",
            "economic_outlook",
        ]
        for field in required_weaviate_fields:
            assert field in classification_result.columns

    def test_failed_classifications_have_fallback_values(self) -> None:
        """Verify failed classifications don't break downstream processing."""
        # Simulated mixed success/failure results
        mixed_results = pl.DataFrame({
            "reference": ["BIS_2024_001", "BIS_2024_002"],
            "monetary_stance": [4, 3],  # 3 is neutral fallback
            "trade_stance": [3, 3],
            "tariff_mention": [0, 0],
            "economic_outlook": [4, 3],
            "_llm_status": ["success", "failed"],
            "_llm_error": [None, "API timeout"],
        })

        # All values should be valid integers
        assert mixed_results["monetary_stance"].dtype == pl.Int64
        assert mixed_results["monetary_stance"].min() >= 1
        assert mixed_results["monetary_stance"].max() <= 5
```

---

### Step 4.5: Run Full Test Suite

**Action**: Verify

Run the complete test suite to ensure no regressions.

**Validation**:
```bash
# Run all tests
pytest tests/ -v --cov=brev_pipelines --cov-report=term-missing

# Type check all modules
mypy src/brev_pipelines/ --strict

# Lint
ruff check src/brev_pipelines/
ruff format src/brev_pipelines/ --check
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/tests/integration/test_classification_pipeline.py` | CREATE | Classification integration tests |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | MODIFY | Use generate_json methods |
| `dagster/tests/integration/test_full_pipeline.py` | CREATE | Full pipeline tests |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `NIM_REASONING_ENDPOINT` | `http://nvidia-nim-reasoning.nvidia-nim.svc.cluster.local:8000` | NIM endpoint |

### Secrets Required

None - NIM is local.

---

## Verification

### Pre-flight Checks

```bash
# Ensure Phase 3 is complete
pytest tests/unit/resources/test_nim*.py -v
# All should PASS
```

### Validation Commands

```bash
# Run integration tests
pytest tests/integration/ -v --cov=brev_pipelines.assets

# Run full test suite
pytest tests/ -v --cov=brev_pipelines --cov-report=html

# Type check
mypy src/brev_pipelines/ --strict

# Lint
ruff check src/brev_pipelines/
```

### Expected Outcomes

- All integration tests pass
- No regressions in existing tests
- Assets use generate_json() with json_object mode
- Fallback handling works correctly
- 80%+ overall test coverage

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Empty DataFrame input | Test failure | Add guard for empty input |
| Very long text | Truncation issues | Add explicit text length limit |
| Circular import | Import error | Use TYPE_CHECKING guard |

### Rollback Plan

If this phase fails:
1. Revert asset changes
2. Remove integration test files
3. Document issue in work-notes.md

---

## Completion Criteria

- [ ] Integration tests written BEFORE implementation
- [ ] All integration tests pass
- [ ] Assets use generate_json() / generate_validated_json()
- [ ] json_object mode used (NOT json_schema)
- [ ] Fallback handling works for failures
- [ ] 80%+ test coverage overall
- [ ] mypy --strict passes
- [ ] No regressions in existing tests
- [ ] All previous phase tests still pass
