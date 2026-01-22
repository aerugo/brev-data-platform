# NIM LLM Observability - Work Notes

**Plan**: [development-plan.md](development-plan.md)
**Spec**: [spec.md](spec.md)

## Session Log

### 2026-01-22 - Initial Planning

**Context**: User requested observability for NIM LLM calls to log prompts, responses, latency, and enable review of AI-generated content.

**Research findings**:
1. NIM has built-in OpenTelemetry and Prometheus support (disabled by default)
2. Existing monitoring stack (Prometheus/Grafana/Loki) already deployed
3. DCGM Exporter already captures GPU metrics
4. No additional infrastructure needed - just enable NIM's native capabilities

**Key environment variables for NIM observability**:
- `NIM_ENABLE_METRICS=true` - Exposes `/v1/metrics` endpoint (Prometheus format)
- `NIM_LOG_REQUESTS=true` - Logs HTTP access info (method, path, status code) to stdout
- `NIM_LOG_LEVEL=INFO` - Appropriate verbosity (DEBUG too noisy for production)
- `OTEL_SERVICE_NAME=nim-llm` - For distributed tracing (optional)

**Important**: `NIM_LOG_REQUESTS` does NOT log actual prompt/response content - only HTTP access logs. For full prompt/response logging, you would need:
1. OpenTelemetry tracing with a span backend (like Tempo)
2. A reverse proxy/middleware that logs requests
3. Application-level logging in the client code

**Decision**: Use NIM's native observability rather than adding external tools like Langfuse or custom wrappers. This aligns with the NVIDIA Enterprise stack approach and avoids adding complexity.

**Files identified for modification**:
- `k8s/apps/nvidia-nim/values.yaml` - Add env vars
- `k8s/apps/monitoring/values.yaml` - Add scrape config (or ServiceMonitor)
- `README.md` - Document observability

---

### 2026-01-22 - Implementation Complete

**Files modified:**

1. `k8s/apps/nvidia-nim/values.yaml`
   - Added `NIM_ENABLE_METRICS=true` environment variable
   - Added `NIM_LOG_REQUESTS=true` for full prompt/response logging
   - Added `OTEL_SERVICE_NAME=nim-llm` for future tracing
   - Added service annotations for Prometheus scraping
   - Added `observability.serviceMonitor` configuration section

2. `k8s/apps/nvidia-nim/templates/service.yaml`
   - Added support for service annotations from values
   - Added `app.kubernetes.io/name` and `app.kubernetes.io/component` labels

3. `k8s/apps/nvidia-nim/templates/servicemonitor.yaml` (NEW)
   - Created ServiceMonitor CRD for Prometheus Operator
   - Configured to scrape `/metrics` endpoint every 30s
   - Labels match monitoring stack's serviceMonitorSelector

4. `k8s/apps/monitoring/templates/dashboards/nim-llm-dashboard.yaml` (NEW)
   - Grafana dashboard ConfigMap with `grafana_dashboard: "1"` label
   - Panels: Request rate, P95 latency, token throughput
   - Latency distribution time series (P50/P95/P99)
   - GPU metrics from DCGM (utilization, memory, power)
   - Loki logs panel for recent LLM requests

5. `README.md`
   - Added comprehensive Observability section
   - Documented LLM logging queries for Loki
   - Documented NIM metrics and example PromQL queries
   - Documented GPU metrics from DCGM

6. `docs/invariants/INVARIANTS.md`
   - Added INV-N004: NIM Observability Enabled

**Validation pending**: Requires deployment to cluster to verify:
- Prometheus scrapes NIM `/metrics` endpoint
- Loki receives logs with prompt/response data
- Grafana dashboard renders correctly

---

---

### 2026-01-22 - Debugging & Metric Corrections

**Issues found during testing:**

1. **Metrics endpoint path**: NIM exposes metrics at `/v1/metrics`, not `/metrics`
   - Fixed ServiceMonitor path and service annotations

2. **Incorrect metric names in dashboard**: Initial dashboard used guessed metric names
   - Original: `nim_request_total`, `nim_request_duration_seconds_bucket`, `nim_token_total`
   - Actual NIM metrics:
     - `prompt_tokens_total` - prefill tokens processed
     - `generation_tokens_total` - generation tokens processed
     - `time_to_first_token_seconds_bucket` - TTFT histogram
     - `time_per_output_token_seconds_bucket` - inter-token latency histogram
     - `e2e_request_latency_seconds_bucket` - end-to-end latency histogram
     - `num_requests_running` / `num_requests_waiting` - concurrent request counts
     - `gpu_cache_usage_perc` - KV cache usage percentage

3. **Loki datasource UID**: Dashboard referenced `uid: loki` but datasource had no fixed UID
   - Added `uid: loki` to Loki datasource in monitoring values

4. **Helm template escaping**: Dashboard JSON with `{{gpu}}` broke Helm templating
   - Fixed with `{{ "{{" }}gpu{{ "}}" }}` escaping

5. **Prompt/response logging limitation**: `NIM_LOG_REQUESTS=true` only logs HTTP access info (method, path, status), NOT actual prompts/responses

**Files updated:**
- `k8s/apps/nvidia-nim/values.yaml` - Fixed service annotation path
- `k8s/apps/nvidia-nim/templates/servicemonitor.yaml` - Fixed metrics path to `/v1/metrics`
- `k8s/apps/monitoring/values.yaml` - Added `uid: loki` to Loki datasource
- `k8s/apps/monitoring/templates/dashboards/nim-llm-dashboard.yaml` - Fixed all metric names

---

## Implementation Notes

- Used ServiceMonitor CRD instead of raw scrape configs for cleaner Prometheus Operator integration
- Dashboard uses `grafana_dashboard: "1"` label for automatic sidecar pickup
- Logs panel queries `{app="nim-llm"}` - shows HTTP access logs only (not prompt content)
- Metrics endpoint at `/v1/metrics` per NVIDIA NIM documentation

## Blockers & Issues

- **Prompt/response logging**: NIM does not natively support logging full prompt/response content. For this capability, additional infrastructure would be needed (OpenTelemetry tracing, proxy middleware, or application-level logging).

## References

- [NVIDIA NIM Documentation - Observability](https://docs.nvidia.com/nim/large-language-models/latest/observability.html)
- [Prometheus ServiceMonitor CRD](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor)
- [Grafana Loki LogQL](https://grafana.com/docs/loki/latest/query/)
