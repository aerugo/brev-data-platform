# Phase 1: Type Definitions & Test Fixtures

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create comprehensive type definitions for NIM API interactions and test fixtures for mocked responses, following TDD principles by writing test infrastructure first.

---

## Invariants Enforced in This Phase

- **INV-P004**: All type definitions have complete annotations
- **INV-P005**: No `Any` types - use TypedDict and Pydantic
- **INV-P006**: Modern Python 3.11+ typing syntax
- **INV-P010**: TDD - Create test fixtures before implementation

---

## Implementation Steps

### Step 1.1: Write Tests for TypedDict Imports

**Action**: Create
**File(s)**: `dagster/tests/unit/test_types.py`

Write tests that verify the type definitions exist and are importable.

```python
"""Tests for type definitions.

These tests verify that all required TypedDicts and Pydantic models
are properly defined and importable.
"""
from __future__ import annotations

import pytest


class TestNIMTypes:
    """Tests for NIM-related type definitions."""

    def test_nim_chat_message_importable(self) -> None:
        """Verify NIMChatMessage TypedDict is importable."""
        from brev_pipelines.types import NIMChatMessage

        # Verify it has required fields
        msg: NIMChatMessage = {
            "role": "user",
            "content": "test",
        }
        assert msg["role"] == "user"

    def test_nim_chat_completion_request_importable(self) -> None:
        """Verify NIMChatCompletionRequest TypedDict is importable."""
        from brev_pipelines.types import NIMChatCompletionRequest

        req: NIMChatCompletionRequest = {
            "model": "openai/gpt-oss-120b",
            "messages": [{"role": "user", "content": "test"}],
        }
        assert req["model"] == "openai/gpt-oss-120b"

    def test_nim_chat_completion_response_importable(self) -> None:
        """Verify NIMChatCompletionResponse TypedDict is importable."""
        from brev_pipelines.types import NIMChatCompletionResponse

        # Minimal valid response
        resp: NIMChatCompletionResponse = {
            "id": "test-id",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "{}"},
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15,
            },
        }
        assert len(resp["choices"]) == 1


class TestClassificationModels:
    """Tests for classification Pydantic models."""

    def test_speech_classification_result_valid(self) -> None:
        """Verify valid classification result passes validation."""
        from brev_pipelines.types import SpeechClassificationResult

        result = SpeechClassificationResult(
            monetary_stance="hawkish",
            trade_stance="neutral",
            tariff_mention=0,
            economic_outlook="positive",
        )
        assert result.monetary_stance == "hawkish"

    def test_speech_classification_result_invalid_stance(self) -> None:
        """Verify invalid stance values raise validation error."""
        from pydantic import ValidationError

        from brev_pipelines.types import SpeechClassificationResult

        with pytest.raises(ValidationError):
            SpeechClassificationResult(
                monetary_stance="invalid",  # Not in allowed values
                trade_stance="neutral",
                tariff_mention=0,
                economic_outlook="positive",
            )

    def test_speech_classification_result_invalid_tariff(self) -> None:
        """Verify invalid tariff_mention raises validation error."""
        from pydantic import ValidationError

        from brev_pipelines.types import SpeechClassificationResult

        with pytest.raises(ValidationError):
            SpeechClassificationResult(
                monetary_stance="hawkish",
                trade_stance="neutral",
                tariff_mention=2,  # Must be 0 or 1
                economic_outlook="positive",
            )
```

**Validation**:
```bash
# Test should FAIL - types don't exist yet
pytest tests/unit/test_types.py -v
```

---

### Step 1.2: Create NIM TypedDict Definitions

**Action**: Modify
**File(s)**: `dagster/src/brev_pipelines/types.py`

Add NIM API type definitions. Add these after the existing Weaviate types section.

```python
# =============================================================================
# NIM API Types (for GPT-OSS-120B)
# =============================================================================

class NIMChatMessage(TypedDict):
    """A single message in NIM chat format."""

    role: Literal["system", "user", "assistant"]
    content: str


class NIMResponseFormat(TypedDict, total=False):
    """Response format configuration for NIM."""

    type: Literal["text", "json_object", "json_schema"]
    json_schema: dict[str, object] | None


class NIMChatCompletionRequest(TypedDict, total=False):
    """Request body for NIM chat completion API."""

    model: str
    messages: list[NIMChatMessage]
    max_tokens: int
    temperature: float
    response_format: NIMResponseFormat
    include_reasoning: bool


class NIMChatChoice(TypedDict):
    """A single choice in NIM chat completion response."""

    index: int
    message: NIMChatMessage
    finish_reason: Literal["stop", "length", "tool_calls"]


class NIMUsage(TypedDict):
    """Token usage information from NIM response."""

    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


class NIMChatCompletionResponse(TypedDict):
    """Response from NIM chat completion API."""

    id: str
    choices: list[NIMChatChoice]
    usage: NIMUsage


# =============================================================================
# Speech Classification Types (for GPT-OSS structured output)
# =============================================================================

# Valid values for classification fields
MonetaryStanceType = Literal[
    "very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"
]
TradeStanceType = Literal[
    "very_protectionist", "protectionist", "neutral", "globalist", "very_globalist"
]
EconomicOutlookType = Literal[
    "very_negative", "negative", "neutral", "positive", "very_positive"
]


class SpeechClassificationResult(BaseModel):
    """Result of LLM speech classification.

    Used for validating GPT-OSS JSON output.
    All fields use constrained Literal types for strict validation.
    """

    model_config = ConfigDict(strict=True, frozen=True)

    monetary_stance: MonetaryStanceType = Field(
        description="Monetary policy stance expressed in the speech"
    )
    trade_stance: TradeStanceType = Field(
        description="Trade policy stance expressed in the speech"
    )
    tariff_mention: Literal[0, 1] = Field(
        description="Whether tariffs are mentioned (1) or not (0)"
    )
    economic_outlook: EconomicOutlookType = Field(
        description="Economic outlook expressed in the speech"
    )


class SpeechClassificationDict(TypedDict):
    """Dictionary form of classification result (for asset returns)."""

    monetary_stance: int
    trade_stance: int
    tariff_mention: int
    economic_outlook: int


# Mapping from string values to numeric scale
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

ECONOMIC_OUTLOOK_SCALE: dict[str, int] = {
    "very_negative": 1,
    "negative": 2,
    "neutral": 3,
    "positive": 4,
    "very_positive": 5,
}
```

**Validation**:
```bash
# Verify types are importable
python -c "from brev_pipelines.types import NIMChatCompletionRequest, SpeechClassificationResult; print('OK')"

# Run type tests - should now PASS
pytest tests/unit/test_types.py -v
```

---

### Step 1.3: Create NIM Mock Fixtures

**Action**: Modify
**File(s)**: `dagster/tests/conftest.py`

Add fixtures for mocked NIM responses.

```python
# =============================================================================
# NIM GPT-OSS Fixtures
# =============================================================================

@pytest.fixture
def mock_nim_classification_response() -> dict[str, object]:
    """Mock NIM classification response with valid JSON."""
    return {
        "id": "gen-test-12345",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": '{"monetary_stance": "hawkish", "trade_stance": "neutral", "tariff_mention": 0, "economic_outlook": "positive"}',
            },
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "total_tokens": 150,
        },
    }


@pytest.fixture
def mock_nim_classification_with_reasoning() -> dict[str, object]:
    """Mock NIM response with reasoning tokens in content (the bug we're fixing)."""
    return {
        "id": "gen-test-12346",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": 'The Fed raised rates so monetary stance is hawkish.\n{"monetary_stance": "hawkish", "trade_stance": "neutral", "tariff_mention": 0, "economic_outlook": "positive"}<|return|>',
            },
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 80,
            "total_tokens": 180,
        },
    }


@pytest.fixture
def mock_nim_malformed_response() -> dict[str, object]:
    """Mock NIM response with malformed JSON (json_schema bug)."""
    return {
        "id": "gen-test-12347",
        "choices": [{
            "index": 0,
            "message": {
                "role": "assistant",
                "content": '{\n    "monetary_stance":"hawkish"\n   ,\n\n\n   "trade_stance"',  # Truncated
            },
            "finish_reason": "length",
        }],
        "usage": {
            "prompt_tokens": 100,
            "completion_tokens": 500,
            "total_tokens": 600,
        },
    }


@pytest.fixture
def mock_nim_error_response() -> dict[str, object]:
    """Mock NIM error response."""
    return {
        "error": {
            "message": "Service temporarily unavailable",
            "type": "server_error",
            "code": 503,
        }
    }


@pytest.fixture
def valid_classification_json() -> str:
    """Valid classification JSON string."""
    return '{"monetary_stance": "hawkish", "trade_stance": "neutral", "tariff_mention": 0, "economic_outlook": "positive"}'


@pytest.fixture
def classification_with_harmony_tokens() -> str:
    """Classification JSON with Harmony control tokens."""
    return '<|channel|>final<|message|>{"monetary_stance": "hawkish", "trade_stance": "neutral", "tariff_mention": 0, "economic_outlook": "positive"}<|return|>'
```

**Validation**:
```bash
# Verify fixtures are available
pytest --fixtures tests/ | grep mock_nim
```

---

### Step 1.4: Write Tests for Harmony Token Constants

**Action**: Create
**File(s)**: `dagster/tests/unit/test_harmony_constants.py`

```python
"""Tests for Harmony token handling constants."""
from __future__ import annotations


class TestHarmonyConstants:
    """Tests for Harmony format constants."""

    def test_harmony_tokens_defined(self) -> None:
        """Verify all Harmony tokens are defined."""
        from brev_pipelines.utils.harmony import HARMONY_TOKENS

        assert "<|start|>" in HARMONY_TOKENS
        assert "<|end|>" in HARMONY_TOKENS
        assert "<|return|>" in HARMONY_TOKENS
        assert "<|channel|>" in HARMONY_TOKENS
        assert "<|message|>" in HARMONY_TOKENS

    def test_harmony_token_pattern_defined(self) -> None:
        """Verify Harmony token regex pattern is defined."""
        from brev_pipelines.utils.harmony import HARMONY_TOKEN_PATTERN

        assert HARMONY_TOKEN_PATTERN is not None
        # Should match <|token|> format
        import re
        assert re.match(HARMONY_TOKEN_PATTERN, "<|return|>")
        assert re.match(HARMONY_TOKEN_PATTERN, "<|channel|>")
        assert not re.match(HARMONY_TOKEN_PATTERN, "regular text")
```

**Validation**:
```bash
# Test should FAIL - harmony module doesn't exist yet
pytest tests/unit/test_harmony_constants.py -v
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/tests/unit/test_types.py` | CREATE | Type definition tests |
| `dagster/src/brev_pipelines/types.py` | MODIFY | Add NIM TypedDicts |
| `dagster/tests/conftest.py` | MODIFY | Add NIM mock fixtures |
| `dagster/tests/unit/test_harmony_constants.py` | CREATE | Harmony constant tests |

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
# Ensure dagster environment is set up
cd dagster
uv sync --all-extras
```

### Validation Commands

```bash
# Type check new definitions
mypy src/brev_pipelines/types.py --strict

# Run type tests
pytest tests/unit/test_types.py -v

# Verify fixtures available
pytest --fixtures tests/ | grep mock_nim

# Run all unit tests (some will fail - that's expected for TDD)
pytest tests/unit/ -v --ignore=tests/unit/test_harmony_constants.py
```

### Expected Outcomes

- TypedDicts are importable and type-correct
- Pydantic models validate correctly
- Mock fixtures are available in test sessions
- `test_harmony_constants.py` tests FAIL (implementation in Phase 2)

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Import cycles | mypy error | Use TYPE_CHECKING guard |
| Pydantic v1 vs v2 | ValidationError differences | Use ConfigDict, not class Config |

### Rollback Plan

If this phase fails:
1. Revert changes to `types.py`
2. Remove new test files
3. Document issues in work-notes.md

---

## Completion Criteria

- [ ] All tests in `test_types.py` pass
- [ ] `mypy src/brev_pipelines/types.py --strict` passes
- [ ] Mock fixtures available via `pytest --fixtures`
- [ ] `test_harmony_constants.py` tests fail (RED state for Phase 2)
- [ ] No `Any` types in new code
