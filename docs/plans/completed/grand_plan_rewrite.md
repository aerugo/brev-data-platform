# Grand Plan Rewrite: K3S → RKE2 + KAI Scheduler

**Status**: Planning
**Created**: 2026-01-21
**Priority**: High
**Scope**: Major architectural change

---

## Executive Summary

This plan outlines the migration from K3S to RKE2 and the addition of KAI Scheduler for GPU workload management. This change is driven by:

1. **Run:AI Compatibility**: K3S is not supported by Run:AI. RKE2 is officially supported.
2. **Enterprise Readiness**: RKE2 is FIPS-compliant and designed for enterprise/government workloads.
3. **GPU Scheduling**: KAI Scheduler (open-source from Run:AI) provides advanced GPU scheduling, fractional GPU allocation, and gang scheduling.
4. **Future Path**: RKE2 + KAI provides a migration path to full Run:AI if needed.

---

## Technology Comparison

### K3S vs RKE2

| Aspect | K3S | RKE2 |
|--------|-----|------|
| Target Use | Edge, IoT, dev | Enterprise, production |
| FIPS Compliance | No | Yes |
| Run:AI Support | No | Yes |
| Container Runtime | containerd | containerd |
| CNI | Flannel | Canal (Calico + Flannel) |
| Install Complexity | Simple | Moderate |
| Resource Footprint | ~512MB RAM | ~1-2GB RAM |
| Binary Size | ~50MB | ~200MB |

### KAI Scheduler Benefits

| Feature | Native K8s | KAI Scheduler |
|---------|------------|---------------|
| GPU Allocation | Whole GPU only | Fractional GPUs |
| Multi-GPU Jobs | Manual | Gang scheduling |
| GPU Memory Limits | None | Enforced |
| Fairness Policies | None | Bin packing, spread |
| Topology Awareness | Limited | NVLink-aware |
| Preemption | Basic | Priority-based |

---

## Impact Analysis

### Files Requiring Modification

#### Documentation (grand_plan/)

| File | Changes Required |
|------|------------------|
| `spec.md` | Update architecture diagram, K3S→RKE2, add KAI references |
| `development-plan.md` | Update deployment flow, phases, invariants |
| `phases/phase-1.md` | Change cloud-init script reference to RKE2 |
| `phases/phase-3.md` | **Complete rewrite** - RKE2 bootstrap instead of K3S |
| `phases/phase-5.5-observability.md` | Update GPU scheduling references |
| `phases/phase-7.md` | Add KAI scheduler integration, update GPU scheduling |
| `phases/phase-7-nvidia-ai.md` | Update NIM/Safe Synth for KAI scheduling |
| `phases/phase-9.md` | Update validation steps |

#### Scripts

| File | Changes Required |
|------|------------------|
| `scripts/bootstrap-k3s.sh` | Replace with `bootstrap-rke2.sh` |
| `scripts/cloud-init/k3s-gpu.yaml` | Replace with `rke2-gpu.yaml` |
| `scripts/setup-kubeconfig.sh` | Update kubeconfig path (RKE2 uses `/etc/rancher/rke2/`) |

#### Kubernetes Manifests

| File | Changes Required |
|------|------------------|
| `k8s/apps/nvidia-nim/values.yaml` | Add KAI scheduler annotations |
| `k8s/apps/nvidia-safe-synth/values.yaml` | Add KAI scheduler annotations |
| `k8s/apps/monitoring/values.yaml` | Add KAI metrics scraping |

#### Other Files

| File | Changes Required |
|------|------------------|
| `Makefile` | Update bootstrap targets, add KAI targets |
| `README.md` | Update quick start instructions |
| `.CLAUDE.md` | Update tech stack description |
| `docs/invariants/INVARIANTS.md` | Add RKE2 and KAI invariants |

---

## New Components to Add

### 1. KAI Scheduler Helm Chart

Create `k8s/apps/kai-scheduler/`:
- `Chart.yaml`
- `values.yaml`
- `values-dev.yaml`
- `templates/` (if not using upstream chart)

### 2. New Phase Document

Create `phases/phase-3.5-kai-scheduler.md`:
- KAI Scheduler deployment
- GPU resource configuration
- Scheduler class setup
- Integration with existing workloads

### 3. RKE2 Bootstrap Scripts

Create:
- `scripts/bootstrap-rke2.sh`
- `scripts/cloud-init/rke2-gpu.yaml`

---

## Detailed Change Plan

### Phase 1: Documentation Updates

#### 1.1 Update spec.md

```diff
- Deploy a complete GPU-accelerated data platform on NVIDIA Brev with K3S, ArgoCD GitOps
+ Deploy a complete GPU-accelerated data platform on NVIDIA Brev with RKE2, KAI Scheduler, ArgoCD GitOps
```

Update architecture diagram to include KAI Scheduler component.

#### 1.2 Update development-plan.md

- Change deployment flow to include KAI Scheduler phase
- Update invariants:
  - `INV-I004`: Cloud-init for RKE2 bootstrap (was K3S)
  - Add `INV-K007`: KAI Scheduler for GPU workloads
- Update sync waves: KAI Scheduler at wave 0.5 (after ArgoCD, before apps)

#### 1.3 Rewrite phase-3.md

Complete rewrite for RKE2:

```yaml
# Key differences from K3S:
RKE2:
  install_script: "curl -sfL https://get.rke2.io | sh -"
  service: rke2-server.service
  kubeconfig: /etc/rancher/rke2/rke2.yaml
  kubectl: /var/lib/rancher/rke2/bin/kubectl
  containerd_config: /etc/rancher/rke2/config.yaml

K3S (old):
  install_script: "curl -sfL https://get.k3s.io | sh -"
  service: k3s.service
  kubeconfig: /etc/rancher/k3s/k3s.yaml
  kubectl: /usr/local/bin/kubectl
```

#### 1.4 Create phase-3.5-kai-scheduler.md

New phase for KAI Scheduler:

```markdown
# Phase 3.5: KAI Scheduler

## Objective
Deploy KAI Scheduler for advanced GPU workload scheduling including fractional GPUs,
gang scheduling, and topology-aware placement.

## Steps
1. Add KAI Scheduler Helm repository
2. Deploy KAI Scheduler
3. Configure GPU resource classes
4. Create scheduler class for GPU workloads
5. Update existing deployments to use KAI scheduler
```

#### 1.5 Update phase-7.md and phase-7-nvidia-ai.md

Add KAI scheduler annotations to NIM and Safe Synthesizer:

```yaml
spec:
  template:
    metadata:
      annotations:
        # KAI Scheduler annotations
        kai.scheduler/gpu-fraction: "1.0"  # Full GPU
        kai.scheduler/gpu-memory: "80Gi"   # Memory limit
    spec:
      schedulerName: kai-scheduler
```

### Phase 2: Script Updates

#### 2.1 Create bootstrap-rke2.sh

```bash
#!/bin/bash
# RKE2 Bootstrap Script for GPU-enabled Brev Instance

set -e

echo "=== Installing RKE2 ==="
curl -sfL https://get.rke2.io | sudo sh -

# Configure RKE2 for GPU support
sudo mkdir -p /etc/rancher/rke2
cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
# RKE2 Configuration
disable:
  - rke2-ingress-nginx  # We'll use ArgoCD-managed ingress if needed

# Container runtime configuration for NVIDIA
# containerd will be configured separately
EOF

# Enable and start RKE2
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service

# Wait for RKE2 to be ready
echo "Waiting for RKE2..."
until sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null; do
  sleep 5
done

# Install NVIDIA Container Toolkit
echo "=== Installing NVIDIA Container Toolkit ==="
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Configure containerd for NVIDIA (RKE2 uses containerd)
sudo nvidia-ctk runtime configure --runtime=containerd --config=/var/lib/rancher/rke2/agent/etc/containerd/config.toml
sudo systemctl restart rke2-server.service

# Install NVIDIA device plugin
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
  apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/nvidia-device-plugin.yml

echo "=== RKE2 with GPU Support Ready ==="
```

#### 2.2 Update setup-kubeconfig.sh

```diff
- REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
+ REMOTE_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
```

#### 2.3 Update Makefile

```makefile
# Change bootstrap-k3s to bootstrap-rke2
bootstrap-rke2: ## Bootstrap RKE2 with GPU support on remote instance
	@echo "$(GREEN)Bootstrapping RKE2 on $(INSTANCE_NAME)...$(RESET)"
	scp -F $(SSH_CONFIG) scripts/bootstrap-rke2.sh $(INSTANCE_NAME)-host:/tmp/
	ssh -F $(SSH_CONFIG) $(INSTANCE_NAME)-host 'chmod +x /tmp/bootstrap-rke2.sh && sudo /tmp/bootstrap-rke2.sh'

# Add KAI Scheduler targets
deploy-kai: ## Deploy KAI Scheduler
	helm upgrade --install kai-scheduler k8s/apps/kai-scheduler -n kube-system

# Keep old target as alias for backwards compatibility
bootstrap-k3s: bootstrap-rke2
	@echo "$(YELLOW)Note: Using RKE2 instead of K3S$(RESET)"
```

### Phase 3: Kubernetes Manifests

#### 3.1 Create KAI Scheduler Helm Chart

`k8s/apps/kai-scheduler/Chart.yaml`:
```yaml
apiVersion: v2
name: kai-scheduler
description: KAI Scheduler for GPU workload scheduling
type: application
version: 0.1.0
appVersion: "0.4.0"

dependencies:
  - name: kai-scheduler
    version: "0.4.0"
    repository: https://project-kai.github.io/kai-scheduler
```

`k8s/apps/kai-scheduler/values.yaml`:
```yaml
kai-scheduler:
  # Enable GPU scheduling features
  gpuScheduling:
    enabled: true
    fractionalGPU: true
    memoryEnforcement: true

  # Topology awareness for multi-GPU
  topology:
    enabled: true
    nvlinkAware: true

  # Resource configuration
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # Metrics for Prometheus
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
```

#### 3.2 Update NIM values.yaml

```yaml
# Add to nvidia-nim/values.yaml
schedulerName: kai-scheduler

podAnnotations:
  kai.scheduler/gpu-fraction: "1.0"
  kai.scheduler/gpu-memory: "80Gi"
  kai.scheduler/priority: "high"
```

#### 3.3 Update Safe Synthesizer values.yaml

```yaml
# Add to nvidia-safe-synth/values.yaml
schedulerName: kai-scheduler

podAnnotations:
  kai.scheduler/gpu-fraction: "1.0"
  kai.scheduler/gpu-memory: "80Gi"
  kai.scheduler/priority: "medium"
```

#### 3.4 Add KAI to ArgoCD App-of-Apps

Create `k8s/apps/argocd-apps/templates/kai-scheduler.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kai-scheduler
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Deploy early, before GPU workloads
spec:
  project: default
  source:
    repoURL: https://github.com/aerugo/brev-data-platform.git
    targetRevision: main
    path: k8s/apps/kai-scheduler
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Phase 4: Update Sync Wave Ordering

New sync wave order:
```
Wave 0:  Bootstrap (ArgoCD, KAI Scheduler)
Wave 1:  Storage (MinIO, LakeFS) + Observability
Wave 2:  Platform (Dagster, Marimo)
Wave 3:  AI (NIM, Safe Synthesizer)
```

---

## Implementation Order

### Step 1: Create New Scripts (No Breaking Changes)
1. [ ] Create `scripts/bootstrap-rke2.sh`
2. [ ] Create `scripts/cloud-init/rke2-gpu.yaml`
3. [ ] Update `scripts/setup-kubeconfig.sh` to support both

### Step 2: Create KAI Scheduler Chart
4. [ ] Create `k8s/apps/kai-scheduler/Chart.yaml`
5. [ ] Create `k8s/apps/kai-scheduler/values.yaml`
6. [ ] Create ArgoCD application for KAI

### Step 3: Update Documentation
7. [ ] Update `spec.md`
8. [ ] Update `development-plan.md`
9. [ ] Rewrite `phases/phase-3.md` for RKE2
10. [ ] Create `phases/phase-3.5-kai-scheduler.md`
11. [ ] Update `phases/phase-7.md` for KAI integration
12. [ ] Update `phases/phase-7-nvidia-ai.md`
13. [ ] Update `phases/phase-9.md` validation steps

### Step 4: Update Application Manifests
14. [ ] Update `k8s/apps/nvidia-nim/values.yaml`
15. [ ] Update `k8s/apps/nvidia-safe-synth/values.yaml`
16. [ ] Update `k8s/apps/monitoring/values.yaml` (KAI metrics)

### Step 5: Update Other Files
17. [ ] Update `Makefile`
18. [ ] Update `README.md`
19. [ ] Update `.CLAUDE.md`
20. [ ] Update `docs/invariants/INVARIANTS.md`

### Step 6: Testing
21. [ ] Test RKE2 bootstrap on fresh Brev instance
22. [ ] Test KAI Scheduler deployment
23. [ ] Test GPU workload scheduling with KAI
24. [ ] Verify NIM and Safe Synthesizer work with KAI

---

## New Invariants to Add

```markdown
# Add to INVARIANTS.md

## Kubernetes Distribution
- **INV-K008**: RKE2 as Kubernetes distribution - K3S is not supported for Run:AI compatibility

## GPU Scheduling
- **INV-K007**: KAI Scheduler for GPU workloads - All GPU pods must use `schedulerName: kai-scheduler`
- **INV-K009**: GPU memory limits enforced - GPU workloads must specify `kai.scheduler/gpu-memory`
```

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| RKE2 higher resource usage | High | Low | H200 has 200GB RAM, plenty of headroom |
| KAI Scheduler learning curve | Medium | Medium | Document common patterns, provide examples |
| Brev compatibility issues | Low | High | Test on fresh instance before full migration |
| Breaking existing scripts | Medium | Medium | Keep backwards-compatible aliases |

---

## Success Criteria

1. [ ] Fresh Brev instance boots with RKE2 successfully
2. [ ] KAI Scheduler deploys and shows as healthy
3. [ ] NIM LLM scheduled via KAI with GPU allocated
4. [ ] Safe Synthesizer scheduled via KAI with GPU allocated
5. [ ] GPU metrics visible in Grafana (via DCGM + KAI metrics)
6. [ ] All documentation updated and consistent
7. [ ] `make full-setup` works end-to-end with new stack

---

## Timeline Estimate

| Phase | Scope | Effort |
|-------|-------|--------|
| Phase 1: Scripts | Create RKE2 bootstrap | 2-3 hours |
| Phase 2: KAI Chart | Create Helm chart | 1-2 hours |
| Phase 3: Documentation | Update all phase docs | 4-6 hours |
| Phase 4: Manifests | Update values files | 1-2 hours |
| Phase 5: Other Files | Makefile, README, etc | 1-2 hours |
| Phase 6: Testing | End-to-end validation | 2-4 hours |
| **Total** | | **11-19 hours** |

---

## References

- [RKE2 Documentation](https://docs.rke2.io/)
- [KAI Scheduler GitHub](https://github.com/project-kai/kai-scheduler)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/overview.html)
- [Run:AI Supported Platforms](https://docs.run.ai/latest/admin/runai-setup/cluster-setup/cluster-prerequisites/)
