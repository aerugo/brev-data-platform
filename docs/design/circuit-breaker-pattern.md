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
from dataclasses import dataclass

from brev_pipelines.resources.llm_retry import (
    LLMRateLimitError,
    LLMServerError,
    LLMTimeoutError,
)


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
import time


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
from collections.abc import Callable
from typing import TypeVar

from brev_pipelines.resources.llm_retry import LLMCallResult, RetryConfig

T = TypeVar("T")


def retry_with_backoff(
    fn: Callable[[], str],
    validate_fn: Callable[[str], T],
    record_id: str,
    fallback_fn: Callable[[], T],
    config: RetryConfig | None = None,
    circuit_breaker: CircuitBreaker | None = None,  # New parameter
    logger: object | None = None,
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

## When to Implement

Consider implementing when:
- Consistent >10% failure rates observed
- NIM service has reliability issues
- Processing datasets with >10,000 records
- Retry overhead impacts pipeline performance

## Testing Strategy

If implemented, test with:
1. Unit tests for state transitions
2. Integration tests with mock LLM service
3. Failure injection testing (chaos engineering)
4. Performance comparison with/without circuit breaker
