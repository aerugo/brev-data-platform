# LLM Failure Handling: Retry with Exponential Backoff and Dead Letter Pattern

**Date:** 2026-01-25
**Context:** Central Bank Speeches Pipeline (7,721 records, thousands of LLM calls)
**Status:** Design Proposal

## Executive Summary

When processing thousands of LLM calls in a data pipeline, failures are inevitable due to:
- Network timeouts
- Service unavailability
- Rate limiting
- Malformed responses
- Validation failures (e.g., invalid JSON)

This report proposes a **retry with exponential backoff** mechanism combined with a **dead letter pattern** for handling failures after max retries. This approach ensures:

1. **Transient failures are recovered** via automatic retries
2. **Persistent failures don't block the pipeline** - processing continues
3. **Failed records are tracked** for debugging and reprocessing
4. **Pipeline completes with partial success** rather than total failure

---

## 1. Current State Analysis

### LLM Resources

| Resource | Retry Logic | After Failure | Location |
|----------|-------------|---------------|----------|
| `NIMResource` | None | Returns `"LLM error: ..."` string | [nim.py](dagster/src/brev_pipelines/resources/nim.py) |
| `NIMEmbeddingResource` | 3 retries, exponential backoff | Mock embeddings fallback | [nim_embedding.py](dagster/src/brev_pipelines/resources/nim_embedding.py) |

### Current Error Handling in Assets

**speech_classification** ([central_bank_speeches.py:462-473](dagster/src/brev_pipelines/assets/central_bank_speeches.py#L462-L473)):
```python
# Current approach: silent fallback to neutral values
monetary, trade, tariff, outlook = 3, 3, 0, 3  # Neutral defaults
try:
    json_match = re.search(r"\{[^}]+\}", response)
    if json_match:
        result = json.loads(json_match.group())
        monetary = MONETARY_STANCE_SCALE.get(result.get("monetary_stance", "neutral"), 3)
        # ... similar for other fields
except Exception:
    pass  # Keep defaults - no visibility into failure
```

**speech_summaries** ([central_bank_speeches.py:616-623](dagster/src/brev_pipelines/assets/central_bank_speeches.py#L616-L623)):
```python
summary = nim_reasoning.generate(prompt, max_tokens=400, temperature=0.2)

# Check for LLM error string
if summary.startswith("LLM error:"):
    summary = f"• Topic: {title[:100]}\n• Speaker: {speaker}\n• Bank: {central_bank}"
```

### Problems with Current Approach

| Issue | Impact |
|-------|--------|
| **No retries** | Transient failures (timeouts, rate limits) cause immediate fallback |
| **Silent failures** | Can't distinguish good data from fallback data |
| **No failure tracking** | No way to identify which records failed or why |
| **Lost debugging info** | Error messages discarded after fallback |
| **No reprocessing path** | Failed records can't be selectively reprocessed |

---

## 2. Proposed Solution: Retry + Dead Letter Pattern

### Architecture Overview

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

### Key Components

#### 2.1 Retry Configuration

```python
@dataclass
class RetryConfig:
    """Configuration for LLM call retries."""
    max_retries: int = 5
    base_delay: float = 1.0  # seconds
    max_delay: float = 60.0  # cap on backoff
    exponential_base: float = 2.0

    # Retryable error conditions
    retry_on_timeout: bool = True
    retry_on_rate_limit: bool = True
    retry_on_server_error: bool = True  # 5xx errors
    retry_on_validation_failure: bool = True
```

#### 2.2 Backoff Schedule

| Attempt | Delay | Cumulative Wait |
|---------|-------|-----------------|
| 1 | 0s (immediate) | 0s |
| 2 | 1s | 1s |
| 3 | 2s | 3s |
| 4 | 4s | 7s |
| 5 | 8s | 15s |
| **Max** | 16s | **31s total** |

With jitter (±20%) to prevent thundering herd.

#### 2.3 Dead Letter Record Structure

```python
@dataclass
class LLMCallResult:
    """Result of an LLM call with full metadata."""
    record_id: str
    status: Literal["success", "failed"]

    # On success
    response: str | None = None
    parsed_data: dict | None = None

    # On failure
    error_type: str | None = None  # "timeout", "rate_limit", "validation", "server_error"
    error_message: str | None = None
    attempts: int = 0

    # Always present
    fallback_used: bool = False
    fallback_values: dict | None = None

    # Timing
    total_duration_ms: int = 0
```

---

## 3. Implementation Design

### 3.1 Retryable LLM Wrapper

Location: `dagster/src/brev_pipelines/resources/llm_retry.py` (new file)

```python
import time
import random
from dataclasses import dataclass, field
from typing import Callable, TypeVar, Generic
from pydantic import BaseModel
import requests

T = TypeVar("T")


class RetryableError(Exception):
    """Error that should trigger a retry."""
    pass


class ValidationError(RetryableError):
    """LLM response failed validation."""
    pass


class LLMTimeoutError(RetryableError):
    """LLM request timed out."""
    pass


class LLMRateLimitError(RetryableError):
    """LLM service returned rate limit error."""
    pass


class LLMServerError(RetryableError):
    """LLM service returned 5xx error."""
    pass


@dataclass
class RetryConfig:
    """Configuration for retry behavior."""
    max_retries: int = 5
    base_delay: float = 1.0
    max_delay: float = 60.0
    exponential_base: float = 2.0
    jitter: float = 0.2  # ±20% randomization


@dataclass
class LLMCallResult(Generic[T]):
    """Result of an LLM call with metadata."""
    record_id: str
    status: str  # "success" or "failed"

    # Success fields
    response: str | None = None
    parsed_data: T | None = None

    # Failure fields
    error_type: str | None = None
    error_message: str | None = None
    attempts: int = 0

    # Fallback info
    fallback_used: bool = False
    fallback_values: T | None = None

    # Timing
    duration_ms: int = 0


def calculate_backoff(attempt: int, config: RetryConfig) -> float:
    """Calculate delay with exponential backoff and jitter."""
    delay = config.base_delay * (config.exponential_base ** attempt)
    delay = min(delay, config.max_delay)

    # Add jitter
    jitter_range = delay * config.jitter
    delay += random.uniform(-jitter_range, jitter_range)

    return max(0, delay)


def retry_with_backoff(
    fn: Callable[[], str],
    validate_fn: Callable[[str], T],
    record_id: str,
    fallback_fn: Callable[[], T],
    config: RetryConfig = RetryConfig(),
    logger = None,
) -> LLMCallResult[T]:
    """
    Execute LLM call with retry logic and validation.

    Args:
        fn: Function that makes the LLM call and returns raw response
        validate_fn: Function that validates/parses the response, raises ValidationError on failure
        record_id: Identifier for the record being processed
        fallback_fn: Function that returns fallback values if all retries fail
        config: Retry configuration
        logger: Optional logger for debugging

    Returns:
        LLMCallResult with either parsed data or fallback values
    """
    start_time = time.time()
    last_error: Exception | None = None
    last_error_type: str | None = None

    for attempt in range(config.max_retries):
        try:
            # Make the LLM call
            raw_response = fn()

            # Check for error responses
            if raw_response.startswith("LLM error:"):
                error_msg = raw_response[len("LLM error:"):].strip()
                if "timeout" in error_msg.lower():
                    raise LLMTimeoutError(error_msg)
                elif "rate" in error_msg.lower() or "429" in error_msg:
                    raise LLMRateLimitError(error_msg)
                elif "5" in error_msg[:3]:  # 5xx status codes
                    raise LLMServerError(error_msg)
                else:
                    raise RetryableError(error_msg)

            # Validate and parse the response
            parsed_data = validate_fn(raw_response)

            # Success!
            duration_ms = int((time.time() - start_time) * 1000)
            return LLMCallResult(
                record_id=record_id,
                status="success",
                response=raw_response,
                parsed_data=parsed_data,
                attempts=attempt + 1,
                duration_ms=duration_ms,
            )

        except RetryableError as e:
            last_error = e
            last_error_type = type(e).__name__

            if attempt < config.max_retries - 1:
                delay = calculate_backoff(attempt, config)
                if logger:
                    logger.warning(
                        f"LLM call failed for {record_id} (attempt {attempt + 1}/{config.max_retries}): "
                        f"{e}. Retrying in {delay:.1f}s..."
                    )
                time.sleep(delay)

        except Exception as e:
            # Non-retryable error
            last_error = e
            last_error_type = "unexpected_error"
            break

    # All retries exhausted - use fallback
    duration_ms = int((time.time() - start_time) * 1000)
    fallback_values = fallback_fn()

    if logger:
        logger.error(
            f"LLM call failed permanently for {record_id} after {config.max_retries} attempts: {last_error}"
        )

    return LLMCallResult(
        record_id=record_id,
        status="failed",
        error_type=last_error_type,
        error_message=str(last_error),
        attempts=config.max_retries,
        fallback_used=True,
        fallback_values=fallback_values,
        duration_ms=duration_ms,
    )
```

### 3.2 Validation Functions

```python
import json
import re
from typing import TypedDict


class ClassificationResult(TypedDict):
    monetary_stance: int
    trade_stance: int
    tariff_mention: int
    economic_outlook: int


MONETARY_STANCE_SCALE = {
    "very_dovish": 1, "dovish": 2, "neutral": 3, "hawkish": 4, "very_hawkish": 5
}
TRADE_STANCE_SCALE = {
    "very_protectionist": 1, "protectionist": 2, "neutral": 3, "globalist": 4, "very_globalist": 5
}
OUTLOOK_SCALE = {
    "very_negative": 1, "negative": 2, "neutral": 3, "positive": 4, "very_positive": 5
}


def validate_classification_response(response: str) -> ClassificationResult:
    """
    Validate and parse classification LLM response.

    Raises:
        ValidationError: If response cannot be parsed as valid classification
    """
    # Try to extract JSON from response
    json_match = re.search(r"\{[^}]+\}", response)
    if not json_match:
        raise ValidationError(f"No JSON found in response: {response[:100]}...")

    try:
        result = json.loads(json_match.group())
    except json.JSONDecodeError as e:
        raise ValidationError(f"Invalid JSON: {e}")

    # Validate required fields
    required_fields = ["monetary_stance", "trade_stance", "tariff_mention", "economic_outlook"]
    missing = [f for f in required_fields if f not in result]
    if missing:
        raise ValidationError(f"Missing required fields: {missing}")

    # Map string values to numeric scales
    monetary = MONETARY_STANCE_SCALE.get(result.get("monetary_stance", ""), None)
    if monetary is None:
        raise ValidationError(f"Invalid monetary_stance: {result.get('monetary_stance')}")

    trade = TRADE_STANCE_SCALE.get(result.get("trade_stance", ""), None)
    if trade is None:
        raise ValidationError(f"Invalid trade_stance: {result.get('trade_stance')}")

    outlook = OUTLOOK_SCALE.get(result.get("economic_outlook", ""), None)
    if outlook is None:
        raise ValidationError(f"Invalid economic_outlook: {result.get('economic_outlook')}")

    tariff = result.get("tariff_mention")
    if tariff not in (0, 1, "0", "1"):
        raise ValidationError(f"Invalid tariff_mention: {tariff}")

    return ClassificationResult(
        monetary_stance=monetary,
        trade_stance=trade,
        tariff_mention=int(tariff),
        economic_outlook=outlook,
    )


def validate_summary_response(response: str) -> str:
    """
    Validate summary LLM response.

    Raises:
        ValidationError: If response is invalid
    """
    if response.startswith("LLM error:"):
        raise ValidationError(response)

    if len(response.strip()) < 50:
        raise ValidationError(f"Summary too short ({len(response)} chars)")

    # Truncate if too long
    if len(response) > 1500:
        return response[:1500] + "..."

    return response.strip()
```

### 3.3 Updated Asset Implementation

```python
@dg.asset(
    deps=[cleaned_speeches],
    io_manager_key="minio_parquet_io_manager",
    kinds={"llm", "polars"},
    compute_kind="nim",
)
def speech_classification(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_reasoning: NIMResource,
    minio: MinIOResource,
) -> pl.DataFrame:
    """Classify speeches with retry logic and failure tracking."""
    df = cleaned_speeches

    # Setup checkpoint manager
    checkpoint_mgr = LLMCheckpointManager(
        minio=minio,
        asset_name="speech_classification",
        run_id=context.run_id,
        checkpoint_interval=10,
    )

    # Retry configuration
    retry_config = RetryConfig(
        max_retries=5,
        base_delay=1.0,
        exponential_base=2.0,
    )

    # Track failures for summary
    failures: list[dict] = []

    def classify_speech(row: dict) -> dict:
        """Process one speech with retry logic."""
        reference = row["reference"]
        text = row.get("text", "")[:8000]

        prompt = f"""Analyze this central bank speech...
        {text}

        Return JSON with: monetary_stance, trade_stance, tariff_mention, economic_outlook
        """

        # Define fallback values
        def get_fallback() -> ClassificationResult:
            return ClassificationResult(
                monetary_stance=3,  # neutral
                trade_stance=3,
                tariff_mention=0,
                economic_outlook=3,
            )

        # Execute with retry
        result = retry_with_backoff(
            fn=lambda: nim_reasoning.generate(prompt, max_tokens=200, temperature=0.1),
            validate_fn=validate_classification_response,
            record_id=reference,
            fallback_fn=get_fallback,
            config=retry_config,
            logger=context.log,
        )

        # Get values (either parsed or fallback)
        values = result.parsed_data if result.status == "success" else result.fallback_values

        # Track failure if applicable
        if result.status == "failed":
            failures.append({
                "reference": reference,
                "error_type": result.error_type,
                "error_message": result.error_message,
                "attempts": result.attempts,
            })

        return {
            "reference": reference,
            "monetary_stance": values["monetary_stance"],
            "trade_stance": values["trade_stance"],
            "tariff_mention": values["tariff_mention"],
            "economic_outlook": values["economic_outlook"],
            "_llm_status": result.status,
            "_llm_error": result.error_message,
            "_llm_attempts": result.attempts,
            "_llm_fallback_used": result.fallback_used,
        }

    # Process with checkpointing
    results_df = process_with_checkpoint(
        df=df,
        id_column="reference",
        process_fn=classify_speech,
        checkpoint_manager=checkpoint_mgr,
        batch_size=10,
        logger=context.log,
    )

    # Log summary
    total = len(results_df)
    failed = len(failures)
    success = total - failed

    context.log.info(f"Classification complete:")
    context.log.info(f"  Total processed: {total}")
    context.log.info(f"  Successful: {success} ({100*success/total:.1f}%)")
    context.log.info(f"  Failed (using fallback): {failed} ({100*failed/total:.1f}%)")

    if failures:
        context.log.warning(f"  Failed references: {[f['reference'] for f in failures[:10]]}...")

        # Add metadata for downstream debugging
        context.add_output_metadata({
            "failed_count": failed,
            "failed_references": [f["reference"] for f in failures],
            "failure_breakdown": {
                error_type: sum(1 for f in failures if f["error_type"] == error_type)
                for error_type in set(f["error_type"] for f in failures)
            },
        })

    checkpoint_mgr.cleanup()
    return results_df
```

---

## 4. Output Schema

### DataFrame Columns

The output DataFrame includes metadata columns for failure tracking:

| Column | Type | Description |
|--------|------|-------------|
| `reference` | str | Record identifier |
| `monetary_stance` | int | Classification value (1-5) |
| `trade_stance` | int | Classification value (1-5) |
| `tariff_mention` | int | Binary (0/1) |
| `economic_outlook` | int | Classification value (1-5) |
| `_llm_status` | str | "success" or "failed" |
| `_llm_error` | str | Error message if failed, null otherwise |
| `_llm_attempts` | int | Number of attempts made |
| `_llm_fallback_used` | bool | Whether fallback values were used |

### Example Output

```
┌────────────┬─────────────────┬──────────────┬────────────────┬──────────────────┬─────────────┬─────────────────────────┬──────────────┬────────────────────┐
│ reference  │ monetary_stance │ trade_stance │ tariff_mention │ economic_outlook │ _llm_status │ _llm_error              │ _llm_attempts│ _llm_fallback_used │
├────────────┼─────────────────┼──────────────┼────────────────┼──────────────────┼─────────────┼─────────────────────────┼──────────────┼────────────────────┤
│ speech_001 │ 4               │ 3            │ 0              │ 4                │ success     │ null                    │ 1            │ false              │
│ speech_002 │ 2               │ 4            │ 1              │ 3                │ success     │ null                    │ 2            │ false              │
│ speech_003 │ 3               │ 3            │ 0              │ 3                │ failed      │ ValidationError: No ... │ 5            │ true               │
│ speech_004 │ 5               │ 2            │ 0              │ 2                │ success     │ null                    │ 1            │ false              │
└────────────┴─────────────────┴──────────────┴────────────────┴──────────────────┴─────────────┴─────────────────────────┴──────────────┴────────────────────┘
```

---

## 5. Dagster Integration

### Asset Metadata

Failed records are surfaced in Dagster UI metadata:

```python
context.add_output_metadata({
    "total_processed": 7721,
    "successful": 7689,
    "failed": 32,
    "success_rate": "99.6%",
    "failed_references": ["speech_42", "speech_189", ...],
    "failure_breakdown": {
        "ValidationError": 18,
        "LLMTimeoutError": 10,
        "LLMServerError": 4,
    },
})
```

### Downstream Asset Filtering

Downstream assets can filter out failed records:

```python
@dg.asset
def high_quality_classifications(
    speech_classification: pl.DataFrame,
) -> pl.DataFrame:
    """Filter to only successful LLM classifications."""
    return speech_classification.filter(
        pl.col("_llm_status") == "success"
    )
```

Or include all with awareness:

```python
@dg.asset
def all_classifications_with_confidence(
    speech_classification: pl.DataFrame,
) -> pl.DataFrame:
    """Include confidence based on LLM status."""
    return speech_classification.with_columns(
        pl.when(pl.col("_llm_status") == "success")
        .then(pl.lit("high"))
        .otherwise(pl.lit("low"))
        .alias("confidence")
    )
```

---

## 6. Reprocessing Failed Records

### Option A: Selective Reprocessing Job

```python
@dg.job
def reprocess_failed_classifications():
    """Reprocess only records that failed in the last run."""

    @dg.op
    def get_failed_records(context, speech_classification: pl.DataFrame) -> pl.DataFrame:
        failed = speech_classification.filter(pl.col("_llm_status") == "failed")
        context.log.info(f"Found {len(failed)} failed records to reprocess")
        return failed

    @dg.op
    def reclassify_speeches(context, failed_records: pl.DataFrame, nim_reasoning: NIMResource) -> pl.DataFrame:
        # Reprocess with fresh retry attempts
        ...
```

### Option B: Checkpoint-Based Recovery

The existing checkpoint system already supports this:
1. On run failure, checkpoint persists in MinIO
2. On re-run, checkpoint is loaded
3. Only unprocessed records are processed
4. Failed records (with `_llm_status=failed`) can be retried by clearing their checkpoint entries

---

## 7. Monitoring and Alerting

### Recommended Alerts

| Metric | Threshold | Action |
|--------|-----------|--------|
| Failure rate | > 5% | Warning - investigate LLM service |
| Failure rate | > 20% | Critical - pause pipeline, check service |
| Consecutive failures | > 10 | Circuit breaker - stop retrying temporarily |
| Avg retry count | > 3 | Warning - service may be degraded |

### Dagster Sensor (Future Enhancement)

```python
@dg.sensor(job=reprocess_failed_classifications)
def high_failure_rate_sensor(context):
    """Trigger reprocessing if failure rate exceeds threshold."""
    # Check recent run metadata
    # If failure_rate > 0.05, trigger reprocessing job
    ...
```

---

## 8. Cost-Benefit Analysis

### Retry Cost

| Scenario | Without Retry | With 5 Retries |
|----------|--------------|----------------|
| Transient failure (5%) | 5% data loss | ~0.01% data loss |
| Service degraded (20% fail) | 20% data loss | ~0.03% data loss |
| Service down | 100% fail, pipeline fails | 100% tracked failures, pipeline completes |

### Backoff Timing

For 7,721 records with 5% transient failure rate:
- ~386 records need retry
- Average 2 retries per failed record
- Total retry time: ~386 × 2 × 3s avg = ~39 minutes additional
- But: Much cheaper than full rerun of successful records

---

## 9. Implementation Plan

### Phase 1: Core Infrastructure (Priority: High)

1. [ ] Create `llm_retry.py` with `RetryConfig`, `LLMCallResult`, and `retry_with_backoff`
2. [ ] Create validation functions for classification and summary responses
3. [ ] Add unit tests for retry logic and validation

### Phase 2: Asset Updates (Priority: High)

4. [ ] Update `speech_classification` asset with retry wrapper
5. [ ] Update `speech_summaries` asset with retry wrapper
6. [ ] Add `_llm_*` metadata columns to output schemas

### Phase 3: Observability (Priority: Medium)

7. [ ] Add Dagster metadata for failure tracking
8. [ ] Create failure summary logging
9. [ ] Document output schema changes

### Phase 4: Operations (Priority: Low)

10. [ ] Create reprocessing job for failed records
11. [ ] Add monitoring alerts for failure rates
12. [ ] Consider circuit breaker pattern for sustained failures

---

## 10. Alternatives Considered

### Alternative A: Fail Fast

**Approach:** Fail entire pipeline on first LLM error
**Pros:** Simple, no partial data
**Cons:** Loses all successful work; expensive rerun

**Verdict:** Rejected - too expensive for thousands of records

### Alternative B: Infinite Retry

**Approach:** Keep retrying until success
**Pros:** Eventually succeeds
**Cons:** May never complete if service is down; blocks pipeline

**Verdict:** Rejected - can hang indefinitely

### Alternative C: Async with Dead Letter Queue

**Approach:** Send failed records to external queue (Redis, SQS)
**Pros:** Clean separation; standard pattern
**Cons:** Adds infrastructure complexity; overkill for batch processing

**Verdict:** Considered for future - current in-DataFrame approach simpler

### Alternative D: Dead Letter Columns (Selected)

**Approach:** Track failures in output DataFrame columns
**Pros:** Simple; no extra infrastructure; queryable; preserves all data
**Cons:** Slightly larger output; need to filter for downstream

**Verdict:** Selected - best fit for batch data pipelines

---

## 11. References

- [Exponential Backoff and Jitter (AWS)](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- [Retry Pattern (Microsoft)](https://learn.microsoft.com/en-us/azure/architecture/patterns/retry)
- [Dead Letter Queue Pattern](https://www.enterpriseintegrationpatterns.com/patterns/messaging/DeadLetterChannel.html)
- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
- [NIMEmbeddingResource retry implementation](dagster/src/brev_pipelines/resources/nim_embedding.py) - existing pattern in codebase

---

## Appendix A: Full RetryConfig Options

```python
@dataclass
class RetryConfig:
    """Complete retry configuration."""

    # Retry limits
    max_retries: int = 5

    # Backoff timing
    base_delay: float = 1.0        # Initial delay in seconds
    max_delay: float = 60.0        # Maximum delay cap
    exponential_base: float = 2.0  # Multiplier per attempt
    jitter: float = 0.2            # Random ±20% variation

    # Retryable conditions
    retry_on_timeout: bool = True
    retry_on_rate_limit: bool = True
    retry_on_server_error: bool = True      # 5xx
    retry_on_connection_error: bool = True
    retry_on_validation_failure: bool = True

    # Circuit breaker (future)
    circuit_breaker_enabled: bool = False
    circuit_breaker_threshold: int = 10     # Consecutive failures
    circuit_breaker_timeout: float = 60.0   # Seconds before retry
```

## Appendix B: Validation Schemas

For strict validation, Pydantic models can be used:

```python
from pydantic import BaseModel, Field, field_validator
from typing import Literal

class ClassificationResponse(BaseModel):
    monetary_stance: Literal["very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"]
    trade_stance: Literal["very_protectionist", "protectionist", "neutral", "globalist", "very_globalist"]
    tariff_mention: Literal[0, 1]
    economic_outlook: Literal["very_negative", "negative", "neutral", "positive", "very_positive"]

    @field_validator("tariff_mention", mode="before")
    @classmethod
    def coerce_tariff(cls, v):
        return int(v) if isinstance(v, str) else v
```
