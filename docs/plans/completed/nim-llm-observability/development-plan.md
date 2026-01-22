# NIM LLM Observability - Development Plan

**Status**: Complete
**Created**: 2026-01-22
**Branch**: `feature/nim-observability`
**Spec**: [spec.md](spec.md)

## Summary

Enable NIM's native OpenTelemetry and Prometheus observability, integrated with the existing Prometheus/Grafana/Loki stack, providing full visibility into all LLM calls including prompts, responses, latency, and throughput.

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md`:

- **INV-K004**: Helm Values Override Pattern - Environment overrides in `values-dev.yaml`, not base `values.yaml`
- **INV-G003**: Source of Truth is Git - All changes via Git, ArgoCD syncs
- **INV-N001**: NIM Requires GPU Node - Observability config must not affect GPU scheduling
- **INV-N002**: Model Configuration in ConfigMap - Keep model config separate from observability config

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-N004**: NIM Observability Enabled - All NIM deployments must have Prometheus metrics and structured logging enabled for operational visibility

## Current State Analysis

### Current Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          Dagster Assets                          │
│                    (calls nim.generate())                        │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                          NIM LLM                                 │
│  ┌─────────────┐                                                │
│  │  /v1/...    │  ← No metrics, no structured logging           │
│  │  (inference)│                                                │
│  └─────────────┘                                                │
└─────────────────────────────────────────────────────────────────┘
          │
          ▼
    ┌──────────┐
    │ Response │  ← Only response returned, nothing logged
    └──────────┘
```

### Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          Dagster Assets                          │
│                    (calls nim.generate())                        │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                          NIM LLM                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │  /v1/...    │  │  /metrics   │  │  stdout (JSON logs)     │  │
│  │  (inference)│  │  (prometheus)│  │  (prompts + responses)  │  │
│  └──────┬──────┘  └──────┬──────┘  └───────────┬─────────────┘  │
└─────────┼────────────────┼─────────────────────┼────────────────┘
          │                │                     │
          ▼                ▼                     ▼
    ┌──────────┐    ┌────────────┐        ┌───────────┐
    │ Response │    │ Prometheus │        │  Promtail │
    └──────────┘    └─────┬──────┘        └─────┬─────┘
                          │                     │
                          ▼                     ▼
                    ┌──────────┐          ┌──────────┐
                    │ Grafana  │◄─────────│   Loki   │
                    │Dashboards│          │  (logs)  │
                    └──────────┘          └──────────┘
```

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `k8s/apps/nvidia-nim/values.yaml` | Basic NIM config with `NIM_LOG_LEVEL=INFO` | Add OTEL and metrics environment variables |
| `k8s/apps/monitoring/values.yaml` | Scrapes DCGM only | Add NIM scrape config |
| `README.md` | No observability documentation | Add Observability section |

### Files to Create

| File | Purpose |
|------|---------|
| `k8s/apps/nvidia-nim/templates/servicemonitor.yaml` | Prometheus ServiceMonitor for NIM metrics |
| `k8s/apps/monitoring/dashboards/nim-llm.json` | Grafana dashboard for NIM metrics |

## Solution Design

### NIM Native Observability

NIM containers support these environment variables (from NVIDIA documentation):

| Variable | Purpose | Value |
|----------|---------|-------|
| `NIM_ENABLE_METRICS` | Enable Prometheus `/metrics` endpoint | `true` |
| `NIM_LOG_LEVEL` | Log verbosity | `DEBUG` (for request logging) |
| `NIM_LOG_REQUESTS` | Log full prompt/response | `true` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OpenTelemetry collector endpoint | (optional, for tracing) |
| `OTEL_SERVICE_NAME` | Service name in traces | `nim-llm` |

### Metrics Exposed by NIM

NIM exposes OpenAI-compatible metrics:

- `nim_request_duration_seconds` - Histogram of request latencies
- `nim_tokens_total` - Counter of tokens processed (prompt + completion)
- `nim_requests_total` - Counter of requests by status
- `nim_model_loaded` - Gauge indicating model readiness
- `nim_batch_size` - Histogram of batch sizes

### Key Design Decisions

1. **Direct stdout logging over OTEL Collector**: Promtail already captures all container stdout. Adding an OTEL Collector would add complexity without benefit for our single-node setup.

2. **ServiceMonitor over scrape config**: Using Prometheus Operator's ServiceMonitor CRD is cleaner than raw scrape configs and auto-discovers the NIM service.

3. **JSON structured logs**: NIM outputs JSON when `NIM_LOG_REQUESTS=true`, making Loki queries straightforward.

## Phase Overview

| Phase | Description | Type | Deliverables |
|-------|-------------|------|--------------|
| 1 | Enable NIM metrics and logging | Kubernetes | Updated values.yaml, ServiceMonitor |
| 2 | Create Grafana dashboard | Kubernetes | Dashboard ConfigMap |
| 3 | Update documentation | Documentation | README.md observability section |
| 4 | Validation | Integration | Verify metrics, logs, dashboard |

## Phase 1: Enable NIM Observability

**Goal**: Configure NIM to expose Prometheus metrics and log all requests
**Type**: Kubernetes

### Deliverables

1. Updated `k8s/apps/nvidia-nim/values.yaml` with observability env vars
2. New `k8s/apps/nvidia-nim/templates/servicemonitor.yaml`
3. Service annotation for metrics port

### Implementation Details

**values.yaml changes:**

```yaml
env:
  # Existing vars...
  - name: NGC_API_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: api-key
  - name: NIM_CACHE_PATH
    value: "/opt/nim/.cache"

  # Observability - NEW
  - name: NIM_LOG_LEVEL
    value: "INFO"
  - name: NIM_ENABLE_METRICS
    value: "true"
  - name: NIM_LOG_REQUESTS
    value: "true"

# Metrics port - NEW
service:
  type: ClusterIP
  port: 8000
  metricsPort: 8000  # Same port, /metrics path
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"
    prometheus.io/path: "/metrics"
```

**ServiceMonitor:**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: nim-llm
  namespace: nvidia-nim
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nvidia-nim
  namespaceSelector:
    matchNames:
      - nvidia-nim
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

### Validation Approach

1. `helm lint k8s/apps/nvidia-nim/` passes
2. `helm template` shows ServiceMonitor resource
3. After deploy: `curl http://nim-llm:8000/metrics` returns Prometheus metrics

### Success Criteria

- [ ] Helm lint passes
- [ ] NIM pod restarts successfully with new env vars
- [ ] `/metrics` endpoint returns Prometheus format data
- [ ] Prometheus targets show NIM as UP

## Phase 2: Create Grafana Dashboard

**Goal**: Provide visual monitoring of NIM performance
**Type**: Kubernetes

### Deliverables

1. `k8s/apps/monitoring/dashboards/nim-llm.json` - Grafana dashboard
2. Updated `k8s/apps/monitoring/values.yaml` to load custom dashboards

### Implementation Details

Dashboard panels:
- **Request Rate**: `rate(nim_requests_total[5m])`
- **Latency P50/P95/P99**: `histogram_quantile(0.95, rate(nim_request_duration_seconds_bucket[5m]))`
- **Token Throughput**: `rate(nim_tokens_total[5m])`
- **Error Rate**: `rate(nim_requests_total{status="error"}[5m])`
- **GPU Utilization** (from DCGM): `DCGM_FI_DEV_GPU_UTIL`
- **GPU Memory** (from DCGM): `DCGM_FI_DEV_FB_USED`
- **Loki Logs Panel**: Recent prompts/responses

### Validation Approach

1. Dashboard JSON is valid
2. Dashboard loads in Grafana without errors
3. Panels show data (after NIM receives requests)

### Success Criteria

- [ ] Dashboard appears in Grafana under "Brev Data Platform" folder
- [ ] All panels render without query errors
- [ ] Latency histogram shows data after test requests

## Phase 3: Update Documentation

**Goal**: Document the observability architecture for operators
**Type**: Documentation

### Deliverables

1. Updated `README.md` with Observability section

### Implementation Details

Add new section to README.md after "Architecture" section:

```markdown
## Observability

### LLM Call Logging

All NIM LLM calls are automatically logged and can be reviewed:

**View recent prompts/responses (Grafana Loki):**
```bash
# Port forward Grafana
make port-forward-grafana

# Open http://localhost:3001
# Navigate to Explore → Loki
# Query: {app="nvidia-nim-llm"} |= "prompt"
```

**Metrics available (Prometheus):**
| Metric | Description |
|--------|-------------|
| `nim_request_duration_seconds` | Request latency histogram |
| `nim_tokens_total` | Tokens processed |
| `nim_requests_total` | Request count by status |

**Grafana Dashboard:**
- Navigate to Dashboards → Brev Data Platform → NIM LLM
- Shows latency, throughput, error rates, and GPU utilization

### GPU Metrics

GPU metrics are collected by DCGM Exporter:
- `DCGM_FI_DEV_GPU_UTIL` - GPU utilization %
- `DCGM_FI_DEV_FB_USED` - GPU memory used
- `DCGM_FI_DEV_POWER_USAGE` - Power consumption
```

### Validation Approach

1. README renders correctly on GitHub
2. Commands in README work as documented

### Success Criteria

- [ ] README includes Observability section
- [ ] Example queries are accurate
- [ ] Links to Grafana dashboard are correct

## Phase 4: Validation

**Goal**: End-to-end verification of observability pipeline
**Type**: Integration

### Validation Steps

1. **Trigger LLM calls**: Run Dagster asset that uses NIM
   ```bash
   # Via Dagster UI or CLI
   dagster asset materialize -m brev_pipelines --select nim_enriched_data
   ```

2. **Verify Prometheus metrics**:
   ```bash
   kubectl port-forward -n monitoring svc/prometheus 9090:9090
   # Query: nim_requests_total
   ```

3. **Verify Loki logs**:
   ```bash
   kubectl port-forward -n monitoring svc/grafana 3001:80
   # Explore → Loki → {app="nvidia-nim-llm"}
   ```

4. **Check Grafana dashboard**: All panels populated

### Success Criteria

- [ ] `nim_requests_total` counter increases after LLM calls
- [ ] `nim_request_duration_seconds` histogram has data
- [ ] Loki shows JSON logs with `prompt` and `completion` fields
- [ ] Grafana dashboard shows all metrics
- [ ] No errors in NIM pod logs

## Validation Strategy

### Kubernetes Validation

- Helm lint: `helm lint k8s/apps/nvidia-nim/`
- Helm template: Verify ServiceMonitor in output
- Dry-run: `helm upgrade --dry-run`

### Integration Validation

- Prometheus targets: NIM shows as UP
- Loki labels: `{app="nvidia-nim-llm"}` returns results
- Dashboard: All panels render

## Documentation Updates

After implementation is complete:

- [x] `docs/invariants/INVARIANTS.md` - Add INV-N004 (NIM Observability Enabled)
- [x] `README.md` - Add Observability section (Phase 3)
- [ ] `.claude/agents/nvidia-ai-specialist.md` - Add observability configuration guidance (deferred)

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Complete | 2026-01-22 | 2026-01-22 | Enable NIM metrics/logging |
| Phase 2 | Complete | 2026-01-22 | 2026-01-22 | Grafana dashboard |
| Phase 3 | Complete | 2026-01-22 | 2026-01-22 | README documentation |
| Phase 4 | Pending | | | End-to-end validation (requires deployment) |
