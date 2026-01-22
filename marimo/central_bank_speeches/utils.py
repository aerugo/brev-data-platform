"""Utility functions for Central Bank Speeches dashboard."""

import io
import os
from typing import Any

import polars as pl
import requests
import weaviate
from weaviate.classes.query import MetadataQuery

# Weaviate connection settings
WEAVIATE_HOST = os.getenv("WEAVIATE_HOST", "weaviate.weaviate.svc.cluster.local")
WEAVIATE_PORT = int(os.getenv("WEAVIATE_PORT", "8080"))
WEAVIATE_GRPC_PORT = int(os.getenv("WEAVIATE_GRPC_PORT", "50051"))

# NIM Embedding settings
NIM_EMBEDDING_ENDPOINT = os.getenv(
    "NIM_EMBEDDING_ENDPOINT",
    "http://nvidia-nim-embedding.nvidia-nim.svc.cluster.local:8000",
)
EMBEDDING_MODEL = "nvidia/llama-3_2-nemoretriever-300m-embed-v2"

# LakeFS settings
LAKEFS_ENDPOINT = os.getenv("LAKEFS_ENDPOINT", "http://lakefs.lakefs.svc.cluster.local:8000")
LAKEFS_ACCESS_KEY = os.getenv("LAKEFS_ACCESS_KEY_ID", "")
LAKEFS_SECRET_KEY = os.getenv("LAKEFS_SECRET_ACCESS_KEY", "")


def get_weaviate_client() -> weaviate.WeaviateClient:
    """Get a connected Weaviate client."""
    return weaviate.connect_to_custom(
        http_host=WEAVIATE_HOST,
        http_port=WEAVIATE_PORT,
        http_secure=False,
        grpc_host=WEAVIATE_HOST,
        grpc_port=WEAVIATE_GRPC_PORT,
        grpc_secure=False,
    )


def embed_query(query: str) -> list[float]:
    """Generate embedding for a search query using local NIM.

    Args:
        query: Search query text.

    Returns:
        1024-dimensional embedding vector.

    Raises:
        requests.RequestException: If NIM embedding service is unavailable.
    """
    payload = {
        "model": EMBEDDING_MODEL,
        "input": [query],
        "input_type": "query",  # Use "query" type for search queries
        "encoding_format": "float",
    }

    response = requests.post(
        f"{NIM_EMBEDDING_ENDPOINT}/v1/embeddings",
        json=payload,
        timeout=30,
    )
    response.raise_for_status()

    return response.json()["data"][0]["embedding"]


def vector_search(
    query: str,
    collection: str = "CentralBankSpeeches",
    limit: int = 10,
) -> list[dict[str, Any]]:
    """Perform vector similarity search on speeches.

    Args:
        query: Search query text.
        collection: Weaviate collection name.
        limit: Maximum results to return.

    Returns:
        List of matching speeches with similarity scores.
    """
    # Generate query embedding
    query_vector = embed_query(query)

    # Search in Weaviate
    client = get_weaviate_client()
    try:
        coll = client.collections.get(collection)

        results = coll.query.near_vector(
            near_vector=query_vector,
            limit=limit,
            return_metadata=MetadataQuery(distance=True, certainty=True),
        )

        output = []
        for obj in results.objects:
            item = dict(obj.properties)
            item["_distance"] = obj.metadata.distance
            item["_certainty"] = obj.metadata.certainty
            # Convert distance to similarity (cosine distance: 0 = identical)
            item["_similarity"] = 1 - (obj.metadata.distance or 0)
            output.append(item)

        return output
    finally:
        client.close()


def get_collection_stats(collection: str) -> dict[str, Any]:
    """Get statistics about a Weaviate collection.

    Args:
        collection: Weaviate collection name.

    Returns:
        Dictionary with exists and count fields.
    """
    client = get_weaviate_client()
    try:
        if not client.collections.exists(collection):
            return {"exists": False, "count": 0}

        coll = client.collections.get(collection)
        response = coll.aggregate.over_all(total_count=True)

        return {
            "exists": True,
            "count": response.total_count or 0,
        }
    finally:
        client.close()


def load_data_product(use_synthetic: bool = False) -> pl.DataFrame:
    """Load the central bank speeches data product from LakeFS.

    Args:
        use_synthetic: If True, load synthetic data instead of real.

    Returns:
        Polars DataFrame with speech data.

    Raises:
        Exception: If data product cannot be loaded.
    """
    import lakefs_sdk
    from lakefs_sdk.client import LakeFSClient

    configuration = lakefs_sdk.Configuration(
        host=LAKEFS_ENDPOINT,
        username=LAKEFS_ACCESS_KEY,
        password=LAKEFS_SECRET_KEY,
    )

    client = LakeFSClient(configuration)

    # Determine path based on data source
    if use_synthetic:
        path = "central-bank-speeches/synthetic/speeches.parquet"
    else:
        path = "central-bank-speeches/speeches.parquet"

    # Download file from LakeFS
    response = client.objects_api.get_object(
        repository="data",
        ref="main",
        path=path,
    )

    return pl.read_parquet(io.BytesIO(response.read()))


def get_sample_queries() -> list[str]:
    """Return sample queries for the dashboard."""
    return [
        "inflation expectations and monetary policy",
        "trade tensions and tariffs impact",
        "interest rate decisions",
        "quantitative easing programs",
        "financial stability risks",
        "cryptocurrency and digital currencies",
        "climate change economic impact",
        "labor market conditions",
        "supply chain disruptions",
        "housing market trends",
    ]


def check_services() -> dict[str, bool]:
    """Check availability of required services.

    Returns:
        Dictionary with service status (weaviate, nim_embedding, lakefs).
    """
    status = {}

    # Check Weaviate
    try:
        client = get_weaviate_client()
        client.is_ready()
        status["weaviate"] = True
        client.close()
    except Exception:
        status["weaviate"] = False

    # Check NIM Embedding
    try:
        response = requests.get(f"{NIM_EMBEDDING_ENDPOINT}/v1/health/ready", timeout=5)
        status["nim_embedding"] = response.status_code == 200
    except Exception:
        status["nim_embedding"] = False

    # Check LakeFS
    try:
        response = requests.get(f"{LAKEFS_ENDPOINT}/api/v1/healthcheck", timeout=5)
        status["lakefs"] = response.status_code == 204 or response.status_code == 200
    except Exception:
        status["lakefs"] = False

    return status
