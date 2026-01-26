# Mock LLM and Weaviate for Local Development Testing

**Date:** 2026-01-26
**Context:** Dagster Pipeline Local Development
**Status:** Design Proposal

## Executive Summary

Local development and testing of Dagster pipelines currently requires access to:
- **NVIDIA NIM services** (LLM inference and embeddings) - running on GPU nodes in Kubernetes
- **Weaviate vector database** - running in Kubernetes cluster

This creates friction for developers who want to:
1. Run pipelines locally without Kubernetes access
2. Write and run tests without network dependencies
3. Iterate quickly without GPU costs
4. Work offline or in CI/CD environments

This report proposes a **Protocol-based mock resource system** that enables:
1. **Full local development** with mock LLM and vector store
2. **Deterministic testing** with reproducible results
3. **Easy switching** between mock and real services via environment variable
4. **Type-safe interfaces** using Python Protocols
5. **PydanticAI compatibility** for structured LLM outputs

---

## 1. Current State Analysis

### Service Dependencies

| Service | Purpose | Requires | Local Alternative |
|---------|---------|----------|-------------------|
| NIM LLM | Text generation, classification | GPU (H100/H200) | None currently |
| NIM Embedding | Vector embeddings (1024-dim) | GPU | None currently |
| Weaviate | Vector search, storage | K8s cluster | Docker (heavy) |

### Current Usage Patterns

**NIM Embedding** (from `marimo/central_bank_speeches/utils.py`):
```python
def embed_query(query: str) -> list[float]:
    payload = {
        "model": EMBEDDING_MODEL,
        "input": [query],
        "input_type": "query",
    }
    response = requests.post(
        f"{NIM_EMBEDDING_ENDPOINT}/v1/embeddings",
        json=payload,
        timeout=30,
    )
    return response.json()["data"][0]["embedding"]
```

**Weaviate** (from `marimo/central_bank_speeches/utils.py`):
```python
def vector_search(query: str, collection: str, limit: int = 10) -> list[dict]:
    query_vector = embed_query(query)
    client = get_weaviate_client()
    coll = client.collections.get(collection)
    results = coll.query.near_vector(
        near_vector=query_vector,
        limit=limit,
    )
    return [dict(obj.properties) for obj in results.objects]
```

### Problems for Local Development

| Issue | Impact |
|-------|--------|
| **Requires K8s port-forward** | Can't work offline or without cluster access |
| **GPU dependency** | Expensive; limited availability |
| **Slow iteration** | Network latency on every test |
| **Non-deterministic** | LLM outputs vary; hard to test |
| **CI/CD complexity** | Need real services or skip tests |

---

## 2. Proposed Solution: Protocol-Based Mock Resources

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Resource Selection Flow                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  DAGSTER_MOCK_SERVICES=true                                         │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    definitions.py                            │    │
│  │                                                             │    │
│  │   if MOCK_MODE:                                             │    │
│  │       embedding = MockNIMEmbeddingResource()                │    │
│  │       llm = MockNIMLLMResource()                            │    │
│  │       vector_store = MockWeaviateResource()                 │    │
│  │   else:                                                     │    │
│  │       embedding = NIMEmbeddingResource(endpoint=...)        │    │
│  │       llm = NIMLLMResource(endpoint=...)                    │    │
│  │       vector_store = WeaviateResource(host=...)             │    │
│  │                                                             │    │
│  └─────────────────────────────────────────────────────────────┘    │
│       │                                                             │
│       ▼                                                             │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      Asset Code                              │    │
│  │                                                             │    │
│  │   @asset                                                    │    │
│  │   def my_asset(                                             │    │
│  │       embedding: EmbeddingProvider,  # Protocol type        │    │
│  │       vector_store: VectorStoreProvider,                    │    │
│  │   ):                                                        │    │
│  │       # Works with both real and mock!                      │    │
│  │       vectors = embedding.embed_texts(texts)                │    │
│  │       vector_store.upsert(...)                              │    │
│  │                                                             │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Directory Structure

```
dagster/src/brev_pipelines/
├── resources/
│   ├── __init__.py
│   ├── protocols.py              # Interface definitions
│   ├── nim.py                    # Real NIM resource (existing)
│   ├── nim_embedding.py          # Real NIM embedding (existing)
│   ├── nim_mock.py               # NEW: Mock NIM implementations
│   ├── weaviate_resource.py      # Real Weaviate resource
│   └── weaviate_mock.py          # NEW: Mock Weaviate implementation
├── definitions.py                # Resource binding
└── ...

dagster/tests/
├── conftest.py                   # Pytest fixtures with auto-mock
├── unit/
│   ├── test_mock_resources.py    # Test the mocks themselves
│   └── test_assets.py            # Asset tests using mocks
└── integration/
    └── test_pipeline.py          # Integration tests
```

---

## 3. Protocol Definitions (Interfaces)

Protocols define the contract that both real and mock implementations must satisfy.

### File: `dagster/src/brev_pipelines/resources/protocols.py`

```python
"""Protocol definitions for resource interfaces.

These protocols define the contract between assets and resources,
enabling mock implementations for local development and testing.
"""

from typing import Protocol, runtime_checkable, Any
import polars as pl


@runtime_checkable
class EmbeddingProvider(Protocol):
    """Protocol for embedding generation services.

    Implementations:
        - NIMEmbeddingResource: Real NVIDIA NIM service
        - MockNIMEmbeddingResource: Deterministic mock for testing
    """

    @property
    def dimensions(self) -> int:
        """Return the dimensionality of embeddings (e.g., 1024)."""
        ...

    def embed_texts(
        self,
        texts: list[str],
        batch_size: int = 32,
    ) -> list[list[float]]:
        """Generate embeddings for a list of texts.

        Args:
            texts: List of text strings to embed
            batch_size: Number of texts per batch (for real service)

        Returns:
            List of embedding vectors, one per input text
        """
        ...

    def embed_query(self, query: str) -> list[float]:
        """Generate embedding for a single query.

        Args:
            query: Search query text

        Returns:
            Embedding vector for the query
        """
        ...


@runtime_checkable
class LLMProvider(Protocol):
    """Protocol for LLM inference services.

    Implementations:
        - NIMLLMResource: Real NVIDIA NIM service
        - MockNIMLLMResource: Canned responses for testing
    """

    def generate(
        self,
        prompt: str,
        max_tokens: int = 500,
        temperature: float = 0.7,
    ) -> str:
        """Generate text completion.

        Args:
            prompt: Input prompt
            max_tokens: Maximum tokens to generate
            temperature: Sampling temperature (0.0 = deterministic)

        Returns:
            Generated text response
        """
        ...

    def get_pydantic_ai_model(self) -> Any:
        """Return a PydanticAI-compatible model.

        For testing, returns pydantic_ai.models.test.TestModel.
        For production, returns configured OpenAIChatModel.
        """
        ...


@runtime_checkable
class VectorStoreProvider(Protocol):
    """Protocol for vector database operations.

    Implementations:
        - WeaviateResource: Real Weaviate database
        - MockWeaviateResource: In-memory mock with cosine similarity
    """

    def collection_exists(self, collection: str) -> bool:
        """Check if a collection exists."""
        ...

    def get_collection_count(self, collection: str) -> int:
        """Get the number of documents in a collection."""
        ...

    def create_collection(
        self,
        collection: str,
        dimensions: int,
        properties: dict[str, str] | None = None,
    ) -> None:
        """Create a new collection.

        Args:
            collection: Collection name
            dimensions: Vector dimensionality
            properties: Property name -> type mapping (e.g., {"title": "text"})
        """
        ...

    def upsert(
        self,
        collection: str,
        ids: list[str],
        vectors: list[list[float]],
        metadata: list[dict[str, str | int | float | bool]],
    ) -> int:
        """Insert or update vectors in a collection.

        Args:
            collection: Target collection name
            ids: Document identifiers
            vectors: Embedding vectors
            metadata: Associated metadata for each document

        Returns:
            Number of documents upserted
        """
        ...

    def search(
        self,
        collection: str,
        query_vector: list[float],
        limit: int = 10,
        filters: dict[str, Any] | None = None,
    ) -> pl.DataFrame:
        """Search by vector similarity.

        Args:
            collection: Collection to search
            query_vector: Query embedding
            limit: Maximum results to return
            filters: Optional metadata filters

        Returns:
            DataFrame with results including _similarity score
        """
        ...

    def delete(
        self,
        collection: str,
        ids: list[str],
    ) -> int:
        """Delete documents by ID.

        Args:
            collection: Collection name
            ids: Document IDs to delete

        Returns:
            Number of documents deleted
        """
        ...
```

---

## 4. Mock Implementations

### 4.1 Mock NIM Embedding Resource

**File: `dagster/src/brev_pipelines/resources/nim_mock.py`**

```python
"""Mock implementations of NIM resources for local development and testing."""

from dagster import ConfigurableResource
from pydantic import Field
import hashlib
import math
from typing import Any


class MockNIMEmbeddingResource(ConfigurableResource):
    """Mock NIM embedding resource for local development.

    Generates deterministic embeddings based on text content hash,
    ensuring reproducible results for testing.

    Example:
        >>> resource = MockNIMEmbeddingResource(dimensions=1024)
        >>> embeddings = resource.embed_texts(["hello", "world"])
        >>> len(embeddings[0])
        1024
        >>> resource.embed_texts(["hello"])[0] == resource.embed_texts(["hello"])[0]
        True  # Deterministic!
    """

    dimensions: int = Field(
        default=1024,
        description="Embedding vector dimensions (must match real NIM model)",
    )
    deterministic: bool = Field(
        default=True,
        description="If True, same text always produces same embedding",
    )
    normalize: bool = Field(
        default=True,
        description="If True, normalize vectors to unit length",
    )

    def _hash_to_vector(self, text: str) -> list[float]:
        """Convert text to a deterministic vector via hashing.

        Uses SHA-256 hash extended to required dimensions.
        """
        # Create deterministic seed from text
        hash_bytes = hashlib.sha256(text.encode()).digest()

        # Extend hash to cover all dimensions
        vector: list[float] = []
        for i in range(self.dimensions):
            # Use different parts of extended hash for each dimension
            extended = hashlib.sha256(hash_bytes + i.to_bytes(4, 'big')).digest()
            # Convert 4 bytes to float in range [-1, 1]
            int_val = int.from_bytes(extended[:4], 'big', signed=True)
            float_val = int_val / (2**31)
            vector.append(float_val)

        return vector

    def _normalize(self, vector: list[float]) -> list[float]:
        """Normalize vector to unit length."""
        norm = math.sqrt(sum(x * x for x in vector))
        if norm < 1e-10:
            return vector
        return [x / norm for x in vector]

    def embed_texts(
        self,
        texts: list[str],
        batch_size: int = 32,  # Ignored in mock
    ) -> list[list[float]]:
        """Generate mock embeddings for texts.

        Args:
            texts: List of text strings
            batch_size: Ignored (for API compatibility)

        Returns:
            List of embedding vectors
        """
        embeddings: list[list[float]] = []

        for text in texts:
            if self.deterministic:
                vector = self._hash_to_vector(text)
            else:
                import random
                vector = [random.gauss(0, 1) for _ in range(self.dimensions)]

            if self.normalize:
                vector = self._normalize(vector)

            embeddings.append(vector)

        return embeddings

    def embed_query(self, query: str) -> list[float]:
        """Generate mock embedding for a single query."""
        return self.embed_texts([query])[0]


class MockNIMLLMResource(ConfigurableResource):
    """Mock NIM LLM resource for local development.

    Supports two modes:
    1. Canned responses: Return predefined responses based on prompt patterns
    2. Echo mode: Return structured response echoing input for testing

    Example:
        >>> resource = MockNIMLLMResource()
        >>> resource.add_canned_response(
        ...     pattern="classify",
        ...     response='{"sentiment": "positive", "confidence": 0.9}'
        ... )
        >>> resource.generate("Please classify this text")
        '{"sentiment": "positive", "confidence": 0.9}'
    """

    model_name: str = Field(
        default="mock/llama-3.1-8b-instruct",
        description="Mock model identifier",
    )
    default_response: str = Field(
        default='{"status": "mock_response", "message": "This is a mock LLM response"}',
        description="Default response when no pattern matches",
    )
    echo_mode: bool = Field(
        default=False,
        description="If True, echo back a structured version of the prompt",
    )

    # Instance-level storage for canned responses
    _canned_responses: dict[str, str] = {}

    def add_canned_response(self, pattern: str, response: str) -> None:
        """Add a canned response for prompts matching pattern.

        Args:
            pattern: Substring to match in prompts (case-insensitive)
            response: Response to return when pattern matches
        """
        self._canned_responses[pattern.lower()] = response

    def clear_canned_responses(self) -> None:
        """Clear all canned responses."""
        self._canned_responses.clear()

    def generate(
        self,
        prompt: str,
        max_tokens: int = 500,
        temperature: float = 0.7,
    ) -> str:
        """Generate mock LLM response.

        Args:
            prompt: Input prompt
            max_tokens: Ignored in mock
            temperature: Ignored in mock

        Returns:
            Mock response string
        """
        prompt_lower = prompt.lower()

        # Check canned responses
        for pattern, response in self._canned_responses.items():
            if pattern in prompt_lower:
                return response

        # Echo mode for testing
        if self.echo_mode:
            # Extract key info from prompt for echo
            lines = prompt.strip().split('\n')
            first_line = lines[0][:100] if lines else "empty"
            return f'{{"echo": true, "prompt_preview": "{first_line}", "length": {len(prompt)}}}'

        return self.default_response

    def get_pydantic_ai_model(self) -> Any:
        """Return PydanticAI TestModel for structured output testing.

        The TestModel from pydantic_ai.models.test allows testing
        PydanticAI agents without real LLM calls.
        """
        try:
            from pydantic_ai.models.test import TestModel
            return TestModel()
        except ImportError:
            raise ImportError(
                "pydantic_ai is required for get_pydantic_ai_model(). "
                "Install with: pip install pydantic-ai"
            )
```

### 4.2 Mock Weaviate Resource

**File: `dagster/src/brev_pipelines/resources/weaviate_mock.py`**

```python
"""Mock Weaviate implementation for local development and testing."""

from dagster import ConfigurableResource
from pydantic import Field, PrivateAttr
import polars as pl
from typing import Any
import math


class MockWeaviateResource(ConfigurableResource):
    """In-memory mock Weaviate for local development.

    Provides a fully functional vector database mock with:
    - Collection management
    - Vector upsert/delete operations
    - Cosine similarity search
    - Metadata filtering

    Data is stored in memory and persists for the resource lifetime.
    Use reset() between tests to clear state.

    Example:
        >>> store = MockWeaviateResource()
        >>> store.create_collection("docs", dimensions=1024)
        >>> store.upsert(
        ...     "docs",
        ...     ids=["doc1"],
        ...     vectors=[[0.1] * 1024],
        ...     metadata=[{"title": "Hello"}]
        ... )
        >>> results = store.search("docs", query_vector=[0.1] * 1024, limit=5)
        >>> len(results)
        1
    """

    # Private attribute for in-memory storage
    _collections: dict[str, dict[str, Any]] = PrivateAttr(default_factory=dict)

    def model_post_init(self, __context: Any) -> None:
        """Initialize storage after Pydantic model creation."""
        self._collections = {}

    def _cosine_similarity(self, a: list[float], b: list[float]) -> float:
        """Calculate cosine similarity between two vectors."""
        dot_product = sum(x * y for x, y in zip(a, b, strict=True))
        norm_a = math.sqrt(sum(x * x for x in a))
        norm_b = math.sqrt(sum(x * x for x in b))

        if norm_a < 1e-10 or norm_b < 1e-10:
            return 0.0

        return dot_product / (norm_a * norm_b)

    def collection_exists(self, collection: str) -> bool:
        """Check if a collection exists."""
        return collection in self._collections

    def get_collection_count(self, collection: str) -> int:
        """Get document count in a collection."""
        if collection not in self._collections:
            return 0
        return len(self._collections[collection].get("documents", {}))

    def create_collection(
        self,
        collection: str,
        dimensions: int,
        properties: dict[str, str] | None = None,
    ) -> None:
        """Create a new collection.

        Args:
            collection: Collection name
            dimensions: Vector dimensionality
            properties: Property schema (ignored in mock, kept for compatibility)
        """
        if collection in self._collections:
            return  # Idempotent

        self._collections[collection] = {
            "dimensions": dimensions,
            "properties": properties or {},
            "documents": {},  # id -> {vector, metadata}
        }

    def upsert(
        self,
        collection: str,
        ids: list[str],
        vectors: list[list[float]],
        metadata: list[dict[str, str | int | float | bool]],
    ) -> int:
        """Upsert documents into collection.

        Args:
            collection: Target collection
            ids: Document IDs
            vectors: Embedding vectors
            metadata: Document metadata

        Returns:
            Number of documents upserted
        """
        if collection not in self._collections:
            # Auto-create collection with inferred dimensions
            if vectors:
                self.create_collection(collection, dimensions=len(vectors[0]))
            else:
                raise ValueError(f"Collection {collection} does not exist")

        coll = self._collections[collection]
        documents = coll["documents"]

        for doc_id, vector, meta in zip(ids, vectors, metadata, strict=True):
            documents[doc_id] = {
                "vector": vector,
                "metadata": meta,
            }

        return len(ids)

    def search(
        self,
        collection: str,
        query_vector: list[float],
        limit: int = 10,
        filters: dict[str, Any] | None = None,
    ) -> pl.DataFrame:
        """Search by vector similarity.

        Args:
            collection: Collection to search
            query_vector: Query embedding
            limit: Max results
            filters: Metadata filters (simple equality matching)

        Returns:
            DataFrame with results sorted by similarity
        """
        if collection not in self._collections:
            return pl.DataFrame()

        documents = self._collections[collection]["documents"]

        if not documents:
            return pl.DataFrame()

        # Calculate similarities
        results: list[dict[str, Any]] = []

        for doc_id, doc in documents.items():
            # Apply filters
            if filters:
                skip = False
                for key, value in filters.items():
                    if doc["metadata"].get(key) != value:
                        skip = True
                        break
                if skip:
                    continue

            similarity = self._cosine_similarity(query_vector, doc["vector"])

            result = {
                "_id": doc_id,
                "_similarity": similarity,
                "_distance": 1 - similarity,
                **doc["metadata"],
            }
            results.append(result)

        # Sort by similarity descending
        results.sort(key=lambda x: x["_similarity"], reverse=True)

        # Return top-k
        top_k = results[:limit]

        if not top_k:
            return pl.DataFrame()

        return pl.DataFrame(top_k)

    def delete(
        self,
        collection: str,
        ids: list[str],
    ) -> int:
        """Delete documents by ID.

        Args:
            collection: Collection name
            ids: IDs to delete

        Returns:
            Number of documents deleted
        """
        if collection not in self._collections:
            return 0

        documents = self._collections[collection]["documents"]
        deleted = 0

        for doc_id in ids:
            if doc_id in documents:
                del documents[doc_id]
                deleted += 1

        return deleted

    def reset(self) -> None:
        """Clear all collections and data.

        Call this between tests to ensure clean state.
        """
        self._collections.clear()

    def get_all_documents(self, collection: str) -> list[dict[str, Any]]:
        """Get all documents in a collection (for testing/debugging).

        Args:
            collection: Collection name

        Returns:
            List of all documents with their metadata
        """
        if collection not in self._collections:
            return []

        documents = self._collections[collection]["documents"]
        return [
            {"_id": doc_id, **doc["metadata"]}
            for doc_id, doc in documents.items()
        ]
```

---

## 5. Resource Binding and Environment Detection

**File: `dagster/src/brev_pipelines/definitions.py`** (additions)

```python
"""Dagster definitions with environment-based resource selection."""

import os
from dagster import Definitions, EnvVar

# Environment detection
MOCK_MODE = os.getenv("DAGSTER_MOCK_SERVICES", "false").lower() == "true"


def get_resources() -> dict[str, Any]:
    """Get resources based on environment.

    Set DAGSTER_MOCK_SERVICES=true for local development.
    """
    if MOCK_MODE:
        from .resources.nim_mock import (
            MockNIMEmbeddingResource,
            MockNIMLLMResource,
        )
        from .resources.weaviate_mock import MockWeaviateResource

        return {
            "nim_embedding": MockNIMEmbeddingResource(
                dimensions=1024,
                deterministic=True,
            ),
            "nim_reasoning": MockNIMLLMResource(
                echo_mode=False,
            ),
            "nim": MockNIMLLMResource(
                echo_mode=False,
            ),
            "vector_store": MockWeaviateResource(),
        }
    else:
        from .resources.nim_embedding import NIMEmbeddingResource
        from .resources.nim import NIMResource
        from .resources.weaviate_resource import WeaviateResource

        return {
            "nim_embedding": NIMEmbeddingResource(
                endpoint=os.getenv(
                    "NIM_EMBEDDING_ENDPOINT",
                    "http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000"
                ),
            ),
            "nim_reasoning": NIMResource(
                endpoint=os.getenv(
                    "NIM_REASONING_ENDPOINT",
                    "http://nvidia-nim-reasoning.nvidia-nim.svc.cluster.local:8000"
                ),
            ),
            "nim": NIMResource(
                endpoint=os.getenv(
                    "NIM_LLM_ENDPOINT",
                    "http://nvidia-nim.nvidia-nim.svc.cluster.local:8000"
                ),
            ),
            "vector_store": WeaviateResource(
                host=os.getenv("WEAVIATE_HOST", "weaviate.weaviate.svc.cluster.local"),
                port=int(os.getenv("WEAVIATE_PORT", "8080")),
                grpc_port=int(os.getenv("WEAVIATE_GRPC_PORT", "50051")),
            ),
        }


# Build definitions
defs = Definitions(
    assets=[...],  # Your assets
    resources=get_resources(),
)
```

---

## 6. Pytest Integration

**File: `dagster/tests/conftest.py`**

```python
"""Pytest fixtures for Dagster pipeline testing with mock resources."""

import os
import pytest
from typing import Generator

# Force mock mode for all tests
os.environ["DAGSTER_MOCK_SERVICES"] = "true"

from brev_pipelines.resources.nim_mock import (
    MockNIMEmbeddingResource,
    MockNIMLLMResource,
)
from brev_pipelines.resources.weaviate_mock import MockWeaviateResource


@pytest.fixture
def mock_embedding() -> MockNIMEmbeddingResource:
    """Provide mock embedding resource with deterministic output."""
    return MockNIMEmbeddingResource(
        dimensions=1024,
        deterministic=True,
        normalize=True,
    )


@pytest.fixture
def mock_llm() -> MockNIMLLMResource:
    """Provide mock LLM resource."""
    resource = MockNIMLLMResource(echo_mode=False)

    # Add common canned responses for testing
    resource.add_canned_response(
        "classify",
        '{"monetary_stance": "neutral", "trade_stance": "neutral", '
        '"tariff_mention": 0, "economic_outlook": "neutral"}'
    )
    resource.add_canned_response(
        "summarize",
        "This speech discusses monetary policy and economic conditions."
    )
    resource.add_canned_response(
        "sentiment",
        '{"sentiment": "neutral", "confidence": 0.85}'
    )

    return resource


@pytest.fixture
def mock_vector_store() -> Generator[MockWeaviateResource, None, None]:
    """Provide mock vector store, reset after each test."""
    store = MockWeaviateResource()
    yield store
    store.reset()  # Clean up after test


@pytest.fixture(autouse=True)
def reset_mock_state(mock_vector_store: MockWeaviateResource) -> Generator[None, None, None]:
    """Automatically reset mock state between tests."""
    yield
    mock_vector_store.reset()


# Dagster-specific fixtures
@pytest.fixture
def dagster_resources(
    mock_embedding: MockNIMEmbeddingResource,
    mock_llm: MockNIMLLMResource,
    mock_vector_store: MockWeaviateResource,
) -> dict:
    """Provide complete resource dictionary for Dagster tests."""
    return {
        "nim_embedding": mock_embedding,
        "nim_reasoning": mock_llm,
        "nim": mock_llm,
        "vector_store": mock_vector_store,
    }
```

### Example Test Using Mocks

**File: `dagster/tests/unit/test_assets.py`**

```python
"""Unit tests for assets using mock resources."""

import polars as pl
import pytest
from dagster import build_asset_context, materialize

from brev_pipelines.resources.nim_mock import (
    MockNIMEmbeddingResource,
    MockNIMLLMResource,
)
from brev_pipelines.resources.weaviate_mock import MockWeaviateResource


class TestEmbeddingAsset:
    """Tests for embedding generation asset."""

    def test_generates_embeddings_for_all_texts(
        self,
        mock_embedding: MockNIMEmbeddingResource,
    ) -> None:
        """Verify embeddings are generated for each input text."""
        texts = ["Hello world", "Goodbye world", "Test text"]

        embeddings = mock_embedding.embed_texts(texts)

        assert len(embeddings) == 3
        assert all(len(e) == 1024 for e in embeddings)

    def test_deterministic_embeddings(
        self,
        mock_embedding: MockNIMEmbeddingResource,
    ) -> None:
        """Verify same text produces same embedding."""
        text = "The Federal Reserve announced rate changes."

        embedding1 = mock_embedding.embed_texts([text])[0]
        embedding2 = mock_embedding.embed_texts([text])[0]

        assert embedding1 == embedding2

    def test_different_texts_different_embeddings(
        self,
        mock_embedding: MockNIMEmbeddingResource,
    ) -> None:
        """Verify different texts produce different embeddings."""
        embedding1 = mock_embedding.embed_texts(["monetary policy"])[0]
        embedding2 = mock_embedding.embed_texts(["fiscal policy"])[0]

        assert embedding1 != embedding2


class TestVectorStoreAsset:
    """Tests for vector store operations."""

    def test_upsert_and_search(
        self,
        mock_embedding: MockNIMEmbeddingResource,
        mock_vector_store: MockWeaviateResource,
    ) -> None:
        """Test complete upsert and search workflow."""
        # Create collection
        mock_vector_store.create_collection("TestSpeeches", dimensions=1024)

        # Generate embeddings
        texts = [
            "The Fed raised interest rates by 25 basis points.",
            "ECB maintains accommodative monetary policy.",
            "Bank of Japan continues yield curve control.",
        ]
        embeddings = mock_embedding.embed_texts(texts)

        # Upsert
        count = mock_vector_store.upsert(
            collection="TestSpeeches",
            ids=["sp1", "sp2", "sp3"],
            vectors=embeddings,
            metadata=[
                {"title": "Fed Rate Decision", "bank": "FED"},
                {"title": "ECB Policy Update", "bank": "ECB"},
                {"title": "BOJ Statement", "bank": "BOJ"},
            ],
        )

        assert count == 3
        assert mock_vector_store.get_collection_count("TestSpeeches") == 3

        # Search for similar to first document
        results = mock_vector_store.search(
            collection="TestSpeeches",
            query_vector=embeddings[0],
            limit=2,
        )

        assert len(results) == 2
        # First result should be exact match
        assert results["_id"][0] == "sp1"
        assert results["_similarity"][0] > 0.99


class TestClassificationAsset:
    """Tests for LLM classification asset."""

    def test_classification_with_canned_response(
        self,
        mock_llm: MockNIMLLMResource,
    ) -> None:
        """Test classification uses canned response."""
        prompt = "Please classify this speech about monetary policy..."

        response = mock_llm.generate(prompt)

        assert "monetary_stance" in response
        assert "neutral" in response

    def test_handles_unknown_prompts(
        self,
        mock_llm: MockNIMLLMResource,
    ) -> None:
        """Test default response for unmatched prompts."""
        response = mock_llm.generate("Random unmatched prompt")

        assert "mock_response" in response
```

---

## 7. Usage Guide

### Local Development

```bash
# Start Dagster with mock services (no external dependencies)
cd dagster
DAGSTER_MOCK_SERVICES=true uv run dagster dev

# Or export for session
export DAGSTER_MOCK_SERVICES=true
uv run dagster dev
```

### Running Tests

```bash
# Tests automatically use mocks (set in conftest.py)
cd dagster
uv run pytest tests/ -v

# Run specific test file
uv run pytest tests/unit/test_assets.py -v

# Run with coverage
uv run pytest tests/ --cov=brev_pipelines --cov-report=html
```

### Makefile Targets

Add to `Makefile`:

```makefile
# Local development with mocks
dagster-dev-mock:
	@echo "Starting Dagster with mock services..."
	cd dagster && DAGSTER_MOCK_SERVICES=true uv run dagster dev

# Run tests (automatically uses mocks)
dagster-test:
	@echo "Running Dagster tests..."
	cd dagster && uv run pytest tests/ -v

# Run tests with coverage
dagster-test-cov:
	@echo "Running Dagster tests with coverage..."
	cd dagster && uv run pytest tests/ --cov=brev_pipelines --cov-report=html

# Type checking
dagster-typecheck:
	@echo "Running type checks..."
	cd dagster && uv run mypy src/ --strict && uv run pyright src/

# Full validation (types + tests)
dagster-validate: dagster-typecheck dagster-test
	@echo "Validation complete!"
```

### CI/CD Integration

```yaml
# .github/workflows/test.yml
name: Test Dagster Pipelines

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install uv
        run: pip install uv

      - name: Install dependencies
        run: cd dagster && uv sync

      - name: Run type checks
        run: cd dagster && uv run mypy src/ --strict

      - name: Run tests
        env:
          DAGSTER_MOCK_SERVICES: "true"
        run: cd dagster && uv run pytest tests/ -v --cov=brev_pipelines
```

---

## 8. Advanced Patterns

### 8.1 Custom Canned Responses for Specific Tests

```python
def test_hawkish_classification(mock_llm: MockNIMLLMResource) -> None:
    """Test handling of hawkish sentiment."""
    # Override canned response for this test
    mock_llm.add_canned_response(
        "classify",
        '{"monetary_stance": "hawkish", "trade_stance": "protectionist", '
        '"tariff_mention": 1, "economic_outlook": "positive"}'
    )

    response = mock_llm.generate("classify this hawkish speech...")

    assert "hawkish" in response
```

### 8.2 Testing Error Handling

```python
def test_handles_llm_error(mock_llm: MockNIMLLMResource) -> None:
    """Test graceful handling of LLM errors."""
    mock_llm.add_canned_response(
        "error_trigger",
        "LLM error: Connection timeout after 30s"
    )

    response = mock_llm.generate("error_trigger prompt")

    assert response.startswith("LLM error:")
```

### 8.3 Integration with PydanticAI

```python
from pydantic import BaseModel
from pydantic_ai import Agent


class SentimentResult(BaseModel):
    sentiment: str
    confidence: float


def test_pydantic_ai_integration(mock_llm: MockNIMLLMResource) -> None:
    """Test PydanticAI agent with mock model."""
    model = mock_llm.get_pydantic_ai_model()

    agent = Agent(
        model=model,
        result_type=SentimentResult,
    )

    # TestModel returns mock structured data
    # Configure expected response in test
    ...
```

### 8.4 Pre-populated Test Data

```python
@pytest.fixture
def populated_vector_store(
    mock_embedding: MockNIMEmbeddingResource,
    mock_vector_store: MockWeaviateResource,
) -> MockWeaviateResource:
    """Provide vector store pre-populated with test data."""
    speeches = [
        {"id": "fed_2024_01", "text": "Rate hike announcement", "bank": "FED"},
        {"id": "ecb_2024_01", "text": "Inflation outlook", "bank": "ECB"},
        {"id": "boj_2024_01", "text": "Yield curve control", "bank": "BOJ"},
    ]

    texts = [s["text"] for s in speeches]
    embeddings = mock_embedding.embed_texts(texts)

    mock_vector_store.create_collection("Speeches", dimensions=1024)
    mock_vector_store.upsert(
        collection="Speeches",
        ids=[s["id"] for s in speeches],
        vectors=embeddings,
        metadata=[{"title": s["text"], "bank": s["bank"]} for s in speeches],
    )

    return mock_vector_store
```

---

## 9. Comparison: Mock vs Real

| Aspect | Mock | Real |
|--------|------|------|
| **Setup time** | Instant | Requires K8s/port-forward |
| **Dependencies** | None | NIM GPU, Weaviate cluster |
| **Speed** | ~1ms per call | ~100-500ms per call |
| **Cost** | Free | GPU compute costs |
| **Determinism** | 100% reproducible | Varies by temperature |
| **Offline** | Yes | No |
| **CI/CD** | Simple | Requires service mocking or skip |
| **Accuracy** | Simulated | Real model behavior |

### When to Use Each

**Use Mocks:**
- Unit testing asset logic
- Local development iteration
- CI/CD pipelines
- Testing error handling
- Validating data flow

**Use Real Services:**
- Integration testing
- Validating LLM prompt quality
- Performance benchmarking
- Pre-production validation
- Evaluating embedding quality

---

## 10. Implementation Plan

### Phase 1: Core Mock Resources

| Task | Priority | Effort |
|------|----------|--------|
| Create `protocols.py` with interfaces | High | 1 hour |
| Implement `MockNIMEmbeddingResource` | High | 2 hours |
| Implement `MockNIMLLMResource` | High | 2 hours |
| Implement `MockWeaviateResource` | High | 3 hours |
| Unit tests for mock resources | High | 2 hours |

### Phase 2: Integration

| Task | Priority | Effort |
|------|----------|--------|
| Update `definitions.py` with env detection | High | 1 hour |
| Create `conftest.py` fixtures | High | 1 hour |
| Update existing asset tests | Medium | 2 hours |
| Add Makefile targets | Medium | 30 min |

### Phase 3: Documentation & CI

| Task | Priority | Effort |
|------|----------|--------|
| Update README with mock usage | Medium | 1 hour |
| Add CI/CD workflow | Medium | 1 hour |
| Create example test patterns | Low | 1 hour |

---

## 11. Alternatives Considered

### Alternative A: Docker Compose for Local Services

**Approach:** Run Weaviate and mock LLM server in Docker locally.

**Pros:**
- More realistic behavior
- Tests actual network calls

**Cons:**
- Requires Docker
- Slower startup
- Still need mock LLM server
- Resource intensive

**Verdict:** More complex than needed for unit testing; consider for integration tests.

### Alternative B: VCR/Recording Approach

**Approach:** Record real API responses and replay them in tests.

**Pros:**
- Uses real responses
- Good for regression testing

**Cons:**
- Recordings become stale
- Hard to cover edge cases
- Requires initial real service access
- Large test fixtures

**Verdict:** Useful complement but not primary testing strategy.

### Alternative C: Dependency Injection via Dagster Resources (Selected)

**Approach:** Use Dagster's resource system with protocol-based interfaces.

**Pros:**
- Native Dagster pattern
- Clean separation of concerns
- Easy environment switching
- Type-safe with protocols
- Fast in-memory execution

**Cons:**
- Mock behavior may differ from real
- Need to maintain both implementations

**Verdict:** Best fit for Dagster pipelines; follows existing patterns.

---

## 12. References

- [Dagster Resources Documentation](https://docs.dagster.io/concepts/resources)
- [Python Protocols (PEP 544)](https://peps.python.org/pep-0544/)
- [PydanticAI Testing Guide](https://ai.pydantic.dev/testing/)
- [Weaviate Python Client](https://weaviate.io/developers/weaviate/client-libraries/python)
- [NVIDIA NIM Documentation](https://docs.nvidia.com/nim/)
- [Existing LLM Retry Pattern](llm-retry-dead-letter-pattern.md)

---

## Appendix A: Complete Protocol Reference

```python
# All protocols in one place for reference

@runtime_checkable
class EmbeddingProvider(Protocol):
    @property
    def dimensions(self) -> int: ...
    def embed_texts(self, texts: list[str], batch_size: int = 32) -> list[list[float]]: ...
    def embed_query(self, query: str) -> list[float]: ...


@runtime_checkable
class LLMProvider(Protocol):
    def generate(self, prompt: str, max_tokens: int = 500, temperature: float = 0.7) -> str: ...
    def get_pydantic_ai_model(self) -> Any: ...


@runtime_checkable
class VectorStoreProvider(Protocol):
    def collection_exists(self, collection: str) -> bool: ...
    def get_collection_count(self, collection: str) -> int: ...
    def create_collection(self, collection: str, dimensions: int, properties: dict[str, str] | None = None) -> None: ...
    def upsert(self, collection: str, ids: list[str], vectors: list[list[float]], metadata: list[dict[str, str | int | float | bool]]) -> int: ...
    def search(self, collection: str, query_vector: list[float], limit: int = 10, filters: dict[str, Any] | None = None) -> pl.DataFrame: ...
    def delete(self, collection: str, ids: list[str]) -> int: ...
```

## Appendix B: Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DAGSTER_MOCK_SERVICES` | `false` | Set to `true` to use mock resources |
| `NIM_EMBEDDING_ENDPOINT` | `http://nvidia-nim-embedding...` | Real NIM embedding endpoint |
| `NIM_LLM_ENDPOINT` | `http://nvidia-nim...` | Real NIM LLM endpoint |
| `NIM_REASONING_ENDPOINT` | `http://nvidia-nim-reasoning...` | Real NIM reasoning endpoint |
| `WEAVIATE_HOST` | `weaviate.weaviate...` | Weaviate host |
| `WEAVIATE_PORT` | `8080` | Weaviate HTTP port |
| `WEAVIATE_GRPC_PORT` | `50051` | Weaviate gRPC port |
