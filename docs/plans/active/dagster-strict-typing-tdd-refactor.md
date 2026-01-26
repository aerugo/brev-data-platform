# Dagster Pipeline Strict Typing & TDD Refactor

> **Status:** Active
> **Created:** 2026-01-25
> **Target:** Strict Python typing, TDD principles, comprehensive linting

---

## Executive Summary

Comprehensive refactoring of the Dagster pipeline codebase to achieve:
- **Strict Python Typing** (INV-P004 through INV-P011)
- **Test-Driven Development** with 80%+ coverage
- **Proper Linting & Static Analysis** (mypy strict, pyright, ruff)

### Current State Analysis

| Metric | Current | Target |
|--------|---------|--------|
| Type violations | 92+ | 0 |
| Test coverage | ~11% | 80%+ |
| MyPy mode | Permissive | Strict |
| Ruff rules | 4/12 | 12/12 |

---

## Phase 1: Linting Infrastructure & Test Foundation

### 1.1 Update pyproject.toml

**File:** `dagster/pyproject.toml`

#### MyPy Configuration (Current vs Required)

```toml
# CURRENT (insufficient)
[tool.mypy]
python_version = "3.11"
ignore_missing_imports = true

# REQUIRED
[tool.mypy]
python_version = "3.11"
strict = true
warn_return_any = true
warn_unused_ignores = true
disallow_untyped_defs = true
disallow_incomplete_defs = true
check_untyped_defs = true
plugins = ["pydantic.mypy"]
```

#### Ruff Configuration (Current vs Required)

```toml
# CURRENT (minimal)
[tool.ruff.lint]
select = ["E", "F", "I", "W"]
ignore = ["E501"]

# REQUIRED (comprehensive)
[tool.ruff.lint]
select = [
    "E",      # pycodestyle errors
    "W",      # pycodestyle warnings
    "F",      # pyflakes
    "I",      # isort
    "B",      # flake8-bugbear
    "C4",     # flake8-comprehensions
    "UP",     # pyupgrade
    "ARG",    # flake8-unused-arguments
    "SIM",    # flake8-simplify
    "TCH",    # flake8-type-checking
    "ANN",    # flake8-annotations
    "D",      # pydocstyle
]

[tool.ruff.lint.pydocstyle]
convention = "google"
```

#### Additional Dev Dependencies

```toml
[project.optional-dependencies]
dev = [
    "pytest>=7.0.0",
    "pytest-cov>=4.0.0",
    "pytest-mock>=3.10.0",     # ADD
    "pytest-asyncio>=0.21.0",  # ADD (for async assets)
    "ruff>=0.1.0",
    "mypy>=1.0.0",
    "pyright>=1.1.0",          # ADD
    "dagster-webserver>=1.6.0",
    "types-requests>=2.31.0",
]
```

#### Pytest Configuration (Missing)

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
python_files = ["test_*.py"]
python_functions = ["test_*"]
addopts = "--cov=brev_pipelines --cov-report=term-missing --cov-report=html"
asyncio_mode = "auto"
```

### 1.2 Create Test Infrastructure

**Create:** `dagster/tests/conftest.py`

```python
"""Shared test fixtures for Dagster pipeline tests.

Provides mock implementations of all external services:
- MinIO (object storage)
- LakeFS (data versioning)
- Weaviate (vector database)
- NIM (LLM inference)
- Kubernetes (for Safe Synthesizer)
"""
from __future__ import annotations

from collections.abc import Generator
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import polars as pl
import pytest
from dagster import build_asset_context

if TYPE_CHECKING:
    from dagster import AssetExecutionContext


# =============================================================================
# MinIO Fixtures
# =============================================================================

@pytest.fixture
def mock_minio_client() -> Generator[MagicMock, None, None]:
    """Mock MinIO client with standard operations."""
    with patch("minio.Minio") as mock:
        client = MagicMock()
        client.bucket_exists.return_value = True
        client.put_object.return_value = None
        client.get_object.return_value = MagicMock()
        mock.return_value = client
        yield client


# =============================================================================
# LakeFS Fixtures
# =============================================================================

@pytest.fixture
def mock_lakefs_client() -> Generator[MagicMock, None, None]:
    """Mock LakeFS client with standard operations."""
    with patch("lakefs_sdk.client.LakeFSClient") as mock:
        client = MagicMock()
        client.objects.upload_object.return_value = None
        client.objects.get_object.return_value = MagicMock()
        client.commits.commit.return_value = MagicMock(id="test-commit-id")
        mock.return_value = client
        yield client


# =============================================================================
# Weaviate Fixtures
# =============================================================================

@pytest.fixture
def mock_weaviate_client() -> Generator[MagicMock, None, None]:
    """Mock Weaviate client with standard operations."""
    with patch("weaviate.connect_to_local") as mock:
        client = MagicMock()
        collection = MagicMock()
        collection.data.insert_many.return_value = MagicMock(
            has_errors=False,
            uuids=["uuid-1", "uuid-2"],
        )
        client.collections.get.return_value = collection
        mock.return_value = client
        yield client


# =============================================================================
# NIM Fixtures
# =============================================================================

@pytest.fixture
def mock_nim_response() -> MagicMock:
    """Mock NIM LLM response for classification."""
    response = MagicMock()
    response.json.return_value = {
        "choices": [{
            "message": {
                "content": '{"monetary_stance": "neutral", "trade_stance": "neutral", "tariff_mention": 0, "economic_outlook": "neutral"}'
            }
        }]
    }
    response.raise_for_status = MagicMock()
    return response


@pytest.fixture
def mock_nim_embedding_response() -> MagicMock:
    """Mock NIM embedding response."""
    response = MagicMock()
    response.json.return_value = {
        "data": [{"embedding": [0.1] * 1024}]
    }
    response.raise_for_status = MagicMock()
    return response


# =============================================================================
# Kubernetes Fixtures
# =============================================================================

@pytest.fixture
def mock_k8s_client() -> Generator[MagicMock, None, None]:
    """Mock Kubernetes client for Safe Synthesizer."""
    with patch("kubernetes.client.BatchV1Api") as batch_mock, \
         patch("kubernetes.client.CoreV1Api") as core_mock, \
         patch("kubernetes.client.AppsV1Api") as apps_mock:

        batch_client = MagicMock()
        core_client = MagicMock()
        apps_client = MagicMock()

        # Job status mock
        job_status = MagicMock()
        job_status.status.succeeded = 1
        job_status.status.completion_time = "2026-01-25T12:00:00Z"
        batch_client.read_namespaced_job_status.return_value = job_status

        batch_mock.return_value = batch_client
        core_mock.return_value = core_client
        apps_mock.return_value = apps_client

        yield {
            "batch": batch_client,
            "core": core_client,
            "apps": apps_client,
        }


# =============================================================================
# Sample Data Fixtures
# =============================================================================

@pytest.fixture
def sample_speeches_df() -> pl.DataFrame:
    """Sample speeches DataFrame for testing."""
    return pl.DataFrame({
        "reference": ["BIS_2024_001", "BIS_2024_002", "ECB_2024_001"],
        "date": ["2024-01-15", "2024-01-20", "2024-02-01"],
        "central_bank": ["FED", "FED", "ECB"],
        "speaker": ["Jerome Powell", "Jerome Powell", "Christine Lagarde"],
        "title": ["Monetary Policy", "Economic Outlook", "Inflation Update"],
        "text": ["The Federal Reserve..." * 100, "Economic conditions..." * 100, "Inflation remains..." * 100],
        "is_gov": [True, True, True],
    })


@pytest.fixture
def sample_embeddings() -> list[list[float]]:
    """Sample embedding vectors for testing (1024 dimensions)."""
    return [[0.1] * 1024, [0.2] * 1024, [0.3] * 1024]


@pytest.fixture
def sample_classifications() -> pl.DataFrame:
    """Sample classification results."""
    return pl.DataFrame({
        "reference": ["BIS_2024_001", "BIS_2024_002"],
        "monetary_stance": [3, 4],
        "trade_stance": [3, 2],
        "tariff_mention": [0, 1],
        "economic_outlook": [3, 4],
    })


# =============================================================================
# Dagster Context Fixtures
# =============================================================================

@pytest.fixture
def asset_context() -> AssetExecutionContext:
    """Build Dagster asset execution context for testing."""
    return build_asset_context()
```

### 1.3 Directory Structure

```
dagster/tests/
├── conftest.py              # Shared fixtures (NEW)
├── __init__.py
├── unit/                    # NEW directory
│   ├── __init__.py
│   ├── resources/
│   │   ├── __init__.py
│   │   ├── test_minio.py
│   │   ├── test_lakefs.py
│   │   ├── test_weaviate.py
│   │   ├── test_nim.py
│   │   ├── test_nim_embedding.py
│   │   └── test_safe_synth.py
│   ├── io_managers/
│   │   ├── __init__.py
│   │   ├── test_checkpoint.py
│   │   ├── test_minio_polars.py
│   │   ├── test_lakefs_polars.py
│   │   └── test_weaviate_io.py
│   └── assets/
│       ├── __init__.py
│       ├── test_demo.py
│       ├── test_health.py
│       ├── test_validation.py
│       ├── test_central_bank_speeches.py
│       └── test_synthetic_speeches.py
├── integration/             # NEW directory
│   ├── __init__.py
│   └── test_pipeline_e2e.py
└── (existing test files - migrate to unit/)
```

### Verification Commands

```bash
cd dagster
uv sync --all-extras
ruff check src/ --select=E,W,F,I
pytest tests/ -v --tb=short
```

---

## Phase 2: Type Definitions Module

### 2.1 Create types.py

**Create:** `dagster/src/brev_pipelines/types.py`

This module centralizes all TypedDict and Protocol definitions to replace `Any` types.

```python
"""Type definitions for Brev Pipelines.

Contains TypedDict definitions for structured dictionaries and
Protocol definitions for dependency injection interfaces.

All types follow INV-P005 (No Any) and INV-P011 (No bare generics).
"""
from __future__ import annotations

from datetime import datetime
from typing import TYPE_CHECKING, Literal, Protocol, TypedDict

from pydantic import BaseModel, ConfigDict, Field

if TYPE_CHECKING:
    from collections.abc import Sequence


# =============================================================================
# Weaviate Types (replaces dict[str, Any] in weaviate.py)
# =============================================================================

class WeaviatePropertyDef(TypedDict):
    """Property definition for Weaviate collection schema."""

    name: str
    data_type: Literal["text", "date", "boolean", "int", "number"]


class WeaviateObjectProperties(TypedDict, total=False):
    """Object properties to insert into Weaviate collection."""

    reference: str
    date: str
    central_bank: str
    speaker: str
    title: str
    text: str
    summary: str
    monetary_stance: int
    trade_stance: int
    tariff_mention: int
    economic_outlook: int
    is_governor: bool
    is_synthetic: bool


class WeaviateSearchHit(TypedDict):
    """Single result from Weaviate vector search."""

    properties: dict[str, str | int | bool | float]
    distance: float
    certainty: float


# =============================================================================
# Safe Synthesizer Types (replaces dict[str, Any] in safe_synth.py)
# =============================================================================

class SafeSynthConfig(TypedDict, total=False):
    """Configuration for Safe Synthesizer job."""

    epsilon: float
    delta: float
    pii_replacement: bool
    temperature: float
    run_mia_evaluation: bool
    run_aia_evaluation: bool
    rope_scaling_factor: int
    num_epochs: int


class SafeSynthJobStatus(TypedDict):
    """Status response from Safe Synthesizer job."""

    state: Literal["pending", "running", "completed", "error", "cancelled"]
    succeeded: int | None
    completion_time: str | None


class SafeSynthEvaluationResult(TypedDict, total=False):
    """Evaluation results from Safe Synthesizer."""

    job_id: str
    mia_score: float | None
    aia_score: float | None
    privacy_passed: bool
    quality_score: float | None
    input_records: int
    output_records: int


# =============================================================================
# Kubernetes Client Protocols (for safe_synth.py K8s client typing)
# =============================================================================

class K8sJobStatus(Protocol):
    """Protocol for Kubernetes Job status object."""

    @property
    def succeeded(self) -> int | None: ...

    @property
    def failed(self) -> int | None: ...

    @property
    def completion_time(self) -> str | None: ...


class K8sJob(Protocol):
    """Protocol for Kubernetes Job object."""

    @property
    def status(self) -> K8sJobStatus: ...


class K8sPodList(Protocol):
    """Protocol for Kubernetes Pod list."""

    @property
    def items(self) -> Sequence[object]: ...


class K8sBatchV1Api(Protocol):
    """Protocol for Kubernetes BatchV1Api client."""

    def create_namespaced_job(
        self,
        namespace: str,
        body: object,
    ) -> K8sJob: ...

    def read_namespaced_job_status(
        self,
        name: str,
        namespace: str,
    ) -> K8sJob: ...

    def delete_namespaced_job(
        self,
        name: str,
        namespace: str,
        propagation_policy: str = "Background",
    ) -> object: ...


class K8sCoreV1Api(Protocol):
    """Protocol for Kubernetes CoreV1Api client."""

    def list_namespaced_pod(
        self,
        namespace: str,
        label_selector: str,
    ) -> K8sPodList: ...

    def read_namespaced_pod_log(
        self,
        name: str,
        namespace: str,
        tail_lines: int = 100,
    ) -> str: ...


class K8sAppsV1Api(Protocol):
    """Protocol for Kubernetes AppsV1Api client."""

    def patch_namespaced_deployment_scale(
        self,
        name: str,
        namespace: str,
        body: dict[str, dict[str, int]],
    ) -> object: ...

    def read_namespaced_deployment(
        self,
        name: str,
        namespace: str,
    ) -> object: ...


# =============================================================================
# Asset Return Types (replaces dict[str, Any] in assets)
# =============================================================================

class DataProductMetadata(TypedDict):
    """Metadata returned by data product assets."""

    path: str
    commit_id: str | None
    num_records: int
    lakefs_ref: str


class WeaviateIndexMetadata(TypedDict):
    """Metadata returned by Weaviate indexing assets."""

    collection: str
    object_count: int
    vector_dimensions: int
    indexing_strategy: str


class SnapshotMetadata(TypedDict):
    """Metadata returned by snapshot assets."""

    path: str
    commit_id: str | None
    num_records: int
    lakefs_ref: str


class EmbeddingsSnapshotMetadata(TypedDict):
    """Metadata returned by embeddings snapshot assets."""

    path: str
    commit_id: str | None
    num_records: int
    lakefs_ref: str
    vector_dimensions: int
    model: str


class SyntheticDataMetadata(TypedDict):
    """Metadata returned by synthetic data assets."""

    path: str
    commit_id: str | None
    num_records: int
    lakefs_ref: str
    input_records: int
    mia_score: float | None
    aia_score: float | None
    privacy_passed: bool


# =============================================================================
# Validation Types (replaces dict[str, Any] in validation.py)
# =============================================================================

class ComponentTestResult(TypedDict):
    """Result of a single validation test."""

    name: str
    status: Literal["passed", "failed", "skipped"]
    message: str


class ComponentValidationResult(TypedDict):
    """Validation result for a single component."""

    component: str
    status: Literal["healthy", "unhealthy", "degraded"]
    tests: list[ComponentTestResult]
    error: str | None


class ValidationSummary(TypedDict):
    """Summary of validation run."""

    overall_status: Literal["healthy", "unhealthy", "degraded"]
    components_checked: int
    tests_passed: int
    tests_failed: int


class ValidationReport(TypedDict):
    """Complete validation report structure."""

    validation_run: dict[str, str | int]
    components: dict[str, ComponentValidationResult]
    summary: ValidationSummary
    report_location: str
    duration_ms: float


class QuickHealthReport(TypedDict):
    """Quick health check report."""

    status: Literal["healthy", "unhealthy"]
    checked_at: str
    components: dict[str, Literal["up", "down"]]


# =============================================================================
# Demo Asset Types
# =============================================================================

class DemoSummary(TypedDict):
    """Summary statistics from demo pipeline."""

    total_records: int
    total_spend: float
    avg_spend: float
    tier_counts: dict[str, int]


# =============================================================================
# Pydantic Models for Validated Data
# =============================================================================

class SpeechClassificationResult(BaseModel):
    """Result of LLM speech classification.

    Used with PydanticAI for structured LLM outputs (INV-P008).
    """

    model_config = ConfigDict(strict=True, frozen=True)

    monetary_stance: Literal[
        "very_dovish", "somewhat_dovish", "neutral",
        "somewhat_hawkish", "very_hawkish"
    ] = Field(description="Monetary policy stance")

    trade_stance: Literal[
        "very_protectionist", "somewhat_protectionist", "neutral",
        "somewhat_globalist", "very_globalist"
    ] = Field(description="Trade policy stance")

    tariff_mention: Literal[0, 1] = Field(
        description="Whether tariffs are mentioned (1) or not (0)"
    )

    economic_outlook: Literal[
        "very_negative", "somewhat_negative", "neutral",
        "somewhat_positive", "very_positive"
    ] = Field(description="Economic outlook expressed")


class SpeechSummaryResult(BaseModel):
    """Result of LLM speech summarization.

    Used with PydanticAI for structured LLM outputs (INV-P008).
    """

    model_config = ConfigDict(strict=True, frozen=True)

    summary: str = Field(
        min_length=100,
        max_length=2000,
        description="Concise summary of the speech"
    )

    key_topics: list[str] = Field(
        max_length=5,
        description="Key topics discussed"
    )
```

### Verification

```bash
cd dagster
python -c "from brev_pipelines.types import *; print('Types module OK')"
mypy src/brev_pipelines/types.py --strict
```

---

## Phase 3: Resources Refactoring

### TDD Approach

For each resource:
1. Write failing test
2. Implement fix
3. Verify test passes
4. Run mypy --strict

### 3.1 LakeFS Resource

**Violation:** Line 14 - `get_client()` missing return type

**Test:** `tests/unit/resources/test_lakefs.py`

**Fix:**
```python
from lakefs_sdk.client import LakeFSClient

def get_client(self) -> LakeFSClient:
    """Get LakeFS client instance."""
    ...
```

### 3.2 Weaviate Resource

**Violations:** Lines 64, 115, 155 - `dict[str, Any]` in signatures

**Fix:**
```python
from brev_pipelines.types import WeaviatePropertyDef, WeaviateSearchHit

def ensure_collection(
    self,
    name: str,
    properties: list[WeaviatePropertyDef],  # Was list[dict[str, Any]]
    vector_dimensions: int = 1024,
) -> None: ...

def insert_objects(
    self,
    collection_name: str,
    objects: list[WeaviateObjectProperties],  # Was list[dict[str, Any]]
    vectors: list[list[float]],
    batch_size: int = 100,
) -> int: ...

def vector_search(
    self,
    collection_name: str,
    query_vector: list[float],
    limit: int = 10,
) -> list[WeaviateSearchHit]:  # Was list[dict[str, Any]]
    ...
```

### 3.3 Safe Synthesizer Resource

**Violations:** 14+ - K8s clients as `Any`, config dicts as `Any`

**Fix:**
```python
from brev_pipelines.types import (
    K8sAppsV1Api,
    K8sBatchV1Api,
    K8sCoreV1Api,
    SafeSynthConfig,
    SafeSynthEvaluationResult,
    SafeSynthJobStatus,
)

def _get_k8s_batch_client(self) -> K8sBatchV1Api: ...
def _get_k8s_core_client(self) -> K8sCoreV1Api: ...
def _get_k8s_apps_client(self) -> K8sAppsV1Api: ...

def create_synthesis_job(
    self,
    job_name: str,
    input_data_path: str,
    output_data_path: str,
    synth_config: SafeSynthConfig | None = None,
) -> str: ...

def wait_for_job(self, job_name: str) -> SafeSynthJobStatus: ...

def synthesize(
    self,
    input_data: list[dict[str, str | int | bool | float]],
    run_id: str,
    config: SafeSynthConfig | None = None,
) -> tuple[list[dict[str, str | int | bool | float]], SafeSynthEvaluationResult]: ...
```

### Verification

```bash
pytest tests/unit/resources/ -v --cov=brev_pipelines.resources
mypy src/brev_pipelines/resources/ --strict
```

---

## Phase 4: I/O Managers Refactoring

### 4.1 Checkpoint Manager

**Violations:**
1. Lines 59-61: Pydantic v1 `class Config:`
2. Line 176: `process_fn: callable`
3. Line 179: `logger=None` untyped

**Fixes:**
```python
from collections.abc import Callable
from pydantic import ConfigDict
from dagster import DagsterLogManager

class LLMCheckpointManager(BaseModel):
    # Replace class Config with:
    model_config = ConfigDict(arbitrary_types_allowed=True)

    ...

def process_with_checkpoint(
    df: pl.DataFrame,
    id_column: str,
    process_fn: Callable[
        [dict[str, str | int | float | None]],
        dict[str, str | int | float | None]
    ],
    checkpoint_manager: LLMCheckpointManager,
    batch_size: int = 10,
    logger: DagsterLogManager | None = None,
) -> pl.DataFrame: ...
```

### Verification

```bash
pytest tests/unit/io_managers/ -v --cov=brev_pipelines.io_managers
mypy src/brev_pipelines/io_managers/ --strict
```

---

## Phase 5: Assets Refactoring

### 5.1 Demo Assets

**Violation:** Line 117 - `dict[str, Any]` return type

**Fix:**
```python
from brev_pipelines.types import DemoSummary

def data_summary(...) -> DemoSummary: ...
```

### 5.2 Validation Assets

**Violations:** 11 - All `validate_*` return `dict[str, Any]`

**Fixes:**
```python
from brev_pipelines.types import (
    ComponentValidationResult,
    ValidationReport,
    QuickHealthReport,
)

def validate_minio(...) -> ComponentValidationResult: ...
def validate_lakefs(...) -> ComponentValidationResult: ...
def validate_nim(...) -> ComponentValidationResult: ...
def validate_platform(...) -> ValidationReport: ...
def quick_health_check(...) -> QuickHealthReport: ...
```

### 5.3 Central Bank Speeches

**Violations:** Lines 730, 816, 911, 1007, 1103 - `dict[str, Any]` return types

**Fixes:**
```python
from brev_pipelines.types import (
    DataProductMetadata,
    WeaviateIndexMetadata,
    SnapshotMetadata,
    EmbeddingsSnapshotMetadata,
)

def speeches_data_product(...) -> DataProductMetadata: ...
def weaviate_index(...) -> WeaviateIndexMetadata: ...
def classification_snapshot(...) -> SnapshotMetadata: ...
def summaries_snapshot(...) -> SnapshotMetadata: ...
def embeddings_snapshot(...) -> EmbeddingsSnapshotMetadata: ...
```

### 5.4 Synthetic Speeches

**Violations:** 9 - Similar to CBS, all `dict[str, Any]` return types

**Fixes:** Same pattern using TypedDict from types.py

### Verification

```bash
pytest tests/unit/assets/ -v --cov=brev_pipelines.assets
mypy src/brev_pipelines/assets/ --strict
```

---

## Phase 6: Integration Tests

### Create E2E Pipeline Tests

**File:** `tests/integration/test_pipeline_e2e.py`

Test scenarios:
- Full CBS pipeline with mocked services
- Synthetic pipeline with mocked Safe Synthesizer
- Checkpoint recovery after simulated failure
- Asset dependency resolution

### Final Verification

```bash
# Complete test suite
pytest tests/ -v --cov=brev_pipelines --cov-report=html

# Type checking
mypy src/brev_pipelines/ --strict
pyright src/brev_pipelines/

# Linting
ruff check src/brev_pipelines/
ruff format src/brev_pipelines/ --check
```

---

## Files Summary

### Files to Modify

| File | Changes |
|------|---------|
| `pyproject.toml` | Strict mypy, comprehensive ruff, pyright, pytest |
| `resources/lakefs.py` | Add return type to `get_client()` |
| `resources/weaviate.py` | Replace 3 Any signatures with TypedDict |
| `resources/safe_synth.py` | Replace 14+ Any usages with TypedDict/Protocol |
| `io_managers/checkpoint.py` | Pydantic v2, Callable type, logger type |
| `assets/demo.py` | Replace Any return type |
| `assets/validation.py` | Replace 11 Any return types |
| `assets/central_bank_speeches.py` | Replace 5 Any return types |
| `assets/synthetic_speeches.py` | Replace 9 Any return types |

### Files to Create

| File | Purpose |
|------|---------|
| `src/brev_pipelines/types.py` | TypedDict and Protocol definitions |
| `tests/conftest.py` | Shared test fixtures |
| `tests/unit/resources/*.py` | Resource unit tests |
| `tests/unit/io_managers/*.py` | I/O manager unit tests |
| `tests/unit/assets/*.py` | Asset unit tests |
| `tests/integration/test_pipeline_e2e.py` | Integration tests |

---

## Coverage Targets

| Category | Current | Target |
|----------|---------|--------|
| Assets | ~5% | 80%+ |
| Resources | ~50% | 90%+ |
| I/O Managers | 0% | 100% |
| Overall | ~11% | 80%+ |

---

## References

- [INVARIANTS.md](../invariants/INVARIANTS.md) - INV-P004 through INV-P011
- [dagster-engineer.md](../../.claude/agents/dagster-engineer.md) - TDD patterns
- [python-stylist.md](../../.claude/agents/python-stylist.md) - Type system rules
- [dagster/.CLAUDE.md](../../dagster/.CLAUDE.md) - Coding guidelines
