# Phase 4: KAI Scheduler

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Install and configure KAI Scheduler for advanced GPU workload scheduling. This enables fractional GPU allocation, gang scheduling, and topology-aware placement for NVIDIA AI workloads.

---

## Why KAI Scheduler?

KAI Scheduler is the open-source GPU scheduler from NVIDIA/Run:AI that provides:

| Feature | Description |
|---------|-------------|
| **Fractional GPU** | Allocate 0.1-1.0 GPU to workloads (e.g., 0.5 GPU) |
| **Gang Scheduling** | Schedule multi-GPU jobs atomically |
| **Topology Awareness** | Optimize placement for NVLink topology |
| **Fair Queuing** | Priority-based scheduling with quotas |
| **Bin Packing** | Maximize GPU utilization |
| **Preemption** | Higher priority jobs can preempt lower ones |

### Use Cases for This Platform

1. **NIM LLM** (~80GB VRAM) - Full GPU access, high priority
2. **Safe Synthesizer** (~80GB VRAM) - Full GPU access, medium priority
3. **Future workloads** - Fractional GPU for smaller inference jobs

---

## Invariants Enforced in This Phase

- **INV-K007**: KAI Scheduler for GPU workloads - All GPU pods use `schedulerName: kai-scheduler`
- **INV-K008**: RKE2 as Kubernetes distribution - Required prerequisite
- **NEW INV-K009**: KAI Scheduler in kube-system - Deployed as core cluster component

---

## Prerequisites

- RKE2 cluster running with GPU support (Phase 3 complete)
- NVIDIA device plugin deployed and GPU visible to Kubernetes
- kubectl access configured locally

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                         │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                      kube-system namespace                  │  │
│  │  ┌──────────────┐  ┌─────────────────┐  ┌──────────────┐   │  │
│  │  │    KAI       │  │  NVIDIA Device  │  │   Default    │   │  │
│  │  │  Scheduler   │  │     Plugin      │  │  Scheduler   │   │  │
│  │  └──────────────┘  └─────────────────┘  └──────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                     nvidia-ai namespace                     │  │
│  │  ┌────────────────┐         ┌────────────────────────┐     │  │
│  │  │    NIM LLM     │◄───────▶│    Safe Synthesizer    │     │  │
│  │  │  (kai-sched)   │         │      (kai-sched)       │     │  │
│  │  └────────────────┘         └────────────────────────┘     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                     Other namespaces                        │  │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐   │  │
│  │  │ ArgoCD │ │ MinIO  │ │ LakeFS │ │Dagster │ │ Marimo │   │  │
│  │  │ (def)  │ │ (def)  │ │ (def)  │ │ (def)  │ │ (def)  │   │  │
│  │  └────────┘ └────────┘ └────────┘ └────────┘ └────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

**Note**: Only GPU workloads use KAI Scheduler. Non-GPU workloads use the default Kubernetes scheduler.

---

## Files Created

### Helm Chart Structure

```
k8s/apps/kai-scheduler/
├── Chart.yaml           # Chart metadata and dependencies
├── values.yaml          # Default configuration
└── values-dev.yaml      # Development environment overrides
```

### ArgoCD Application

```
k8s/apps/argocd-apps/templates/kai-scheduler.yaml
```

---

## Step 3.5.1: Deploy KAI Scheduler via Helm

### Option A: Direct Helm Install (Before ArgoCD)

```bash
# Add NVIDIA Helm repository
helm repo add nvidia https://nvidia.github.io/KAI-Scheduler
helm repo update

# Create the Helm chart locally (if not already created)
# The chart is at k8s/apps/kai-scheduler/

# Install KAI Scheduler
helm upgrade --install kai-scheduler k8s/apps/kai-scheduler \
  -n kube-system \
  -f k8s/apps/kai-scheduler/values.yaml \
  -f k8s/apps/kai-scheduler/values-dev.yaml

# Watch pod status
kubectl get pods -n kube-system -l app.kubernetes.io/name=kai-scheduler -w
```

### Option B: Via ArgoCD (After Phase 4)

KAI Scheduler is automatically deployed via ArgoCD app-of-apps at sync wave 0.

```bash
# Verify ArgoCD application
kubectl get application kai-scheduler -n argocd

# Check sync status
argocd app get kai-scheduler
```

---

## Step 3.5.2: Verify KAI Scheduler Installation

```bash
# Check KAI Scheduler pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=kai-scheduler
# Expected: kai-scheduler-* pods in Running state

# Check KAI Scheduler logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kai-scheduler --tail=50

# Verify scheduler is registered
kubectl get pods -n kube-system -o wide | grep kai

# Check CRDs installed
kubectl get crds | grep kai
# Expected: podgroups.kai.nvidia.com, queues.kai.nvidia.com
```

---

## Step 3.5.3: Test KAI Scheduler

### Test 1: Schedule a GPU Pod via KAI

```bash
# Create a test GPU pod using KAI Scheduler
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: kai-gpu-test
  namespace: default
spec:
  schedulerName: kai-scheduler
  restartPolicy: Never
  containers:
    - name: cuda-test
      image: nvidia/cuda:12.0-base
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

# Watch pod scheduling
kubectl get pod kai-gpu-test -w

# Check which scheduler was used
kubectl get pod kai-gpu-test -o jsonpath='{.spec.schedulerName}'
# Expected: kai-scheduler

# Check pod events
kubectl describe pod kai-gpu-test | grep -A 10 "Events:"

# View GPU output
kubectl logs kai-gpu-test

# Clean up
kubectl delete pod kai-gpu-test
```

### Test 2: Verify Default Scheduler Still Works

```bash
# Create a non-GPU pod using default scheduler
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: default-scheduler-test
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: alpine
      image: alpine
      command: ["echo", "hello from default scheduler"]
EOF

# Check scheduler used
kubectl get pod default-scheduler-test -o jsonpath='{.spec.schedulerName}'
# Expected: default-scheduler

# Clean up
kubectl delete pod default-scheduler-test
```

---

## Step 3.5.4: Configure Queues and Quotas (Optional)

For multi-tenant or prioritized workloads:

```bash
# Create a high-priority queue for NIM
cat <<EOF | kubectl apply -f -
apiVersion: kai.nvidia.com/v1
kind: Queue
metadata:
  name: nvidia-ai-high
spec:
  priority: 100
  quota:
    gpu: 1
EOF

# Create a medium-priority queue for Safe Synthesizer
cat <<EOF | kubectl apply -f -
apiVersion: kai.nvidia.com/v1
kind: Queue
metadata:
  name: nvidia-ai-medium
spec:
  priority: 50
  quota:
    gpu: 1
EOF

# List queues
kubectl get queues.kai.nvidia.com
```

---

## Scheduler Selection Strategy

| Workload Type | Scheduler | Reason |
|---------------|-----------|--------|
| NIM LLM | `kai-scheduler` | GPU workload, needs priority scheduling |
| Safe Synthesizer | `kai-scheduler` | GPU workload, needs bin packing |
| Dagster Workers (GPU) | `kai-scheduler` | If using GPU for ML jobs |
| Dagster Workers (CPU) | `default-scheduler` | No GPU, default is fine |
| MinIO | `default-scheduler` | Storage, no GPU |
| LakeFS | `default-scheduler` | Storage, no GPU |
| ArgoCD | `default-scheduler` | Control plane, no GPU |
| Prometheus/Grafana | `default-scheduler` | Monitoring, no GPU |
| Marimo | `default-scheduler` | Usually CPU-based notebooks |

---

## Configuring Workloads to Use KAI Scheduler

### In Helm Values (Recommended)

```yaml
# Example: k8s/apps/nvidia-nim/values.yaml
schedulerName: kai-scheduler

# Or in pod spec directly
podSpec:
  schedulerName: kai-scheduler
```

### In Deployment Manifests

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-llm
spec:
  template:
    spec:
      schedulerName: kai-scheduler  # <-- Add this
      containers:
        - name: nim
          resources:
            limits:
              nvidia.com/gpu: 1
```

---

## KAI Scheduler Configuration

### values.yaml Key Settings

```yaml
kai-scheduler:
  # Enable GPU scheduling features
  config:
    gpuScheduling:
      enabled: true

    # Fractional GPU support
    fractionalGpu:
      enabled: true
      minFraction: 0.1

    # GPU memory enforcement
    memoryEnforcement:
      enabled: true

    # Gang scheduling for multi-GPU jobs
    gangScheduling:
      enabled: true
      timeout: 300s

    # Topology-aware placement
    topologyAwareness:
      enabled: true

    # Bin packing strategy
    binPacking:
      enabled: true
      strategy: "best-fit"
```

---

## Validation Approach

```bash
# 1. KAI Scheduler pods running
kubectl get pods -n kube-system -l app.kubernetes.io/name=kai-scheduler

# 2. CRDs installed
kubectl get crds | grep kai

# 3. GPU pod scheduled via KAI
kubectl run kai-test --rm -it --restart=Never \
  --overrides='{"spec":{"schedulerName":"kai-scheduler"}}' \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi

# 4. Check scheduler metrics (if Prometheus is running)
kubectl port-forward -n kube-system svc/kai-scheduler-metrics 8080:8080
curl http://localhost:8080/metrics | grep kai_scheduler
```

---

## Troubleshooting

### KAI Scheduler Pod Not Starting

```bash
# Check pod events
kubectl describe pod -n kube-system -l app.kubernetes.io/name=kai-scheduler

# Check logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kai-scheduler

# Common issues:
# - Missing RBAC permissions
# - CRD installation failed
# - Incompatible Kubernetes version
```

### GPU Pods Stuck in Pending

```bash
# Check pod events
kubectl describe pod <pod-name>

# Check KAI Scheduler logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kai-scheduler | grep -i error

# Verify GPU is available
kubectl describe node | grep -A5 "Allocatable"

# Verify schedulerName is correct
kubectl get pod <pod-name> -o jsonpath='{.spec.schedulerName}'
```

### Scheduler Not Picking Up Pods

```bash
# Verify pod has correct schedulerName
kubectl get pod <pod-name> -o yaml | grep schedulerName

# Check scheduler binding events
kubectl get events --field-selector reason=Scheduled
```

---

## Resource Status After This Phase

| Resource | Status | Verification |
|----------|--------|--------------|
| KAI Scheduler | Running | `kubectl get pods -n kube-system -l app.kubernetes.io/name=kai-scheduler` |
| KAI CRDs | Installed | `kubectl get crds \| grep kai` |
| GPU Scheduling | Working | Test pod with `schedulerName: kai-scheduler` |
| Default Scheduler | Unaffected | Non-GPU pods schedule normally |

---

## Completion Criteria

- [ ] KAI Scheduler pods running in `kube-system` namespace
- [ ] KAI CRDs installed (podgroups, queues)
- [ ] Can schedule GPU pod using `schedulerName: kai-scheduler`
- [ ] KAI Scheduler logs show successful scheduling
- [ ] Default scheduler still works for non-GPU pods
- [ ] Test GPU workload completes successfully

---

## Next Phase

Once KAI Scheduler is running, proceed to [Phase 5: ArgoCD Bootstrap](phase-5.md) to set up GitOps deployment.

**Note**: After Phase 5, all GPU workloads (NIM, Safe Synthesizer) will automatically use KAI Scheduler via their Helm values.
