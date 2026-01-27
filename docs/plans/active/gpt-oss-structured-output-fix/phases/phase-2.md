# Phase 2: Harmony Parser & Validation

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create the Harmony token cleanup functions and response validation, following strict TDD by writing comprehensive tests before implementation.

---

## Invariants Enforced in This Phase

- **INV-P004**: Complete type annotations on all functions
- **INV-P005**: No `Any` types
- **INV-P007**: Pydantic v2 for validation
- **INV-P010**: TDD - Write tests BEFORE implementation

---

## Implementation Steps

### Step 2.1: Write Failing Tests for Harmony Parser

**Action**: Create
**File(s)**: `dagster/tests/unit/test_harmony_parser.py`

Write comprehensive tests for the harmony parsing functions BEFORE implementing them.

```python
"""Tests for Harmony response format parsing.

Tests follow TDD - written BEFORE implementation.
The Harmony format is used by GPT-OSS models.
"""
from __future__ import annotations

import pytest


class TestExtractJsonFromHarmony:
    """Tests for extract_json_from_harmony function."""

    def test_clean_json_unchanged(self) -> None:
        """Clean JSON without Harmony tokens should be unchanged."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"monetary_stance": "hawkish", "tariff_mention": 0}'
        result = extract_json_from_harmony(content)
        assert result == {"monetary_stance": "hawkish", "tariff_mention": 0}

    def test_removes_return_token(self) -> None:
        """Should remove <|return|> token from end."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"key": "value"}<|return|>'
        result = extract_json_from_harmony(content)
        assert result == {"key": "value"}

    def test_removes_channel_tokens(self) -> None:
        """Should remove <|channel|>final pattern."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '<|channel|>final<|message|>{"key": "value"}'
        result = extract_json_from_harmony(content)
        assert result == {"key": "value"}

    def test_removes_multiple_tokens(self) -> None:
        """Should remove all Harmony tokens."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '<|start|>assistant<|channel|>final<|message|>{"key": "value"}<|end|><|return|>'
        result = extract_json_from_harmony(content)
        assert result == {"key": "value"}

    def test_handles_reasoning_prefix(self) -> None:
        """Should extract JSON even with reasoning text before it."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = 'The Fed raised rates so stance is hawkish.\n{"monetary_stance": "hawkish"}'
        result = extract_json_from_harmony(content)
        assert result == {"monetary_stance": "hawkish"}

    def test_handles_reasoning_with_tokens(self) -> None:
        """Should handle reasoning text plus Harmony tokens."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = 'Analysis complete.<|channel|>final<|message|>{"key": "value"}<|return|>'
        result = extract_json_from_harmony(content)
        assert result == {"key": "value"}

    def test_raises_on_no_json(self) -> None:
        """Should raise ValueError when no JSON found."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        with pytest.raises(ValueError, match="No JSON found"):
            extract_json_from_harmony("Just plain text without any JSON")

    def test_raises_on_invalid_json(self) -> None:
        """Should raise ValueError on malformed JSON."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        with pytest.raises(ValueError, match="Invalid JSON"):
            extract_json_from_harmony('{"key": "value"')  # Missing closing brace

    def test_handles_nested_json(self) -> None:
        """Should correctly parse nested JSON objects."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"outer": {"inner": "value"}, "list": [1, 2, 3]}'
        result = extract_json_from_harmony(content)
        assert result == {"outer": {"inner": "value"}, "list": [1, 2, 3]}

    def test_handles_whitespace(self) -> None:
        """Should handle JSON with extra whitespace."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '  \n  {"key": "value"}  \n  <|return|>'
        result = extract_json_from_harmony(content)
        assert result == {"key": "value"}


class TestRemoveHarmonyTokens:
    """Tests for remove_harmony_tokens function."""

    def test_removes_all_tokens(self) -> None:
        """Should remove all Harmony control tokens."""
        from brev_pipelines.utils.harmony import remove_harmony_tokens

        content = '<|start|>assistant<|channel|>final<|message|>text<|end|>'
        result = remove_harmony_tokens(content)
        assert "<|" not in result
        assert "|>" not in result
        assert "text" in result

    def test_preserves_non_token_text(self) -> None:
        """Should preserve all non-token text."""
        from brev_pipelines.utils.harmony import remove_harmony_tokens

        content = 'Hello <|return|> World'
        result = remove_harmony_tokens(content)
        assert result == "Hello  World"

    def test_empty_string(self) -> None:
        """Should handle empty string."""
        from brev_pipelines.utils.harmony import remove_harmony_tokens

        result = remove_harmony_tokens("")
        assert result == ""


class TestValidateClassificationResponse:
    """Tests for validate_classification_response function."""

    def test_valid_response(self) -> None:
        """Valid response should return SpeechClassificationResult."""
        from brev_pipelines.utils.harmony import validate_classification_response
        from brev_pipelines.types import SpeechClassificationResult

        raw_json = {
            "monetary_stance": "hawkish",
            "trade_stance": "neutral",
            "tariff_mention": 0,
            "economic_outlook": "positive",
        }
        result = validate_classification_response(raw_json)
        assert isinstance(result, SpeechClassificationResult)
        assert result.monetary_stance == "hawkish"

    def test_invalid_stance_raises(self) -> None:
        """Invalid stance value should raise ValidationError."""
        from pydantic import ValidationError

        from brev_pipelines.utils.harmony import validate_classification_response

        raw_json = {
            "monetary_stance": "invalid_stance",
            "trade_stance": "neutral",
            "tariff_mention": 0,
            "economic_outlook": "positive",
        }
        with pytest.raises(ValidationError):
            validate_classification_response(raw_json)

    def test_missing_field_raises(self) -> None:
        """Missing required field should raise ValidationError."""
        from pydantic import ValidationError

        from brev_pipelines.utils.harmony import validate_classification_response

        raw_json = {
            "monetary_stance": "hawkish",
            # Missing trade_stance, tariff_mention, economic_outlook
        }
        with pytest.raises(ValidationError):
            validate_classification_response(raw_json)

    def test_tariff_mention_must_be_0_or_1(self) -> None:
        """tariff_mention must be exactly 0 or 1."""
        from pydantic import ValidationError

        from brev_pipelines.utils.harmony import validate_classification_response

        raw_json = {
            "monetary_stance": "hawkish",
            "trade_stance": "neutral",
            "tariff_mention": 2,  # Invalid
            "economic_outlook": "positive",
        }
        with pytest.raises(ValidationError):
            validate_classification_response(raw_json)


class TestClassificationToNumeric:
    """Tests for classification_to_numeric function."""

    def test_converts_all_fields(self) -> None:
        """Should convert all string fields to numeric values."""
        from brev_pipelines.utils.harmony import classification_to_numeric
        from brev_pipelines.types import SpeechClassificationResult

        result = SpeechClassificationResult(
            monetary_stance="hawkish",
            trade_stance="neutral",
            tariff_mention=0,
            economic_outlook="positive",
        )
        numeric = classification_to_numeric(result)

        assert numeric["monetary_stance"] == 4  # hawkish = 4
        assert numeric["trade_stance"] == 3     # neutral = 3
        assert numeric["tariff_mention"] == 0
        assert numeric["economic_outlook"] == 4  # positive = 4

    def test_all_dovish_values(self) -> None:
        """Test dovish/protectionist/negative mappings."""
        from brev_pipelines.utils.harmony import classification_to_numeric
        from brev_pipelines.types import SpeechClassificationResult

        result = SpeechClassificationResult(
            monetary_stance="very_dovish",
            trade_stance="very_protectionist",
            tariff_mention=1,
            economic_outlook="very_negative",
        )
        numeric = classification_to_numeric(result)

        assert numeric["monetary_stance"] == 1
        assert numeric["trade_stance"] == 1
        assert numeric["tariff_mention"] == 1
        assert numeric["economic_outlook"] == 1
```

**Validation**:
```bash
# All tests should FAIL - functions don't exist yet
pytest tests/unit/test_harmony_parser.py -v
# Expected: Multiple FAILED tests
```

---

### Step 2.2: Create Harmony Utils Module

**Action**: Create
**File(s)**: `dagster/src/brev_pipelines/utils/__init__.py`

```python
"""Utility modules for Brev Pipelines."""
```

**File(s)**: `dagster/src/brev_pipelines/utils/harmony.py`

Implement the functions to make tests pass.

```python
"""Harmony response format utilities.

GPT-OSS models output in the Harmony format which uses control tokens
to separate different output channels (analysis, final, commentary).

This module provides functions to:
1. Remove Harmony control tokens from responses
2. Extract JSON from Harmony-formatted content
3. Validate classification responses
4. Convert classification results to numeric values

References:
- https://cookbook.openai.com/articles/openai-harmony
- https://github.com/openai/harmony
"""
from __future__ import annotations

import json
import re
from typing import TYPE_CHECKING

from pydantic import ValidationError

from brev_pipelines.types import (
    ECONOMIC_OUTLOOK_SCALE,
    MONETARY_STANCE_SCALE,
    TRADE_STANCE_SCALE,
    SpeechClassificationDict,
    SpeechClassificationResult,
)

if TYPE_CHECKING:
    pass

# Harmony control tokens
HARMONY_TOKENS: frozenset[str] = frozenset({
    "<|start|>",
    "<|end|>",
    "<|return|>",
    "<|call|>",
    "<|channel|>",
    "<|message|>",
    "<|constrain|>",
})

# Regex pattern to match any Harmony token
# Matches: <|token_name|> where token_name is alphanumeric
HARMONY_TOKEN_PATTERN: str = r"<\|[a-zA-Z_]+\|>"


def remove_harmony_tokens(content: str) -> str:
    """Remove all Harmony control tokens from content.

    Args:
        content: Raw content that may contain Harmony tokens.

    Returns:
        Content with all Harmony tokens removed.

    Example:
        >>> remove_harmony_tokens('<|return|>text<|end|>')
        'text'
    """
    return re.sub(HARMONY_TOKEN_PATTERN, "", content)


def extract_json_from_harmony(content: str) -> dict[str, object]:
    """Extract and parse JSON from Harmony-formatted content.

    Handles:
    - Harmony control tokens (<|return|>, <|channel|>, etc.)
    - Reasoning text before the JSON
    - Whitespace and formatting

    Args:
        content: Raw content from NIM response.

    Returns:
        Parsed JSON as a dictionary.

    Raises:
        ValueError: If no valid JSON found in content.

    Example:
        >>> extract_json_from_harmony('{"key": "value"}<|return|>')
        {'key': 'value'}
    """
    # Remove Harmony tokens first
    cleaned = remove_harmony_tokens(content)

    # Try to find JSON object in the content
    # Match outermost {} including nested objects
    json_pattern = r"\{(?:[^{}]|\{[^{}]*\})*\}"
    json_match = re.search(json_pattern, cleaned)

    if not json_match:
        raise ValueError(f"No JSON found in response: {content[:200]}...")

    json_str = json_match.group()

    try:
        return json.loads(json_str)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON: {e}") from e


def validate_classification_response(
    raw_json: dict[str, object],
) -> SpeechClassificationResult:
    """Validate raw JSON against SpeechClassificationResult schema.

    Args:
        raw_json: Parsed JSON dictionary from LLM response.

    Returns:
        Validated SpeechClassificationResult.

    Raises:
        ValidationError: If JSON doesn't match expected schema.
    """
    return SpeechClassificationResult(**raw_json)


def classification_to_numeric(
    result: SpeechClassificationResult,
) -> SpeechClassificationDict:
    """Convert classification result to numeric values.

    Converts string stance values to 1-5 scale:
    - very_dovish/very_protectionist/very_negative = 1
    - dovish/protectionist/negative = 2
    - neutral = 3
    - hawkish/globalist/positive = 4
    - very_hawkish/very_globalist/very_positive = 5

    Args:
        result: Validated classification result.

    Returns:
        Dictionary with numeric values for all fields.
    """
    return SpeechClassificationDict(
        monetary_stance=MONETARY_STANCE_SCALE[result.monetary_stance],
        trade_stance=TRADE_STANCE_SCALE[result.trade_stance],
        tariff_mention=result.tariff_mention,
        economic_outlook=ECONOMIC_OUTLOOK_SCALE[result.economic_outlook],
    )
```

**Validation**:
```bash
# All tests should now PASS
pytest tests/unit/test_harmony_parser.py -v
# Expected: All PASSED

# Type check
mypy src/brev_pipelines/utils/harmony.py --strict
```

---

### Step 2.3: Add Harmony Constants Test (from Phase 1)

**Action**: Verify
**File(s)**: `dagster/tests/unit/test_harmony_constants.py`

The tests written in Phase 1 should now pass.

**Validation**:
```bash
# These tests should now PASS
pytest tests/unit/test_harmony_constants.py -v
```

---

### Step 2.4: Write Edge Case Tests

**Action**: Create
**File(s)**: `dagster/tests/unit/test_harmony_edge_cases.py`

```python
"""Edge case tests for Harmony parsing.

Tests unusual but possible scenarios.
"""
from __future__ import annotations

import pytest


class TestHarmonyEdgeCases:
    """Edge case tests for Harmony parsing."""

    def test_multiple_json_objects_takes_first(self) -> None:
        """When multiple JSON objects present, take the first valid one."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"first": 1} {"second": 2}'
        result = extract_json_from_harmony(content)
        assert result == {"first": 1}

    def test_json_with_unicode(self) -> None:
        """Should handle JSON with unicode characters."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"text": "Économie française"}'
        result = extract_json_from_harmony(content)
        assert result == {"text": "Économie française"}

    def test_json_with_escaped_quotes(self) -> None:
        """Should handle JSON with escaped quotes."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"text": "He said \\"hello\\""}'
        result = extract_json_from_harmony(content)
        assert result == {"text": 'He said "hello"'}

    def test_deeply_nested_json(self) -> None:
        """Should handle deeply nested JSON."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{"a": {"b": {"c": {"d": "value"}}}}'
        result = extract_json_from_harmony(content)
        assert result["a"]["b"]["c"]["d"] == "value"

    def test_json_array_not_supported(self) -> None:
        """JSON arrays should raise ValueError (we expect objects)."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        with pytest.raises(ValueError, match="No JSON found"):
            extract_json_from_harmony('[1, 2, 3]')

    def test_empty_json_object(self) -> None:
        """Empty JSON object should be valid."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '{}'
        result = extract_json_from_harmony(content)
        assert result == {}

    def test_json_with_newlines(self) -> None:
        """Should handle pretty-printed JSON with newlines."""
        from brev_pipelines.utils.harmony import extract_json_from_harmony

        content = '''
        {
            "key": "value",
            "number": 42
        }
        '''
        result = extract_json_from_harmony(content)
        assert result == {"key": "value", "number": 42}
```

**Validation**:
```bash
pytest tests/unit/test_harmony_edge_cases.py -v
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/tests/unit/test_harmony_parser.py` | CREATE | Main parser tests (TDD) |
| `dagster/src/brev_pipelines/utils/__init__.py` | CREATE | Utils package init |
| `dagster/src/brev_pipelines/utils/harmony.py` | CREATE | Harmony parsing implementation |
| `dagster/tests/unit/test_harmony_edge_cases.py` | CREATE | Edge case tests |

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
# Ensure Phase 1 is complete
pytest tests/unit/test_types.py -v
# All should PASS
```

### Validation Commands

```bash
# Run all harmony tests
pytest tests/unit/test_harmony*.py -v --cov=brev_pipelines.utils.harmony

# Type check
mypy src/brev_pipelines/utils/ --strict

# Lint
ruff check src/brev_pipelines/utils/
```

### Expected Outcomes

- All `test_harmony_parser.py` tests pass
- All `test_harmony_constants.py` tests pass
- All `test_harmony_edge_cases.py` tests pass
- 100% test coverage on `harmony.py`
- mypy strict mode passes

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Nested JSON regex fails | Test failure | Use recursive pattern or json.loads directly |
| Unicode handling | Test failure | Ensure UTF-8 encoding |
| ValidationError import | Import error | Import from pydantic, not pydantic.error_wrappers |

### Rollback Plan

If this phase fails:
1. Revert `utils/harmony.py`
2. Remove test files
3. Document issue in work-notes.md

---

## Completion Criteria

- [ ] All tests written BEFORE implementation (TDD)
- [ ] All 20+ tests pass
- [ ] `mypy --strict` passes
- [ ] 100% test coverage on harmony.py
- [ ] No `Any` types used
- [ ] Phase 1 tests still pass (no regressions)
