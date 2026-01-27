# Phase 3: NIM Resource Enhancement

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Enhance the NIM resource with a `generate_json()` method that properly handles GPT-OSS structured output using `json_object` mode, with comprehensive tests written first.

---

## Invariants Enforced in This Phase

- **INV-I006**: Local-only infrastructure - use local NIM endpoint only
- **INV-P004**: Complete type annotations
- **INV-P005**: No `Any` types
- **INV-P009**: Composition over inheritance - use Protocol for testing
- **INV-P010**: TDD - write tests BEFORE implementation
- **INV-N005**: NIM observability - maintain logging

---

## Implementation Steps

### Step 3.1: Write Failing Tests for generate_json()

**Action**: Create
**File(s)**: `dagster/tests/unit/resources/test_nim_json.py`

Write comprehensive tests BEFORE implementing the method.

```python
"""Tests for NIM resource JSON generation.

Tests follow TDD - written BEFORE implementation.
All HTTP calls are mocked.
"""
from __future__ import annotations

from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

if TYPE_CHECKING:
    pass


class TestNIMResourceGenerateJson:
    """Tests for NIMLLMResource.generate_json() method."""

    @pytest.fixture
    def nim_resource(self) -> MagicMock:
        """Create NIM resource for testing."""
        from brev_pipelines.resources.nim import NIMLLMResource

        return NIMLLMResource(
            endpoint="http://test-nim:8000",
            model="openai/gpt-oss-120b",
        )

    def test_generate_json_returns_dict(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """generate_json should return parsed dictionary."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            result = nim_resource.generate_json(
                prompt="Classify this speech",
                system_prompt="You are a classifier",
                schema_description="Return JSON with monetary_stance",
            )

            assert isinstance(result, dict)
            assert "monetary_stance" in result

    def test_generate_json_uses_json_object_format(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Should use json_object response format, NOT json_schema."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            nim_resource.generate_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
            )

            # Verify the request used json_object, not json_schema
            call_args = mock_post.call_args
            request_body = call_args.kwargs["json"]
            assert request_body["response_format"]["type"] == "json_object"

    def test_generate_json_includes_reasoning_false(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Should include include_reasoning: false in request."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            nim_resource.generate_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
            )

            call_args = mock_post.call_args
            request_body = call_args.kwargs["json"]
            assert request_body.get("include_reasoning") is False

    def test_generate_json_handles_harmony_tokens(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_with_reasoning: dict[str, object],
    ) -> None:
        """Should clean Harmony tokens from response."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_with_reasoning
            mock_post.return_value.raise_for_status = MagicMock()

            result = nim_resource.generate_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
            )

            # Should have extracted clean JSON despite tokens
            assert "monetary_stance" in result
            assert "<|return|>" not in str(result)

    def test_generate_json_includes_schema_in_system_prompt(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Schema description should be included in system prompt."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            nim_resource.generate_json(
                prompt="Classify this",
                system_prompt="You are a classifier",
                schema_description="Return JSON with monetary_stance field",
            )

            call_args = mock_post.call_args
            request_body = call_args.kwargs["json"]
            system_message = request_body["messages"][0]["content"]
            assert "monetary_stance" in system_message

    def test_generate_json_uses_low_reasoning(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Should include 'Reasoning: low' in system prompt."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            nim_resource.generate_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
            )

            call_args = mock_post.call_args
            request_body = call_args.kwargs["json"]
            system_message = request_body["messages"][0]["content"]
            assert "Reasoning: low" in system_message

    def test_generate_json_raises_on_malformed_response(
        self,
        nim_resource: MagicMock,
        mock_nim_malformed_response: dict[str, object],
    ) -> None:
        """Should raise ValueError on malformed JSON response."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_malformed_response
            mock_post.return_value.raise_for_status = MagicMock()

            with pytest.raises(ValueError, match="Invalid JSON|No JSON found"):
                nim_resource.generate_json(
                    prompt="Test",
                    system_prompt="Test",
                    schema_description="Test",
                )

    def test_generate_json_raises_on_http_error(
        self,
        nim_resource: MagicMock,
    ) -> None:
        """Should raise on HTTP error."""
        import requests

        with patch("requests.post") as mock_post:
            mock_post.return_value.raise_for_status.side_effect = (
                requests.exceptions.HTTPError("503 Service Unavailable")
            )

            with pytest.raises(requests.exceptions.HTTPError):
                nim_resource.generate_json(
                    prompt="Test",
                    system_prompt="Test",
                    schema_description="Test",
                )

    def test_generate_json_respects_max_tokens(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Should pass max_tokens parameter."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            nim_resource.generate_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
                max_tokens=250,
            )

            call_args = mock_post.call_args
            request_body = call_args.kwargs["json"]
            assert request_body["max_tokens"] == 250

    def test_generate_json_respects_temperature(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Should pass temperature parameter."""
        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            nim_resource.generate_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
                temperature=0.1,
            )

            call_args = mock_post.call_args
            request_body = call_args.kwargs["json"]
            assert request_body["temperature"] == 0.1


class TestNIMResourceValidateJson:
    """Tests for NIMLLMResource.generate_validated_json() method."""

    @pytest.fixture
    def nim_resource(self) -> MagicMock:
        """Create NIM resource for testing."""
        from brev_pipelines.resources.nim import NIMLLMResource

        return NIMLLMResource(
            endpoint="http://test-nim:8000",
            model="openai/gpt-oss-120b",
        )

    def test_generate_validated_json_returns_pydantic_model(
        self,
        nim_resource: MagicMock,
        mock_nim_classification_response: dict[str, object],
    ) -> None:
        """Should return validated Pydantic model."""
        from brev_pipelines.types import SpeechClassificationResult

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = mock_nim_classification_response
            mock_post.return_value.raise_for_status = MagicMock()

            result = nim_resource.generate_validated_json(
                prompt="Test",
                system_prompt="Test",
                schema_description="Test",
                response_model=SpeechClassificationResult,
            )

            assert isinstance(result, SpeechClassificationResult)
            assert result.monetary_stance == "hawkish"

    def test_generate_validated_json_raises_on_validation_failure(
        self,
        nim_resource: MagicMock,
    ) -> None:
        """Should raise ValidationError when response doesn't match model."""
        from pydantic import ValidationError

        from brev_pipelines.types import SpeechClassificationResult

        invalid_response = {
            "id": "test",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": '{"monetary_stance": "invalid_value"}',
                },
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
        }

        with patch("requests.post") as mock_post:
            mock_post.return_value.status_code = 200
            mock_post.return_value.json.return_value = invalid_response
            mock_post.return_value.raise_for_status = MagicMock()

            with pytest.raises(ValidationError):
                nim_resource.generate_validated_json(
                    prompt="Test",
                    system_prompt="Test",
                    schema_description="Test",
                    response_model=SpeechClassificationResult,
                )
```

**Validation**:
```bash
# All tests should FAIL - methods don't exist yet
pytest tests/unit/resources/test_nim_json.py -v
# Expected: Multiple FAILED tests
```

---

### Step 3.2: Implement generate_json() Method

**Action**: Modify
**File(s)**: `dagster/src/brev_pipelines/resources/nim.py`

Add the new methods to the existing NIM resource.

```python
# Add these imports at the top
from typing import TypeVar

from pydantic import BaseModel

from brev_pipelines.utils.harmony import extract_json_from_harmony

T = TypeVar("T", bound=BaseModel)


# Add these methods to the NIMLLMResource class

def generate_json(
    self,
    prompt: str,
    system_prompt: str,
    schema_description: str,
    max_tokens: int = 500,
    temperature: float = 0.1,
) -> dict[str, object]:
    """Generate structured JSON output from GPT-OSS.

    Uses json_object mode (NOT json_schema) to avoid vLLM bug #23120.
    Includes reasoning suppression and Harmony token cleanup.

    Args:
        prompt: User prompt with content to analyze.
        system_prompt: Base system instructions.
        schema_description: Description of expected JSON schema.
        max_tokens: Maximum tokens to generate.
        temperature: Sampling temperature (lower = more deterministic).

    Returns:
        Parsed JSON dictionary.

    Raises:
        ValueError: If response cannot be parsed as JSON.
        requests.HTTPError: If NIM API returns an error.

    Example:
        >>> result = nim.generate_json(
        ...     prompt="Classify: The Fed raised rates",
        ...     system_prompt="You are a classifier",
        ...     schema_description="Return JSON with monetary_stance field",
        ... )
        >>> print(result)
        {"monetary_stance": "hawkish", ...}
    """
    # Build system prompt with reasoning level and schema
    full_system_prompt = f"""Reasoning: low
{system_prompt}

{schema_description}

Return ONLY valid JSON, no other text."""

    # Build request payload
    payload = {
        "model": self.model,
        "messages": [
            {"role": "system", "content": full_system_prompt},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "response_format": {"type": "json_object"},
        "include_reasoning": False,
    }

    # Make API call
    response = requests.post(
        f"{self.endpoint}/v1/chat/completions",
        json=payload,
        timeout=60,
    )
    response.raise_for_status()

    # Extract content from response
    result = response.json()
    content = result["choices"][0]["message"]["content"]

    # Parse JSON, handling any residual Harmony tokens
    return extract_json_from_harmony(content)


def generate_validated_json(
    self,
    prompt: str,
    system_prompt: str,
    schema_description: str,
    response_model: type[T],
    max_tokens: int = 500,
    temperature: float = 0.1,
) -> T:
    """Generate and validate JSON output against a Pydantic model.

    Combines generate_json() with Pydantic validation.

    Args:
        prompt: User prompt with content to analyze.
        system_prompt: Base system instructions.
        schema_description: Description of expected JSON schema.
        response_model: Pydantic model class to validate against.
        max_tokens: Maximum tokens to generate.
        temperature: Sampling temperature.

    Returns:
        Validated Pydantic model instance.

    Raises:
        ValidationError: If response doesn't match the model schema.
        ValueError: If response cannot be parsed as JSON.
        requests.HTTPError: If NIM API returns an error.
    """
    raw_json = self.generate_json(
        prompt=prompt,
        system_prompt=system_prompt,
        schema_description=schema_description,
        max_tokens=max_tokens,
        temperature=temperature,
    )

    return response_model(**raw_json)
```

**Validation**:
```bash
# All tests should now PASS
pytest tests/unit/resources/test_nim_json.py -v
# Expected: All PASSED

# Type check
mypy src/brev_pipelines/resources/nim.py --strict
```

---

### Step 3.3: Add Protocol for Testing

**Action**: Modify
**File(s)**: `dagster/src/brev_pipelines/types.py`

Add a Protocol for the NIM resource to enable easier mocking.

```python
# Add to types.py

class LLMProvider(Protocol):
    """Protocol for LLM providers.

    Enables dependency injection and mocking for testing.
    """

    def generate(
        self,
        prompt: str,
        max_tokens: int = 500,
        temperature: float = 0.7,
    ) -> str:
        """Generate text completion."""
        ...

    def generate_json(
        self,
        prompt: str,
        system_prompt: str,
        schema_description: str,
        max_tokens: int = 500,
        temperature: float = 0.1,
    ) -> dict[str, object]:
        """Generate structured JSON output."""
        ...
```

**Validation**:
```bash
# Verify Protocol is usable
python -c "from brev_pipelines.types import LLMProvider; print('OK')"
```

---

### Step 3.4: Update Existing NIM Tests

**Action**: Modify
**File(s)**: `dagster/tests/unit/resources/test_nim.py` (if exists)

Ensure existing tests still pass and add Protocol compliance test.

```python
def test_nim_resource_implements_llm_provider_protocol() -> None:
    """Verify NIMLLMResource implements LLMProvider protocol."""
    from brev_pipelines.resources.nim import NIMLLMResource
    from brev_pipelines.types import LLMProvider

    # This should not raise - resource implements protocol
    resource = NIMLLMResource(endpoint="http://test:8000")
    assert isinstance(resource, LLMProvider)
```

**Validation**:
```bash
# Run all NIM tests
pytest tests/unit/resources/test_nim*.py -v --cov=brev_pipelines.resources.nim
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `dagster/tests/unit/resources/test_nim_json.py` | CREATE | generate_json tests (TDD) |
| `dagster/src/brev_pipelines/resources/nim.py` | MODIFY | Add generate_json methods |
| `dagster/src/brev_pipelines/types.py` | MODIFY | Add LLMProvider Protocol |
| `dagster/tests/unit/resources/test_nim.py` | MODIFY | Add Protocol test |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `NIM_REASONING_ENDPOINT` | `http://nvidia-nim-reasoning.nvidia-nim.svc.cluster.local:8000` | NIM endpoint |

### Secrets Required

None - NIM is local and doesn't require API key.

---

## Verification

### Pre-flight Checks

```bash
# Ensure Phase 2 is complete
pytest tests/unit/test_harmony*.py -v
# All should PASS
```

### Validation Commands

```bash
# Run all NIM tests
pytest tests/unit/resources/test_nim*.py -v --cov=brev_pipelines.resources.nim

# Type check
mypy src/brev_pipelines/resources/nim.py --strict

# Lint
ruff check src/brev_pipelines/resources/nim.py
```

### Expected Outcomes

- All `test_nim_json.py` tests pass
- generate_json() uses json_object format
- include_reasoning is set to false
- Harmony tokens are cleaned from responses
- 90%+ test coverage
- mypy strict mode passes

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Circular import with types.py | Import error | Use TYPE_CHECKING guard |
| requests not imported | NameError | Add import at top |
| TypeVar bound issue | mypy error | Ensure T = TypeVar("T", bound=BaseModel) |

### Rollback Plan

If this phase fails:
1. Revert changes to `nim.py`
2. Remove test file
3. Document issue in work-notes.md

---

## Completion Criteria

- [ ] Tests written BEFORE implementation (TDD)
- [ ] All 15+ tests pass
- [ ] generate_json() uses json_object (NOT json_schema)
- [ ] include_reasoning: false in all requests
- [ ] Harmony token cleanup working
- [ ] Protocol defined for mocking
- [ ] 90%+ test coverage
- [ ] mypy --strict passes
- [ ] Phase 2 tests still pass (no regressions)
