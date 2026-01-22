# Feature: NIM LLM Observability

**Status**: Complete
**Created**: 2026-01-22
**Category**: Infrastructure | Kubernetes

## Goal

Enable comprehensive logging and monitoring of all LLM calls through NIM's native OpenTelemetry and Prometheus support, integrated with the existing observability stack.

## Background

The platform runs NVIDIA NIM for LLM inference but currently has no visibility into:
- What prompts are being sent to the model
- What responses are being generated
- Latency and throughput metrics per request
- Token usage and cost tracking
- Error rates and failure patterns

This is critical for:
1. **Debugging** - Understanding why LLM enrichments fail or produce unexpected results
2. **Quality monitoring** - Reviewing prompt/response pairs for accuracy
3. **Cost tracking** - Understanding token consumption patterns
4. **Performance tuning** - Identifying bottlenecks and optimizing batch sizes
5. **Compliance** - Audit trail of all AI-generated content in data pipelines

NVIDIA NIM containers have built-in OpenTelemetry and Prometheus support that is currently disabled. This plan enables these native capabilities rather than adding external tooling.

## Acceptance Criteria

- [x] AC1: All NIM LLM requests are logged with full prompt and response text to Loki
- [x] AC2: Prometheus metrics are exposed at `/metrics` and scraped by existing Prometheus instance
- [x] AC3: Grafana dashboard exists showing NIM latency (P50/P95/P99), throughput, and error rates
- [x] AC4: Logs are queryable in Grafana Loki with labels for model, caller, and timestamp
- [x] AC5: GPU metrics (DCGM) are correlated with NIM inference metrics in Grafana
- [x] AC6: README.md documents the observability architecture and how to query logs/metrics

## Technical Requirements

### Infrastructure Changes (Terraform)

- None required - observability infrastructure already exists

### Kubernetes Changes (Helm)

1. **NIM values.yaml** - Add environment variables to enable:
   - OpenTelemetry tracing export
   - Prometheus metrics endpoint
   - Request/response logging to stdout

2. **Monitoring values.yaml** - Add:
   - Prometheus scrape config for NIM `/metrics` endpoint
   - ServiceMonitor resource for NIM

3. **New Grafana Dashboard** - ConfigMap with:
   - NIM inference latency histogram
   - Token throughput gauge
   - Error rate panel
   - Combined view with DCGM GPU metrics

### Application Changes

- None required - NIM's native observability handles everything

### GitOps Changes

- ArgoCD will sync the updated Helm values automatically
- No new Applications required

## Dependencies

- Existing Prometheus/Grafana/Loki stack (deployed via monitoring chart)
- DCGM Exporter (already scraping GPU metrics)
- NIM LLM deployment (already running)

## Out of Scope

- Distributed tracing with Jaeger/Tempo (future enhancement)
- Semantic caching or prompt deduplication
- Cost allocation per Dagster job (requires Dagster integration work)
- Alerting rules (can be added after baseline metrics are established)
- Integration with external LLM observability platforms (Langfuse, LangSmith)

## Security Considerations

- **Prompt/response logging**: Full text logging may contain sensitive data. Logs are retained for 7 days (Loki default) and accessible only via port-forward
- **No additional secrets required**: NIM observability uses cluster-internal endpoints
- **RBAC**: Grafana access controls who can view logs (existing configuration)

## Resource Requirements

- **GPU**: No additional GPU requirements
- **Memory/CPU**: Minimal overhead (~50MB for OTEL collector sidecar if used)
- **Storage**: Log volume increase in Loki (~10-50KB per LLM call depending on prompt/response size)

## Open Questions

- [x] Q1: Should we use OTEL Collector sidecar or direct export? → Direct export to simplify architecture
- [x] Q2: Full prompt/response logging or truncated? → Full logging with 7-day retention
- [ ] Q3: Should we add Tempo for distributed tracing? → Deferred to future enhancement