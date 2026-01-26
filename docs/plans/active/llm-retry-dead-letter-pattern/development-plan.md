# LLM Retry with Dead Letter Pattern - Development Plan

**Status**: In Progress
**Created**: 2026-01-26
**Branch**: `feature/llm-retry-dead-letter`
**Spec**: [spec.md](spec.md)
**Report**: [llm-retry-dead-letter-pattern.md](../../reports/llm-retry-dead-letter-pattern.md)

## Summary

Implement retry with exponential backoff and dead letter tracking for LLM calls in the Central Bank Speeches pipeline, ensuring transient failures are recovered and persistent failures are tracked for debugging and reprocessing.

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md`:

- **INV-P004**: Complete Type Annotations - All retry functions and result types must have complete type annotations
- **INV-P005**: No Any Types - Use TypedDict for result structures, not `dict[str, Any]`
- **INV-P006**: Modern Python 3.11+ Syntax - Use `list[str]`, `dict[str, int]`, `str | None`
- **INV-P007**: Pydantic v2 for Data Models - Use Pydantic v2 syntax for RetryConfig
- **INV-P010**: Test-Driven Development - Write tests BEFORE implementation
- **INV-P011**: No Bare Generics - Use `list[float]`, not `list`

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-P012**: LLM Calls Must Use Retry Wrapper - All LLM calls in assets must use `retry_with_backoff` for resilience
- **NEW INV-P013**: Dead Letter Columns in LLM Output - Assets producing LLM results must include `_llm_status`, `_llm_error`, `_llm_attempts`, `_llm_fallback_used` columns

## Current State Analysis

### Current LLM Error Handling

| Resource | Retry Logic | After Failure | Location |
|----------|-------------|---------------|----------|
| `NIMResource` | None | Returns `"LLM error: ..."` string | `nim.py` |
| `NIMEmbeddingResource` | 3 retries, exponential backoff | Mock embeddings fallback | `nim_embedding.py` |

**Problems:**
1. `speech_classification` silently falls back to neutral values with no visibility
2. `speech_summaries` checks for error string but has no retry logic
3. No tracking of which records failed or why
4. No way to selectively reprocess failed records

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `dagster/src/brev_pipelines/types.py` | Contains TypedDict definitions | Add `LLMCallResult`, `RetryConfig`, validation result types |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | Silent fallback on LLM errors | Use retry wrapper, add dead letter columns |

### Files to Create

| File | Purpose |
|------|---------|
| `dagster/src/brev_pipelines/resources/llm_retry.py` | Retry wrapper, backoff calculation, error types |
| `dagster/tests/unit/resources/test_llm_retry.py` | Unit tests for retry logic |

## Solution Design

```
┌─────────────────────────────────────────────────────────────────────┐
│                        LLM Call Flow                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Input Record                                                       │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────┐                                                    │
│  │  LLM Call   │◄──────────────────────────┐                        │
│  └─────────────┘                           │                        │
│       │                                    │                        │
│       ▼                                    │                        │
│  ┌─────────────┐    No     ┌───────────┐   │                        │
│  │  Success?   │──────────►│ Retry < 5 │───┘                        │
│  └─────────────┘           └───────────┘   Exponential Backoff      │
│       │ Yes                     │ No       (1s, 2s, 4s, 8s, 16s)    │
│       │                        ▼                                    │
│       │               ┌──────────────────┐                          │
│       │               │  Dead Letter     │                          │
│       │               │  - Record ID     │                          │
│       │               │  - Error message │                          │
│       │               │  - Attempt count │                          │
│       │               │  - Fallback used │                          │
│       │               └──────────────────┘                          │
│       │                        │                                    │
│       ▼                        ▼                                    │
│  ┌─────────────────────────────────────────┐                        │
│  │           Output DataFrame              │                        │
│  │  ┌─────────┬─────────┬─────────────┐    │                        │
│  │  │ data... │ _status │ _error      │    │                        │
│  │  ├─────────┼─────────┼─────────────┤    │                        │
│  │  │ values  │ success │ null        │    │                        │
│  │  │ fallbck │ failed  │ "Timeout"   │    │                        │
│  │  └─────────┴─────────┴─────────────┘    │                        │
│  └─────────────────────────────────────────┘                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **DataFrame columns for dead letter tracking**: Simpler than external queue, queryable, no infrastructure changes
2. **5 retries with exponential backoff**: Balances recovery rate vs. time spent retrying
3. **Jitter on backoff delays**: Prevents thundering herd when multiple records fail simultaneously
4. **Typed validation functions**: Ensure LLM responses match expected schema before processing
5. **Generic retry wrapper**: Reusable across `speech_classification` and `speech_summaries`

### Backoff Schedule

| Attempt | Delay | Cumulative Wait |
|---------|-------|-----------------|
| 1 | 0s (immediate) | 0s |
| 2 | 1s | 1s |
| 3 | 2s | 3s |
| 4 | 4s | 7s |
| 5 | 8s | 15s |
| **Max** | 16s | **31s total** |

With jitter (±20%) to prevent thundering herd.

## Phase Overview

| Phase | Description | Type | Deliverables |
|-------|-------------|------|--------------|
| 1 | Core Infrastructure | Application | `llm_retry.py`, validation functions, unit tests |
| 2 | Asset Updates | Application | Updated `speech_classification`, `speech_summaries` with retry |
| 3 | Observability | Application | Dagster metadata, failure logging |
| 4 | Operations | Application | Reprocessing job design, monitoring alerts (documentation) |

## Phase 1: Core Infrastructure

**Goal**: Create reusable retry wrapper with typed results and validation functions
**Type**: Application
**Detailed Plan**: [phases/phase-1.md](phases/phase-1.md)

### Deliverables

1. `dagster/src/brev_pipelines/resources/llm_retry.py` - Retry wrapper module
2. `dagster/src/brev_pipelines/types.py` additions - `LLMCallResult`, `RetryConfig`, `ClassificationResult`
3. `dagster/tests/unit/resources/test_llm_retry.py` - Unit tests

### Validation Approach

1. `pytest tests/unit/resources/test_llm_retry.py -v` passes
2. `mypy src/brev_pipelines/resources/llm_retry.py --strict` passes
3. `ruff check src/brev_pipelines/resources/llm_retry.py` passes

### Success Criteria

- [ ] `retry_with_backoff` function handles all retryable error types
- [ ] Backoff calculation with jitter works correctly
- [ ] Validation functions parse and validate LLM responses
- [ ] All code has complete type annotations
- [ ] 100% test coverage for retry logic

## Phase 2: Asset Updates

**Goal**: Update `speech_classification` and `speech_summaries` to use retry wrapper
**Type**: Application
**Detailed Plan**: [phases/phase-2.md](phases/phase-2.md)

### Deliverables

1. Updated `speech_classification` asset with retry logic
2. Updated `speech_summaries` asset with retry logic
3. Dead letter columns in output DataFrames
4. Integration tests for asset retry behavior

### Validation Approach

1. `pytest tests/unit/assets/test_central_bank_speeches.py -v` passes
2. Manual test with mock NIM failures
3. Verify output DataFrame has `_llm_*` columns

### Success Criteria

- [ ] `speech_classification` retries on transient failures
- [ ] `speech_summaries` retries on transient failures
- [ ] Output DataFrames include all 4 dead letter columns
- [ ] Fallback values are used after max retries exhausted
- [ ] Existing checkpoint functionality still works

## Phase 3: Observability

**Goal**: Add Dagster metadata and structured logging for failure visibility
**Type**: Application
**Detailed Plan**: [phases/phase-3.md](phases/phase-3.md)

### Deliverables

1. Dagster asset metadata with failure statistics
2. Structured logging with failure details
3. Example downstream asset filtering failed records

### Validation Approach

1. Run pipeline with simulated failures
2. Verify metadata visible in Dagster UI
3. Verify logs contain failure information

### Success Criteria

- [ ] Asset metadata shows `failed_count`, `success_rate`, `failure_breakdown`
- [ ] Asset metadata includes list of failed record IDs
- [ ] Logs show retry attempts and final failure reasons
- [ ] Downstream assets can filter by `_llm_status`

## Phase 4: Operations (Documentation)

**Goal**: Document reprocessing patterns and monitoring recommendations
**Type**: Application
**Detailed Plan**: [phases/phase-4.md](phases/phase-4.md)

### Deliverables

1. Documentation for selective reprocessing of failed records
2. Recommended monitoring alerts and thresholds
3. Circuit breaker pattern design (future enhancement)

### Validation Approach

1. Documentation review
2. Verify reprocessing workflow is documented

### Success Criteria

- [ ] Reprocessing workflow documented
- [ ] Alert thresholds defined (>5% failure rate = warning, >20% = critical)
- [ ] Circuit breaker design documented for future implementation

## Validation Strategy

### Application Validation

```bash
# Unit tests
pytest dagster/tests/unit/resources/test_llm_retry.py -v --cov

# Type checking
mypy dagster/src/brev_pipelines/resources/llm_retry.py --strict
mypy dagster/src/brev_pipelines/assets/central_bank_speeches.py --strict

# Linting
ruff check dagster/src/brev_pipelines/resources/llm_retry.py
ruff check dagster/src/brev_pipelines/assets/central_bank_speeches.py
```

### Integration Validation

```bash
# Run pipeline with test data
cd dagster && dagster dev

# Materialize speech_classification with mock failures
# Verify dead letter columns in output
```

## Documentation Updates

After implementation is complete:

- [ ] `docs/invariants/INVARIANTS.md` - Add INV-P012 (retry wrapper required), INV-P013 (dead letter columns)
- [ ] `dagster/.CLAUDE.md` - Update with retry pattern guidance
- [ ] `docs/reports/llm-retry-dead-letter-pattern.md` - Mark as implemented

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Pending | | | Core infrastructure |
| Phase 2 | Pending | | | Asset updates |
| Phase 3 | Pending | | | Observability |
| Phase 4 | Pending | | | Documentation only |
