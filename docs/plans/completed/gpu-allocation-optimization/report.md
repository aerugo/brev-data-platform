# GPU Allocation Optimization Report

> **Status**: Completed
> **Date**: 2026-01-23
> **Branch**: `claude/optimize-gpu-allocation-BuNKL`

---

## Executive Summary

This report documents the implementation of a dual-model GPU allocation strategy for the Brev Data Platform. The optimization enables running two LLM models concurrently (Llama 3.1 8B and GPT-OSS-120B) on a single NVIDIA H200 141GB GPU using KAI Scheduler's fractional GPU allocation.

**Key Outcomes:**
- Added GPT-OSS-120B reasoning model (80GB) for complex tasks
- Right-sized Llama 8B allocation from 70GB to 25GB
- Increased GPU utilization from 50% to 76%
- Maintained 34GB headroom for notebooks and batch jobs

---

## 1. Problem Statement

### Original Configuration

The platform was configured with a single LLM (Llama 3.1 8B) allocated **70GB** of GPU memory, despite the model only requiring ~20GB. This over-allocation:

- Wasted ~50GB of available VRAM
- Prevented running additional GPU workloads concurrently
- Limited the platform to a single inference model
- Required manual intervention to run batch jobs (Safe Synthesizer)

### Requirements

- Add a larger reasoning model for complex tasks
- Maintain fast inference capability for simple queries
- Enable concurrent operation of multiple models
- Preserve ability to run JupyterHub GPU notebooks and batch jobs

---

## 2. Solution Architecture

### Dual-Model Strategy

The solution implements two complementary LLM services:

| Service | Model | GPU Memory | Use Case |
|---------|-------|------------|----------|
| `nim-llm` | Llama 3.1 8B | 25GB | Fast inference, simple tasks |
| `nim-reasoning` | GPT-OSS-120B | 80GB | Complex reasoning, multi-step problems |
| `nim-embedding` | nv-embedqa-e5-v5 | 2GB | Vector embeddings for RAG |

### Why GPT-OSS-120B?

GPT-OSS-120B uses a **Mixture-of-Experts (MoE)** architecture:

- 117B total parameters across 128 experts
- Only **5.1B parameters active** per inference
- Trained with MXFP4 quantization to fit in 80GB
- Provides configurable reasoning effort (low/medium/high)

This architecture delivers 120B-class quality with 80GB memory footprint—ideal for the H200's capacity.

---

## 3. GPU Memory Budget

### H200 141GB Allocation

```
┌─────────────────────────────────────────────────────────────────┐
│                     NVIDIA H200 (141GB)                         │
├─────────────────────────────────────────────────────────────────┤
│ ┌─────────────┐ ┌──────────────────────────────┐ ┌───┐ ┌──────┐ │
│ │  Llama 8B   │ │       GPT-OSS-120B           │ │Emb│ │ Free │ │
│ │    25GB     │ │          80GB                │ │2GB│ │ 34GB │ │
│ └─────────────┘ └──────────────────────────────┘ └───┘ └──────┘ │
│     nim-llm          nim-reasoning           nim-embedding      │
└─────────────────────────────────────────────────────────────────┘
     Total Inference: 107GB          Available: 34GB
```

### Comparison: Before vs After

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Models available | 1 | 2 | +100% |
| GPU utilization | 50% (70/141) | 76% (107/141) | +52% |
| Reasoning capability | Basic | Advanced (configurable) | Significant |
| Available for notebooks | 71GB | 34GB | Trade-off |
| Concurrent inference | Yes | Yes | Maintained |

---

## 4. Technical Implementation

### 4.1 New Helm Chart: `nvidia-nim-reasoning`

Created at `k8s/apps/nvidia-nim-reasoning/` with the following structure:

```
nvidia-nim-reasoning/
├── Chart.yaml              # Helm chart metadata
├── values.yaml             # Configuration (80GB GPU, priorities)
└── templates/
    ├── deployment.yaml     # Kubernetes deployment
    ├── service.yaml        # ClusterIP service (port 8000)
    ├── pvc.yaml            # 100Gi persistent volume for model cache
    └── servicemonitor.yaml # Prometheus metrics collection
```

**Key Configuration** (`values.yaml`):

```yaml
image:
  repository: nvcr.io/nim/openai/gpt-oss-120b
  tag: "1.0.0"

resources:
  requests:
    nvidia.com/gpu: 1
    memory: 96Gi
  limits:
    nvidia.com/gpu: 1
    memory: 128Gi

podAnnotations:
  kai.scheduler.nvidia.com/gpu-memory: "80Gi"

schedulerName: kai-scheduler
priorityClassName: inference

podLabels:
  kai.scheduler/queue: inference-queue
  model-type: reasoning
```

### 4.2 Right-Sized Llama 8B Allocation

Modified `k8s/apps/nvidia-nim/values.yaml`:

```yaml
# Before: 70Gi (over-allocated)
# After:  25Gi (right-sized with headroom)
podAnnotations:
  kai.scheduler.nvidia.com/gpu-memory: "25Gi"
```

### 4.3 Updated KAI Scheduler Queues

Modified `k8s/apps/kai-scheduler/templates/queues.yaml`:

```yaml
# inference-queue now supports 3 GPU requests
spec:
  resources:
    gpu:
      quota: 1
      limit: 3      # Was 2, now 3 (LLM, Reasoning, Embedding)
    memory:
      quota: 110000000000  # ~110GB for all inference models
```

### 4.4 ArgoCD Integration

Created `k8s/apps/argocd-apps/templates/nvidia-nim-reasoning.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nvidia-nim-reasoning
  annotations:
    argocd.argoproj.io/sync-wave: "3"  # AI Layer
spec:
  source:
    path: k8s/apps/nvidia-nim-reasoning
  destination:
    namespace: nvidia-ai
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## 5. How KAI Scheduler Manages GPU Sharing

### Fractional GPU Allocation

KAI Scheduler enables multiple pods to share a single GPU through:

1. **Memory Enforcement**: Each pod declares GPU memory needs via annotation
   ```yaml
   kai.scheduler.nvidia.com/gpu-memory: "80Gi"
   ```

2. **Admission Control**: KAI validates total memory requests don't exceed GPU capacity

3. **Scheduling Decisions**: Pods are co-located on the same GPU when memory permits

### Priority-Based Preemption

When resources are constrained:

| Priority Class | Value | Behavior |
|---------------|-------|----------|
| `batch-high` | 130 | Can preempt inference workloads |
| `inference` | 125 | Non-preemptible under normal conditions |
| `build-preemptible` | 75 | Can be preempted by higher priority |

**Preemption Flow** (Safe Synthesizer example):

1. Safe Synthesizer job submitted with `batch-high` priority (130)
2. KAI preempts lower-priority inference pods if GPU memory insufficient
3. Job runs to completion
4. Kubernetes restarts preempted deployments automatically

### Queue Hierarchy

```
default-parent-queue (cluster-level, 1 GPU)
├── inference-queue (priority 100, limit 3 GPUs via fractional)
│   ├── nim-llm (25GB)
│   ├── nim-reasoning (80GB)
│   └── nim-embedding (2GB)
├── batch-queue (priority 50, borrows via preemption)
│   └── safe-synthesizer jobs
└── default-queue (backwards compatibility)
```

---

## 6. Service Endpoints

After deployment, applications can access both models in the `nvidia-ai` namespace:

### Fast Inference (Llama 8B)

```bash
curl http://nim-llm.nvidia-ai:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Deep Reasoning (GPT-OSS-120B)

```bash
curl http://nim-reasoning.nvidia-ai:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-120b",
    "messages": [{"role": "user", "content": "Explain quantum entanglement"}],
    "reasoning_effort": "high"
  }'
```

### Model Selection Guide

| Task Type | Recommended Model | Reason |
|-----------|-------------------|--------|
| Simple Q&A | Llama 8B | Faster response, lower latency |
| Code generation | Llama 8B | Good quality, high throughput |
| Complex reasoning | GPT-OSS-120B | Better multi-step reasoning |
| Math problems | GPT-OSS-120B | Configurable reasoning depth |
| Summarization | Llama 8B | Adequate quality, faster |
| Analysis tasks | GPT-OSS-120B | More thorough analysis |

---

## 7. Files Changed

| File | Change Type | Description |
|------|-------------|-------------|
| `k8s/apps/nvidia-nim-reasoning/Chart.yaml` | Created | Helm chart metadata |
| `k8s/apps/nvidia-nim-reasoning/values.yaml` | Created | GPT-OSS-120B configuration |
| `k8s/apps/nvidia-nim-reasoning/templates/deployment.yaml` | Created | Kubernetes deployment |
| `k8s/apps/nvidia-nim-reasoning/templates/service.yaml` | Created | ClusterIP service |
| `k8s/apps/nvidia-nim-reasoning/templates/pvc.yaml` | Created | Model cache PVC |
| `k8s/apps/nvidia-nim-reasoning/templates/servicemonitor.yaml` | Created | Prometheus metrics |
| `k8s/apps/argocd-apps/templates/nvidia-nim-reasoning.yaml` | Created | ArgoCD application |
| `k8s/apps/nvidia-nim/values.yaml` | Modified | Reduced GPU: 70GB → 25GB |
| `k8s/apps/nvidia-nim/Chart.yaml` | Modified | Updated documentation |
| `k8s/apps/kai-scheduler/templates/queues.yaml` | Modified | GPU limit: 2 → 3 |
| `docs/invariants/INVARIANTS.md` | Modified | Documented new GPU budget |

---

## 8. Performance Expectations

### Inference Throughput

| Model | Tokens/sec | Time-to-first-token | Concurrent Requests |
|-------|------------|---------------------|---------------------|
| Llama 8B | 50-100 | 100-300ms | 8-16 |
| GPT-OSS-120B | 30-50 | 500ms-1s | 2-4 |

### Quality Comparison

| Capability | Llama 8B | GPT-OSS-120B |
|------------|----------|--------------|
| Simple tasks | Good | Excellent (overkill) |
| Code generation | Good | Excellent |
| Multi-step reasoning | Moderate | Excellent |
| Mathematical reasoning | Moderate | Excellent |
| Instruction following | Good | Excellent |

---

## 9. Monitoring and Observability

Both models expose Prometheus metrics at `/v1/metrics`:

- Request latency histograms
- Token throughput
- Queue depth
- GPU memory utilization
- Error rates

ServiceMonitor resources are created for both services, enabling automatic scraping by the Prometheus stack.

---

## 10. Future Considerations

### Potential Optimizations

1. **Dynamic Model Loading**: Load GPT-OSS-120B on-demand to free GPU for notebooks
2. **Request Routing**: Implement intelligent routing based on query complexity
3. **Batch Inference**: Queue requests for GPT-OSS-120B to maximize throughput
4. **Model Caching**: Pre-warm models after preemption for faster recovery

### Scaling Options

- **Horizontal**: Add second H200 for dedicated reasoning workloads
- **Vertical**: Upgrade to H200 SXM (larger memory) if available
- **Hybrid**: Use API-based inference for overflow during peak demand

---

## 11. Conclusion

The dual-model GPU allocation strategy successfully:

- **Increases model diversity** by adding GPT-OSS-120B for reasoning tasks
- **Improves GPU utilization** from 50% to 76%
- **Maintains concurrency** via KAI Scheduler fractional allocation
- **Preserves flexibility** with 34GB available for notebooks and batch jobs
- **Enables intelligent routing** - applications can choose fast vs. thorough inference

The implementation follows GitOps principles with all configuration in version control and automatic deployment via ArgoCD.

---

## Appendix A: Commit History

```
fe3c792 Add GPT-OSS-120B reasoning model alongside Llama 8B
```

## Appendix B: Related Documentation

- [INVARIANTS.md](../../invariants/INVARIANTS.md) - INV-I003: H200 GPU requirements
- [KAI Scheduler Queues](../../../../k8s/apps/kai-scheduler/templates/queues.yaml)
- [NVIDIA NIM Values](../../../../k8s/apps/nvidia-nim/values.yaml)
- [NVIDIA NIM Reasoning Values](../../../../k8s/apps/nvidia-nim-reasoning/values.yaml)
