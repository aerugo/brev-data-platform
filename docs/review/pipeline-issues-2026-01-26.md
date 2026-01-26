# Pipeline Review Issues - 2026-01-26

## Summary

Comprehensive review of all pipeline components, assets, IO managers, resources, and jobs.
This document catalogs issues discovered during the review for prioritization and resolution.

## Issue Severity Levels

- **CRITICAL**: Prevents pipeline from functioning correctly
- **HIGH**: Significant risk of failures or data quality issues
- **MEDIUM**: Code quality, maintainability, or minor reliability concerns
- **LOW**: Style, minor improvements, or future considerations

---

## 1. Central Bank Speeches Pipeline

### Fixed Issues

| ID | Severity | Issue | Resolution |
|----|----------|-------|------------|
| CBS-001 | CRITICAL | Dead letter columns (`_llm_status`, `_llm_error`, etc.) were not propagated to `enriched_speeches` | Fixed: Columns now propagated with suffixes (`_llm_status_class`, `_llm_status_summary`) |
| CBS-002 | HIGH | `classification_snapshot` and `summaries_snapshot` excluded dead letter columns | Fixed: Columns now included in snapshots |

### Outstanding Issues

None identified - pipeline is working correctly after fixes.

---

## 2. Synthetic Speeches Pipeline

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| SYN-001 | HIGH | Dead letter columns from input data not validated | `enriched_data_for_synthesis` | Should check for `_llm_status` columns and filter/warn on failed records |
| SYN-002 | HIGH | No retry logic for Safe Synthesizer API calls | `safe_synth_model`, `synthetic_summaries` | Should use similar retry pattern as LLM calls |
| SYN-003 | MEDIUM | KAI scheduler logic has incomplete fallback path | `safe_synth_model` | Scheduler name branching could fail silently |
| SYN-004 | LOW | `synthesize_batch()` doesn't validate input DataFrame structure | `synthetic_summaries` | Could fail with unclear error if columns missing |

---

## 3. Demo Pipeline

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| DEMO-001 | MEDIUM | No error handling on NIM `chat_completion` calls | `demo_query_nim` | Network errors will crash the asset |
| DEMO-002 | MEDIUM | No error handling on MinIO operations | `demo_minio_read` | MinIO failures will crash the asset |
| DEMO-003 | LOW | Returns raw string responses without validation | `demo_query_nim` | Could return error strings as valid output |

---

## 4. Validation/Health Assets

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| VAL-001 | HIGH | Weaviate validation completely missing | `validate_platform` | Platform validation skips Weaviate entirely |
| VAL-002 | HIGH | NIM health check has no exception handling | `health.py:nim_health` | Network errors will crash health checks |
| VAL-003 | MEDIUM | LakeFS validation catches generic `Exception` | `validation.py` | Could hide specific errors |
| VAL-004 | LOW | Validation assets don't return structured results | Multiple | Return dicts instead of TypedDicts |

---

## 5. Resources

### NIMResource

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| NIM-001 | HIGH | `chat_completion` returns error strings instead of raising exceptions | `nim.py:chat_completion` | Inconsistent error handling - callers must check for error strings |
| NIM-002 | MEDIUM | Different error handling pattern between `chat_completion` and `embed_texts` | `nim.py` | Inconsistent API |
| NIM-003 | MEDIUM | Timeout not configurable per-call | `nim.py` | Only set at resource level |

### NIMEmbeddingResource

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| NIME-001 | LOW | No timeout configuration, inherits defaults | `nim_embedding.py` | Should match NIMResource pattern |

### WeaviateResource

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| WEAV-001 | MEDIUM | No error handling on connection failures | `weaviate.py` | Connection errors propagate uncaught |
| WEAV-002 | LOW | No connection health check method | `weaviate.py` | Unlike MinIO/LakeFS which have health checks |

### LakeFSResource

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| LAKE-001 | MEDIUM | Returns `None` on failure vs raising exceptions | `lakefs.py` | Inconsistent with other resources |
| LAKE-002 | LOW | No explicit connection validation | `lakefs.py` | Could fail late during operations |

### SafeSynthesizerResource

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| SAFE-001 | MEDIUM | Complex error paths with mixed None/raise patterns | `safe_synth.py` | Hard to predict failure behavior |
| SAFE-002 | MEDIUM | Job wait polling has no exponential backoff | `safe_synth.py` | Fixed interval polling |

---

## 6. IO Managers

### LakeFSPolarsIOManager

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| LFIO-001 | LOW | Import inside method | `lakefs_polars.py:78` | `from lakefs_sdk.models import CommitCreation` should be at module level |
| LFIO-002 | MEDIUM | `allow_empty=False` could cause commit failures | `lakefs_polars.py:93` | If data unchanged, commit will fail |

### MinIOPolarsIOManager

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| MPIO-001 | LOW | No error handling on `get_object` | `minio_polars.py:91` | Will raise if file doesn't exist |

### WeaviateIOManager

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| WVIO-001 | LOW | `load_input` returns count instead of data | `weaviate_io.py:102` | Unusual pattern, but documented |

### LLMCheckpointManager

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| CKPT-001 | MEDIUM | Uses `dict[str, Any]` | `checkpoint.py:64,100,174` | Violates INV-P005 (no Any types) |
| CKPT-002 | MEDIUM | Bare `except Exception` hides errors | `checkpoint.py:96` | Could mask real issues |
| CKPT-003 | LOW | Recursive load pattern inefficient | `checkpoint.py:121` | `_flush_checkpoint` calls `load()` |

---

## 7. Jobs and Definitions

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| DEF-001 | LOW | Mixed `os.getenv()` and `EnvVar()` usage | `definitions.py` | Inconsistent environment variable handling |
| DEF-002 | LOW | Jobs use "ops" in config for assets | `jobs.py` | Works but potentially confusing terminology |

---

## 8. Type System (types.py)

| ID | Severity | Issue | Location | Notes |
|----|----------|-------|----------|-------|
| TYPE-001 | LOW | Some Protocol types use `object` for unknown types | `types.py:313,389` | Could be more specific |

---

## Priority Matrix

### Critical (Fix Immediately)

None remaining - CBS-001 and CBS-002 were fixed.

### High Priority (Fix Soon)

1. **SYN-001**: Dead letter column validation in synthesis pipeline
2. **SYN-002**: Retry logic for Safe Synthesizer
3. **VAL-001**: Add Weaviate validation
4. **VAL-002**: Add exception handling to NIM health check
5. **NIM-001**: Make NIMResource raise exceptions consistently

### Medium Priority (Fix When Convenient)

1. **CKPT-001**: Replace `dict[str, Any]` with TypedDict
2. **LFIO-002**: Handle empty commit case
3. **NIM-002/NIM-003**: Standardize NIM error handling

### Low Priority (Tech Debt)

All other issues marked LOW.

---

## Recommendations

### Immediate Actions

1. **Add Weaviate validation** to `validate_platform` asset
2. **Add exception handling** to `nim_health` in health.py
3. **Review NIMResource error handling** - decide on raise vs return pattern

### Short-term Improvements

1. Create retry wrapper for Safe Synthesizer (similar to LLM retry)
2. Validate dead letter columns in synthesis pipeline
3. Standardize error handling across all resources

### Long-term Considerations

1. Consider implementing circuit breaker pattern (design doc exists)
2. Add comprehensive monitoring sensors (design doc exists)
3. Create integration tests for full pipeline flows

---

## Test Coverage Notes

- CBS pipeline: 54 tests passing, good coverage
- Synthesis pipeline: Basic coverage, needs dead letter tests
- Demo pipeline: Minimal testing
- Validation assets: Basic coverage
- Resources: Unit tests exist but integration tests needed
- IO Managers: Basic coverage

---

## Review Metadata

- **Date**: 2026-01-26
- **Reviewer**: Claude (AI Assistant)
- **Scope**: Full systematic review of all pipeline components
- **Total Issues Found**: 33
  - Critical: 2 (fixed)
  - High: 5
  - Medium: 14
  - Low: 12
