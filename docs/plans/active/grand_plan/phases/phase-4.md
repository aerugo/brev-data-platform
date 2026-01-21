# Phase 4: ArgoCD Bootstrap

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy ArgoCD for GitOps-based continuous deployment. Configure repository access and set up the app-of-apps pattern for managing all platform applications.

---

## Invariants Enforced in This Phase

- **INV-G001**: App-of-apps pattern for ArgoCD - Single entry point for all applications
- **INV-G002**: Automated sync for dev environment - Auto-sync with self-heal
- **INV-G003**: Source of truth is Git - Repository connected to ArgoCD
- **INV-K001**: Namespace per application - ArgoCD in `argocd` namespace

---

## Files to Create

### 1. k8s/bootstrap/argocd/values.yaml

```yaml
# ArgoCD Helm values for brev-data-platform

# Server configuration
server:
  replicas: 1

  # Resource limits
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  # Disable TLS (we use port-forward)
  extraArgs:
    - --insecure

# Repo server
repoServer:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

# Application controller
controller:
  replicas: 1
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

# Redis
redis:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# Dex (disable - not needed for dev)
dex:
  enabled: false

# Notifications (disable for simplicity)
notifications:
  enabled: false

# ApplicationSet controller
applicationSet:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi

# Global configs
configs:
  params:
    # Allow insecure access (dev only)
    server.insecure: true

  # Repository credentials (will be added via secret)
  repositories: {}

  # Resource customizations for NVIDIA CRDs (if needed)
  resource.customizations: |
    argoproj.io/Application:
      health.lua: |
        hs = {}
        hs.status = "Healthy"
        hs.message = ""
        if obj.status ~= nil then
          if obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            end
          end
        end
        return hs
```

### 2. k8s/bootstrap/argocd/install.sh

```bash
#!/bin/bash
# Install ArgoCD using Helm

set -e

echo "Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values k8s/bootstrap/argocd/values.yaml \
  --wait

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

echo ""
echo "ArgoCD installed successfully!"
echo ""
echo "Get admin password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Port forward:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo ""
echo "Access: https://localhost:8080"
echo "Username: admin"
```

### 3. k8s/apps/argocd-apps/Chart.yaml

```yaml
apiVersion: v2
name: argocd-apps
description: ArgoCD Application definitions for brev-data-platform
type: application
version: 0.1.0
appVersion: "1.0.0"
```

### 4. k8s/apps/argocd-apps/values.yaml

```yaml
# ArgoCD Applications configuration

# Git repository
repoURL: https://github.com/YOUR_USERNAME/brev-data-platform.git
targetRevision: HEAD

# Base path for apps
basePath: k8s/apps

# Applications to deploy
applications:
  minio:
    enabled: true
    namespace: minio
    path: k8s/apps/minio
    syncWave: "1"

  lakefs:
    enabled: true
    namespace: lakefs
    path: k8s/apps/lakefs
    syncWave: "1"

  dagster:
    enabled: true
    namespace: dagster
    path: k8s/apps/dagster
    syncWave: "2"

  marimo:
    enabled: true
    namespace: marimo
    path: k8s/apps/marimo
    syncWave: "2"

  nvidia-nim:
    enabled: true
    namespace: nvidia-ai
    path: k8s/apps/nvidia-nim
    syncWave: "3"

  nvidia-safe-synth:
    enabled: true
    namespace: nvidia-ai
    path: k8s/apps/nvidia-safe-synth
    syncWave: "3"
```

### 5. k8s/apps/argocd-apps/templates/applications.yaml

```yaml
{{- range $name, $app := .Values.applications }}
{{- if $app.enabled }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ $name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ $app.syncWave | quote }}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: {{ $.Values.repoURL }}
    targetRevision: {{ $.Values.targetRevision }}
    path: {{ $app.path }}
    helm:
      valueFiles:
        - values.yaml
        - values-dev.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: {{ $app.namespace }}

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true

  ignoreDifferences:
    - group: ""
      kind: Secret
      jsonPointers:
        - /data
{{- end }}
{{- end }}
```

### 6. k8s/apps/argocd-apps/templates/root-app.yaml

```yaml
# Root Application - manages all other applications
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: {{ .Values.repoURL }}
    targetRevision: {{ .Values.targetRevision }}
    path: k8s/apps/argocd-apps
    helm:
      valueFiles:
        - values.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Step 4.1: Install ArgoCD

```bash
# Ensure kubeconfig is set
export KUBECONFIG=$PWD/kubeconfig.yaml

# Make install script executable
chmod +x k8s/bootstrap/argocd/install.sh

# Run installation
./k8s/bootstrap/argocd/install.sh

# Or use make
make bootstrap-argocd
```

---

## Step 4.2: Access ArgoCD UI

```bash
# Get admin password
make argocd-password
# Or: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port forward
make port-forward-argocd
# Or: kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open browser to https://localhost:8080
# Username: admin
# Password: (from above command)
```

---

## Step 4.3: Apply Repository Credentials

The repository credentials secret should be applied so ArgoCD can pull from your private repo:

```bash
# Decrypt and apply the secret
sops -d k8s/apps/argocd-apps/secrets.enc.yaml | kubectl apply -f -
```

---

## Step 4.4: Deploy App-of-Apps

```bash
# Update values.yaml with your repo URL
sed -i "s|YOUR_USERNAME|your-actual-username|g" k8s/apps/argocd-apps/values.yaml

# Apply the root application
helm template argocd-apps k8s/apps/argocd-apps | kubectl apply -f -

# Or apply just the root app manually
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/brev-data-platform.git
    targetRevision: HEAD
    path: k8s/apps/argocd-apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

---

## Step 4.5: Verify ArgoCD Setup

```bash
# Check ArgoCD pods
kubectl get pods -n argocd

# Check applications
kubectl get applications -n argocd

# Check application status (via CLI)
kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}'
```

---

## Validation Approach

### ArgoCD Health

```bash
# All ArgoCD pods running
kubectl get pods -n argocd
# Expected: argocd-server, argocd-repo-server, argocd-application-controller, argocd-redis

# ArgoCD server accessible
curl -k https://localhost:8080/healthz  # (with port-forward active)
```

### Repository Connection

In ArgoCD UI:
1. Go to Settings → Repositories
2. Verify your repository shows "Successful" connection status

### Applications

```bash
# Root application synced
kubectl get application root-apps -n argocd -o jsonpath='{.status.sync.status}'
# Expected: Synced

# Child applications created (may be OutOfSync until charts exist)
kubectl get applications -n argocd
```

---

## Completion Criteria

- [ ] ArgoCD installed and all pods Running
- [ ] Can access ArgoCD UI at https://localhost:8080
- [ ] Admin password retrieved and working
- [ ] Repository credentials secret applied
- [ ] Repository shows "Successful" in ArgoCD UI
- [ ] Root application created
- [ ] App-of-apps pattern configured
- [ ] Child applications visible (status may be OutOfSync)

---

## Notes

- Child applications will show as "OutOfSync" or "Missing" until their Helm charts are created in subsequent phases
- This is expected - ArgoCD is ready but waiting for the application manifests

---

## Next Phase

Once ArgoCD is running, proceed to [Phase 5: Storage Layer](phase-5.md) to deploy MinIO and LakeFS.
