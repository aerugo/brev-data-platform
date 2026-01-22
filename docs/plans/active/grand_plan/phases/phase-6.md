# Phase 6: Storage Layer (MinIO + LakeFS)

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy MinIO for S3-compatible object storage and LakeFS for Git-like data versioning. Create the foundational buckets and repositories for the data platform.

---

## Invariants Enforced in This Phase

- **INV-K001**: Namespace per application - MinIO in `minio`, LakeFS in `lakefs`
- **INV-K002**: Resource limits on all pods
- **INV-K005**: No `latest` image tags
- **INV-S004**: MinIO credentials encrypted
- **INV-D001**: Standard bucket structure - `raw-data`, `data-products`, `lakefs`
- **INV-G004**: Sync waves for dependencies - MinIO (wave 1) before LakeFS (wave 1)

---

## Files to Create

### MinIO

#### k8s/apps/minio/Chart.yaml

```yaml
apiVersion: v2
name: minio
description: MinIO object storage for brev-data-platform
type: application
version: 0.1.0
appVersion: "RELEASE.2024-01-16T16-07-38Z"

dependencies:
  - name: minio
    version: 5.0.15
    repository: https://charts.min.io/
```

#### k8s/apps/minio/values.yaml

```yaml
# MinIO default values

minio:
  # Mode: standalone for dev
  mode: standalone

  # Image
  image:
    repository: quay.io/minio/minio
    tag: RELEASE.2024-01-16T16-07-38Z
    pullPolicy: IfNotPresent

  # Resources
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi

  # Persistence
  persistence:
    enabled: true
    size: 100Gi
    storageClass: local-path  # RKE2/K3S default

  # Root credentials from secret
  existingSecret: minio-credentials
  accessKey: ""  # From secret
  secretKey: ""  # From secret

  # Console
  consoleService:
    type: ClusterIP
    port: 9001

  # API
  service:
    type: ClusterIP
    port: 9000

  # Buckets to create on startup
  buckets:
    - name: raw-data
      policy: none
      purge: false
    - name: data-products
      policy: none
      purge: false
    - name: lakefs
      policy: none
      purge: false

  # No ingress (use port-forward)
  ingress:
    enabled: false
  consoleIngress:
    enabled: false
```

#### k8s/apps/minio/values-dev.yaml

```yaml
# Dev environment overrides

minio:
  persistence:
    size: 50Gi  # Smaller for dev

  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
```

#### k8s/apps/minio/templates/secret.yaml

```yaml
# Placeholder - actual secret is SOPS encrypted
# This tells ArgoCD to expect the secret from secrets.enc.yaml
{{- if not (lookup "v1" "Secret" .Release.Namespace "minio-credentials") }}
# Secret will be created from secrets.enc.yaml
{{- end }}
```

### LakeFS

#### k8s/apps/lakefs/Chart.yaml

```yaml
apiVersion: v2
name: lakefs
description: LakeFS data versioning for brev-data-platform
type: application
version: 0.1.0
appVersion: "1.3.1"

dependencies:
  - name: lakefs
    version: 1.0.0
    repository: https://charts.lakefs.io
```

#### k8s/apps/lakefs/values.yaml

```yaml
# LakeFS default values

lakefs:
  # Image
  image:
    repository: treeverse/lakefs
    tag: "1.3.1"
    pullPolicy: IfNotPresent

  # Resources
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi

  # Service
  service:
    type: ClusterIP
    port: 8000

  # Liveness/readiness
  livenessProbe:
    enabled: true
  readinessProbe:
    enabled: true

  # Configuration
  configuration:
    database:
      type: local  # Embedded database for dev
      local:
        path: /lakefs/data

    blockstore:
      type: s3
      s3:
        endpoint: http://minio.minio.svc.cluster.local:9000
        force_path_style: true
        # Credentials from env vars (populated from secret)

    auth:
      # Initial admin user
      encrypt:
        secret_key: "$(LAKEFS_AUTH_ENCRYPT_SECRET_KEY)"

  # Environment from secret
  extraEnvFrom:
    - secretRef:
        name: lakefs-credentials

  # Persistence for embedded DB
  persistence:
    enabled: true
    size: 10Gi
    storageClass: local-path

  # No ingress
  ingress:
    enabled: false

  # Init container to wait for MinIO
  initContainers:
    - name: wait-for-minio
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          until nc -z minio.minio.svc.cluster.local 9000; do
            echo "Waiting for MinIO..."
            sleep 5
          done
          echo "MinIO is ready!"
```

#### k8s/apps/lakefs/values-dev.yaml

```yaml
# Dev environment overrides

lakefs:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi

  persistence:
    size: 5Gi
```

#### k8s/apps/lakefs/templates/setup-job.yaml

```yaml
# Job to create initial repository after LakeFS is ready
apiVersion: batch/v1
kind: Job
metadata:
  name: lakefs-setup
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "10"
    helm.sh/hook-delete-policy: hook-succeeded
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: setup
          image: curlimages/curl:8.5.0
          command:
            - sh
            - -c
            - |
              echo "Waiting for LakeFS to be ready..."
              until curl -sf http://lakefs.lakefs.svc.cluster.local:8000/_health; do
                sleep 5
              done

              echo "Creating initial repository..."
              curl -X POST http://lakefs.lakefs.svc.cluster.local:8000/api/v1/repositories \
                -H "Content-Type: application/json" \
                -u "${LAKEFS_ACCESS_KEY_ID}:${LAKEFS_SECRET_ACCESS_KEY}" \
                -d '{
                  "name": "main-repo",
                  "storage_namespace": "s3://lakefs/main-repo",
                  "default_branch": "main"
                }' || echo "Repository may already exist"

              echo "Setup complete!"
          envFrom:
            - secretRef:
                name: lakefs-credentials
```

---

## Step 5.1: Update Helm Dependencies

```bash
# Update MinIO chart
cd k8s/apps/minio
helm dependency update
cd ../../..

# Update LakeFS chart
cd k8s/apps/lakefs
helm dependency update
cd ../../..
```

---

## Step 5.2: Apply Secrets

```bash
# Apply MinIO secrets
sops -d k8s/apps/minio/secrets.enc.yaml | kubectl apply -f -

# Apply LakeFS secrets
sops -d k8s/apps/lakefs/secrets.enc.yaml | kubectl apply -f -
```

---

## Step 5.3: Deploy via ArgoCD

If ArgoCD is configured, push to git and let it sync:

```bash
git add k8s/apps/minio k8s/apps/lakefs
git commit -m "Add MinIO and LakeFS charts"
git push

# ArgoCD will auto-sync, or force sync:
kubectl patch application minio -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
kubectl patch application lakefs -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'
```

Or deploy manually:

```bash
# Deploy MinIO
helm upgrade --install minio k8s/apps/minio \
  -n minio \
  -f k8s/apps/minio/values.yaml \
  -f k8s/apps/minio/values-dev.yaml

# Wait for MinIO
kubectl wait --for=condition=ready pod -l app=minio -n minio --timeout=300s

# Deploy LakeFS
helm upgrade --install lakefs k8s/apps/lakefs \
  -n lakefs \
  -f k8s/apps/lakefs/values.yaml \
  -f k8s/apps/lakefs/values-dev.yaml
```

---

## Step 5.4: Verify MinIO

```bash
# Check pods
kubectl get pods -n minio

# Port forward console
make port-forward-minio
# Or: kubectl port-forward svc/minio-console -n minio 9001:9001

# Access http://localhost:9001
# Login with credentials from secrets
```

In MinIO Console:
1. Verify you can log in
2. Check buckets exist: `raw-data`, `data-products`, `lakefs`
3. Try uploading a test file

---

## Step 5.5: Verify LakeFS

```bash
# Check pods
kubectl get pods -n lakefs

# Port forward
make port-forward-lakefs
# Or: kubectl port-forward svc/lakefs -n lakefs 8000:8000

# Access http://localhost:8000
# Login with LakeFS credentials from secrets
```

In LakeFS UI:
1. Verify you can log in
2. Check `main-repo` repository exists
3. Verify `main` branch exists

---

## Step 5.6: Test Data Flow

```bash
# Test MinIO CLI access (install mc if needed: brew install minio/stable/mc)
mc alias set brev-minio http://localhost:9000 admin YOUR_PASSWORD

# Upload test file
echo "test data" > /tmp/test.txt
mc cp /tmp/test.txt brev-minio/raw-data/

# List files
mc ls brev-minio/raw-data/

# Test LakeFS CLI (install lakectl if needed)
# Or use curl:
curl -u "ACCESS_KEY:SECRET_KEY" http://localhost:8000/api/v1/repositories
```

---

## Validation Approach

```bash
# MinIO running
kubectl get pods -n minio | grep -E "Running|1/1"

# LakeFS running
kubectl get pods -n lakefs | grep -E "Running|1/1"

# Buckets exist (via MinIO CLI or API)
mc ls brev-minio/ | grep -E "raw-data|data-products|lakefs"

# LakeFS repository exists
curl -sf -u "$LAKEFS_KEY:$LAKEFS_SECRET" http://localhost:8000/api/v1/repositories/main-repo
```

---

## Completion Criteria

- [ ] MinIO pods running in `minio` namespace
- [ ] MinIO console accessible at http://localhost:9001
- [ ] Buckets created: `raw-data`, `data-products`, `lakefs`
- [ ] LakeFS pods running in `lakefs` namespace
- [ ] LakeFS UI accessible at http://localhost:8000
- [ ] LakeFS connected to MinIO backend
- [ ] Repository `main-repo` created
- [ ] Can upload/download files via MinIO
- [ ] Can list repositories via LakeFS API
- [ ] ArgoCD shows both applications as Synced/Healthy

---

## Next Phase

Once storage layer is running, proceed to [Phase 7: Observability Stack](phase-7.md) to deploy monitoring and logging.
