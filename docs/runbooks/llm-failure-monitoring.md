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

## Dead Letter Column Reference

Assets output these columns for failure tracking:

| Column | Type | Description |
|--------|------|-------------|
| `_llm_status` | String | "success" or "failed" |
| `_llm_error` | String | Error message (null on success) |
| `_llm_attempts` | Int | Number of attempts made |
| `_llm_fallback_used` | Boolean | Whether fallback values were used |

## Downstream Filtering

Downstream assets can filter by status:

```python
# Keep only successful records
successful = df.filter(pl.col("_llm_status") == "success")

# Add confidence column
df = df.with_columns(
    pl.when(pl.col("_llm_status") == "success")
    .then(pl.lit("high"))
    .otherwise(pl.lit("low"))
    .alias("confidence")
)
```
