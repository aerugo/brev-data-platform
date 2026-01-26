# Brev Data Platform - Architectural Invariants

> **Purpose**: This document captures architectural constraints and rules that must be maintained across the codebase. Violating these invariants will break the deployment or compromise security.

---

## Infrastructure Invariants (INV-I)

### INV-I001: Terraform State Must Be Remote

Terraform state must never be stored locally or committed to Git. Use remote backend (S3, GCS, or Terraform Cloud).

```hcl
# Correct
terraform {
  backend "s3" {
    bucket = "terraform-state-bucket"
    key    = "brev-data-platform/dev/terraform.tfstate"
    region = "us-east-1"
  }
}

# Incorrect - local state
terraform {
  backend "local" {
    path = "terraform.tfstate"  # NEVER
  }
}
```

**Rationale**: Local state causes conflicts, loses state on machine failure, and may expose sensitive outputs.

### INV-I002: Environment Isolation via Directories

Each environment (dev, staging, prod) has its own directory under `terraform/environments/`. Environments must not share state.

```
terraform/
├── environments/
│   ├── dev/          # Development environment
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   └── prod/         # Production environment (if created)
│       └── ...
└── modules/          # Shared modules
```

**Rationale**: Environment isolation prevents accidental cross-environment changes.

### INV-I003: H200 141GB GPU Required

Brev instances for this platform **MUST** have an NVIDIA H200 141GB GPU. Smaller GPUs (A100 80GB, T4, etc.) are NOT supported due to:
- **NIM LLM (Llama 8B)**: Primary inference model (~25GB model, uses full GPU when running)
- **NIM Reasoning (GPT-OSS-120B)**: On-demand reasoning model (~80GB, preempts LLM)
- **NIM Embedding**: Always-on embedding model (~2GB)
- A100 80GB cannot support the larger reasoning model

```bash
# Correct - H200 141GB (Brev instance from web console)
# CRUSOE provider (required):
INSTANCE_TYPE="h200-141gb.1x"    # H200 141GB

# Incorrect - insufficient VRAM for reasoning model
INSTANCE_TYPE="a100-80gb.1x"    # INSUFFICIENT - only 80GB
GPU_TYPE="n1-highmem-4:nvidia-tesla-t4:1"  # NEVER - only 16GB
```

**Note**: H200 instances are available through CRUSOE provider via Brev web console. The Brev CLI only supports GCP which does not have H200 availability. See INV-I005 for documented exception.

**Rationale**: The platform uses GPU time-sharing via KAI Scheduler priority-based preemption. NIM containers allocate the full GPU when running (not fractional), so models cannot run concurrently. The H200's 141GB allows running either the 8B fast model OR the 120B reasoning model on demand.

### INV-I004: Cloud-Init/Script for RKE2 Bootstrap

RKE2 installation must be automated via cloud-init user data or bootstrap scripts, not manual SSH commands. This ensures reproducibility.

```bash
# Correct - automated bootstrap script
make bootstrap-rke2  # Runs scripts/bootstrap-rke2.sh

# Correct - cloud-init (if supported by Brev)
# Instance user_data points to scripts/cloud-init/rke2-gpu.yaml

# Incorrect - manual SSH and typing commands
brev shell instance
curl -sfL https://get.rke2.io | sh -  # NEVER manually
```

**Rationale**: Manual installation is not reproducible and creates configuration drift.

### INV-I005: Configuration as Code (No Manual Steps)

ALL infrastructure and application configuration MUST be defined in code and applied via automated tooling. No manual kubectl commands, no manual cloud console changes, no undocumented configuration.

```bash
# Correct - all configuration via Makefile/scripts
make full-setup          # Creates instance, bootstraps RKE2, deploys KAI
make bootstrap-argocd    # ArgoCD then manages everything via GitOps
make apply-secrets       # Secrets applied from SOPS-encrypted files

# Incorrect - manual commands
kubectl create secret generic my-secret --from-literal=key=value  # NEVER
kubectl edit deployment dagster  # NEVER
brev shell instance && apt install something  # NEVER
```

**Exceptions that require documentation:**
- Account creation and API key generation (one-time setup)
- Initial Age key generation for SOPS encryption
- Brev instance creation via web console (H200 GPU not available via CLI)
- GitHub repository secrets configuration

**Rationale**: Manual configuration creates drift, is not reproducible, cannot be audited, and will be lost on rebuild.

### INV-I006: Local-Only Infrastructure (No Cloud APIs)

This platform operates on a **strict local-only policy**. All services must run on our own infrastructure - NEVER use external cloud APIs or services.

```python
# Correct - local NIM endpoint
nim_provider = OpenAIProvider(
    base_url="http://nvidia-nim.nvidia-nim.svc.cluster.local:8000/v1",
    api_key="not-required",  # Local NIM doesn't require API key
)

# FORBIDDEN - cloud LLM APIs
OpenAI(api_key=os.environ["OPENAI_API_KEY"])  # NEVER
Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])  # NEVER
OpenAIProvider(base_url="https://integrate.api.nvidia.com/v1", ...)  # NEVER
OpenAIProvider(base_url="https://api.openai.com/v1", ...)  # NEVER
```

**Forbidden cloud services:**
- OpenAI API (GPT-4, etc.)
- Anthropic API (Claude)
- NVIDIA Cloud API (integrate.api.nvidia.com)
- Google Vertex AI
- AWS Bedrock
- Azure OpenAI
- Any external embedding or LLM service

**Rationale**:
- Data sovereignty - sensitive data never leaves our infrastructure
- Cost control - no per-token API charges
- Latency - local inference is faster than cloud round-trips
- Availability - no external dependencies for core functionality

---

## Kubernetes Invariants (INV-K)

### INV-K001: Namespace Per Application

Each application deploys to its own namespace. Never deploy multiple unrelated applications to the same namespace.

```yaml
# Correct - dedicated namespace
apiVersion: v1
kind: Namespace
metadata:
  name: dagster
---
# Dagster resources in dagster namespace

# Incorrect - mixing apps in default namespace
# All apps in namespace: default  # NEVER
```

**Rationale**: Namespace isolation enables RBAC, resource quotas, and clean teardown.

### INV-K002: Resource Limits on All Pods

All pods must have resource requests and limits defined. No unbounded resource consumption.

```yaml
# Correct
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "500m"

# Incorrect - no limits
resources: {}  # NEVER
```

**Rationale**: Unbounded pods can starve other workloads and crash nodes.

### INV-K003: GPU Resources Explicitly Requested

Workloads requiring GPU must explicitly request `nvidia.com/gpu` resources. Never assume GPU availability.

```yaml
# Correct
resources:
  limits:
    nvidia.com/gpu: 1

# Incorrect - hoping GPU is available
# No GPU resource specified but expecting GPU access  # NEVER
```

**Rationale**: Without explicit GPU request, pods may schedule on non-GPU nodes or share GPUs unexpectedly.

### INV-K004: Helm Values Override Pattern

Base values in `values.yaml`, environment overrides in `values-<env>.yaml`. Never modify `values.yaml` for environment-specific settings.

```
k8s/apps/dagster/
├── Chart.yaml
├── values.yaml           # Defaults (environment-agnostic)
├── values-dev.yaml       # Dev overrides
└── values-prod.yaml      # Prod overrides (if needed)
```

**Rationale**: Keeps defaults clean and makes environment differences explicit.

### INV-K005: No Hardcoded Images Tags as `latest`

All container images must use specific version tags, never `latest`.

```yaml
# Correct
image: dagster/dagster:1.6.0

# Incorrect
image: dagster/dagster:latest  # NEVER
image: dagster/dagster         # NEVER (implies latest)
```

**Rationale**: `latest` is mutable and causes unpredictable deployments.

---

## Security Invariants (INV-S)

### INV-S001: No Plaintext Secrets in Git

All secrets must be encrypted with SOPS before committing. Plaintext secrets in Git is a critical security violation.

```yaml
# Correct - SOPS encrypted file
# secrets.enc.yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
data:
  access-key: ENC[AES256_GCM,data:...,type:str]
  secret-key: ENC[AES256_GCM,data:...,type:str]
sops:
  kms: []
  age:
    - recipient: age1...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...

# Incorrect - plaintext
# secrets.yaml
data:
  access-key: bXlhY2Nlc3NrZXk=  # NEVER commit this
```

**Rationale**: Plaintext secrets in Git are permanently exposed, even after deletion.

### INV-S002: SOPS Configuration in Repository Root

`.sops.yaml` must exist in repository root and define encryption rules for all secret files.

```yaml
# .sops.yaml
creation_rules:
  - path_regex: .*\.enc\.yaml$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  - path_regex: .*\.enc\.json$
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**Rationale**: Ensures consistent encryption across the team and prevents accidental plaintext commits.

### INV-S003: NGC API Key as Kubernetes Secret

NVIDIA NGC API key must be stored as a Kubernetes secret (SOPS encrypted), never in ConfigMaps or environment variables in plain Helm values.

```yaml
# Correct - reference secret
env:
  - name: NGC_API_KEY
    valueFrom:
      secretKeyRef:
        name: ngc-credentials
        key: api-key

# Incorrect - plain value
env:
  - name: NGC_API_KEY
    value: "nvapi-xxxx"  # NEVER
```

**Rationale**: NGC API keys provide access to NVIDIA AI Enterprise resources and must be protected.

### INV-S004: MinIO Credentials Encrypted

MinIO root user and password must be SOPS encrypted secrets, never plaintext in values files.

**Rationale**: MinIO stores all data lake content. Credential exposure compromises all data.

---

## GitOps Invariants (INV-G)

### INV-G001: App-of-Apps Pattern for ArgoCD

All applications are managed through the app-of-apps pattern. The root Application points to `k8s/apps/` which contains individual Application manifests.

```
k8s/
├── bootstrap/
│   └── argocd-apps.yaml    # Root Application (app-of-apps)
└── apps/
    ├── minio/
    │   └── application.yaml  # ArgoCD Application for MinIO
    ├── dagster/
    │   └── application.yaml  # ArgoCD Application for Dagster
    └── ...
```

**Rationale**: Single entry point for all applications, enables bulk operations and consistent management.

### INV-G002: Automated Sync for Dev Environment

Development environment applications use automated sync with self-heal enabled.

```yaml
# Dev application
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

**Rationale**: Dev environment should auto-update on Git push for rapid iteration.

### INV-G003: Source of Truth is Git

The Git repository is the single source of truth. Never make manual `kubectl` changes that bypass ArgoCD.

```bash
# Correct - change in Git, ArgoCD syncs
git commit -m "Update replica count"
git push
# ArgoCD detects and applies

# Incorrect - direct kubectl
kubectl scale deployment dagster --replicas=3  # NEVER
```

**Rationale**: Manual changes cause drift and will be reverted by ArgoCD sync.

### INV-G004: Sync Waves for Dependencies

Applications with dependencies must use sync waves to ensure correct ordering.

```yaml
# Database deploys first (wave 0)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"

# App deploys after database (wave 1)
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
```

**Rationale**: Prevents race conditions where apps start before their dependencies.

---

## Data Invariants (INV-D)

### INV-D001: Standard Bucket Structure

MinIO must have these standard buckets:
- `raw-data` - Ingested raw data
- `data-products` - Transformed/processed data
- `lakefs` - LakeFS metadata (managed by LakeFS)

**Rationale**: Consistent bucket structure enables reusable pipeline patterns.

### INV-D002: LakeFS for Data Versioning

All data transformations must go through LakeFS branches. Never write directly to MinIO buckets that LakeFS manages.

```python
# Correct - write via LakeFS
lakefs_client.objects.upload_object(
    repository="main-repo",
    branch="feature-branch",
    path="data/output.parquet",
    content=data
)

# Incorrect - direct MinIO write
minio_client.put_object("data-products", "output.parquet", data)  # NEVER
```

**Rationale**: Direct writes bypass versioning and break data lineage.

### INV-D003: Parquet for Structured Data

Structured data must be stored as Parquet format, not CSV or JSON.

**Rationale**: Parquet provides schema, compression, and columnar access for analytics.

---

## Pipeline Invariants (INV-P)

### INV-P001: Assets Over Ops

Dagster pipelines must use the asset-based paradigm (`@asset`) over the legacy ops paradigm (`@op`) for data transformations.

```python
# Correct
@asset
def processed_data(raw_data: pd.DataFrame) -> pd.DataFrame:
    return raw_data.transform(...)

# Discouraged - use only when assets don't fit
@op
def process_data(context, data):
    ...
```

**Rationale**: Assets provide better lineage, observability, and incremental computation.

### INV-P002: I/O Managers for Storage

All asset persistence must use I/O managers, not direct storage calls within asset code.

```python
# Correct - I/O manager handles storage
@asset(io_manager_key="lakefs_io_manager")
def my_asset() -> pd.DataFrame:
    return pd.DataFrame(...)  # I/O manager writes to LakeFS

# Incorrect - direct storage in asset
@asset
def my_asset() -> None:
    df = pd.DataFrame(...)
    minio_client.put_object(...)  # NEVER
```

**Rationale**: I/O managers centralize storage logic and enable environment-specific configuration.

### INV-P003: Type Annotations on Assets

All Dagster assets must have type annotations for inputs and outputs.

```python
# Correct
@asset
def clean_data(raw_data: pd.DataFrame) -> pd.DataFrame:
    ...

# Incorrect - no types
@asset
def clean_data(raw_data):  # Missing types
    ...
```

**Rationale**: Type annotations enable Dagster's type checking and documentation.

### INV-P004: Complete Type Annotations on All Functions

Every function, method, and asset must have **complete** type annotations for all parameters AND return types. No exceptions.

```python
# Correct - complete annotations
def process_speeches(
    speeches: list[Speech],
    batch_size: int = 32,
) -> tuple[pl.DataFrame, list[list[float]]]:
    ...

def get_embedding(text: str) -> list[float]:
    return embedder.embed(text)

# Incorrect - missing return type
def get_embedding(text: str):  # NEVER - missing return type
    return embedder.embed(text)

# Incorrect - missing parameter types
def process_speeches(speeches, batch_size=32):  # NEVER
    ...
```

**Rationale**: Complete type annotations enable static analysis, IDE support, and catch bugs before runtime. Partial annotations provide false confidence.

### INV-P005: No `Any` Types

Never use `typing.Any`. Replace with proper types using Pydantic models, TypedDict, or specific type unions.

```python
# Correct - use Pydantic models
from pydantic import BaseModel

class ProcessResult(BaseModel):
    status: str
    count: int
    items: list[SpeechDict]

def process(data: SpeechRecord) -> ProcessResult:
    ...

# Correct - use TypedDict for dict shapes
from typing import TypedDict

class EmbeddingResult(TypedDict):
    reference: str
    embedding: list[float]

def get_embeddings(texts: list[str]) -> list[EmbeddingResult]:
    ...

# Incorrect - leaks unknown types
from typing import Any

def process(data: dict[str, Any]) -> Any:  # NEVER
    ...

def get_result() -> dict[str, Any]:  # NEVER
    ...
```

**Rationale**: `Any` defeats the purpose of type checking. It propagates through the codebase and hides bugs that would otherwise be caught statically.

### INV-P006: Modern Python 3.11+ Typing Syntax

Use native Python type syntax. Never import `List`, `Dict`, `Optional`, `Union`, `Tuple`, or `Set` from `typing`.

```python
# Correct - modern syntax
def func(items: list[str]) -> dict[str, int | None]:
    ...

def find_speech(id: str) -> Speech | None:
    ...

def parse(val: str) -> int | str:
    ...

# Incorrect - legacy imports
from typing import List, Dict, Optional, Union  # NEVER

def func(items: List[str]) -> Dict[str, Optional[int]]:  # NEVER
    ...
```

**Allowed typing imports:**
- `Protocol`, `runtime_checkable` - for interfaces
- `TypedDict` - for dict shapes
- `Annotated` - for metadata (Pydantic, Dagster)
- `TypeVar`, `Generic` - for generic classes
- `Callable` - for function types
- `Self` - for method return types
- `Literal` - for literal types

**Rationale**: Modern syntax is more readable and is the Python standard. Legacy imports add noise and will eventually be deprecated.

### INV-P007: Pydantic v2 for Data Models

All structured data must use Pydantic v2 models with proper Field definitions and validators.

```python
# Correct - Pydantic v2 model
from pydantic import BaseModel, Field, field_validator

class Speech(BaseModel):
    """A central bank speech record."""

    speech_id: str = Field(..., description="Unique identifier")
    title: str = Field(..., min_length=1)
    text: str = Field(..., min_length=10)
    central_bank: str = Field(..., description="Issuing institution")
    monetary_stance: int = Field(default=3, ge=1, le=5)
    tariff_mention: bool = Field(default=False)

    @field_validator("central_bank")
    @classmethod
    def normalize_bank(cls, v: str) -> str:
        return v.strip().upper()

# Incorrect - plain dict or dataclass without validation
speech = {
    "speech_id": "123",
    "title": "",  # Invalid but not caught
    "text": "x",  # Too short but not caught
}
```

**Rationale**: Pydantic provides:
- Runtime validation with clear error messages
- Automatic serialization/deserialization
- Schema generation for documentation
- Integration with Dagster ConfigurableResource

### INV-P008: PydanticAI for All LLM Processing

**All LLM calls must use PydanticAI with strictly-typed Pydantic response models.** Never use raw LLM APIs or manual JSON parsing.

**CRITICAL: Local-Only Policy** - This platform uses ONLY local LLMs deployed via NVIDIA NIM on our own infrastructure. We NEVER use cloud LLM APIs (OpenAI, Anthropic, NVIDIA Cloud, etc.). All inference runs on our H200 GPU.

#### Configuration with NVIDIA NIM (Local Deployment)

NVIDIA NIM provides an OpenAI-compatible API. Configure PydanticAI using `OpenAIChatModel` with `OpenAIProvider`:

```python
from pydantic import BaseModel, Field
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider
from typing import Literal

# Configure for local NVIDIA NIM (OpenAI-compatible API)
nim_provider = OpenAIProvider(
    base_url="http://nvidia-nim.nvidia-nim.svc.cluster.local:8000/v1",
    api_key="not-required",  # Local NIM doesn't require API key
)

nim_model = OpenAIChatModel(
    model_name="meta/llama3-8b-instruct",
    provider=nim_provider,
)

# Define strictly-typed response model
class TariffClassification(BaseModel):
    """Structured classification result - all fields strictly typed."""

    mentions_tariff: bool = Field(
        description="Whether the speech discusses tariffs or trade barriers"
    )
    confidence: float = Field(
        ge=0.0, le=1.0,
        description="Confidence score for the classification"
    )
    evidence: list[str] = Field(
        default_factory=list,
        max_length=3,
        description="Key quotes supporting the classification"
    )
    stance: Literal["protectionist", "globalist", "neutral"] = Field(
        description="Overall trade policy stance"
    )

# Create agent with typed response
tariff_classifier = Agent(
    model=nim_model,
    result_type=TariffClassification,
    system_prompt="Classify central bank speeches for tariff and trade policy mentions.",
)

async def classify_speech(text: str) -> TariffClassification:
    """Classify a speech - returns strictly typed result."""
    result = await tariff_classifier.run(text[:4000])
    return result.data  # Guaranteed to match TariffClassification schema
```

#### Incorrect Patterns (NEVER USE)

```python
# WRONG: Manual JSON parsing
import json
import re

def classify_speech(text: str) -> dict:  # NEVER - untyped return
    response = llm.generate(f"Classify: {text}")
    json_match = re.search(r"\{[^}]+\}", response)
    if json_match:
        return json.loads(json_match.group())  # Brittle, no validation
    return {"mentions_tariff": False}  # Silent fallback

# WRONG: Using raw requests to NIM
import requests

def classify_speech(text: str) -> dict:  # NEVER
    response = requests.post(
        "http://nim:8000/v1/chat/completions",
        json={"messages": [{"role": "user", "content": text}]},
    )
    return response.json()["choices"][0]["message"]["content"]  # Untyped string!

# WRONG: Untyped response model
class BadClassification(BaseModel):
    result: dict  # NEVER - loses type information
    metadata: Any  # NEVER - Any is forbidden
```

**Rationale**: PydanticAI with strictly-typed models provides:
- **Guaranteed structured outputs** matching Pydantic schemas
- **Automatic retries** on validation failures
- **Complete type safety** through the entire pipeline
- **OpenAI-compatible API support** for NVIDIA NIM
- **No manual JSON parsing** - eliminates brittle regex/string manipulation
- **Runtime validation** - catches malformed LLM responses immediately

### INV-P009: Composition Over Inheritance

Build functionality through composition, not class hierarchies. Use Protocols for interfaces.

```python
# Correct - composition with protocols
from typing import Protocol

class Embedder(Protocol):
    def embed_texts(self, texts: list[str]) -> list[list[float]]:
        ...

class EmbeddingPipeline:
    def __init__(
        self,
        embedder: Embedder,  # Injected dependency
        storage: VectorStore,
    ) -> None:
        self.embedder = embedder
        self.storage = storage

    def process(self, texts: list[str]) -> list[str]:
        embeddings = self.embedder.embed_texts(texts)
        return self.storage.store(embeddings)

# Incorrect - deep inheritance hierarchy
class BaseEmbedder:  # NEVER
    def embed(self): ...

class NIMEmbedder(BaseEmbedder):  # NEVER
    def embed(self): ...

class BatchNIMEmbedder(NIMEmbedder):  # NEVER - too deep
    def embed(self): ...

class CachingBatchNIMEmbedder(BatchNIMEmbedder):  # NEVER - way too deep
    def embed(self): ...
```

**Rationale**: Composition:
- Makes dependencies explicit and testable
- Avoids diamond inheritance problems
- Enables easy mocking in tests
- Keeps classes focused on single responsibilities

### INV-P010: Test-Driven Development (TDD)

All new code must be developed using TDD. Write tests BEFORE implementation.

```python
# Step 1: Write the test first
# dagster/tests/unit/test_models.py
class TestSpeechModel:
    def test_monetary_stance_bounds(self) -> None:
        """Test monetary_stance must be 1-5."""
        with pytest.raises(ValidationError):
            Speech(
                speech_id="1",
                title="Test",
                text="x" * 100,
                central_bank="FED",
                monetary_stance=6,  # Invalid
            )

# Step 2: Run test (should FAIL - Speech doesn't exist yet)
# Step 3: Write minimal code to pass
# Step 4: Run test (should PASS)
# Step 5: Refactor while keeping tests green
```

**Test requirements:**
- Unit tests for all Pydantic models
- Unit tests for all Dagster resources
- Unit tests for all Dagster assets
- Integration tests for pipeline flows
- All external services (NIM, MinIO, LakeFS, Weaviate) must be mocked

```python
# Correct - mocked external service
@patch("requests.post")
def test_embed_texts_success(self, mock_post: Mock) -> None:
    mock_post.return_value.json.return_value = {
        "data": [{"embedding": [0.1] * 1024}]
    }
    resource = NIMEmbeddingResource(endpoint="http://test:8000")
    embeddings = resource.embed_texts(["text"])
    assert len(embeddings[0]) == 1024

# Incorrect - calling real service
def test_embed_texts_success(self) -> None:  # NEVER
    resource = NIMEmbeddingResource(
        endpoint="http://real-nim-service:8000"  # Real service!
    )
    embeddings = resource.embed_texts(["text"])  # Network call!
```

**Rationale**: TDD ensures:
- All code is testable by design
- Requirements are captured as executable tests
- Regressions are caught immediately
- Tests serve as documentation

### INV-P011: No Bare Generics

Never use bare `list`, `dict`, or `set` without type arguments.

```python
# Correct - fully specified
def get_embeddings() -> list[list[float]]:
    ...

def get_config() -> dict[str, str | int | bool]:
    ...

results: list[ClassificationResult] = []

# Incorrect - bare generics
def get_embeddings() -> list:  # NEVER - what's in the list?
    ...

def get_config() -> dict:  # NEVER - what are the key/value types?
    ...

results: list = []  # NEVER
```

**Rationale**: Bare generics provide no type information and make static analysis ineffective.

---

## NVIDIA Invariants (INV-N)

### INV-N001: NIM Requires GPU Node

NIM deployments must be scheduled on nodes with GPU. Use node selectors or taints/tolerations.

```yaml
spec:
  nodeSelector:
    nvidia.com/gpu.present: "true"
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
```

**Rationale**: NIM without GPU will fail or fall back to unusable CPU performance.

### INV-N002: Model Configuration in ConfigMap

NIM model selection and parameters must be in ConfigMaps, not hardcoded in deployments.

```yaml
# Correct
apiVersion: v1
kind: ConfigMap
metadata:
  name: nim-config
data:
  model_name: "meta/llama3-8b-instruct"
  max_tokens: "4096"

# Incorrect - hardcoded in deployment
env:
  - name: MODEL
    value: "meta/llama3-8b-instruct"  # Move to ConfigMap
```

**Rationale**: Enables model swapping without deployment changes.

### INV-N003: Safe Synthesizer Output to LakeFS

Synthetic data generated by Safe Synthesizer must be written to LakeFS branches, not directly to MinIO.

**Rationale**: Synthetic data needs versioning and lineage tracking like any other data product.

### INV-N004: GPU Time-Sharing via Priority Preemption

NIM models share the GPU via time-sharing, NOT concurrent fractional allocation. NIM containers allocate full GPU memory when running.

```yaml
# nim-llm (always-on, preemptible)
priorityClassName: inference      # Priority 125
replicaCount: 1                   # Default on

# nim-reasoning (on-demand, preempts llm)
priorityClassName: batch-high     # Priority 130 (higher = preempts lower)
replicaCount: 0                   # Default off, scale up on demand

# nim-embedding (always-on, shares with llm)
priorityClassName: inference      # Priority 125
replicaCount: 1                   # Small enough to coexist
```

**Usage:**
```bash
# Enable reasoning (preempts nim-llm)
kubectl scale deployment nim-reasoning -n nvidia-ai --replicas=1

# Disable reasoning (nim-llm auto-restarts)
kubectl scale deployment nim-reasoning -n nvidia-ai --replicas=0
```

**Rationale**: KAI Scheduler's `gpu-memory` annotation only affects scheduling decisions, not actual GPU memory usage. NIM allocates whatever GPU memory is available. Time-sharing via preemption is the only way to run multiple large models on a single GPU.

### INV-N005: NIM Observability Enabled

All NIM deployments must have Prometheus metrics and request logging enabled for operational visibility.

```yaml
# Correct - observability enabled
env:
  - name: NIM_ENABLE_METRICS
    value: "true"
  - name: NIM_LOG_REQUESTS
    value: "true"
  - name: OTEL_SERVICE_NAME
    value: "nim-llm"

# Incorrect - no observability
env:
  - name: NIM_LOG_LEVEL
    value: "INFO"
  # Missing NIM_ENABLE_METRICS and NIM_LOG_REQUESTS
```

**Rationale**: LLM inference requires observability for:
- Debugging unexpected outputs and failures
- Performance monitoring (latency, throughput)
- Cost tracking (token usage)
- Compliance and audit trails
- Quality assurance of AI-generated content

### INV-N006: Safe Synthesizer Context Limit

Input records for Safe Synthesizer must fit within TinyLlama's context window. With `rope_scaling_factor=6`, max context is ~12K tokens (~10K characters per record). Full speech text (~20K+ chars) **cannot** be synthesized directly.

```python
# Correct - synthesize compact data that fits in context
synthesis_columns = [
    "reference", "date", "central_bank", "speaker", "title",  # metadata
    "monetary_stance", "trade_stance", "economic_outlook",     # classifications
    "summary",  # ~1000 chars - fits in context
]
# Total per record: ~1500 chars

# Incorrect - will cause underfitting or invalid output
synthesis_columns = ["reference", "text"]  # text is ~20K chars - TOO LONG
```

**Rationale**: TinyLlama (1.1B parameters) has a 2K base context window. RoPE scaling extends this to ~12K tokens, but synthesizing very long text fields causes:
- Underfitting (model can't learn the distribution)
- Invalid JSON output (truncated records)
- Extremely slow training

### INV-N007: Safe Synthesizer GPU Preemption

Safe Synthesizer must use `batch-high` priority (130) to preempt NIM inference pods (priority 125). After synthesis completes, scale deployment back to 0 replicas to release GPU for NIM.

```yaml
# Safe Synthesizer deployment
priorityClassName: batch-high  # 130 - preempts inference (125)
```

```python
# Correct - automatic scale up/down in Dagster resource
def synthesize(self, ...):
    self._scale_deployment(replicas=1)   # KAI preempts NIM
    try:
        return self._synthesize_via_api(...)
    finally:
        self._scale_deployment(replicas=0)  # NIM auto-restarts

# Incorrect - leaving Safe Synth running blocks NIM
# Never leave Safe Synthesizer at replicas=1 after job completion
```

**Rationale**: Safe Synthesizer requires ~80GB GPU memory. NIM and Safe Synth cannot run concurrently on H200 (141GB) when both need full GPU. Priority-based preemption via KAI Scheduler enables time-sharing.

### INV-N008: Synthetic Data Isolation

Synthetic data must be stored separately from real data to prevent confusion and maintain data lineage:

```python
# Correct - separate collections and paths
REAL_COLLECTION = "CentralBankSpeeches"
SYNTHETIC_COLLECTION = "SyntheticSpeeches"  # Separate collection

real_path = "central-bank-speeches/speeches.parquet"
synthetic_path = "central-bank-speeches/synthetic/speeches.parquet"  # /synthetic/ subdirectory

# All synthetic records must have marker
synthetic_df = df.with_columns(pl.lit(True).alias("is_synthetic"))

# Incorrect - mixing real and synthetic
collection = "AllSpeeches"  # NEVER mix real and synthetic
synthetic_df = df  # Missing is_synthetic marker
```

**Rationale**: Mixing synthetic and real data:
- Corrupts analytics and ML training
- Violates data governance requirements
- Makes lineage tracking impossible
- Can lead to "model collapse" if synthetic data is used to train future models

### INV-N009: Privacy Evaluation Required

All Safe Synthesizer jobs must enable MIA (Membership Inference Attack) and AIA (Attribute Inference Attack) evaluation. Privacy scores must be logged and stored with synthetic data products.

```python
# Correct - privacy evaluation enabled
synth_config = {
    "evaluation": {
        "mia_enabled": True,
        "aia_enabled": True,
    },
}
# Store evaluation results
report = {
    "mia_score": evaluation.get("mia_score"),
    "aia_score": evaluation.get("aia_score"),
    "privacy_passed": evaluation.get("privacy_passed"),
}

# Incorrect - skipping privacy evaluation
synth_config = {
    "evaluation": {
        "mia_enabled": False,  # NEVER for production
        "aia_enabled": False,  # NEVER for production
    },
}
```

**Rationale**: Synthetic data without privacy evaluation may:
- Leak sensitive information from training data
- Fail compliance requirements (GDPR, HIPAA)
- Be indistinguishable from real data (privacy failure)

---

## Adding New Invariants

When discovering new architectural constraints:

1. Add to this document with next available number in the appropriate category
2. Include code examples of correct and incorrect usage
3. Explain the rationale
4. Consider adding validation (CI check, lint rule, etc.)
5. Update related documentation

### Category Prefixes

| Prefix | Category |
|--------|----------|
| INV-I | Infrastructure (Terraform, Brev) |
| INV-K | Kubernetes (K3S, Helm, resources) |
| INV-S | Security (secrets, credentials) |
| INV-G | GitOps (ArgoCD, sync) |
| INV-D | Data (MinIO, LakeFS, formats) |
| INV-P | Pipeline (Dagster) |
| INV-N | NVIDIA (NIM, Safe Synthesizer, GPU) |

---

*Created: 2026-01-21*
*Last Updated: 2026-01-25*
