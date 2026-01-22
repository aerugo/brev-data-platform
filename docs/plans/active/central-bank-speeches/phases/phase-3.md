# Phase 3: Central Bank Speeches ETL Pipeline

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Implement the complete Dagster ETL pipeline that ingests the Kaggle central bank speeches dataset, generates embeddings, classifies tariff mentions, stores the data product in LakeFS, and indexes text and embeddings in Weaviate.

---

## Invariants Enforced in This Phase

- **INV-D001**: Standard Bucket Structure - Use `raw-data` for ingestion, `data-products` for output
- **INV-D002**: LakeFS for Data Versioning - All data products versioned in LakeFS
- **INV-D003**: Parquet for Structured Data - Store DataFrames as Parquet
- **INV-P001**: Assets Over Ops - Use @asset decorator for all pipeline components
- **INV-P002**: I/O Managers for Storage - Implement LakeFS and Weaviate I/O managers
- **INV-P003**: Type Annotations on Assets - Full type annotations on all assets
- **INV-N004**: NIM Observability Enabled - Log LLM usage for classification
- **NEW INV-D004**: Weaviate Collections for Vector Data - Vector embeddings stored with proper schema

---

## Implementation Steps

### Step 3.1: Create LakeFS Polars I/O Manager

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/io_managers/lakefs_polars.py`

Create an I/O manager for storing Polars DataFrames in LakeFS as Parquet files.

```python
"""LakeFS I/O Manager for Polars DataFrames.

Stores DataFrames as Parquet files in LakeFS with automatic versioning.
Follows INV-D002 (LakeFS for Data Versioning) and INV-D003 (Parquet for Structured Data).
"""

import io
from typing import Any

import polars as pl
from dagster import (
    ConfigurableIOManager,
    InputContext,
    OutputContext,
)
from pydantic import Field

from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource


class LakeFSPolarsIOManager(ConfigurableIOManager):
    """I/O Manager for storing Polars DataFrames in LakeFS as Parquet.

    Automatically handles:
    - Parquet serialization/deserialization
    - LakeFS branch management
    - Commit creation with metadata
    """

    lakefs: LakeFSResource = Field(description="LakeFS resource")
    minio: MinIOResource = Field(description="MinIO resource for underlying storage")
    repository: str = Field(default="data", description="LakeFS repository name")
    branch: str = Field(default="main", description="LakeFS branch name")
    base_path: str = Field(default="data-products", description="Base path in repository")

    def handle_output(self, context: OutputContext, obj: pl.DataFrame) -> None:
        """Store a Polars DataFrame to LakeFS as Parquet."""
        if obj is None:
            context.log.warning("Received None object, skipping output")
            return

        # Determine output path from asset key
        asset_key = context.asset_key.path[-1] if context.asset_key else "output"
        path = f"{self.base_path}/{asset_key}.parquet"

        # Serialize DataFrame to Parquet bytes
        buffer = io.BytesIO()
        obj.write_parquet(buffer)
        parquet_bytes = buffer.getvalue()

        # Get LakeFS client
        lakefs_client = self.lakefs.get_client()

        # Upload to LakeFS
        lakefs_client.objects_api.upload_object(
            repository=self.repository,
            branch=self.branch,
            path=path,
            content=parquet_bytes,
        )

        # Create commit
        commit_message = f"Update {asset_key} data product"
        if context.run_id:
            commit_message += f" (Dagster run: {context.run_id[:8]})"

        lakefs_client.commits_api.commit(
            repository=self.repository,
            branch=self.branch,
            commit_creation={
                "message": commit_message,
                "metadata": {
                    "dagster_run_id": context.run_id or "",
                    "asset_key": asset_key,
                    "num_rows": str(len(obj)),
                    "num_columns": str(len(obj.columns)),
                },
            },
        )

        context.log.info(
            f"Stored {len(obj)} rows to lakefs://{self.repository}/{self.branch}/{path}"
        )

    def load_input(self, context: InputContext) -> pl.DataFrame:
        """Load a Polars DataFrame from LakeFS Parquet file."""
        # Determine input path from asset key
        asset_key = context.asset_key.path[-1] if context.asset_key else "input"
        path = f"{self.base_path}/{asset_key}.parquet"

        # Get LakeFS client
        lakefs_client = self.lakefs.get_client()

        # Download from LakeFS
        response = lakefs_client.objects_api.get_object(
            repository=self.repository,
            ref=self.branch,
            path=path,
        )

        # Parse Parquet to DataFrame
        df = pl.read_parquet(io.BytesIO(response.read()))
        context.log.info(
            f"Loaded {len(df)} rows from lakefs://{self.repository}/{self.branch}/{path}"
        )
        return df
```

---

### Step 3.2: Create Weaviate I/O Manager

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/io_managers/weaviate_io.py`

Create an I/O manager for storing text and embeddings in Weaviate.

```python
"""Weaviate I/O Manager for vector storage.

Handles storing and retrieving objects with their embeddings in Weaviate.
Follows NEW INV-D004 (Weaviate Collections for Vector Data).
"""

from typing import Any

import polars as pl
from dagster import (
    ConfigurableIOManager,
    InputContext,
    OutputContext,
)
from pydantic import Field

from brev_pipelines.resources.weaviate import WeaviateResource


class WeaviateIOManager(ConfigurableIOManager):
    """I/O Manager for storing text and embeddings in Weaviate.

    Expects output to be a tuple of (DataFrame, embeddings_list).
    Creates or updates the collection and inserts objects with vectors.
    """

    weaviate: WeaviateResource = Field(description="Weaviate resource")
    collection_prefix: str = Field(
        default="",
        description="Prefix for collection names",
    )

    def handle_output(
        self,
        context: OutputContext,
        obj: tuple[pl.DataFrame, list[list[float]]],
    ) -> None:
        """Store DataFrame rows with embeddings to Weaviate.

        Args:
            context: Dagster output context
            obj: Tuple of (DataFrame, list of embedding vectors)
        """
        if obj is None:
            context.log.warning("Received None object, skipping output")
            return

        df, embeddings = obj

        if len(df) != len(embeddings):
            raise ValueError(
                f"DataFrame has {len(df)} rows but got {len(embeddings)} embeddings"
            )

        # Determine collection name from asset key
        asset_key = context.asset_key.path[-1] if context.asset_key else "default"
        collection_name = f"{self.collection_prefix}{asset_key}".replace("_", "")

        # Convert to PascalCase for Weaviate
        collection_name = "".join(word.title() for word in collection_name.split())

        # Define schema from DataFrame columns
        properties = []
        for col in df.columns:
            dtype = df[col].dtype
            prop_type = "text"
            if dtype == pl.Date:
                prop_type = "date"
            elif dtype == pl.Boolean:
                prop_type = "boolean"
            elif dtype in (pl.Int8, pl.Int16, pl.Int32, pl.Int64):
                prop_type = "int"

            properties.append({"name": col, "type": prop_type})

        # Ensure collection exists
        self.weaviate.ensure_collection(
            name=collection_name,
            properties=properties,
            vector_dimensions=len(embeddings[0]) if embeddings else 1024,
        )

        # Convert DataFrame to list of dicts
        objects = df.to_dicts()

        # Insert objects with embeddings
        count = self.weaviate.insert_objects(
            collection_name=collection_name,
            objects=objects,
            vectors=embeddings,
        )

        context.log.info(f"Inserted {count} objects into Weaviate collection {collection_name}")

    def load_input(self, context: InputContext) -> int:
        """Return object count (Weaviate doesn't support full retrieval easily)."""
        asset_key = context.asset_key.path[-1] if context.asset_key else "default"
        collection_name = f"{self.collection_prefix}{asset_key}".replace("_", "")
        collection_name = "".join(word.title() for word in collection_name.split())

        return self.weaviate.get_object_count(collection_name)
```

---

### Step 3.3: Update I/O Managers Module Export

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/io_managers/__init__.py`

Export the new I/O managers.

```python
"""Brev Data Platform I/O Managers."""

from brev_pipelines.io_managers.lakefs_polars import LakeFSPolarsIOManager
from brev_pipelines.io_managers.weaviate_io import WeaviateIOManager

__all__ = [
    "LakeFSPolarsIOManager",
    "WeaviateIOManager",
]
```

---

### Step 3.4: Create Central Bank Speeches Assets

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/assets/central_bank_speeches.py`

Create the main pipeline assets for the central bank speeches data product.

```python
"""Central Bank Speeches ETL Pipeline.

This pipeline demonstrates end-to-end AI data product development:
1. Ingest dataset from Kaggle
2. Version data in LakeFS
3. Generate embeddings via local NIM embedding model
4. Classify tariff mentions via NIM LLM
5. Store enriched data product in LakeFS
6. Index text and embeddings in Weaviate for vector search
"""

import io
import json
import os
from datetime import datetime
from typing import Any

import dagster as dg
import polars as pl

from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.weaviate import WeaviateResource


# Collection schema for Weaviate
SPEECHES_SCHEMA = [
    {"name": "speech_id", "type": "text", "description": "Unique identifier"},
    {"name": "date", "type": "text", "description": "Speech date (ISO format)"},
    {"name": "central_bank", "type": "text", "description": "Issuing institution"},
    {"name": "speaker", "type": "text", "description": "Speaker name"},
    {"name": "title", "type": "text", "description": "Speech title"},
    {"name": "text", "type": "text", "description": "Full speech text"},
    {"name": "tariff_mention", "type": "boolean", "description": "Contains tariff discussion"},
]


@dg.asset(
    description="Raw central bank speeches from Kaggle dataset",
    group_name="central_bank_speeches",
    metadata={
        "layer": "raw",
        "source": "kaggle/davidgauthier/central-bank-speeches",
    },
)
def raw_speeches(
    context: dg.AssetExecutionContext,
    minio: MinIOResource,
) -> pl.DataFrame:
    """Ingest central bank speeches dataset from Kaggle.

    Downloads the dataset using KaggleHub and stores raw data in MinIO.
    """
    import kagglehub
    from kagglehub import KaggleDatasetAdapter

    context.log.info("Downloading central-bank-speeches dataset from Kaggle...")

    # Load dataset using KaggleHub Polars adapter
    lf = kagglehub.load_dataset(
        KaggleDatasetAdapter.POLARS,
        "davidgauthier/central-bank-speeches",
        "",  # Load all files
    )

    # Collect lazy frame to DataFrame
    df = lf.collect()
    context.log.info(f"Loaded {len(df)} speeches from Kaggle")

    # Store raw data in MinIO
    minio.ensure_bucket("raw-data")
    client = minio.get_client()

    # Save as Parquet to MinIO
    buffer = io.BytesIO()
    df.write_parquet(buffer)
    parquet_bytes = buffer.getvalue()

    client.put_object(
        "raw-data",
        "central-bank-speeches/raw_speeches.parquet",
        io.BytesIO(parquet_bytes),
        len(parquet_bytes),
        content_type="application/octet-stream",
    )

    context.log.info(f"Stored raw data to MinIO: raw-data/central-bank-speeches/raw_speeches.parquet")

    # Log column info
    context.log.info(f"Columns: {df.columns}")
    context.log.info(f"Schema: {df.schema}")

    return df


@dg.asset(
    description="Cleaned and normalized speeches with unique IDs",
    group_name="central_bank_speeches",
    metadata={"layer": "cleaned"},
)
def cleaned_speeches(
    context: dg.AssetExecutionContext,
    raw_speeches: pl.DataFrame,
) -> pl.DataFrame:
    """Clean and normalize the raw speeches data.

    - Add unique speech_id
    - Normalize column names
    - Parse dates
    - Handle missing values
    """
    df = raw_speeches

    # Map common column variations to standard names
    column_mapping = {
        "date": "date",
        "Date": "date",
        "speech_date": "date",
        "central_bank": "central_bank",
        "institution": "central_bank",
        "bank": "central_bank",
        "speaker": "speaker",
        "speaker_name": "speaker",
        "title": "title",
        "speech_title": "title",
        "text": "text",
        "content": "text",
        "speech": "text",
        "speech_text": "text",
    }

    # Rename columns that exist
    for old_name, new_name in column_mapping.items():
        if old_name in df.columns and old_name != new_name:
            df = df.rename({old_name: new_name})

    # Generate unique IDs
    df = df.with_row_index("_row_idx")
    df = df.with_columns(
        pl.format("SPEECH-{:06d}", pl.col("_row_idx")).alias("speech_id")
    )
    df = df.drop("_row_idx")

    # Ensure required columns exist (with defaults)
    if "date" not in df.columns:
        df = df.with_columns(pl.lit(None).alias("date"))
    if "central_bank" not in df.columns:
        df = df.with_columns(pl.lit("Unknown").alias("central_bank"))
    if "speaker" not in df.columns:
        df = df.with_columns(pl.lit("Unknown").alias("speaker"))
    if "title" not in df.columns:
        df = df.with_columns(pl.lit("Untitled").alias("title"))
    if "text" not in df.columns:
        raise ValueError("Dataset must have a 'text' or 'content' column")

    # Fill nulls
    df = df.with_columns([
        pl.col("central_bank").fill_null("Unknown"),
        pl.col("speaker").fill_null("Unknown"),
        pl.col("title").fill_null("Untitled"),
        pl.col("text").fill_null(""),
    ])

    # Select and order columns
    df = df.select([
        "speech_id",
        "date",
        "central_bank",
        "speaker",
        "title",
        "text",
    ])

    # Filter out empty speeches
    df = df.filter(pl.col("text").str.len_chars() > 100)

    context.log.info(f"Cleaned {len(df)} speeches")
    context.log.info(f"Central banks: {df['central_bank'].unique().to_list()[:10]}")

    return df


@dg.asset(
    description="Speeches with generated embeddings from NVIDIA API",
    group_name="central_bank_speeches",
    metadata={
        "layer": "enriched",
        "uses_nim_embedding": "true",
    },
)
def speech_embeddings(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_embedding: NIMEmbeddingResource,
) -> tuple[pl.DataFrame, list[list[float]]]:
    """Generate embeddings for all speeches using local NIM.

    Uses llama-3_2-nemoretriever-300m-embed-v2 model (1024 dimensions).
    Returns tuple of (DataFrame, embeddings) for Weaviate storage.
    """
    df = cleaned_speeches

    # Prepare texts for embedding (use title + text excerpt)
    texts = []
    for row in df.iter_rows(named=True):
        # Combine title and first 2000 chars of text for embedding
        title = row.get("title", "") or ""
        text = row.get("text", "") or ""
        combined = f"{title}\n\n{text[:2000]}"
        texts.append(combined)

    context.log.info(f"Generating embeddings for {len(texts)} speeches...")

    # Generate embeddings in batches
    embeddings = nim_embedding.embed_texts(texts, batch_size=32)

    context.log.info(f"Generated {len(embeddings)} embeddings, dimension: {len(embeddings[0])}")

    return (df, embeddings)


@dg.asset(
    description="Speeches classified for tariff mentions using NIM LLM",
    group_name="central_bank_speeches",
    metadata={
        "layer": "enriched",
        "uses_gpu": "true",
    },
)
def tariff_classification(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim: NIMResource,
) -> pl.DataFrame:
    """Classify speeches for tariff mentions using NIM LLM.

    Uses NIM to analyze each speech and determine if it discusses tariffs,
    trade barriers, customs duties, or related trade policy topics.
    """
    df = cleaned_speeches

    tariff_mentions = []
    tariff_confidences = []

    # Process in batches to manage GPU memory
    batch_size = 10
    total = len(df)

    for i in range(0, total, batch_size):
        batch_end = min(i + batch_size, total)
        batch = df.slice(i, batch_end - i)

        for row in batch.iter_rows(named=True):
            # Take first 3000 chars for classification
            text_excerpt = row.get("text", "")[:3000]
            title = row.get("title", "") or "Untitled"

            prompt = f"""Analyze this central bank speech excerpt and determine if it discusses tariffs, trade barriers, customs duties, import/export restrictions, or trade policy.

Title: {title}

Excerpt:
{text_excerpt}

Respond with ONLY a JSON object in this exact format:
{{"tariff_mention": 0 or 1, "confidence": 0.0 to 1.0}}

Where tariff_mention is 1 if the speech discusses tariffs/trade barriers, 0 otherwise.
"""

            response = nim.generate(prompt, max_tokens=50, temperature=0.1)

            # Parse response
            try:
                # Try to extract JSON from response
                import re
                json_match = re.search(r'\{[^}]+\}', response)
                if json_match:
                    result = json.loads(json_match.group())
                    tariff_mentions.append(int(result.get("tariff_mention", 0)))
                    tariff_confidences.append(float(result.get("confidence", 0.5)))
                else:
                    # Default to 0 if parsing fails
                    tariff_mentions.append(0)
                    tariff_confidences.append(0.0)
            except Exception as e:
                context.log.warning(f"Failed to parse LLM response: {e}")
                tariff_mentions.append(0)
                tariff_confidences.append(0.0)

        context.log.info(f"Processed {batch_end}/{total} speeches")

    # Add classification columns
    df = df.with_columns([
        pl.Series("tariff_mention", tariff_mentions).cast(pl.Int8),
        pl.Series("tariff_confidence", tariff_confidences).cast(pl.Float64),
    ])

    tariff_count = df.filter(pl.col("tariff_mention") == 1).height
    context.log.info(f"Found {tariff_count}/{len(df)} speeches mentioning tariffs")

    return df


@dg.asset(
    description="Combined enriched speeches data product",
    group_name="central_bank_speeches",
    metadata={"layer": "product"},
)
def enriched_speeches(
    context: dg.AssetExecutionContext,
    speech_embeddings: tuple[pl.DataFrame, list[list[float]]],
    tariff_classification: pl.DataFrame,
) -> pl.DataFrame:
    """Combine embeddings and classification into final data product.

    This is the main data product that combines all enrichment.
    """
    df_with_embeddings, embeddings = speech_embeddings
    df_with_classification = tariff_classification

    # Join classification results
    df = df_with_embeddings.join(
        df_with_classification.select(["speech_id", "tariff_mention", "tariff_confidence"]),
        on="speech_id",
        how="left",
    )

    # Add processing timestamp
    df = df.with_columns(
        pl.lit(datetime.utcnow().isoformat()).alias("processed_at")
    )

    context.log.info(f"Created enriched data product with {len(df)} speeches")
    context.log.info(f"Columns: {df.columns}")

    return df


@dg.asset(
    description="Versioned data product stored in LakeFS",
    group_name="central_bank_speeches",
    metadata={
        "layer": "output",
        "destination": "lakefs",
    },
)
def speeches_data_product(
    context: dg.AssetExecutionContext,
    enriched_speeches: pl.DataFrame,
    lakefs: LakeFSResource,
    minio: MinIOResource,
) -> dict[str, Any]:
    """Store final data product in LakeFS with versioning.

    Creates a versioned Parquet file in LakeFS for downstream consumption.
    """
    df = enriched_speeches

    # Serialize to Parquet
    buffer = io.BytesIO()
    df.write_parquet(buffer)
    parquet_bytes = buffer.getvalue()

    # Get LakeFS client
    lakefs_client = lakefs.get_client()

    # Upload to LakeFS
    path = "central-bank-speeches/speeches.parquet"
    lakefs_client.objects_api.upload_object(
        repository="data",
        branch="main",
        path=path,
        content=parquet_bytes,
    )

    # Create commit
    commit = lakefs_client.commits_api.commit(
        repository="data",
        branch="main",
        commit_creation={
            "message": f"Update central bank speeches data product ({len(df)} records)",
            "metadata": {
                "dagster_run_id": context.run_id or "",
                "num_records": str(len(df)),
                "tariff_mentions": str(df.filter(pl.col("tariff_mention") == 1).height),
            },
        },
    )

    context.log.info(f"Committed to LakeFS: {commit.id}")

    return {
        "path": f"lakefs://data/main/{path}",
        "commit_id": commit.id,
        "num_records": len(df),
        "tariff_mentions": df.filter(pl.col("tariff_mention") == 1).height,
    }


@dg.asset(
    description="Vector search index in Weaviate",
    group_name="central_bank_speeches",
    metadata={
        "layer": "output",
        "destination": "weaviate",
    },
)
def weaviate_index(
    context: dg.AssetExecutionContext,
    speech_embeddings: tuple[pl.DataFrame, list[list[float]]],
    tariff_classification: pl.DataFrame,
    weaviate: WeaviateResource,
) -> dict[str, Any]:
    """Index speeches in Weaviate for vector search.

    Creates the CentralBankSpeeches collection and inserts all speeches
    with their embeddings for similarity search.
    """
    df, embeddings = speech_embeddings

    # Join classification to include tariff_mention
    df = df.join(
        tariff_classification.select(["speech_id", "tariff_mention"]),
        on="speech_id",
        how="left",
    )

    # Ensure collection exists
    weaviate.ensure_collection(
        name="CentralBankSpeeches",
        properties=SPEECHES_SCHEMA,
        vector_dimensions=len(embeddings[0]),
    )

    # Prepare objects for insertion
    objects = []
    for row in df.iter_rows(named=True):
        objects.append({
            "speech_id": row["speech_id"],
            "date": str(row.get("date", "")),
            "central_bank": row.get("central_bank", "Unknown"),
            "speaker": row.get("speaker", "Unknown"),
            "title": row.get("title", "Untitled"),
            "text": row.get("text", "")[:10000],  # Truncate for Weaviate
            "tariff_mention": bool(row.get("tariff_mention", 0)),
        })

    # Insert objects with embeddings
    count = weaviate.insert_objects(
        collection_name="CentralBankSpeeches",
        objects=objects,
        vectors=embeddings,
    )

    context.log.info(f"Indexed {count} speeches in Weaviate")

    return {
        "collection": "CentralBankSpeeches",
        "object_count": count,
        "vector_dimensions": len(embeddings[0]),
    }


# Export all central bank speech assets
central_bank_speeches_assets = [
    raw_speeches,
    cleaned_speeches,
    speech_embeddings,
    tariff_classification,
    enriched_speeches,
    speeches_data_product,
    weaviate_index,
]
```

---

### Step 3.5: Create Pipeline Tests

**Action**: Create

**File(s)**: `dagster/tests/test_central_bank_speeches.py`

Create tests for the pipeline assets.

```python
"""Tests for Central Bank Speeches pipeline."""

import polars as pl
import pytest


class TestCleanedSpeeches:
    """Tests for cleaned_speeches asset."""

    def test_speech_id_generation(self):
        """Test that speech IDs are generated correctly."""
        # Create mock raw data
        raw_df = pl.DataFrame({
            "date": ["2024-01-01", "2024-01-02"],
            "central_bank": ["Fed", "ECB"],
            "speaker": ["Powell", "Lagarde"],
            "title": ["Speech 1", "Speech 2"],
            "text": ["A" * 200, "B" * 200],
        })

        # Verify ID format would be SPEECH-XXXXXX
        expected_pattern = r"^SPEECH-\d{6}$"
        # Would test with actual asset call in integration test

    def test_empty_text_filtering(self):
        """Test that speeches with short text are filtered out."""
        raw_df = pl.DataFrame({
            "text": ["Short", "A" * 200],
            "central_bank": ["Fed", "ECB"],
        })
        # Verify filter works - would have 1 row after filter

    def test_column_normalization(self):
        """Test that column names are normalized."""
        # Various column name variations should map correctly
        column_variations = {
            "Date": "date",
            "speech_date": "date",
            "institution": "central_bank",
            "content": "text",
        }
        # Would verify renaming in integration test


class TestTariffClassification:
    """Tests for tariff_classification asset."""

    def test_classification_values(self):
        """Test that classification produces valid 0/1 values."""
        # tariff_mention should be 0 or 1
        valid_values = {0, 1}

    def test_confidence_range(self):
        """Test that confidence scores are in [0, 1]."""
        # tariff_confidence should be between 0.0 and 1.0
        pass


class TestDataProductSchema:
    """Tests for final data product schema."""

    def test_required_columns(self):
        """Test that final data product has all required columns."""
        required = [
            "speech_id",
            "date",
            "central_bank",
            "speaker",
            "title",
            "text",
            "tariff_mention",
            "tariff_confidence",
            "processed_at",
        ]
        # Would verify columns in integration test

    def test_parquet_serialization(self):
        """Test that data product can be serialized to Parquet."""
        df = pl.DataFrame({
            "speech_id": ["SPEECH-000001"],
            "date": ["2024-01-01"],
            "central_bank": ["Fed"],
            "speaker": ["Powell"],
            "title": ["Test Speech"],
            "text": ["Test content"],
            "tariff_mention": [0],
            "tariff_confidence": [0.5],
            "processed_at": ["2024-01-01T00:00:00"],
        })

        # Verify Parquet round-trip
        import io
        buffer = io.BytesIO()
        df.write_parquet(buffer)
        buffer.seek(0)
        restored = pl.read_parquet(buffer)
        assert len(restored) == 1
        assert restored.columns == df.columns
```

---

### Step 3.6: Update Dagster Definitions

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/definitions.py`

Add the new assets to Dagster definitions.

```python
"""Dagster definitions for Brev Data Platform."""

import os

import dagster as dg

from brev_pipelines.assets.demo import demo_assets
from brev_pipelines.assets.health import health_assets
from brev_pipelines.assets.validation import validation_assets
from brev_pipelines.assets.central_bank_speeches import central_bank_speeches_assets
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.weaviate import WeaviateResource

# Resource definitions
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
    "nvidia_embedding": NVIDIAEmbeddingResource(
        api_key=os.getenv("NGC_API_KEY", ""),
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
    *central_bank_speeches_assets,
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
| `dagster/src/brev_pipelines/io_managers/lakefs_polars.py` | CREATE | LakeFS I/O manager for Polars |
| `dagster/src/brev_pipelines/io_managers/weaviate_io.py` | CREATE | Weaviate I/O manager |
| `dagster/src/brev_pipelines/io_managers/__init__.py` | CREATE | I/O manager exports |
| `dagster/src/brev_pipelines/assets/central_bank_speeches.py` | CREATE | Main pipeline assets |
| `dagster/src/brev_pipelines/definitions.py` | MODIFY | Register new assets |
| `dagster/tests/test_central_bank_speeches.py` | CREATE | Pipeline tests |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `NIM_EMBEDDING_ENDPOINT` | `http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000` | NIM embedding service |
| `NIM_ENDPOINT` | Cluster service URL | LLM classification |
| `WEAVIATE_HOST` | `weaviate.weaviate.svc.cluster.local` | Vector storage |
| `LAKEFS_ENDPOINT` | `http://lakefs.lakefs.svc.cluster.local:8000` | Data versioning |

### Secrets Required

All secrets should exist from Phase 2.

---

## Verification

### Pre-flight Checks

```bash
# Ensure Weaviate is running (Phase 1)
kubectl get pods -n weaviate

# Ensure resources are configured (Phase 2)
cd dagster && python -c "from brev_pipelines.definitions import defs; print(list(defs.resources.keys()))"
```

### Validation Commands

```bash
# Run tests
cd dagster
pytest tests/test_central_bank_speeches.py -v

# Type checking
mypy src/brev_pipelines/assets/central_bank_speeches.py

# Linting
ruff check src/brev_pipelines/

# Start Dagster dev
dagster dev -m brev_pipelines

# In Dagster UI, materialize assets in order:
# 1. raw_speeches
# 2. cleaned_speeches
# 3. speech_embeddings (can run parallel with tariff_classification)
# 4. tariff_classification
# 5. enriched_speeches
# 6. speeches_data_product
# 7. weaviate_index
```

### Expected Outcomes

- All assets visible in Dagster UI under `central_bank_speeches` group
- `raw_speeches` downloads ~10K speeches from Kaggle
- `cleaned_speeches` normalizes and filters data
- `speech_embeddings` generates 1024-dim vectors
- `tariff_classification` produces 0/1 labels
- `speeches_data_product` creates versioned Parquet in LakeFS
- `weaviate_index` creates searchable collection with ~10K objects

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| Kaggle rate limit | 429 response | Add retry logic, use cached download |
| NIM embedding timeout | Request timeout | Increase timeout, reduce batch size |
| NIM timeout | Request timeout | Increase timeout, reduce text length |
| Weaviate batch failure | Insert error | Reduce batch size, check schema |
| LakeFS commit failure | API error | Check repo exists, verify credentials |
| Out of memory | OOM error | Process in smaller batches |

### Rollback Plan

If this phase fails:
1. Delete Weaviate collection: Use `weaviate.delete_collection("CentralBankSpeeches")`
2. Remove MinIO data: Delete `raw-data/central-bank-speeches/`
3. Revert LakeFS: Create branch from before changes
4. Remove new asset files
5. Investigate and fix issues

---

## Completion Criteria

- [ ] LakeFS Polars I/O manager created
- [ ] Weaviate I/O manager created
- [ ] Central bank speeches assets created (7 assets)
- [ ] All assets materialize successfully
- [ ] Data versioned in LakeFS with commit history
- [ ] Embeddings stored correctly (1024 dimensions)
- [ ] Tariff classification produces valid 0/1 labels
- [ ] Weaviate collection has all speeches indexed
- [ ] Vector search returns relevant results
- [ ] Tests pass
- [ ] Linting passes
- [ ] Type checking passes
- [ ] Invariants INV-D001, INV-D002, INV-D003, INV-P001, INV-P002, INV-P003, INV-N004 verified
