# Feature: LLM Retry with Dead Letter Pattern

**Status**: Approved
**Created**: 2026-01-26
**Category**: Application
**Report**: [llm-retry-dead-letter-pattern.md](../../reports/llm-retry-dead-letter-pattern.md)

## Goal

Implement robust LLM failure handling with exponential backoff retries and dead letter tracking to ensure pipeline resilience when processing thousands of LLM calls.

## Background

When processing large datasets through LLM calls (e.g., 7,721 central bank speeches), failures are inevitable due to:
- Network timeouts
- Service unavailability
- Rate limiting
- Malformed LLM responses
- Validation failures (invalid JSON, missing fields)

**Current problems:**
1. **No retries** - Transient failures cause immediate fallback
2. **Silent failures** - Cannot distinguish good data from fallback data
3. **No failure tracking** - No visibility into which records failed or why
4. **Lost debugging info** - Error messages discarded after fallback
5. **No reprocessing path** - Failed records cannot be selectively reprocessed

**Proposed solution:**
- **Retry with exponential backoff** for transient failures
- **Dead letter pattern** via DataFrame columns for failure tracking
- **Validation functions** with typed responses
- **Observability** through Dagster metadata and logging

## Acceptance Criteria

- [ ] AC1: LLM calls automatically retry up to 5 times with exponential backoff (1s, 2s, 4s, 8s, 16s)
- [ ] AC2: Failed records use fallback values and continue processing (pipeline doesn't fail)
- [ ] AC3: Output DataFrames include `_llm_status`, `_llm_error`, `_llm_attempts`, `_llm_fallback_used` columns
- [ ] AC4: Dagster asset metadata shows failure counts, rates, and affected record IDs
- [ ] AC5: Validation functions parse and validate LLM responses with typed outputs
- [ ] AC6: All new code has complete type annotations (INV-P004) and unit tests (INV-P010)
- [ ] AC7: Downstream assets can filter by `_llm_status` to use only successful classifications

## Technical Requirements

### Infrastructure Changes (Terraform)
- None required

### Kubernetes Changes (Helm)
- None required

### Application Changes

**New files:**
- `dagster/src/brev_pipelines/resources/llm_retry.py` - Retry wrapper and result types
- `dagster/tests/unit/resources/test_llm_retry.py` - Unit tests for retry logic

**Modified files:**
- `dagster/src/brev_pipelines/assets/central_bank_speeches.py` - Update `speech_classification` and `speech_summaries` assets
- `dagster/src/brev_pipelines/types.py` - Add `LLMCallResult`, `RetryConfig`, validation types

### GitOps Changes
- None required

## Dependencies

- Existing `NIMResource` for LLM calls
- Existing `LLMCheckpointManager` for checkpointing (unchanged)
- Existing `process_with_checkpoint` function (unchanged)

## Out of Scope

- External dead letter queue (Redis, SQS) - using DataFrame columns instead
- Circuit breaker pattern - future enhancement
- Async/concurrent retries - using synchronous processing
- Automatic reprocessing job - documented but not implemented in Phase 4

## Security Considerations

- No secret management changes required
- No network policy changes required
- No RBAC changes required

## Resource Requirements

- No additional GPU requirements
- No additional memory/CPU requirements
- Slightly larger output DataFrames due to metadata columns (~0.1% increase)

## Open Questions

- [x] Q1: Should we use in-DataFrame dead letter columns or external queue? **Resolved: DataFrame columns for simplicity**
- [x] Q2: Maximum retry count and backoff schedule? **Resolved: 5 retries, 1/2/4/8/16s backoff**
- [ ] Q3: Should circuit breaker be implemented in Phase 4? **Deferred to future enhancement**
