# GPT-OSS Structured Output Fix - Development Plan

**Status**: In Progress
**Created**: 2026-01-27
**Branch**: `claude/fix-gpt-oss-output-JotGH`
**Spec**: [spec.md](spec.md)

## Summary

Fix GPT-OSS-120B NIM integration to properly handle reasoning tokens and structured JSON output by using `json_object` mode and client-side Harmony token cleanup.

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md`:

- **INV-I006**: Local-Only Infrastructure - All LLM calls must use local NIM, never cloud APIs
- **INV-P004**: Complete Type Annotations - All new functions must have complete type annotations
- **INV-P005**: No `Any` Types - Use TypedDict and Pydantic models instead
- **INV-P007**: Pydantic v2 for Data Models - Response validation must use Pydantic v2
- **INV-P008**: PydanticAI for LLM Processing - Consider PydanticAI for structured outputs
- **INV-P009**: Composition Over Inheritance - Use Protocol-based design
- **INV-P010**: Test-Driven Development - Write tests BEFORE implementation
- **INV-N005**: NIM Observability Enabled - Maintain logging and metrics

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-N010**: GPT-OSS JSON Mode Required - GPT-OSS-120B must use `json_object` response format, never `json_schema` strict mode (due to vLLM bug #23120)
- **NEW INV-N011**: GPT-OSS Reasoning Suppression - GPT-OSS-120B calls must include `include_reasoning: false` to prevent reasoning token leakage

## Current State Analysis

### The Problem

1. **Reasoning in Content**: GPT-OSS outputs reasoning (chain-of-thought) to the `analysis` channel and final response to the `final` channel. The NIM parser sometimes fails to separate these, causing reasoning text to appear in the main response content.

2. **Malformed JSON**: When using `response_format: { type: "json_schema" }`, vLLM's structured generation conflicts with the reasoning parser state machine, producing whitespace-filled malformed JSON.

### Root Causes

| Issue | Root Cause | Evidence |
|-------|------------|----------|
| Reasoning leakage | Harmony parser bug | NVIDIA forum post, `<\|return\|>` in content |
| JSON malformation | vLLM bug #23120 | Structured output fails with reasoning models |

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `dagster/src/brev_pipelines/resources/nim.py` | Basic generate() method | Add generate_json() with Harmony cleanup |
| `dagster/src/brev_pipelines/types.py` | Missing NIM types | Add NIM request/response TypedDicts |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | Uses raw LLM response | Use generate_json() with validation |

### Files to Create

| File | Purpose |
|------|---------|
| `dagster/tests/unit/resources/test_nim_json.py` | Unit tests for JSON generation |
| `dagster/tests/unit/test_harmony_parser.py` | Unit tests for Harmony token cleanup |
| `dagster/tests/integration/test_classification_pipeline.py` | E2E classification test |

## Solution Design

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Fixed LLM Call Flow                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Asset Code                                                              │
│      │                                                                   │
│      ▼                                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  nim_resource.generate_json(                                      │   │
│  │      prompt="Classify this speech...",                           │   │
│  │      system_prompt="You are a classifier...",                    │   │
│  │      schema_description="Return JSON with monetary_stance...",   │   │
│  │      response_model=SpeechClassificationResult,                  │   │
│  │  )                                                               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│      │                                                                   │
│      ▼                                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  NIM API Call                                                     │   │
│  │  {                                                                │   │
│  │    "model": "openai/gpt-oss-120b",                               │   │
│  │    "messages": [...],                                            │   │
│  │    "response_format": {"type": "json_object"},  ◄── NOT schema   │   │
│  │    "include_reasoning": false,                   ◄── Suppress CoT│   │
│  │  }                                                                │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│      │                                                                   │
│      ▼                                                                   │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Response Processing                                              │   │
│  │  1. Extract content from response                                │   │
│  │  2. Remove Harmony tokens: <|return|>, <|channel|>, etc.         │   │
│  │  3. Parse JSON from content                                      │   │
│  │  4. Validate with Pydantic model                                 │   │
│  │  5. Return typed result                                          │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│      │                                                                   │
│      ▼                                                                   │
│  SpeechClassificationResult (Pydantic model, fully typed)               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Use `json_object` over `json_schema`**: The strict schema mode is broken with GPT-OSS reasoning models. JSON object mode works reliably.

2. **Schema in prompt, not API**: Since we can't use json_schema, we embed the schema description in the system prompt and validate with Pydantic client-side.

3. **Suppress reasoning by default**: Use `include_reasoning: false` to prevent reasoning tokens in the response. Reasoning is still generated internally but not returned.

4. **Client-side Harmony cleanup**: Even with reasoning suppressed, add defensive regex cleanup for any residual Harmony control tokens.

5. **Protocol-based design**: Use `LLMProvider` Protocol so the resource can be mocked in tests.

## Phase Overview

| Phase | Description | Type | Deliverables |
|-------|-------------|------|--------------|
| 1 | Type Definitions & Test Fixtures | Application | TypedDict definitions, mock fixtures |
| 2 | Harmony Parser & Validation | Application | Parser function, Pydantic models, unit tests |
| 3 | NIM Resource Enhancement | Application | generate_json() method, unit tests |
| 4 | Asset Integration | Application | Updated assets, integration tests |

## Phase 1: Type Definitions & Test Fixtures

**Goal**: Create type definitions and test infrastructure following TDD
**Type**: Application
**Detailed Plan**: [phases/phase-1.md](phases/phase-1.md)

### Deliverables

1. NIM request/response TypedDicts in `types.py`
2. Test fixtures for mocked NIM responses in `conftest.py`
3. Harmony token test cases

### Validation Approach

1. `python -c "from brev_pipelines.types import *"` succeeds
2. `mypy src/brev_pipelines/types.py --strict` passes
3. `pytest tests/` discovers new fixtures

### Success Criteria

- [ ] All TypedDicts have complete type annotations
- [ ] No `Any` types used
- [ ] Test fixtures provide realistic mock data
- [ ] mypy strict mode passes

## Phase 2: Harmony Parser & Validation

**Goal**: Create Harmony token cleanup and response validation with tests first
**Type**: Application
**Detailed Plan**: [phases/phase-2.md](phases/phase-2.md)

### Deliverables

1. `extract_json_from_harmony()` function
2. `SpeechClassificationResult` Pydantic model
3. Unit tests with 100% coverage

### Validation Approach

1. Write failing tests first
2. Implement functions to pass tests
3. `pytest tests/unit/test_harmony_parser.py -v` passes
4. `mypy` strict mode passes

### Success Criteria

- [ ] Tests written before implementation
- [ ] All Harmony control tokens handled
- [ ] Pydantic validation catches malformed responses
- [ ] 100% test coverage on parser functions

## Phase 3: NIM Resource Enhancement

**Goal**: Add `generate_json()` method to NIM resource with comprehensive tests
**Type**: Application
**Detailed Plan**: [phases/phase-3.md](phases/phase-3.md)

### Deliverables

1. `generate_json()` method on NIM resource
2. Protocol-based typing for dependency injection
3. Comprehensive unit tests with mocked HTTP calls

### Validation Approach

1. Write failing tests for generate_json()
2. Implement method to pass tests
3. `pytest tests/unit/resources/test_nim_json.py -v` passes
4. `mypy src/brev_pipelines/resources/nim.py --strict` passes

### Success Criteria

- [ ] Tests written before implementation
- [ ] All external HTTP calls mocked
- [ ] Error handling tested
- [ ] Retry logic tested
- [ ] 90%+ coverage

## Phase 4: Asset Integration

**Goal**: Update assets to use new NIM methods with integration tests
**Type**: Application
**Detailed Plan**: [phases/phase-4.md](phases/phase-4.md)

### Deliverables

1. Updated `speech_classification` asset
2. Updated `speech_summaries` asset
3. Integration test for classification pipeline

### Validation Approach

1. Write failing integration tests
2. Update assets to pass tests
3. `pytest tests/integration/` passes
4. Full test suite passes

### Success Criteria

- [ ] Assets use generate_json() method
- [ ] Fallback handling works correctly
- [ ] Integration tests pass with mocks
- [ ] No regressions in existing tests

## Validation Strategy

### Test-Driven Development Workflow

For each function/method:

```bash
# 1. Write the test (RED)
# tests/unit/test_harmony_parser.py
def test_extract_json_removes_return_token():
    raw = '{"key": "value"}<|return|>'
    result = extract_json_from_harmony(raw)
    assert result == {"key": "value"}

# 2. Run test - should FAIL
pytest tests/unit/test_harmony_parser.py::test_extract_json_removes_return_token -v
# Expected: FAILED (function doesn't exist)

# 3. Write minimal implementation (GREEN)
# src/brev_pipelines/utils/harmony.py
def extract_json_from_harmony(content: str) -> dict[str, Any]:
    content = re.sub(r'<\|[^|]+\|>', '', content)
    return json.loads(content)

# 4. Run test - should PASS
pytest tests/unit/test_harmony_parser.py::test_extract_json_removes_return_token -v
# Expected: PASSED

# 5. Refactor while keeping tests green
# 6. Add more tests for edge cases
```

### Application Validation

```bash
# Type checking
mypy src/brev_pipelines/ --strict
pyright src/brev_pipelines/

# Linting
ruff check src/brev_pipelines/
ruff format src/brev_pipelines/ --check

# Unit tests
pytest tests/unit/ -v --cov=brev_pipelines --cov-report=term-missing

# Integration tests
pytest tests/integration/ -v
```

### Pre-Commit Checklist

```bash
# Run all validation
cd dagster
ruff check src/ && \
ruff format src/ --check && \
mypy src/brev_pipelines/ --strict && \
pytest tests/ -v --cov=brev_pipelines
```

## Documentation Updates

After implementation is complete:

- [ ] `docs/invariants/INVARIANTS.md` - Add INV-N010 and INV-N011
- [ ] `docs/reports/gpt-oss-reasoning-structured-output.md` - Mark as implemented
- [ ] `dagster/.CLAUDE.md` - Update if patterns changed

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Pending | | | Type definitions & fixtures |
| Phase 2 | Pending | | | Harmony parser |
| Phase 3 | Pending | | | NIM resource |
| Phase 4 | Pending | | | Asset integration |

## References

- [GPT-OSS Research Report](../../reports/gpt-oss-reasoning-structured-output.md)
- [INVARIANTS.md](../../invariants/INVARIANTS.md)
- [OpenAI Harmony Format](https://cookbook.openai.com/articles/openai-harmony)
- [vLLM Bug #23120](https://github.com/vllm-project/vllm/issues/23120)
- [dagster-strict-typing-tdd-refactor.md](../dagster-strict-typing-tdd-refactor.md) - TDD patterns
