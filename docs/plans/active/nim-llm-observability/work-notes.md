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
- `NIM_ENABLE_METRICS=true` - Exposes `/metrics` endpoint
- `NIM_LOG_REQUESTS=true` - Logs full prompt/response to stdout
- `NIM_LOG_LEVEL=INFO` - Appropriate verbosity (DEBUG too noisy for production)
- `OTEL_SERVICE_NAME=nim-llm` - For distributed tracing (optional)

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

## Implementation Notes

- Used ServiceMonitor CRD instead of raw scrape configs for cleaner Prometheus Operator integration
- Dashboard uses `grafana_dashboard: "1"` label for automatic sidecar pickup
- Logs panel queries `{app="nim-llm"}` - may need adjustment based on actual label naming

## Blockers & Issues

(None)

## References

- [NVIDIA NIM Documentation - Observability](https://docs.nvidia.com/nim/large-language-models/latest/observability.html)
- [Prometheus ServiceMonitor CRD](https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.ServiceMonitor)
- [Grafana Loki LogQL](https://grafana.com/docs/loki/latest/query/)
