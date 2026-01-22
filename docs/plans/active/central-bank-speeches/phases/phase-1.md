# Phase 1: Weaviate Infrastructure

**Status**: Pending
**Type**: Kubernetes
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy Weaviate vector database as a single-node instance in the Kubernetes cluster, configured for development use with persistent storage and proper resource limits. Weaviate is managed by ArgoCD and automatically included in `make setup` via the app-of-apps pattern.

---

## Integration with `make setup`

Weaviate is automatically included when running `make setup` on a fresh cluster:

1. The `bootstrap-argocd.sh` script deploys the ArgoCD app-of-apps
2. ArgoCD reads all Application manifests from `k8s/apps/argocd-apps/templates/`
3. The `weaviate.yaml` Application manifest tells ArgoCD to deploy Weaviate
4. ArgoCD syncs the Weaviate Helm chart from `k8s/apps/weaviate/`
5. PersistentVolumeClaim is created for vector storage (20Gi)

**No modifications to `make setup` or `scripts/` are required** - the existing GitOps workflow handles new applications automatically.

---

## Invariants Enforced in This Phase

- **INV-K001**: Namespace Per Application - Weaviate deploys to dedicated `weaviate` namespace
- **INV-K002**: Resource Limits on All Pods - Configure requests and limits for Weaviate pod
- **INV-K005**: No Hardcoded Image Tags as `latest` - Pin Weaviate to specific version (1.27.6)
- **INV-G001**: App-of-Apps Pattern - Add Weaviate Application via argocd-apps
- **INV-G004**: Sync Waves for Dependencies - Weaviate in wave 1 (with storage layer)
- **INV-K003**: Persistent Storage for Stateful Services - Weaviate uses PVC for vector index data

---

## Implementation Steps

### Step 1.1: Create Weaviate Helm Chart Directory

**Action**: Create

**File(s)**: `k8s/apps/weaviate/`

Create the directory structure for the Weaviate Helm chart.

```bash
mkdir -p k8s/apps/weaviate/templates
```

---

### Step 1.2: Create Chart.yaml

**Action**: Create

**File(s)**: `k8s/apps/weaviate/Chart.yaml`

Create the Helm chart metadata. We'll use Weaviate's official Helm chart as a dependency.

```yaml
apiVersion: v2
name: weaviate
description: Weaviate vector database for Brev Data Platform
type: application
version: 0.1.0
appVersion: "1.27.6"

dependencies:
  - name: weaviate
    version: "17.4.0"
    repository: "https://weaviate.github.io/weaviate-helm"
```

**Validation**:
```bash
# Verify chart structure
cat k8s/apps/weaviate/Chart.yaml
```

---

### Step 1.3: Create values.yaml

**Action**: Create

**File(s)**: `k8s/apps/weaviate/values.yaml`

Configure Weaviate for single-node development deployment.

```yaml
# Weaviate Vector Database Configuration
# Official chart: https://github.com/weaviate/weaviate-helm
#
# Configured for single-node development deployment
# - No authentication (internal-only access)
# - Persistent storage for vector index
# - Resource limits per INV-K002

weaviate:
  # Single replica for development
  replicas: 1

  # Image configuration (pinned version per INV-K005)
  image:
    registry: cr.weaviate.io
    repo: semitechnologies/weaviate
    tag: 1.27.6

  # Service configuration
  service:
    name: weaviate
    type: ClusterIP
    port: 8080
    grpcPort: 50051
    annotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "2112"
      prometheus.io/path: "/metrics"

  # Resource limits per INV-K002
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi

  # Persistence configuration - REQUIRED for data durability
  # Creates a PersistentVolumeClaim for the vector index
  storage:
    size: 20Gi
    storageClassName: ""  # Use default storage class (Longhorn on Brev)

  # Ensure persistence is enabled
  persistence:
    enabled: true
    size: 20Gi
    accessMode: ReadWriteOnce
    # Note: Weaviate chart creates PVC automatically when persistence.enabled=true

  # Environment configuration
  env:
    # Cluster configuration (single-node)
    CLUSTER_HOSTNAME: "weaviate-0"
    CLUSTER_JOIN: ""

    # Module configuration
    DEFAULT_VECTORIZER_MODULE: "none"
    ENABLE_MODULES: ""

    # Performance tuning for dev
    QUERY_DEFAULTS_LIMIT: 20
    QUERY_MAXIMUM_RESULTS: 10000

    # Disable authentication for development
    AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED: "true"

    # Telemetry (optional, can be disabled)
    DISABLE_TELEMETRY: "true"

    # Logging
    LOG_LEVEL: "info"
    LOG_FORMAT: "text"

  # Disable authentication for development
  # NOTE: For production, enable OIDC or API key auth
  authentication:
    anonymous_access:
      enabled: true

  # Disable authorization for development
  authorization:
    admin_list: []

  # Liveness and readiness probes
  livenessProbe:
    enabled: true
    initialDelaySeconds: 30
    periodSeconds: 10
    timeoutSeconds: 5

  readinessProbe:
    enabled: true
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 5

  # gRPC configuration for vector operations
  grpcService:
    enabled: true
    type: ClusterIP
    port: 50051

  # Backups disabled for development
  backups:
    enabled: false

  # Modules - using external embeddings, no vectorizer modules needed
  modules:
    # No text2vec modules - we generate embeddings externally via NVIDIA API
    text2vecContextionary:
      enabled: false
    text2vecTransformers:
      enabled: false
    text2vecOpenAI:
      enabled: false
    text2vecCohere:
      enabled: false
    # Generative module disabled - using NIM for generation
    generativeOpenAI:
      enabled: false
    generativeCohere:
      enabled: false
```

**Validation**:
```bash
# Lint the values
helm lint k8s/apps/weaviate/
```

---

### Step 1.4: Update Helm Dependencies

**Action**: Configure

**File(s)**: `k8s/apps/weaviate/`

Download the Weaviate dependency chart.

```bash
cd k8s/apps/weaviate
helm dependency update
cd ../../..
```

**Validation**:
```bash
# Verify Chart.lock was created
cat k8s/apps/weaviate/Chart.lock

# Verify charts directory
ls k8s/apps/weaviate/charts/
```

---

### Step 1.5: Create ArgoCD Application

**Action**: Create

**File(s)**: `k8s/apps/argocd-apps/templates/weaviate.yaml`

Create the ArgoCD Application manifest to deploy Weaviate via GitOps.

```yaml
# Weaviate Application - Vector Database
# Sync Wave 1: Storage Layer (with MinIO, LakeFS)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: weaviate
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/aerugo/brev-data-platform.git
    targetRevision: main
    path: k8s/apps/weaviate
  destination:
    server: https://kubernetes.default.svc
    namespace: weaviate
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**Validation**:
```bash
# Verify YAML syntax
cat k8s/apps/argocd-apps/templates/weaviate.yaml | kubectl apply --dry-run=client -f -
```

---

### Step 1.6: Create .helmignore

**Action**: Create

**File(s)**: `k8s/apps/weaviate/.helmignore`

Standard Helm ignore file.

```
# Patterns to ignore when building packages.
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
*~
.project
.idea/
*.tmproj
.vscode/
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `k8s/apps/weaviate/Chart.yaml` | CREATE | Helm chart metadata with dependency |
| `k8s/apps/weaviate/values.yaml` | CREATE | Weaviate configuration |
| `k8s/apps/weaviate/.helmignore` | CREATE | Helm ignore patterns |
| `k8s/apps/weaviate/Chart.lock` | GENERATE | Dependency lock file |
| `k8s/apps/weaviate/charts/` | GENERATE | Downloaded chart dependency |
| `k8s/apps/argocd-apps/templates/weaviate.yaml` | CREATE | ArgoCD application manifest |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED` | `true` | Allow unauthenticated access (dev only) |
| `DEFAULT_VECTORIZER_MODULE` | `none` | No auto-vectorization (we provide embeddings) |
| `QUERY_DEFAULTS_LIMIT` | `20` | Default query result limit |
| `QUERY_MAXIMUM_RESULTS` | `10000` | Max results for large queries |
| `LOG_LEVEL` | `info` | Standard logging |

### Secrets Required

No new secrets required for Weaviate in development mode (anonymous access enabled).

For production, would need:
| Secret | Source | How to Create |
|--------|--------|---------------|
| `weaviate-api-key` | SOPS | For API key authentication |

---

## Verification

### Pre-flight Checks

```bash
# Ensure Helm is available
helm version

# Ensure ArgoCD is running
kubectl get pods -n argocd

# Ensure storage class is available
kubectl get storageclass
```

### Validation Commands

```bash
# Helm validation
helm lint k8s/apps/weaviate/
helm template weaviate k8s/apps/weaviate/ --namespace weaviate

# After ArgoCD sync, verify deployment
kubectl get pods -n weaviate
kubectl get pvc -n weaviate
kubectl get svc -n weaviate

# Check Weaviate health (from within cluster)
kubectl run -n weaviate curl-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s http://weaviate.weaviate.svc.cluster.local:8080/v1/.well-known/ready

# Check metrics endpoint
kubectl run -n weaviate curl-test --rm -it --image=curlimages/curl:8.5.0 --restart=Never -- \
  curl -s http://weaviate.weaviate.svc.cluster.local:2112/metrics | head -20
```

### Expected Outcomes

- `helm lint` passes without errors
- ArgoCD syncs the Weaviate application successfully
- Weaviate pod reaches Running state
- PVC is bound with 20Gi storage
- Health endpoint returns `{"status":"HEALTHY"}`
- gRPC port 50051 is accessible
- REST API port 8080 is accessible

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| PVC not binding | Pod stuck in Pending | Check storage class, verify PV availability |
| Pod OOMKilled | Pod restarts with OOMKilled | Increase memory limit in values.yaml |
| Helm dependency download fails | `helm dependency update` errors | Check network, verify Weaviate chart repo URL |
| ArgoCD sync fails | Application stuck in OutOfSync | Check ArgoCD logs, verify GitHub access |
| Port conflict | Service not created | Check if port 8080 in use by another service |

### Rollback Plan

If this phase fails:
1. Delete ArgoCD application: `kubectl delete application weaviate -n argocd`
2. Delete namespace: `kubectl delete namespace weaviate`
3. Remove files: `rm -rf k8s/apps/weaviate k8s/apps/argocd-apps/templates/weaviate.yaml`
4. Investigate logs and fix issues
5. Retry from Step 1.1

---

## Completion Criteria

- [ ] `k8s/apps/weaviate/` directory structure created
- [ ] Chart.yaml with Weaviate dependency defined
- [ ] values.yaml with proper resource limits and persistence enabled
- [ ] Chart.lock generated by helm dependency update
- [ ] ArgoCD Application manifest created at `k8s/apps/argocd-apps/templates/weaviate.yaml`
- [ ] `helm lint k8s/apps/weaviate/` passes
- [ ] `helm template` renders valid YAML
- [ ] ArgoCD syncs Weaviate application automatically (app-of-apps)
- [ ] Weaviate pod in Running state
- [ ] **PVC bound with 20Gi storage** (verify with `kubectl get pvc -n weaviate`)
- [ ] Health endpoint returns 200
- [ ] Included automatically in `make setup` (no script changes needed)
- [ ] Invariants INV-K001, INV-K002, INV-K003, INV-K005, INV-G001, INV-G004 verified
