# Phase 4: Operations (Documentation)

**Status**: Pending
**Type**: Application (Documentation Only)
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Document operational procedures for reprocessing failed records, recommended monitoring alerts, and future circuit breaker enhancement design.

---

## Invariants Enforced in This Phase

This phase is documentation-only and does not introduce code changes that affect invariants.

---

## Implementation Steps

### Step 4.1: Document Reprocessing Workflow

**Action**: Create

**File(s)**: `docs/runbooks/reprocess-failed-llm-records.md`

Document how operators can reprocess failed records.

```markdown
# Reprocessing Failed LLM Records

## Overview

When LLM-powered assets (speech_classification, speech_summaries) have failures
that exceed acceptable thresholds, operators can selectively reprocess failed records.

## Prerequisites

- Access to Dagster UI or CLI
- Access to MinIO/LakeFS for data inspection
- Understanding of dead letter columns (`_llm_status`, `_llm_error`, etc.)

## Identifying Failed Records

### Via Dagster UI

1. Navigate to Assets > speech_classification (or speech_summaries)
2. Click on the latest materialization
3. Check the Metadata panel:
   - `failed`: Number of failed records
   - `failed_references`: List of record IDs that failed
   - `failure_breakdown`: Count by error type

### Via Data Inspection

```python
import polars as pl

# Read the output parquet
df = pl.read_parquet("s3://data-products/central-bank-speeches/classification.parquet")

# Filter failed records
failed = df.filter(pl.col("_llm_status") == "failed")
print(f"Failed records: {len(failed)}")
print(failed.select(["reference", "_llm_error", "_llm_attempts"]))
```

## Reprocessing Options

### Option A: Full Re-run

If failure rate is high (>20%), consider a full re-run:

1. Clear checkpoint files:
   ```bash
   mc rm --recursive minio/checkpoints/speech_classification/
   ```

2. Rematerialize the asset in Dagster UI

3. Monitor for improved success rate

### Option B: Selective Reprocessing via Checkpoint

The checkpoint system already supports partial reprocessing:

1. Identify failed record IDs from metadata
2. Remove those records from the checkpoint:
   ```python
   # This requires custom script - see implementation below
   ```
3. Rematerialize - only cleared records will be reprocessed

### Option C: Create Filtered Input (Future Enhancement)

For targeted reprocessing, create a job that:
1. Reads the failed record IDs
2. Filters input data to only those records
3. Processes just the failed subset
4. Merges results back

## Selective Reprocessing Script

```python
"""Script to clear specific records from checkpoint for reprocessing."""
import json
from minio import Minio

def clear_failed_from_checkpoint(
    minio_client: Minio,
    asset_name: str,
    run_id: str,
    failed_references: list[str],
) -> int:
    """Remove failed records from checkpoint to enable reprocessing.

    Args:
        minio_client: MinIO client
        asset_name: Name of the asset (e.g., "speech_classification")
        run_id: Dagster run ID
        failed_references: List of record IDs to clear

    Returns:
        Number of records cleared
    """
    checkpoint_path = f"checkpoints/{asset_name}/{run_id}/checkpoint.json"

    try:
        response = minio_client.get_object("checkpoints", checkpoint_path)
        checkpoint = json.loads(response.read().decode())
    except Exception:
        print(f"No checkpoint found at {checkpoint_path}")
        return 0

    # Remove failed references from processed set
    processed = set(checkpoint.get("processed_ids", []))
    initial_count = len(processed)

    for ref in failed_references:
        processed.discard(ref)

    checkpoint["processed_ids"] = list(processed)

    # Write updated checkpoint
    checkpoint_bytes = json.dumps(checkpoint).encode()
    minio_client.put_object(
        "checkpoints",
        checkpoint_path,
        data=io.BytesIO(checkpoint_bytes),
        length=len(checkpoint_bytes),
    )

    cleared = initial_count - len(processed)
    print(f"Cleared {cleared} records from checkpoint")
    return cleared


# Usage
if __name__ == "__main__":
    from minio import Minio

    client = Minio(
        "minio.minio.svc.cluster.local:9000",
        access_key="...",
        secret_key="...",
        secure=False,
    )

    # Get failed references from Dagster metadata or data inspection
    failed_refs = ["BIS_2024_042", "ECB_2024_189", ...]

    clear_failed_from_checkpoint(
        minio_client=client,
        asset_name="speech_classification",
        run_id="<run-id-from-dagster>",
        failed_references=failed_refs,
    )
```

## When to Reprocess

| Failure Rate | Action |
|--------------|--------|
| < 1% | Acceptable - review failed records manually |
| 1-5% | Monitor - investigate error types |
| 5-20% | Investigate - check NIM service health, then reprocess |
| > 20% | Critical - pause, fix root cause, full re-run |

## Root Cause Investigation

Before reprocessing, investigate why failures occurred:

1. **Check NIM service health**:
   ```bash
   kubectl get pods -n nvidia-nim
   kubectl logs -n nvidia-nim deployment/nim-llm --tail=100
   ```

2. **Check failure breakdown**:
   - High `LLMTimeoutError`: NIM overloaded or network issues
   - High `LLMRateLimitError`: Adjust rate limiting or add delays
   - High `ValidationError`: Prompt may need adjustment
   - High `LLMServerError`: NIM service issues

3. **Check resource usage**:
   ```bash
   kubectl top pods -n nvidia-nim
   ```
```

**Validation**:
- Document reviewed by team
- Runbook tested with simulated failures

---

### Step 4.2: Document Monitoring Alerts

**Action**: Create

**File(s)**: `docs/runbooks/llm-failure-monitoring.md`

Document recommended monitoring thresholds and alerts.

```markdown
# LLM Failure Monitoring

## Overview

This document defines monitoring thresholds and alerting recommendations for
LLM-powered pipeline assets.

## Key Metrics

### From Asset Metadata

| Metric | Source | Description |
|--------|--------|-------------|
| `failed` | Asset metadata | Count of failed LLM calls |
| `success_rate` | Asset metadata | Percentage of successful calls |
| `avg_attempts` | Asset metadata | Average retry attempts per record |
| `failure_breakdown.*` | Asset metadata | Count by error type |

### Derived Metrics

| Metric | Calculation | Purpose |
|--------|-------------|---------|
| Failure rate | `failed / total_processed` | Overall health |
| Retry overhead | `avg_attempts - 1` | Service degradation indicator |
| Timeout ratio | `LLMTimeoutError / failed` | Network/service issues |

## Alert Thresholds

### Warning Level (P3)

| Condition | Threshold | Response |
|-----------|-----------|----------|
| Failure rate | > 5% | Investigate error types |
| Average attempts | > 2.5 | NIM may be degraded |
| Timeout ratio | > 50% | Check network/NIM health |

### Critical Level (P2)

| Condition | Threshold | Response |
|-----------|-----------|----------|
| Failure rate | > 20% | Pause pipeline, investigate |
| Average attempts | > 4.0 | NIM severely degraded |
| Consecutive failures | > 10 records | Potential outage |

### Emergency Level (P1)

| Condition | Threshold | Response |
|-----------|-----------|----------|
| Failure rate | > 50% | Stop pipeline immediately |
| NIM service down | Health check fails | Escalate to infra team |

## Alert Configuration (Future)

### Dagster Sensor (Design)

```python
@dg.sensor(job=alert_on_high_failure_rate)
def llm_failure_rate_sensor(context: dg.SensorEvaluationContext):
    """Monitor LLM failure rates and trigger alerts."""
    # Get latest materialization metadata
    latest = context.instance.get_latest_materialization_event(
        AssetKey("speech_classification")
    )

    if latest and latest.asset_materialization:
        metadata = latest.asset_materialization.metadata
        failure_rate = metadata.get("failed", 0) / metadata.get("total_processed", 1)

        if failure_rate > 0.20:
            return RunRequest(
                run_key=f"alert-{latest.run_id}",
                run_config={
                    "ops": {
                        "send_alert": {
                            "config": {
                                "severity": "critical",
                                "message": f"LLM failure rate: {failure_rate:.1%}",
                            }
                        }
                    }
                }
            )

    return SkipReason("Failure rate within acceptable limits")
```

### Prometheus Metrics (Future)

If Prometheus is deployed, export metrics:

```python
from prometheus_client import Counter, Gauge

llm_calls_total = Counter(
    "dagster_llm_calls_total",
    "Total LLM calls",
    ["asset", "status"]
)

llm_failure_rate = Gauge(
    "dagster_llm_failure_rate",
    "Current failure rate",
    ["asset"]
)

# Update in asset code
llm_calls_total.labels(asset="speech_classification", status="success").inc()
llm_failure_rate.labels(asset="speech_classification").set(failed / total)
```

## Response Procedures

### On Warning Alert

1. Check Dagster UI for failure breakdown
2. Review NIM logs: `kubectl logs -n nvidia-nim deployment/nim-llm`
3. If transient, allow pipeline to complete
4. If persistent, investigate root cause

### On Critical Alert

1. Pause pipeline if in progress
2. Check NIM service health
3. Review recent changes (prompts, model config)
4. Reprocess failed records after fix

### On Emergency Alert

1. Stop all LLM-dependent pipelines
2. Escalate to infrastructure team
3. Check GPU health: `nvidia-smi`
4. Check NIM container status
5. Restore service before resuming
```

**Validation**:
- Thresholds reviewed with team
- Alert procedures tested

---

### Step 4.3: Document Circuit Breaker Design (Future)

**Action**: Create

**File(s)**: `docs/design/circuit-breaker-pattern.md`

Document circuit breaker pattern for future implementation.

```markdown
# Circuit Breaker Pattern for LLM Calls (Design)

## Status

**Proposed** - Not yet implemented. This document captures the design for future enhancement.

## Overview

A circuit breaker prevents cascading failures by stopping requests to a failing service
after a threshold of failures, then gradually allowing requests to resume.

## States

```
┌─────────┐  failures > threshold  ┌──────────┐
│ CLOSED  │ ────────────────────►  │   OPEN   │
│ (allow) │                        │ (reject) │
└─────────┘                        └──────────┘
     ▲                                   │
     │                                   │ timeout
     │                                   ▼
     │         success            ┌───────────┐
     └────────────────────────────│ HALF_OPEN │
                                  │  (test)   │
                                  └───────────┘
```

- **CLOSED**: Normal operation, requests allowed
- **OPEN**: Circuit tripped, requests rejected immediately
- **HALF_OPEN**: Testing if service recovered

## Proposed Configuration

```python
@dataclass
class CircuitBreakerConfig:
    """Circuit breaker configuration."""

    # Threshold to trip circuit
    failure_threshold: int = 10  # Consecutive failures

    # Time before testing recovery
    recovery_timeout: float = 60.0  # seconds

    # Successful calls needed to close circuit
    success_threshold: int = 3

    # Error types that count as failures
    counted_errors: tuple[type[Exception], ...] = (
        LLMTimeoutError,
        LLMServerError,
        LLMRateLimitError,
    )
```

## Proposed Implementation

```python
class CircuitBreaker:
    """Circuit breaker for LLM calls."""

    def __init__(self, config: CircuitBreakerConfig) -> None:
        self.config = config
        self.state = "closed"
        self.failure_count = 0
        self.success_count = 0
        self.last_failure_time: float | None = None

    def can_execute(self) -> bool:
        """Check if request should be allowed."""
        if self.state == "closed":
            return True

        if self.state == "open":
            # Check if recovery timeout elapsed
            if self.last_failure_time:
                elapsed = time.time() - self.last_failure_time
                if elapsed >= self.config.recovery_timeout:
                    self.state = "half_open"
                    return True
            return False

        # half_open - allow limited requests
        return True

    def record_success(self) -> None:
        """Record successful call."""
        self.failure_count = 0

        if self.state == "half_open":
            self.success_count += 1
            if self.success_count >= self.config.success_threshold:
                self.state = "closed"
                self.success_count = 0

    def record_failure(self, error: Exception) -> None:
        """Record failed call."""
        if not isinstance(error, self.config.counted_errors):
            return

        self.failure_count += 1
        self.success_count = 0
        self.last_failure_time = time.time()

        if self.failure_count >= self.config.failure_threshold:
            self.state = "open"

        if self.state == "half_open":
            self.state = "open"
```

## Integration with Retry Wrapper

```python
def retry_with_backoff(
    fn: Callable[[], str],
    validate_fn: Callable[[str], T],
    record_id: str,
    fallback_fn: Callable[[], T],
    config: RetryConfig | None = None,
    circuit_breaker: CircuitBreaker | None = None,  # New parameter
    logger: DagsterLogManager | None = None,
) -> LLMCallResult[T]:
    """Execute LLM call with retry logic and optional circuit breaker."""

    if circuit_breaker and not circuit_breaker.can_execute():
        # Circuit is open - skip to fallback immediately
        return LLMCallResult(
            record_id=record_id,
            status="failed",
            error_type="CircuitOpen",
            error_message="Circuit breaker is open - service unavailable",
            attempts=0,
            fallback_used=True,
            fallback_values=fallback_fn(),
            duration_ms=0,
        )

    # ... existing retry logic ...

    # On success
    if circuit_breaker:
        circuit_breaker.record_success()

    # On failure
    if circuit_breaker:
        circuit_breaker.record_failure(last_error)
```

## Benefits

1. **Fast failure**: Skip retries when service is known to be down
2. **Service protection**: Reduce load on struggling service
3. **Automatic recovery**: Test service health after timeout
4. **Visibility**: Circuit state can be logged/monitored

## Implementation Priority

**Low** - Current retry pattern handles most cases. Circuit breaker adds value when:
- Service outages are common
- Pipeline processes very large datasets
- Reducing retry overhead is important
```

**Validation**:
- Design reviewed by team
- Decision to implement or defer documented

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `docs/runbooks/reprocess-failed-llm-records.md` | CREATE | Reprocessing procedures |
| `docs/runbooks/llm-failure-monitoring.md` | CREATE | Monitoring and alerting |
| `docs/design/circuit-breaker-pattern.md` | CREATE | Future enhancement design |

---

## Configuration Details

### Environment Variables

None required.

### Secrets Required

None required.

---

## Verification

### Pre-flight Checks

- Phase 1-3 complete
- Documentation directory exists

### Validation Commands

```bash
# Verify documentation files created
ls -la docs/runbooks/
ls -la docs/design/
```

### Expected Outcomes

- Runbooks accessible to operators
- Monitoring thresholds defined
- Circuit breaker design documented for future reference

---

## Edge Cases and Error Handling

Not applicable - documentation phase.

### Rollback Plan

If documentation is inaccurate:
1. Update documentation
2. No code changes required

---

## Completion Criteria

- [ ] `reprocess-failed-llm-records.md` created with clear procedures
- [ ] `llm-failure-monitoring.md` created with alert thresholds
- [ ] `circuit-breaker-pattern.md` created with future design
- [ ] Documentation reviewed by team
- [ ] Runbooks tested with simulated scenarios
