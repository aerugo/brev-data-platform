# Pipeline Reliability Fixes - Development Plan

**Status**: Pending
**Created**: 2026-01-26
**Branch**: `feature/pipeline-reliability-fixes`
**Source**: [Pipeline Review Issues](../../review/pipeline-issues-2026-01-26.md)

## Summary

Address 31 outstanding issues identified in the comprehensive pipeline review, focusing on error handling consistency, missing validation, retry logic gaps, and type system compliance.

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md`:

- **INV-P004**: Complete Type Annotations - All new/modified code must have complete type annotations
- **INV-P005**: No Any Types - Replace `dict[str, Any]` with TypedDict definitions
- **INV-P006**: Modern Python 3.11+ Syntax - Use modern union syntax, generic subscripts
- **INV-P010**: Test-Driven Development - Write tests BEFORE implementation
- **INV-P012**: LLM Calls Must Use Retry Wrapper - Extend to Safe Synthesizer calls
- **INV-P013**: Dead Letter Columns in LLM Output - Validate these in downstream assets

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-P014**: Resources Must Raise Exceptions on Failure - No returning error strings or None; raise typed exceptions
- **NEW INV-P015**: All External Service Calls Must Have Error Handling - Network calls must catch and handle exceptions appropriately

## Current State Analysis

### Issue Summary by Severity

| Severity | Count | Description |
|----------|-------|-------------|
| High | 5 | Critical gaps in error handling and validation |
| Medium | 14 | Inconsistent patterns, type violations |
| Low | 12 | Tech debt, style improvements |

### Key Problem Areas

1. **Validation Gaps**: Weaviate validation missing, NIM health check unprotected
2. **Inconsistent Error Handling**: Resources return errors differently (strings, None, exceptions)
3. **Synthesis Pipeline**: No retry logic, doesn't validate input dead letter columns
4. **Type System**: `dict[str, Any]` usage violates INV-P005
5. **Demo/Minor Assets**: No error handling on external calls

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `dagster/src/brev_pipelines/assets/validation.py` | Missing Weaviate | Add Weaviate validation |
| `dagster/src/brev_pipelines/assets/health.py` | No exception handling | Add try/except to NIM health |
| `dagster/src/brev_pipelines/resources/nim.py` | Returns error strings | Raise exceptions |
| `dagster/src/brev_pipelines/resources/lakefs.py` | Returns None on error | Raise exceptions |
| `dagster/src/brev_pipelines/resources/safe_synth.py` | Mixed error patterns | Standardize exceptions |
| `dagster/src/brev_pipelines/assets/synthetic_speeches.py` | No retry, no validation | Add retry wrapper, validate input |
| `dagster/src/brev_pipelines/io_managers/checkpoint.py` | Uses `dict[str, Any]` | Use TypedDict |

### Files to Create

| File | Purpose |
|------|---------|
| `dagster/src/brev_pipelines/resources/safe_synth_retry.py` | Retry wrapper for Safe Synthesizer |
| `dagster/tests/unit/assets/test_validation_weaviate.py` | Tests for Weaviate validation |
| `dagster/tests/unit/resources/test_safe_synth_retry.py` | Tests for Safe Synth retry |

## Solution Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Error Handling Standardization                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Current State (Inconsistent)           Target State (Consistent)            │
│  ─────────────────────────────          ────────────────────────            │
│                                                                              │
│  NIMResource:                           All Resources:                       │
│    Returns "LLM error: ..."             Raise typed exceptions               │
│                                           │                                  │
│  LakeFSResource:                          ▼                                  │
│    Returns None                         ┌────────────────────┐               │
│                                         │  ServiceError      │               │
│  SafeSynthResource:                     │  ├─ NIMError       │               │
│    Mixed (raise/return)                 │  ├─ LakeFSError    │               │
│                                         │  ├─ WeaviateError  │               │
│                                         │  └─ SafeSynthError │               │
│                                         └────────────────────┘               │
│                                                   │                          │
│                                                   ▼                          │
│                                         Assets catch & handle                │
│                                         with retry or fallback               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Exceptions over return values**: Resources raise typed exceptions, callers handle them
2. **Retry wrapper for Safe Synth**: Similar pattern to LLM retry wrapper
3. **Input validation for synthesis**: Check dead letter columns, warn on failed records
4. **Incremental fixes**: Each phase is independently deployable

## Phase Overview

| Phase | Description | Type | Deliverables | Issues Addressed |
|-------|-------------|------|--------------|------------------|
| 1 | Critical Error Handling | Application | Weaviate validation, NIM health fix, NIM exceptions | VAL-001, VAL-002, NIM-001 |
| 2 | Synthesis Pipeline Hardening | Application | Retry wrapper, input validation | SYN-001, SYN-002 |
| 3 | Resource Consistency | Application | Standardized exceptions across resources | NIM-002, LAKE-001, SAFE-001 |
| 4 | Type System & IO Manager Fixes | Application | TypedDict replacements, IO manager fixes | CKPT-001, LFIO-002 |
| 5 | Tech Debt Cleanup | Application | Demo fixes, minor improvements | DEMO-*, LOW priority |

## Phase 1: Critical Error Handling

**Goal**: Fix the highest-impact error handling gaps that could cause production failures
**Type**: Application
**Detailed Plan**: [phases/phase-1.md](phases/phase-1.md)

### Deliverables

1. Weaviate validation in `validate_platform` asset
2. Exception handling in `nim_health` asset
3. NIMResource raises exceptions instead of returning error strings
4. Unit tests for all changes

### Validation Approach

1. `pytest tests/unit/assets/test_validation*.py -v` passes
2. `pytest tests/unit/assets/test_health.py -v` passes
3. All 54 existing tests still pass

### Success Criteria

- [ ] `validate_platform` includes Weaviate validation
- [ ] `nim_health` handles network errors gracefully
- [ ] `NIMResource.chat_completion` raises `NIMError` on failure
- [ ] Callers of NIMResource updated to catch exceptions
- [ ] Tests cover error scenarios

## Phase 2: Synthesis Pipeline Hardening

**Goal**: Add retry logic and input validation to synthesis pipeline
**Type**: Application
**Detailed Plan**: [phases/phase-2.md](phases/phase-2.md)

### Deliverables

1. `safe_synth_retry.py` - Retry wrapper for Safe Synthesizer API calls
2. Input validation in `enriched_data_for_synthesis` for dead letter columns
3. Retry logic in `safe_synth_model` and `synthetic_summaries`
4. Unit tests for retry logic

### Validation Approach

1. `pytest tests/unit/resources/test_safe_synth_retry.py -v` passes
2. `pytest tests/unit/assets/test_synthetic*.py -v` passes
3. Manual test with simulated Safe Synth failures

### Success Criteria

- [ ] Safe Synthesizer calls retry on transient failures
- [ ] `enriched_data_for_synthesis` validates input data quality
- [ ] Warning logged when input contains failed LLM records
- [ ] Tests cover retry scenarios and input validation

## Phase 3: Resource Consistency

**Goal**: Standardize error handling across all resources
**Type**: Application
**Detailed Plan**: [phases/phase-3.md](phases/phase-3.md)

### Deliverables

1. `LakeFSResource` raises exceptions instead of returning None
2. `SafeSynthesizerResource` consistent exception patterns
3. `WeaviateResource` connection error handling
4. Updated callers to handle new exception patterns
5. Unit tests for error scenarios

### Validation Approach

1. `pytest tests/unit/resources/` passes
2. All asset tests still pass
3. Integration test with simulated failures

### Success Criteria

- [ ] All resources raise typed exceptions on failure
- [ ] No resource methods return None or error strings on failure
- [ ] All asset code handles resource exceptions appropriately
- [ ] Error messages are informative for debugging

## Phase 4: Type System & IO Manager Fixes

**Goal**: Fix type system violations and IO manager issues
**Type**: Application
**Detailed Plan**: [phases/phase-4.md](phases/phase-4.md)

### Deliverables

1. TypedDict for checkpoint manager result types
2. LakeFSPolarsIOManager empty commit handling
3. Module-level imports in IO managers
4. Unit tests for edge cases

### Validation Approach

1. `mypy dagster/src/brev_pipelines/ --strict` passes
2. `pytest tests/unit/io_managers/` passes
3. No `dict[str, Any]` in checkpoint.py

### Success Criteria

- [ ] `LLMCheckpointManager` uses TypedDict, not `dict[str, Any]`
- [ ] `LakeFSPolarsIOManager` handles unchanged data gracefully
- [ ] All imports at module level
- [ ] mypy strict mode passes

## Phase 5: Tech Debt Cleanup

**Goal**: Address remaining low-priority issues
**Type**: Application
**Detailed Plan**: [phases/phase-5.md](phases/phase-5.md)

### Deliverables

1. Demo pipeline error handling
2. Consistent environment variable handling in definitions.py
3. Minor improvements across codebase

### Validation Approach

1. All tests pass
2. Linting passes
3. Code review

### Success Criteria

- [ ] Demo assets handle errors gracefully
- [ ] Consistent use of EnvVar vs os.getenv
- [ ] All LOW priority issues addressed

## Validation Strategy

### Application Validation

```bash
# Full test suite
cd dagster && uv run pytest tests/ -v

# Type checking
uv run mypy src/brev_pipelines/ --strict

# Linting
uv run ruff check src/brev_pipelines/
uv run ruff format --check src/brev_pipelines/
```

### Integration Validation

```bash
# Run Dagster locally
cd dagster && dagster dev

# Test validation assets
# Test health assets
# Test synthesis pipeline with simulated failures
```

## Documentation Updates

After implementation is complete:

- [ ] `docs/invariants/INVARIANTS.md` - Add INV-P014 (exceptions required), INV-P015 (error handling required)
- [ ] `docs/review/pipeline-issues-2026-01-26.md` - Mark issues as resolved
- [ ] Resource docstrings - Document exception behavior

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Completed | 2026-01-26 | 2026-01-26 | Critical error handling |
| Phase 2 | Completed | 2026-01-26 | 2026-01-26 | Synthesis hardening |
| Phase 3 | Completed | 2026-01-26 | 2026-01-26 | Resource consistency |
| Phase 4 | Completed | 2026-01-26 | 2026-01-26 | Type system fixes |
| Phase 5 | Pending | | | Tech debt cleanup |

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Breaking existing callers when switching to exceptions | Medium | High | Update all callers in same PR, comprehensive tests |
| Safe Synth retry adds latency | Low | Low | Configurable retry limits |
| Type changes break runtime | Low | Medium | Maintain backwards compatibility where needed |

## Dependencies

- Phase 1 should be completed before Phase 3 (NIM changes used by other resources)
- Phase 2 can proceed independently
- Phase 4 can proceed independently
- Phase 5 depends on Phases 1-4
