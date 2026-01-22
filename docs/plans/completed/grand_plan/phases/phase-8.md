# Phase 8: Data Platform (Dagster + Marimo)

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Deploy Dagster for data pipeline orchestration and Marimo for interactive notebooks. Configure both to connect to MinIO and LakeFS from Phase 5.

---

## Invariants Enforced in This Phase

- **INV-K001**: Namespace per application - Dagster in `dagster`, Marimo in `marimo`
- **INV-K002**: Resource limits on all pods
- **INV-K005**: No `latest` image tags
- **INV-P001**: Assets over ops - Dagster pipeline uses `@asset` pattern
- **INV-P002**: I/O managers for storage - LakeFS I/O manager configured
- **INV-P003**: Type annotations on assets
- **NEW INV-K006**: Sync wave ordering - Platform (wave 2) after Storage (wave 1)

---

## Files to Create

### Dagster Helm Chart

#### k8s/apps/dagster/Chart.yaml

```yaml
apiVersion: v2
name: dagster
description: Dagster pipeline orchestration for brev-data-platform
type: application
version: 0.1.0
appVersion: "1.6.0"

dependencies:
  - name: dagster
    version: 1.6.0
    repository: https://dagster-io.github.io/helm
```

#### k8s/apps/dagster/values.yaml

```yaml
# Dagster default values

dagster:
  # Global settings
  global:
    serviceAccountName: dagster

  # PostgreSQL for run storage (embedded for dev)
  postgresql:
    enabled: true
    postgresqlUsername: dagster
    postgresqlPassword: dagster
    postgresqlDatabase: dagster
    persistence:
      enabled: true
      size: 10Gi
      storageClass: local-path  # Installed by RKE2 bootstrap script

  # Dagster webserver
  dagsterWebserver:
    replicaCount: 1
    image:
      repository: dagster/dagster-celery-k8s
      tag: 1.6.0
      pullPolicy: IfNotPresent
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi
    service:
      type: ClusterIP
      port: 3000

  # Dagster daemon
  dagsterDaemon:
    enabled: true
    image:
      repository: dagster/dagster-celery-k8s
      tag: 1.6.0
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi

  # User code deployments
  dagsterUserDeployments:
    enabled: true
    deployments:
      - name: brev-pipelines
        image:
          repository: ghcr.io/YOUR_ORG/brev-data-platform/dagster
          tag: latest  # Will be updated by CI
          pullPolicy: Always
        dagsterApiGrpcArgs:
          - "--python-file"
          - "/opt/dagster/app/definitions.py"
        port: 3030
        envSecrets:
          - name: dagster-env-secrets
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: 2000m
            memory: 4Gi

  # Run launcher config
  runLauncher:
    type: K8sRunLauncher
    config:
      k8sRunLauncher:
        envSecrets:
          - name: dagster-env-secrets

  # No ingress
  ingress:
    enabled: false
```

#### k8s/apps/dagster/values-dev.yaml

```yaml
# Dev environment overrides

dagster:
  postgresql:
    persistence:
      size: 5Gi

  dagsterWebserver:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1Gi

  dagsterDaemon:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 1Gi

  dagsterUserDeployments:
    deployments:
      - name: brev-pipelines
        image:
          repository: ghcr.io/YOUR_ORG/brev-data-platform/dagster
          tag: dev
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 1000m
            memory: 2Gi
```

### Dagster Pipeline Code

#### dagster/Dockerfile

```dockerfile
FROM python:3.11-slim

WORKDIR /opt/dagster/app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Expose gRPC port
EXPOSE 3030

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import dagster; print('ok')"
```

#### dagster/requirements.txt

```
dagster==1.6.0
dagster-postgres==0.22.0
dagster-k8s==0.22.0
pandas>=2.0.0
pyarrow>=14.0.0
boto3>=1.34.0
requests>=2.31.0
lakefs-sdk>=0.6.0
```

#### dagster/definitions.py

```python
"""Dagster definitions for brev-data-platform."""

from dagster import Definitions, EnvVar

from assets.ingestion import raw_data_assets
from assets.transformation import transformed_data_assets
from io_managers.lakefs_io_manager import lakefs_parquet_io_manager
from resources.lakefs import LakeFSResource
from resources.minio import MinIOResource

defs = Definitions(
    assets=[
        *raw_data_assets,
        *transformed_data_assets,
    ],
    resources={
        "lakefs": LakeFSResource(
            endpoint=EnvVar("LAKEFS_ENDPOINT"),
            access_key_id=EnvVar("LAKEFS_ACCESS_KEY_ID"),
            secret_access_key=EnvVar("LAKEFS_SECRET_ACCESS_KEY"),
        ),
        "minio": MinIOResource(
            endpoint=EnvVar("MINIO_ENDPOINT"),
            access_key=EnvVar("MINIO_ACCESS_KEY"),
            secret_key=EnvVar("MINIO_SECRET_KEY"),
        ),
        "lakefs_parquet_io_manager": lakefs_parquet_io_manager.configured({
            "repository": "main-repo",
            "branch": "main",
        }),
    },
)
```

#### dagster/assets/__init__.py

```python
"""Dagster assets package."""
```

#### dagster/assets/ingestion.py

```python
"""Data ingestion assets."""

from dagster import asset, AssetExecutionContext
import pandas as pd

@asset(
    description="Sample raw data for testing",
    group_name="ingestion",
    io_manager_key="lakefs_parquet_io_manager",
)
def sample_raw_data(context: AssetExecutionContext) -> pd.DataFrame:
    """Generate sample raw data for testing the pipeline."""
    context.log.info("Generating sample raw data")

    df = pd.DataFrame({
        "id": range(1, 101),
        "name": [f"Item {i}" for i in range(1, 101)],
        "value": [i * 10.5 for i in range(1, 101)],
        "category": ["A", "B", "C", "D"] * 25,
    })

    context.log.info(f"Generated {len(df)} rows of sample data")
    return df

raw_data_assets = [sample_raw_data]
```

#### dagster/assets/transformation.py

```python
"""Data transformation assets."""

from dagster import asset, AssetExecutionContext
import pandas as pd

@asset(
    description="Transformed and enriched data",
    group_name="transformation",
    io_manager_key="lakefs_parquet_io_manager",
    deps=["sample_raw_data"],
)
def transformed_data(
    context: AssetExecutionContext,
    sample_raw_data: pd.DataFrame,
) -> pd.DataFrame:
    """Transform raw data with aggregations."""
    context.log.info(f"Transforming {len(sample_raw_data)} rows")

    # Add computed columns
    df = sample_raw_data.copy()
    df["value_normalized"] = df["value"] / df["value"].max()
    df["category_count"] = df.groupby("category")["id"].transform("count")

    context.log.info(f"Transformation complete: {len(df)} rows")
    return df

transformed_data_assets = [transformed_data]
```

#### dagster/resources/__init__.py

```python
"""Dagster resources package."""
```

#### dagster/resources/lakefs.py

```python
"""LakeFS resource for Dagster."""

from dagster import ConfigurableResource
import lakefs_sdk
from lakefs_sdk.client import LakeFSClient

class LakeFSResource(ConfigurableResource):
    """Resource for interacting with LakeFS."""

    endpoint: str
    access_key_id: str
    secret_access_key: str

    def get_client(self) -> LakeFSClient:
        """Get configured LakeFS client."""
        configuration = lakefs_sdk.Configuration(
            host=self.endpoint,
            username=self.access_key_id,
            password=self.secret_access_key,
        )
        return LakeFSClient(configuration)
```

#### dagster/resources/minio.py

```python
"""MinIO resource for Dagster."""

from dagster import ConfigurableResource
import boto3

class MinIOResource(ConfigurableResource):
    """Resource for interacting with MinIO."""

    endpoint: str
    access_key: str
    secret_key: str

    def get_client(self):
        """Get configured S3 client for MinIO."""
        return boto3.client(
            "s3",
            endpoint_url=f"http://{self.endpoint}",
            aws_access_key_id=self.access_key,
            aws_secret_access_key=self.secret_key,
        )
```

#### dagster/io_managers/__init__.py

```python
"""Dagster I/O managers package."""
```

#### dagster/io_managers/lakefs_io_manager.py

```python
"""LakeFS Parquet I/O Manager for Dagster."""

from dagster import IOManager, InputContext, OutputContext, io_manager
import pandas as pd
import io

class LakeFSParquetIOManager(IOManager):
    """I/O Manager that stores DataFrames as Parquet in LakeFS."""

    def __init__(self, lakefs_resource, repository: str, branch: str):
        self.lakefs = lakefs_resource
        self.repository = repository
        self.branch = branch

    def _get_path(self, context) -> str:
        """Generate storage path from asset key."""
        return f"assets/{'/'.join(context.asset_key.path)}.parquet"

    def handle_output(self, context: OutputContext, obj: pd.DataFrame) -> None:
        """Write DataFrame to LakeFS as Parquet."""
        if obj is None:
            return

        path = self._get_path(context)
        client = self.lakefs.get_client()

        # Write to buffer
        buffer = io.BytesIO()
        obj.to_parquet(buffer, index=False)
        buffer.seek(0)

        # Upload to LakeFS
        client.objects_api.upload_object(
            repository=self.repository,
            branch=self.branch,
            path=path,
            content=buffer.read(),
        )

        context.log.info(f"Wrote {len(obj)} rows to lakefs://{self.repository}/{self.branch}/{path}")

    def load_input(self, context: InputContext) -> pd.DataFrame:
        """Load DataFrame from LakeFS Parquet file."""
        path = self._get_path(context)
        client = self.lakefs.get_client()

        # Download from LakeFS
        response = client.objects_api.get_object(
            repository=self.repository,
            ref=self.branch,
            path=path,
        )

        return pd.read_parquet(io.BytesIO(response))

@io_manager(config_schema={"repository": str, "branch": str}, required_resource_keys={"lakefs"})
def lakefs_parquet_io_manager(context):
    """Factory for LakeFS Parquet I/O Manager."""
    return LakeFSParquetIOManager(
        lakefs_resource=context.resources.lakefs,
        repository=context.resource_config["repository"],
        branch=context.resource_config["branch"],
    )
```

### Marimo

#### k8s/apps/marimo/Chart.yaml

```yaml
apiVersion: v2
name: marimo
description: Marimo interactive notebooks for brev-data-platform
type: application
version: 0.1.0
appVersion: "0.3.0"
```

#### k8s/apps/marimo/values.yaml

```yaml
# Marimo default values

image:
  repository: marimo-team/marimo
  tag: "0.3.0"
  pullPolicy: IfNotPresent

replicaCount: 1

resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi

service:
  type: ClusterIP
  port: 2718

# Environment variables for data access
env:
  - name: MINIO_ENDPOINT
    valueFrom:
      secretKeyRef:
        name: marimo-env-secrets
        key: MINIO_ENDPOINT
  - name: LAKEFS_ENDPOINT
    valueFrom:
      secretKeyRef:
        name: marimo-env-secrets
        key: LAKEFS_ENDPOINT

# Mount notebooks from ConfigMap or PVC
persistence:
  enabled: true
  size: 5Gi
  storageClass: local-path
```

#### k8s/apps/marimo/templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: marimo
  labels:
    app: marimo
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: marimo
  template:
    metadata:
      labels:
        app: marimo
    spec:
      containers:
        - name: marimo
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command:
            - marimo
            - edit
            - --host=0.0.0.0
            - --port=2718
            - --no-token
            - /notebooks
          ports:
            - containerPort: 2718
              name: http
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          envFrom:
            - secretRef:
                name: marimo-env-secrets
          volumeMounts:
            - name: notebooks
              mountPath: /notebooks
      volumes:
        - name: notebooks
          persistentVolumeClaim:
            claimName: marimo-notebooks
```

#### k8s/apps/marimo/templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: marimo
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
  selector:
    app: marimo
```

---

## Step 6.1: Build and Push Dagster Image

```bash
# Build locally
make build-dagster

# Tag and push to GitHub Container Registry
docker tag brev-data-platform/dagster:latest ghcr.io/YOUR_ORG/brev-data-platform/dagster:dev
docker push ghcr.io/YOUR_ORG/brev-data-platform/dagster:dev
```

---

## Step 6.2: Apply Secrets

```bash
# Apply Dagster secrets
sops -d k8s/apps/dagster/secrets.enc.yaml | kubectl apply -f -

# Create Marimo secrets (similar to Dagster)
# ... (create marimo secrets.enc.yaml with same pattern)
sops -d k8s/apps/marimo/secrets.enc.yaml | kubectl apply -f -
```

---

## Step 6.3: Deploy via ArgoCD

Push and let ArgoCD sync, or manually deploy:

```bash
# Update Helm dependencies
cd k8s/apps/dagster && helm dependency update && cd ../../..

# Deploy Dagster
helm upgrade --install dagster k8s/apps/dagster \
  -n dagster \
  -f k8s/apps/dagster/values.yaml \
  -f k8s/apps/dagster/values-dev.yaml

# Deploy Marimo
helm upgrade --install marimo k8s/apps/marimo \
  -n marimo \
  -f k8s/apps/marimo/values.yaml
```

---

## Step 6.4: Verify Dagster

```bash
# Check pods
kubectl get pods -n dagster

# Port forward
make port-forward-dagster

# Access http://localhost:3000
```

In Dagster UI:
1. Navigate to Assets
2. Verify `sample_raw_data` and `transformed_data` assets are visible
3. Try materializing an asset

---

## Step 6.5: Verify Marimo

```bash
# Check pods
kubectl get pods -n marimo

# Port forward
make port-forward-marimo

# Access http://localhost:2718
```

---

## Completion Criteria

- [ ] Dagster image built and pushed
- [ ] Dagster webserver pod running
- [ ] Dagster daemon pod running
- [ ] Dagster user code deployment running
- [ ] Dagster UI accessible at http://localhost:3000
- [ ] Assets visible in Dagster UI
- [ ] Can materialize sample assets
- [ ] Marimo pod running
- [ ] Marimo UI accessible at http://localhost:2718
- [ ] Both applications show Synced in ArgoCD

---

## Next Phase

Once Dagster and Marimo are running, proceed to [Phase 9: NVIDIA AI Enterprise](phase-9.md).
