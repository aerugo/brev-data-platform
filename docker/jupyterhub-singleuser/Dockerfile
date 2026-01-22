# JupyterHub Singleuser with Marimo Extension
# For Brev Data Platform
#
# Build:
#   docker build -t ghcr.io/aerugo/brev-marimo-singleuser:latest .
#
# Push:
#   docker push ghcr.io/aerugo/brev-marimo-singleuser:latest

FROM quay.io/jupyterhub/k8s-singleuser-sample:4.3.2

LABEL maintainer="Brev Data Platform"
LABEL description="JupyterHub singleuser with Marimo and data science libraries"

USER root

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

USER jovyan

# Install Marimo and extension
RUN pip install --no-cache-dir \
    'marimo>=0.10.0' \
    jupyterlab-marimo

# Install data science libraries
RUN pip install --no-cache-dir \
    pandas \
    numpy \
    scipy \
    scikit-learn \
    matplotlib \
    seaborn \
    plotly \
    polars \
    pyarrow \
    duckdb \
    sqlalchemy \
    psycopg2-binary

# Install cloud/storage clients
RUN pip install --no-cache-dir \
    boto3 \
    s3fs \
    lakefs-client \
    requests \
    httpx

# Install ML libraries (CPU versions - GPU pods will have CUDA available)
RUN pip install --no-cache-dir \
    torch --index-url https://download.pytorch.org/whl/cpu \
    transformers \
    openai \
    anthropic

# Set working directory
WORKDIR /home/jovyan

# Expose JupyterHub singleuser port
EXPOSE 8888

# Default command (inherited from base image)
# CMD ["jupyterhub-singleuser"]
