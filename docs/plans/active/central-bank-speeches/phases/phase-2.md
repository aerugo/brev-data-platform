# Phase 2: NIM Embedding & Resource Setup

**Status**: Pending
**Type**: Infrastructure + Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy NVIDIA NIM embedding model (`llama-3_2-nemoretriever-300m-embed-v2`) to the cluster and create Dagster resources for embeddings and Weaviate client. All embedding generation uses local NIM endpoints - no external APIs.

---

## Invariants Enforced in This Phase

- **INV-S001**: No Plaintext Secrets in Git - Kaggle and NGC credentials encrypted with SOPS
- **INV-P003**: Type Annotations on Assets - Full type annotations on all resource methods
- **INV-N001**: NIM Requires GPU - Embedding NIM shares GPU with LLM NIM via KAI Scheduler
- **INV-K001**: Namespace Per Application - Embedding NIM in existing `nvidia-nim` namespace
- **INV-K002**: Resource Limits on All Pods - Embedding NIM has appropriate resource requests/limits
- **INV-K005**: No Hardcoded Image Tags as `latest` - Pin NIM embedding to specific version
- **NEW INV-N005**: Local-Only AI Services - No external API dependencies for AI workloads

---

## NIM Embedding Model Details

**Model**: `llama-3_2-nemoretriever-300m-embed-v2`
- 300M parameters (~600MB GPU memory in fp16)
- 1024-dimensional embeddings
- Optimized for retrieval tasks
- OpenAI-compatible API endpoint

**GPU Sharing Strategy**:
- LLM NIM uses ~70GB GPU memory
- Embedding NIM uses ~1GB GPU memory
- Both can run concurrently on H200 (141GB) via KAI Scheduler
- Total: ~71GB, leaving headroom for other workloads

---

## Implementation Steps

### Step 2.1: Create NIM Embedding Helm Chart

**Action**: Create

**File(s)**: `k8s/apps/nvidia-nim-embedding/Chart.yaml`

Create Helm chart metadata for NIM embedding model.

```yaml
apiVersion: v2
name: nvidia-nim-embedding
description: NVIDIA NIM Embedding Model for vector generation
type: application
version: 0.1.0
appVersion: "25.01"
```

---

### Step 2.2: Create NIM Embedding Values

**Action**: Create

**File(s)**: `k8s/apps/nvidia-nim-embedding/values.yaml`

Configure NIM embedding deployment with GPU sharing via KAI.

```yaml
# NVIDIA NIM Embedding Model Configuration
# Model: llama-3_2-nemoretriever-300m-embed-v2
#
# This is a 300M parameter embedding model optimized for retrieval.
# It shares the GPU with the LLM NIM via KAI Scheduler fractional allocation.

# Container image
image:
  repository: nvcr.io/nim/nvidia/llama-3_2-nemoretriever-300m-embed-v2
  tag: "1.3.0"
  pullPolicy: IfNotPresent

# NGC image pull secret
imagePullSecrets:
  - name: ngc-image-pull

# Replica count (single instance for development)
replicaCount: 1

# Service configuration
service:
  type: ClusterIP
  port: 8000
  annotations: {}

# Resource allocation
# 300M model uses ~1GB GPU memory, minimal CPU
resources:
  requests:
    cpu: "500m"
    memory: "2Gi"
    nvidia.com/gpu: "1"
  limits:
    cpu: "2"
    memory: "4Gi"
    nvidia.com/gpu: "1"

# KAI Scheduler configuration
schedulerName: kai-scheduler

# Queue assignment - shares inference queue with LLM NIM
podLabels:
  kai.scheduler/queue: inference-queue

# GPU memory annotation for KAI (fractional allocation)
podAnnotations:
  kai.scheduler.nvidia.com/gpu-memory: "2Gi"

# Priority class - same as LLM NIM
priorityClassName: inference

# Environment variables
env:
  - name: NGC_API_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: api-key
  - name: NIM_CACHE_PATH
    value: "/opt/nim/.cache"
  - name: NIM_LOG_LEVEL
    value: "INFO"

# Volume for model cache
persistence:
  enabled: true
  size: 20Gi
  storageClass: ""
  accessMode: ReadWriteOnce

# Health checks
livenessProbe:
  httpGet:
    path: /v1/health/live
    port: 8000
  initialDelaySeconds: 60
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /v1/health/ready
    port: 8000
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

# GPU node tolerations
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule

# Node selector (optional - run on GPU node)
nodeSelector: {}

# NVIDIA RuntimeClass
runtimeClassName: nvidia

# Service account
serviceAccount:
  create: true
  name: nvidia-nim-embedding

# Pod security context
podSecurityContext:
  fsGroup: 1000

securityContext:
  runAsUser: 1000
  runAsNonRoot: true
```

---

### Step 2.3: Create NIM Embedding Deployment Template

**Action**: Create

**File(s)**: `k8s/apps/nvidia-nim-embedding/templates/deployment.yaml`

Create the Kubernetes deployment for NIM embedding.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "nvidia-nim-embedding.fullname" . }}
  labels:
    {{- include "nvidia-nim-embedding.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "nvidia-nim-embedding.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "nvidia-nim-embedding.selectorLabels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        {{- with .Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ .Values.serviceAccount.name }}
      schedulerName: {{ .Values.schedulerName }}
      priorityClassName: {{ .Values.priorityClassName }}
      runtimeClassName: {{ .Values.runtimeClassName }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: nim-embedding
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          env:
            {{- toYaml .Values.env | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          volumeMounts:
            - name: cache
              mountPath: /opt/nim/.cache
      volumes:
        - name: cache
          {{- if .Values.persistence.enabled }}
          persistentVolumeClaim:
            claimName: {{ include "nvidia-nim-embedding.fullname" . }}-cache
          {{- else }}
          emptyDir: {}
          {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

---

### Step 2.4: Create Supporting Templates

**Action**: Create

**File(s)**:
- `k8s/apps/nvidia-nim-embedding/templates/_helpers.tpl`
- `k8s/apps/nvidia-nim-embedding/templates/service.yaml`
- `k8s/apps/nvidia-nim-embedding/templates/pvc.yaml`
- `k8s/apps/nvidia-nim-embedding/templates/serviceaccount.yaml`

**_helpers.tpl**:
```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "nvidia-nim-embedding.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "nvidia-nim-embedding.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "nvidia-nim-embedding.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nvidia-nim-embedding.labels" -}}
helm.sh/chart: {{ include "nvidia-nim-embedding.chart" . }}
{{ include "nvidia-nim-embedding.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nvidia-nim-embedding.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nvidia-nim-embedding.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

**service.yaml**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "nvidia-nim-embedding.fullname" . }}
  labels:
    {{- include "nvidia-nim-embedding.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    {{- include "nvidia-nim-embedding.selectorLabels" . | nindent 4 }}
```

**pvc.yaml**:
```yaml
{{- if .Values.persistence.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "nvidia-nim-embedding.fullname" . }}-cache
  labels:
    {{- include "nvidia-nim-embedding.labels" . | nindent 4 }}
spec:
  accessModes:
    - {{ .Values.persistence.accessMode }}
  {{- if .Values.persistence.storageClass }}
  storageClassName: {{ .Values.persistence.storageClass }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.persistence.size }}
{{- end }}
```

**serviceaccount.yaml**:
```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceAccount.name }}
  labels:
    {{- include "nvidia-nim-embedding.labels" . | nindent 4 }}
{{- end }}
```

---

### Step 2.5: Create ArgoCD Application

**Action**: Create

**File(s)**: `k8s/apps/argocd-apps/templates/nvidia-nim-embedding.yaml`

Add NIM embedding to ArgoCD app-of-apps.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nvidia-nim-embedding
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "3"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: {{ .Values.spec.source.repoURL }}
    targetRevision: {{ .Values.spec.source.targetRevision }}
    path: k8s/apps/nvidia-nim-embedding
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: {{ .Values.spec.destination.server }}
    namespace: nvidia-nim
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

### Step 2.6: Update pyproject.toml Dependencies

**Action**: Modify

**File(s)**: `dagster/pyproject.toml`

Add required dependencies (no OpenAI needed - using direct HTTP requests).

```toml
[project]
name = "brev_pipelines"
version = "0.1.0"
description = "Dagster pipelines for Brev Data Platform"
requires-python = ">=3.10"
dependencies = [
    "dagster>=1.6.0,<2.0.0",
    "pandas>=2.0.0",
    "polars>=1.0.0",
    "minio>=7.2.0",
    "lakefs-sdk>=1.0.0",
    "requests>=2.31.0",
    # New dependencies for central bank speeches
    "kagglehub[polars-datasets]>=0.3.0",
    "weaviate-client>=4.9.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=7.0.0",
    "pytest-cov>=4.0.0",
    "ruff>=0.1.0",
    "mypy>=1.0.0",
    "dagster-webserver>=1.6.0",
    "types-requests>=2.31.0",
]
```

**Validation**:
```bash
cd dagster
pip install -e ".[dev]"
pip list | grep -E "(kagglehub|weaviate|polars)"
```

---

### Step 2.7: Create NIM Embedding Resource

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/resources/nim_embedding.py`

Create a Dagster resource for generating embeddings via local NIM.

```python
"""NIM Embedding resource for Dagster.

Uses the locally deployed NIM embedding model (llama-3_2-nemoretriever-300m-embed-v2)
to generate text embeddings. The model exposes an OpenAI-compatible API endpoint.

Model: llama-3_2-nemoretriever-300m-embed-v2 (1024 dimensions)
"""

from typing import Any

import requests
from dagster import ConfigurableResource
from pydantic import Field


class NIMEmbeddingResource(ConfigurableResource):
    """NIM embedding resource for generating text embeddings via local NIM."""

    endpoint: str = Field(
        default="http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000",
        description="NIM embedding service endpoint",
    )
    model: str = Field(
        default="nvidia/llama-3_2-nemoretriever-300m-embed-v2",
        description="Embedding model name",
    )
    timeout: int = Field(default=120, description="Request timeout in seconds")
    max_retries: int = Field(default=3, description="Maximum retry attempts")

    def embed_texts(self, texts: list[str], batch_size: int = 32) -> list[list[float]]:
        """Generate embeddings for a list of texts.

        Args:
            texts: List of text strings to embed
            batch_size: Number of texts to embed per API call

        Returns:
            List of embedding vectors (1024 dimensions each)
        """
        all_embeddings: list[list[float]] = []

        for i in range(0, len(texts), batch_size):
            batch = texts[i : i + batch_size]
            embeddings = self._embed_batch(batch)
            all_embeddings.extend(embeddings)

        return all_embeddings

    def embed_text(self, text: str) -> list[float]:
        """Generate embedding for a single text.

        Args:
            text: Text string to embed

        Returns:
            Embedding vector (1024 dimensions)
        """
        return self._embed_batch([text])[0]

    def _embed_batch(self, texts: list[str]) -> list[list[float]]:
        """Internal method to embed a batch of texts."""
        # Truncate long texts (model has input limit)
        truncated_texts = [text[:8192] if len(text) > 8192 else text for text in texts]

        payload = {
            "model": self.model,
            "input": truncated_texts,
            "input_type": "passage",  # Use "query" for search queries
            "encoding_format": "float",
        }

        last_error = None
        for attempt in range(self.max_retries):
            try:
                response = requests.post(
                    f"{self.endpoint}/v1/embeddings",
                    json=payload,
                    timeout=self.timeout,
                )
                response.raise_for_status()
                data = response.json()

                # Sort by index to maintain order
                sorted_data = sorted(data["data"], key=lambda x: x["index"])
                return [item["embedding"] for item in sorted_data]

            except requests.exceptions.RequestException as e:
                last_error = e
                if attempt < self.max_retries - 1:
                    import time
                    time.sleep(2 ** attempt)  # Exponential backoff
                continue

        raise RuntimeError(f"NIM embedding error after {self.max_retries} attempts: {last_error}")

    def embed_query(self, query: str) -> list[float]:
        """Generate embedding for a search query.

        Uses 'query' input_type optimized for retrieval.

        Args:
            query: Query text to embed

        Returns:
            Embedding vector (1024 dimensions)
        """
        truncated = query[:8192] if len(query) > 8192 else query

        payload = {
            "model": self.model,
            "input": [truncated],
            "input_type": "query",  # Optimized for queries
            "encoding_format": "float",
        }

        response = requests.post(
            f"{self.endpoint}/v1/embeddings",
            json=payload,
            timeout=self.timeout,
        )
        response.raise_for_status()
        data = response.json()

        return data["data"][0]["embedding"]

    def health_check(self) -> bool:
        """Check if the NIM embedding service is healthy."""
        try:
            response = requests.get(
                f"{self.endpoint}/v1/health/ready",
                timeout=10,
            )
            return response.status_code == 200
        except Exception:
            return False

    @property
    def dimensions(self) -> int:
        """Return the embedding dimensions for the configured model."""
        # llama-3_2-nemoretriever-300m-embed-v2 produces 1024-dimensional embeddings
        return 1024
```

**Validation**:
```bash
cd dagster
python -c "from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource; print('Import OK')"
```

---

### Step 2.8: Create Weaviate Resource

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/resources/weaviate.py`

Create a Dagster resource for Weaviate client operations.

```python
"""Weaviate client resource for Dagster.

Provides methods for connecting to Weaviate, managing collections,
and performing vector operations. Uses Weaviate Python client v4.
"""

from typing import Any

import weaviate
from weaviate.classes.config import Configure, Property, DataType
from weaviate.classes.query import MetadataQuery
from dagster import ConfigurableResource
from pydantic import Field


class WeaviateResource(ConfigurableResource):
    """Weaviate vector database resource."""

    host: str = Field(
        default="weaviate.weaviate.svc.cluster.local",
        description="Weaviate host",
    )
    port: int = Field(default=8080, description="Weaviate HTTP port")
    grpc_port: int = Field(default=50051, description="Weaviate gRPC port")

    def get_client(self) -> weaviate.WeaviateClient:
        """Get a connected Weaviate client.

        Returns:
            Connected WeaviateClient instance
        """
        client = weaviate.connect_to_custom(
            http_host=self.host,
            http_port=self.port,
            http_secure=False,
            grpc_host=self.host,
            grpc_port=self.grpc_port,
            grpc_secure=False,
        )
        return client

    def ensure_collection(
        self,
        name: str,
        properties: list[dict[str, Any]],
        vector_dimensions: int = 1024,
    ) -> None:
        """Ensure a collection exists with the given schema.

        Args:
            name: Collection name (PascalCase)
            properties: List of property definitions
            vector_dimensions: Dimension of vectors to store
        """
        client = self.get_client()
        try:
            if client.collections.exists(name):
                return

            # Build property definitions
            props = []
            for prop in properties:
                data_type = DataType.TEXT
                if prop.get("type") == "date":
                    data_type = DataType.DATE
                elif prop.get("type") == "boolean":
                    data_type = DataType.BOOL
                elif prop.get("type") == "int":
                    data_type = DataType.INT

                props.append(Property(
                    name=prop["name"],
                    data_type=data_type,
                    description=prop.get("description", ""),
                ))

            # Create collection with no vectorizer (we provide embeddings)
            client.collections.create(
                name=name,
                vectorizer_config=Configure.Vectorizer.none(),
                properties=props,
            )
        finally:
            client.close()

    def insert_objects(
        self,
        collection_name: str,
        objects: list[dict[str, Any]],
        vectors: list[list[float]],
        batch_size: int = 100,
    ) -> int:
        """Insert objects with their vectors into a collection.

        Args:
            collection_name: Target collection name
            objects: List of property dictionaries
            vectors: Corresponding embedding vectors
            batch_size: Objects per batch insert

        Returns:
            Number of objects inserted
        """
        if len(objects) != len(vectors):
            raise ValueError("Objects and vectors must have same length")

        client = self.get_client()
        try:
            collection = client.collections.get(collection_name)

            with collection.batch.dynamic() as batch:
                for obj, vector in zip(objects, vectors):
                    batch.add_object(properties=obj, vector=vector)

            return len(objects)
        finally:
            client.close()

    def vector_search(
        self,
        collection_name: str,
        query_vector: list[float],
        limit: int = 10,
        return_properties: list[str] | None = None,
    ) -> list[dict[str, Any]]:
        """Perform vector similarity search.

        Args:
            collection_name: Collection to search
            query_vector: Query embedding vector
            limit: Maximum results to return
            return_properties: Properties to include in results

        Returns:
            List of matching objects with scores
        """
        client = self.get_client()
        try:
            collection = client.collections.get(collection_name)

            results = collection.query.near_vector(
                near_vector=query_vector,
                limit=limit,
                return_metadata=MetadataQuery(distance=True, certainty=True),
            )

            output = []
            for obj in results.objects:
                item = dict(obj.properties)
                item["_distance"] = obj.metadata.distance
                item["_certainty"] = obj.metadata.certainty
                output.append(item)

            return output
        finally:
            client.close()

    def get_object_count(self, collection_name: str) -> int:
        """Get the number of objects in a collection."""
        client = self.get_client()
        try:
            collection = client.collections.get(collection_name)
            response = collection.aggregate.over_all(total_count=True)
            return response.total_count or 0
        finally:
            client.close()

    def health_check(self) -> bool:
        """Check if Weaviate is healthy."""
        try:
            client = self.get_client()
            is_ready = client.is_ready()
            client.close()
            return is_ready
        except Exception:
            return False

    def delete_collection(self, name: str) -> bool:
        """Delete a collection if it exists."""
        client = self.get_client()
        try:
            if client.collections.exists(name):
                client.collections.delete(name)
                return True
            return False
        finally:
            client.close()
```

**Validation**:
```bash
cd dagster
python -c "from brev_pipelines.resources.weaviate import WeaviateResource; print('Import OK')"
```

---

### Step 2.9: Update Resource Exports

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/resources/__init__.py`

Update the resources module to export new resources.

```python
"""Brev Data Platform resources."""

from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.weaviate import WeaviateResource

__all__ = [
    "LakeFSResource",
    "MinIOResource",
    "NIMResource",
    "NIMEmbeddingResource",
    "WeaviateResource",
]
```

---

### Step 2.10: Add Resource Tests

**Action**: Modify

**File(s)**: `dagster/tests/test_resources.py`

Add tests for the new resources.

```python
"""Tests for Dagster resources."""

import pytest

from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.weaviate import WeaviateResource


class TestMinIOResource:
    """Tests for MinIO resource."""

    def test_initialization(self):
        """Test MinIO resource initialization."""
        resource = MinIOResource(
            endpoint="localhost:9000",
            access_key="minioadmin",
            secret_key="minioadmin",
            secure=False,
        )
        assert resource.endpoint == "localhost:9000"


class TestLakeFSResource:
    """Tests for LakeFS resource."""

    def test_initialization(self):
        """Test LakeFS resource initialization."""
        resource = LakeFSResource(
            endpoint="http://localhost:8000",
            access_key_id="test",
            secret_access_key="test",
        )
        assert "localhost" in resource.endpoint


class TestNIMResource:
    """Tests for NIM resource."""

    def test_initialization(self):
        """Test NIM resource initialization."""
        resource = NIMResource(
            endpoint="http://localhost:8000",
            model="meta/llama3-8b-instruct",
        )
        assert resource.model == "meta/llama3-8b-instruct"


class TestNIMEmbeddingResource:
    """Tests for NIM embedding resource."""

    def test_initialization(self):
        """Test NIM embedding resource initialization."""
        resource = NIMEmbeddingResource(
            endpoint="http://localhost:8000",
        )
        assert resource.model == "nvidia/llama-3_2-nemoretriever-300m-embed-v2"
        assert resource.dimensions == 1024

    def test_default_values(self):
        """Test default configuration values."""
        resource = NIMEmbeddingResource()
        assert "nvidia-nim-embedding" in resource.endpoint
        assert resource.timeout == 120
        assert resource.max_retries == 3

    def test_custom_endpoint(self):
        """Test custom endpoint configuration."""
        resource = NIMEmbeddingResource(
            endpoint="http://custom-nim:8000",
        )
        assert resource.endpoint == "http://custom-nim:8000"


class TestWeaviateResource:
    """Tests for Weaviate resource."""

    def test_initialization(self):
        """Test Weaviate resource initialization."""
        resource = WeaviateResource(
            host="weaviate.weaviate.svc.cluster.local",
            port=8080,
        )
        assert resource.host == "weaviate.weaviate.svc.cluster.local"

    def test_default_ports(self):
        """Test default port configuration."""
        resource = WeaviateResource()
        assert resource.port == 8080
        assert resource.grpc_port == 50051
```

**Validation**:
```bash
cd dagster
pytest tests/test_resources.py -v
```

---

### Step 2.11: Update .env.example

**Action**: Modify

**File(s)**: `.env.example`

Add Kaggle credentials placeholder.

```bash
# Add to existing .env.example
# Kaggle API credentials (for dataset download)
KAGGLE_USERNAME=your-kaggle-username
KAGGLE_KEY=your-kaggle-api-key
```

---

### Step 2.12: Update secrets creation script

**Action**: Modify

**File(s)**: `scripts/create-secrets.sh`

Add Kaggle secret creation. Add the following section to the script:

```bash
# Kaggle credentials secret for Dagster
echo "Creating Kaggle credentials secret..."
KAGGLE_SECRET=$(cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kaggle-credentials
  namespace: dagster
type: Opaque
stringData:
  username: "${KAGGLE_USERNAME}"
  key: "${KAGGLE_KEY}"
EOF
)

echo "$KAGGLE_SECRET" | sops --encrypt --age "$AGE_RECIPIENT" /dev/stdin > \
    "k8s/apps/dagster/secrets/kaggle-credentials.enc.yaml"
echo "Created k8s/apps/dagster/secrets/kaggle-credentials.enc.yaml"
```

---

### Step 2.13: Update Dagster definitions.py

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/definitions.py`

Add new resources to the Dagster definitions.

```python
"""Dagster definitions for Brev Data Platform."""

import os

import dagster as dg

from brev_pipelines.assets.demo import demo_assets
from brev_pipelines.assets.health import health_assets
from brev_pipelines.assets.validation import validation_assets
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.weaviate import WeaviateResource

# Resource definitions with environment variable configuration
resources = {
    "minio": MinIOResource(
        endpoint=os.getenv("MINIO_ENDPOINT", "minio.minio.svc.cluster.local:9000"),
        access_key=os.getenv("MINIO_ACCESS_KEY", "admin"),
        secret_key=os.getenv("MINIO_SECRET_KEY", ""),
        secure=os.getenv("MINIO_SECURE", "false").lower() == "true",
    ),
    "lakefs": LakeFSResource(
        endpoint=os.getenv("LAKEFS_ENDPOINT", "http://lakefs.lakefs.svc.cluster.local:8000"),
        access_key_id=os.getenv("LAKEFS_ACCESS_KEY_ID", ""),
        secret_access_key=os.getenv("LAKEFS_SECRET_ACCESS_KEY", ""),
    ),
    "nim": NIMResource(
        endpoint=os.getenv("NIM_ENDPOINT", "http://nvidia-nim-llm.nvidia-nim.svc.cluster.local:8000"),
        model=os.getenv("NIM_MODEL", "meta/llama3-8b-instruct"),
    ),
    "nim_embedding": NIMEmbeddingResource(
        endpoint=os.getenv(
            "NIM_EMBEDDING_ENDPOINT",
            "http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000",
        ),
    ),
    "weaviate": WeaviateResource(
        host=os.getenv("WEAVIATE_HOST", "weaviate.weaviate.svc.cluster.local"),
        port=int(os.getenv("WEAVIATE_PORT", "8080")),
        grpc_port=int(os.getenv("WEAVIATE_GRPC_PORT", "50051")),
    ),
}

# Combine all assets
all_assets = [
    *demo_assets,
    *health_assets,
    *validation_assets,
]

# Create definitions
defs = dg.Definitions(
    assets=all_assets,
    resources=resources,
)
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `k8s/apps/nvidia-nim-embedding/Chart.yaml` | CREATE | Helm chart metadata |
| `k8s/apps/nvidia-nim-embedding/values.yaml` | CREATE | NIM embedding configuration |
| `k8s/apps/nvidia-nim-embedding/templates/deployment.yaml` | CREATE | Deployment manifest |
| `k8s/apps/nvidia-nim-embedding/templates/_helpers.tpl` | CREATE | Helm helper templates |
| `k8s/apps/nvidia-nim-embedding/templates/service.yaml` | CREATE | Service manifest |
| `k8s/apps/nvidia-nim-embedding/templates/pvc.yaml` | CREATE | PVC manifest |
| `k8s/apps/nvidia-nim-embedding/templates/serviceaccount.yaml` | CREATE | ServiceAccount |
| `k8s/apps/argocd-apps/templates/nvidia-nim-embedding.yaml` | CREATE | ArgoCD Application |
| `dagster/pyproject.toml` | MODIFY | Add new dependencies |
| `dagster/src/brev_pipelines/resources/nim_embedding.py` | CREATE | NIM embedding resource |
| `dagster/src/brev_pipelines/resources/weaviate.py` | CREATE | Weaviate client resource |
| `dagster/src/brev_pipelines/resources/__init__.py` | MODIFY | Export new resources |
| `dagster/src/brev_pipelines/definitions.py` | MODIFY | Register new resources |
| `dagster/tests/test_resources.py` | MODIFY | Add resource tests |
| `.env.example` | MODIFY | Add Kaggle credential placeholders |
| `scripts/create-secrets.sh` | MODIFY | Add Kaggle secret creation |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `NIM_EMBEDDING_ENDPOINT` | `http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000` | NIM embedding service |
| `WEAVIATE_HOST` | `weaviate.weaviate.svc.cluster.local` | Weaviate service host |
| `WEAVIATE_PORT` | `8080` | Weaviate HTTP port |
| `WEAVIATE_GRPC_PORT` | `50051` | Weaviate gRPC port |
| `KAGGLE_USERNAME` | From secret | Kaggle authentication |
| `KAGGLE_KEY` | From secret | Kaggle API key |

### Secrets Required

| Secret | Source | How to Create |
|--------|--------|---------------|
| `ngc-credentials` | SOPS | Already exists |
| `ngc-image-pull` | SOPS | Already exists |
| `kaggle-credentials` | SOPS | `make create-secrets` (after adding to .env.local) |

### GPU Resource Allocation

| Workload | GPU Memory | Priority Class |
|----------|------------|----------------|
| NIM LLM (llama3-8b) | ~70GB | inference (125) |
| NIM Embedding (300M) | ~2GB | inference (125) |
| **Total** | ~72GB | - |

Both models share the inference-queue and can run concurrently on the H200 (141GB).

---

## Verification

### Pre-flight Checks

```bash
# Ensure Weaviate is deployed (Phase 1)
kubectl get pods -n weaviate

# Ensure NGC credentials exist
kubectl get secret ngc-credentials -n nvidia-nim
kubectl get secret ngc-image-pull -n nvidia-nim
```

### Validation Commands

```bash
# Validate Helm chart
helm lint k8s/apps/nvidia-nim-embedding/
helm template nvidia-nim-embedding k8s/apps/nvidia-nim-embedding/

# After ArgoCD sync, verify NIM embedding is running
kubectl get pods -n nvidia-nim -l app.kubernetes.io/name=nvidia-nim-embedding
kubectl logs -n nvidia-nim deployment/nvidia-nim-embedding

# Test embedding endpoint
kubectl exec -n nvidia-nim deployment/nvidia-nim-embedding -- \
  curl -s localhost:8000/v1/health/ready

# Install updated Python dependencies
cd dagster
pip install -e ".[dev]"

# Run tests
pytest tests/test_resources.py -v

# Type checking
mypy src/brev_pipelines/resources/

# Linting
ruff check src/brev_pipelines/resources/

# Import check
python -c "from brev_pipelines.definitions import defs; print(f'Resources: {list(defs.resources.keys())}')"
```

### Expected Outcomes

- NIM embedding pod running in `nvidia-nim` namespace
- NIM embedding health check returns 200
- Both NIM LLM and NIM Embedding running concurrently
- All new dependencies install successfully
- Resource tests pass
- Type checking passes
- Linting passes
- Resources appear in Dagster definitions

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| NIM embedding OOM | Pod OOMKilled | Reduce GPU memory annotation, check for memory leaks |
| GPU contention | Pods pending | Verify KAI scheduler is running, check queue config |
| Model download slow | Pod stuck Init | Increase initialDelaySeconds, check NGC connectivity |
| Weaviate connection refused | Connection error | Verify Weaviate is running, check service name |
| NGC pull error | ImagePullBackOff | Verify ngc-image-pull secret in namespace |
| Kaggle auth fails | 401 during download | Verify credentials, check Kaggle account |

### Rollback Plan

If this phase fails:
1. Delete NIM embedding deployment: `kubectl delete -n nvidia-nim deployment nvidia-nim-embedding`
2. Remove ArgoCD application: `kubectl delete application nvidia-nim-embedding -n argocd`
3. Revert `pyproject.toml` changes
4. Delete new resource files
5. Revert `definitions.py` changes
6. Reinstall original dependencies
7. Investigate and fix issues

---

## Completion Criteria

- [ ] NIM embedding Helm chart created and linted
- [ ] ArgoCD Application created
- [ ] NIM embedding pod running in `nvidia-nim` namespace
- [ ] NIM embedding health check passing
- [ ] Both NIM models running concurrently (LLM + Embedding)
- [ ] Dependencies installed successfully
- [ ] `nim_embedding.py` resource created with proper typing
- [ ] `weaviate.py` resource created with proper typing
- [ ] Resources exported in `__init__.py`
- [ ] Resources registered in `definitions.py`
- [ ] All resource tests pass
- [ ] `ruff check` passes
- [ ] `mypy` passes
- [ ] Kaggle credentials added to secrets template
- [ ] Invariants INV-S001, INV-P003, INV-N001, INV-K001, INV-K002, INV-K005, NEW INV-N005 verified
