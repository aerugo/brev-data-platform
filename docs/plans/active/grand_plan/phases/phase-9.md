# Phase 9: NVIDIA AI Enterprise

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy NVIDIA NIM LLM for inference and NVIDIA Safe Synthesizer for synthetic data generation. Both services will be accessible from Dagster pipelines and Marimo notebooks. All GPU workloads are scheduled via KAI Scheduler for optimal resource utilization.

---

## Invariants Enforced in This Phase

- **INV-K003**: GPU resources explicitly requested - Both services must request `nvidia.com/gpu`
- **INV-K007**: KAI Scheduler for GPU workloads - All GPU pods use `schedulerName: kai-scheduler`
- **INV-N001**: NIM requires GPU node - Node selector for GPU
- **INV-N002**: Model configuration in ConfigMap - NIM model settings externalized
- **INV-N003**: Safe Synthesizer output to LakeFS - Synthetic data versioned
- **INV-S003**: NGC API key as Kubernetes secret - SOPS encrypted
- **INV-K006**: Sync wave ordering - AI (wave 3) after Platform (wave 2)

---

## Prerequisites

1. NGC API Key in encrypted secrets (from Phase 2)
2. RKE2 cluster with GPU support (verified in Phase 3)
3. KAI Scheduler deployed and running (Phase 3.5)
4. NVIDIA AI Enterprise license (for production models)

---

## Files to Create

### NIM LLM

#### k8s/apps/nvidia-nim/Chart.yaml

```yaml
apiVersion: v2
name: nvidia-nim
description: NVIDIA NIM LLM inference for brev-data-platform
type: application
version: 0.1.0
appVersion: "1.0.0"
```

#### k8s/apps/nvidia-nim/values.yaml

```yaml
# NVIDIA NIM LLM default values

image:
  repository: nvcr.io/nim/meta/llama3-8b-instruct
  tag: "1.0.0"
  pullPolicy: IfNotPresent

# NGC image pull secret
imagePullSecrets:
  - name: ngc-image-pull

replicaCount: 1

# GPU resources - REQUIRED
resources:
  requests:
    cpu: 4000m
    memory: 16Gi
    nvidia.com/gpu: 1
  limits:
    cpu: 8000m
    memory: 32Gi
    nvidia.com/gpu: 1

# KAI Scheduler for GPU workloads
schedulerName: kai-scheduler

# Node selection for GPU
nodeSelector:
  nvidia.com/gpu.present: "true"

tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"

# Service
service:
  type: ClusterIP
  port: 8000

# Model configuration
model:
  name: meta/llama3-8b-instruct
  maxTokens: 4096

# Environment
env:
  - name: NGC_API_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: api-key

# Readiness probe (model loading can take time)
readinessProbe:
  httpGet:
    path: /v1/health/ready
    port: 8000
  initialDelaySeconds: 120
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30

livenessProbe:
  httpGet:
    path: /v1/health/live
    port: 8000
  initialDelaySeconds: 120
  periodSeconds: 30
  timeoutSeconds: 5
```

#### k8s/apps/nvidia-nim/values-dev.yaml

```yaml
# Dev environment overrides

# Use smaller model for dev if needed
image:
  repository: nvcr.io/nim/meta/llama3-8b-instruct
  tag: "1.0.0"

resources:
  requests:
    cpu: 2000m
    memory: 8Gi
    nvidia.com/gpu: 1
  limits:
    cpu: 4000m
    memory: 16Gi
    nvidia.com/gpu: 1
```

#### k8s/apps/nvidia-nim/templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nim-llm
  labels:
    app: nim-llm
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: nim-llm
  template:
    metadata:
      labels:
        app: nim-llm
    spec:
      # KAI Scheduler for GPU workloads
      schedulerName: {{ .Values.schedulerName | default "kai-scheduler" }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: nim
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 8000
              name: http
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          env:
            {{- toYaml .Values.env | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

#### k8s/apps/nvidia-nim/templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nim-llm
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: nim-llm
```

#### k8s/apps/nvidia-nim/templates/configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nim-config
data:
  model_name: "{{ .Values.model.name }}"
  max_tokens: "{{ .Values.model.maxTokens }}"
```

### Safe Synthesizer

#### k8s/apps/nvidia-safe-synth/Chart.yaml

```yaml
apiVersion: v2
name: nvidia-safe-synth
description: NVIDIA Safe Synthesizer for synthetic data generation
type: application
version: 0.1.0
appVersion: "1.0.0"
```

#### k8s/apps/nvidia-safe-synth/values.yaml

```yaml
# NVIDIA Safe Synthesizer default values

image:
  repository: nvcr.io/nvidia/safe-synthesizer
  tag: "1.0.0"
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: ngc-image-pull

replicaCount: 1

# KAI Scheduler for GPU workloads
schedulerName: kai-scheduler

# GPU resources
resources:
  requests:
    cpu: 2000m
    memory: 8Gi
    nvidia.com/gpu: 1
  limits:
    cpu: 4000m
    memory: 16Gi
    nvidia.com/gpu: 1

nodeSelector:
  nvidia.com/gpu.present: "true"

tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"

service:
  type: ClusterIP
  port: 8080

env:
  - name: NGC_API_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: api-key
  # MinIO/LakeFS connection for data storage
  - name: S3_ENDPOINT
    value: "http://minio.minio.svc.cluster.local:9000"
  - name: S3_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: minio-access-key
        optional: true
  - name: S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: minio-secret-key
        optional: true

readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 10

livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 30
```

#### k8s/apps/nvidia-safe-synth/templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: safe-synthesizer
  labels:
    app: safe-synthesizer
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: safe-synthesizer
  template:
    metadata:
      labels:
        app: safe-synthesizer
    spec:
      # KAI Scheduler for GPU workloads
      schedulerName: {{ .Values.schedulerName | default "kai-scheduler" }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: safe-synth
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: 8080
              name: http
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          env:
            {{- toYaml .Values.env | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

#### k8s/apps/nvidia-safe-synth/templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: safe-synthesizer
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: safe-synthesizer
```

### Config Files

#### config/nim/model-config.yaml

```yaml
# NIM Model Configuration

model:
  name: meta/llama3-8b-instruct
  max_tokens: 4096
  temperature: 0.7
  top_p: 0.9

# Inference settings
inference:
  batch_size: 1
  timeout_seconds: 60

# Usage in Dagster pipelines
dagster_resource_config:
  endpoint: "http://nim-llm.nvidia-ai.svc.cluster.local:8000"
  model: "meta/llama3-8b-instruct"
```

#### config/safe-synthesizer/synth-config.yaml

```yaml
# Safe Synthesizer Configuration

# Default synthesis parameters
synthesis:
  method: "dp-ctgan"  # Differential privacy CTGAN
  epsilon: 1.0        # Privacy budget
  sample_size: 1000

# Output configuration
output:
  format: "parquet"
  destination: "lakefs://main-repo/main/synthetic/"

# Dagster resource config
dagster_resource_config:
  endpoint: "http://safe-synthesizer.nvidia-ai.svc.cluster.local:8080"
```

---

## Step 7.1: Apply Secrets

Ensure NGC credentials are applied (should be done in Phase 2):

```bash
# Verify secret exists
kubectl get secret ngc-credentials -n nvidia-ai

# If not, apply it
sops -d k8s/apps/nvidia-ai/secrets.enc.yaml | kubectl apply -f -
```

---

## Step 7.2: Deploy NIM LLM

```bash
# Deploy NIM
helm upgrade --install nvidia-nim k8s/apps/nvidia-nim \
  -n nvidia-ai \
  -f k8s/apps/nvidia-nim/values.yaml \
  -f k8s/apps/nvidia-nim/values-dev.yaml

# Watch pod status (model download takes time)
kubectl get pods -n nvidia-ai -w

# Check logs
kubectl logs -f deployment/nim-llm -n nvidia-ai
```

**Note**: NIM will take several minutes to start as it downloads and loads the model.

---

## Step 7.3: Verify NIM

```bash
# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=nim-llm -n nvidia-ai --timeout=600s

# Port forward
make port-forward-nim
# Or: kubectl port-forward svc/nim-llm -n nvidia-ai 8001:8000

# Test inference
curl -X POST http://localhost:8001/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama3-8b-instruct",
    "prompt": "What is the capital of France?",
    "max_tokens": 50
  }'
```

Expected response with generated text.

---

## Step 7.4: Deploy Safe Synthesizer

```bash
# Deploy Safe Synthesizer
helm upgrade --install nvidia-safe-synth k8s/apps/nvidia-safe-synth \
  -n nvidia-ai \
  -f k8s/apps/nvidia-safe-synth/values.yaml

# Watch pod status
kubectl get pods -n nvidia-ai -w
```

---

## Step 7.5: Verify Safe Synthesizer

```bash
# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=safe-synthesizer -n nvidia-ai --timeout=300s

# Port forward
kubectl port-forward svc/safe-synthesizer -n nvidia-ai 8082:8080

# Check health
curl http://localhost:8082/health
```

---

## Step 7.6: Verify GPU Utilization

```bash
# SSH into Brev instance
brev shell brev-data-platform-dev

# Check GPU usage
nvidia-smi

# Expected: NIM process using GPU memory
```

---

## Step 7.7: Add NIM Resource to Dagster

Update `dagster/resources/nvidia.py`:

```python
"""NVIDIA NIM resource for Dagster."""

from dagster import ConfigurableResource
import requests

class NIMResource(ConfigurableResource):
    """Resource for NVIDIA NIM LLM inference."""

    endpoint: str
    model: str = "meta/llama3-8b-instruct"
    api_key: str = ""  # Optional, for NGC authentication

    def generate(
        self,
        prompt: str,
        max_tokens: int = 1024,
        temperature: float = 0.7,
    ) -> str:
        """Generate text using NIM LLM."""
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        response = requests.post(
            f"{self.endpoint}/v1/completions",
            headers=headers,
            json={
                "model": self.model,
                "prompt": prompt,
                "max_tokens": max_tokens,
                "temperature": temperature,
            },
            timeout=60,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["text"]

    def chat(
        self,
        messages: list[dict],
        max_tokens: int = 1024,
        temperature: float = 0.7,
    ) -> str:
        """Chat completion using NIM LLM."""
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        response = requests.post(
            f"{self.endpoint}/v1/chat/completions",
            headers=headers,
            json={
                "model": self.model,
                "messages": messages,
                "max_tokens": max_tokens,
                "temperature": temperature,
            },
            timeout=60,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"]
```

---

## Validation Approach

```bash
# Check all NVIDIA AI pods running
kubectl get pods -n nvidia-ai

# Verify KAI Scheduler is used for GPU pods
kubectl get pods -n nvidia-ai -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.schedulerName}{"\n"}{end}'
# Expected: all GPU pods should show "kai-scheduler"

# Check GPU allocation
kubectl describe node | grep -A 10 "Allocated resources"

# Test NIM endpoint
curl -sf http://localhost:8001/v1/models | jq

# Test Safe Synthesizer
curl -sf http://localhost:8082/health

# Verify from inside cluster (via Dagster/Marimo)
kubectl run test-nim --rm -it --restart=Never \
  --image=curlimages/curl:8.5.0 \
  -- curl -s http://nim-llm.nvidia-ai.svc.cluster.local:8000/v1/models
```

---

## Troubleshooting

### NIM Won't Start

1. Check GPU available: `kubectl describe node | grep nvidia`
2. Check image pull: `kubectl describe pod -l app=nim-llm -n nvidia-ai`
3. Check NGC credentials: `kubectl get secret ngc-image-pull -n nvidia-ai`
4. Check logs: `kubectl logs -f deployment/nim-llm -n nvidia-ai`

### GPU Out of Memory

1. Only one GPU-using pod at a time
2. Reduce model size or use quantized version
3. Check other processes: `nvidia-smi` on instance

### Image Pull Errors

1. Verify NGC API key is correct
2. Check dockerconfigjson secret format
3. Try manual pull: `docker login nvcr.io`

---

## Completion Criteria

- [ ] NGC image pull secret applied
- [ ] NIM LLM pod running in `nvidia-ai` namespace
- [ ] NIM responds to inference requests
- [ ] Safe Synthesizer pod running
- [ ] Safe Synthesizer health endpoint responds
- [ ] GPU utilization visible in `nvidia-smi`
- [ ] Both pods using KAI Scheduler (`schedulerName: kai-scheduler`)
- [ ] NIM resource added to Dagster
- [ ] Both applications show Synced in ArgoCD

---

## Next Phase

Once NVIDIA AI services are running, proceed to [Phase 10: CI/CD Workflows](phase-10.md).
