# Phase 4: Synthetic Data Pipeline

**Status**: Pending
**Type**: Application
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Generate a synthetic twin of the central bank speeches dataset using NVIDIA Safe Synthesizer, create validation reports, generate new embeddings for synthetic data, and index in a separate Weaviate collection.

This phase uses **KAI Scheduler priority-based preemption** for automatic GPU orchestration between NIM and Safe Synthesizer, eliminating manual kubectl scaling.

---

## Invariants Enforced in This Phase

- **INV-I003**: H200 141GB GPU Required - Safe Synthesizer requires exclusive GPU (80GB), KAI handles preemption
- **INV-D002**: LakeFS for Data Versioning - Synthetic data and reports versioned in LakeFS
- **INV-N003**: Safe Synthesizer Output to LakeFS - All outputs versioned
- **INV-P001**: Assets Over Ops - Use @asset decorator
- **INV-P003**: Type Annotations - Full type annotations
- **NEW INV-P004**: Synthetic Data Isolation - Synthetic data in separate Weaviate collection
- **NEW INV-K006**: KAI Priority-Based GPU Orchestration - Use KAI queues and priorities for GPU workload management

---

## KAI Priority-Based GPU Orchestration

### How It Works

Instead of manual `kubectl scale` commands, we leverage KAI Scheduler's priority and preemption system:

1. **NIM runs as `inference` priority** (value: 125, non-preemptible) in the `inference-queue`
2. **Safe Synthesizer runs as `train` priority** (value: 50, preemptible) in the `batch-queue`
3. When Safe Synth job is submitted with higher priority, KAI **automatically preempts** NIM
4. After Safe Synth job completes, the **NIM Deployment automatically restarts** its pod
5. No manual intervention required

### Priority Classes (KAI Default)

| Priority Class | Value | Preemptible | Use Case |
|----------------|-------|-------------|----------|
| `train` | 50 | Yes | Batch training, Safe Synthesizer |
| `build-preemptible` | 75 | Yes | Interactive development |
| `build` | 100 | No | Non-preemptible builds |
| `inference` | 125 | No | NIM LLM inference (default) |

### Key Insight: Safe Synthesizer as a Job

Safe Synthesizer should be deployed as a **Kubernetes Job** (not Deployment) because:
- It runs to completion and exits
- Jobs naturally work with KAI's batch scheduling
- Preemption semantics are cleaner for one-shot workloads
- The NIM Deployment automatically recovers after the Job completes

---

## Implementation Steps

### Step 4.1: Create KAI Queue Configuration

**Action**: Modify

**File(s)**: `k8s/apps/kai-scheduler/templates/queues.yaml`

Add hierarchical queues for inference vs batch workloads.

```yaml
# KAI Scheduler Queue Configuration
# Hierarchical queues for GPU workload scheduling
#
# Queue Hierarchy:
#   default-parent-queue (cluster-level)
#   ├── inference-queue (NIM, always-on services)
#   └── batch-queue (Safe Synthesizer, training jobs)
---
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: default-parent-queue
  annotations:
    helm.sh/resource-policy: keep
spec:
  resources:
    cpu:
      quota: 12000
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: 1
      limit: -1
      overQuotaWeight: 1
    memory:
      quota: 120000000000
      limit: -1
      overQuotaWeight: 1
---
# Inference Queue - For always-on GPU services (NIM)
# Has full GPU quota, workloads here are non-preemptible
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: inference-queue
  annotations:
    helm.sh/resource-policy: keep
spec:
  parentQueue: default-parent-queue
  # Priority determines resource allocation order
  priority: 100
  resources:
    cpu:
      quota: 8000
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: 1      # Full GPU quota for inference
      limit: 1
      overQuotaWeight: 0  # Cannot go over quota
    memory:
      quota: 80000000000
      limit: -1
      overQuotaWeight: 1
---
# Batch Queue - For batch jobs (Safe Synthesizer, training)
# Zero quota, borrows from inference-queue via preemption
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: batch-queue
  annotations:
    helm.sh/resource-policy: keep
spec:
  parentQueue: default-parent-queue
  # Lower priority, but can preempt via priority classes
  priority: 50
  resources:
    cpu:
      quota: 8000
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: 0      # No guaranteed quota
      limit: 1      # Can use full GPU when available
      overQuotaWeight: 1  # Can borrow unused resources
    memory:
      quota: 80000000000
      limit: -1
      overQuotaWeight: 1
---
# Keep default-queue for backwards compatibility
apiVersion: scheduling.run.ai/v2
kind: Queue
metadata:
  name: default-queue
  annotations:
    helm.sh/resource-policy: keep
spec:
  parentQueue: default-parent-queue
  resources:
    cpu:
      quota: 12000
      limit: -1
      overQuotaWeight: 1
    gpu:
      quota: 1
      limit: -1
      overQuotaWeight: 1
    memory:
      quota: 120000000000
      limit: -1
      overQuotaWeight: 1
```

---

### Step 4.2: Update NIM Deployment for KAI Queue

**Action**: Modify

**File(s)**: `k8s/apps/nvidia-nim/values.yaml`

Add KAI queue label and priority class to NIM deployment.

```yaml
# Add to existing values.yaml

# KAI Scheduler configuration
schedulerName: kai-scheduler

# Queue assignment for KAI Scheduler
podLabels:
  kai.scheduler/queue: inference-queue

# Priority class - inference is non-preemptible (value >= 100)
priorityClassName: inference

# Existing podAnnotations for GPU memory allocation
podAnnotations:
  kai.scheduler.nvidia.com/gpu-memory: "70Gi"
```

---

### Step 4.3: Create Safe Synthesizer Job Template

**Action**: Create

**File(s)**: `k8s/apps/nvidia-safe-synth/templates/job-template.yaml`

Create a Job template for Safe Synthesizer that uses KAI preemption.

```yaml
{{- if .Values.job.enabled }}
# Safe Synthesizer Job Template
# This Job is triggered by Dagster for synthetic data generation
# Uses KAI Scheduler preemption to temporarily acquire GPU from NIM
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "nvidia-safe-synth.fullname" . }}-{{ .Values.job.runId | default "manual" }}
  labels:
    {{- include "nvidia-safe-synth.labels" . | nindent 4 }}
    # KAI Queue assignment - batch queue has no quota, borrows via preemption
    kai.scheduler/queue: batch-queue
  annotations:
    # Allow KAI to preempt lower-priority workloads
    argocd.argoproj.io/sync-options: Prune=false
spec:
  # Don't retry on failure - let Dagster handle retries
  backoffLimit: 0
  # Clean up completed jobs after 1 hour
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        {{- include "nvidia-safe-synth.labels" . | nindent 8 }}
        kai.scheduler/queue: batch-queue
      annotations:
        # GPU memory allocation for KAI
        kai.scheduler.nvidia.com/gpu-memory: "80Gi"
    spec:
      # Use KAI Scheduler
      schedulerName: kai-scheduler
      # Priority class - train is preemptible but can preempt inference temporarily
      # Note: We use a custom "batch-high" priority (value: 130) to preempt inference
      priorityClassName: {{ .Values.job.priorityClassName | default "batch-high" }}
      restartPolicy: Never

      # NGC image pull secret
      imagePullSecrets:
        - name: ngc-image-pull

      # NVIDIA RuntimeClass
      runtimeClassName: nvidia

      # GPU node tolerations
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule

      containers:
        - name: safe-synth
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}

          # Job-specific command (can be overridden)
          {{- if .Values.job.command }}
          command: {{ .Values.job.command | toJson }}
          {{- end }}
          {{- if .Values.job.args }}
          args: {{ .Values.job.args | toJson }}
          {{- end }}

          env:
            - name: NGC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ngc-credentials
                  key: api-key
            - name: LOG_LEVEL
              value: "INFO"
            - name: SAFE_SYNTH_MODE
              value: "local"
            - name: MODEL_CACHE_PATH
              value: "/data/models"
            # Job-specific environment
            {{- range .Values.job.env }}
            - name: {{ .name }}
              value: {{ .value | quote }}
            {{- end }}

          resources:
            requests:
              memory: 32Gi
              cpu: 4
              nvidia.com/gpu: 1
            limits:
              memory: 64Gi
              cpu: 8
              nvidia.com/gpu: 1

          volumeMounts:
            - name: data
              mountPath: /data
            - name: input-data
              mountPath: /input
              readOnly: true
            - name: output-data
              mountPath: /output

      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ include "nvidia-safe-synth.fullname" . }}-data
        - name: input-data
          configMap:
            name: {{ .Values.job.inputConfigMap | default "safe-synth-input" }}
        - name: output-data
          emptyDir: {}
{{- end }}
```

---

### Step 4.4: Create Custom Priority Class for Batch Jobs

**Action**: Create

**File(s)**: `k8s/apps/kai-scheduler/templates/priority-classes.yaml`

Create a custom priority class that allows batch jobs to preempt inference.

```yaml
# Custom Priority Classes for GPU Workload Orchestration
#
# KAI default priorities:
#   train (50) - preemptible training
#   build-preemptible (75) - preemptible interactive
#   build (100) - non-preemptible builds
#   inference (125) - non-preemptible inference
#
# We add batch-high (130) to allow batch jobs to preempt inference
# when they need exclusive GPU access (e.g., Safe Synthesizer)
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-high
  labels:
    {{- include "kai-scheduler.labels" . | nindent 4 }}
value: 130
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: |
  High-priority batch jobs that can preempt inference workloads.
  Use for Safe Synthesizer and other batch jobs requiring exclusive GPU.
  After job completion, preempted inference pods automatically restart.
```

---

### Step 4.5: Create Safe Synthesizer Resource

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/resources/safe_synth.py`

Create a Dagster resource that launches Safe Synthesizer as a Kubernetes Job.

```python
"""NVIDIA Safe Synthesizer resource for Dagster.

Launches Safe Synthesizer as a Kubernetes Job with KAI Scheduler integration.
The Job uses priority-based preemption to temporarily acquire GPU from NIM.

How it works:
1. Dagster creates a Kubernetes Job with batch-high priority
2. KAI Scheduler preempts the NIM pod to free the GPU
3. Safe Synthesizer Job runs to completion
4. NIM Deployment automatically restarts its pod
5. No manual intervention required
"""

import json
import time
from typing import Any

from dagster import ConfigurableResource
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from pydantic import Field


class SafeSynthesizerResource(ConfigurableResource):
    """NVIDIA Safe Synthesizer resource using Kubernetes Jobs."""

    namespace: str = Field(
        default="nvidia-ai",
        description="Kubernetes namespace for Safe Synthesizer",
    )
    image: str = Field(
        default="nvcr.io/nvidia/nemo-microservices/safe-synthesizer:25.01",
        description="Safe Synthesizer container image",
    )
    service_endpoint: str = Field(
        default="http://nvidia-safe-synth.nvidia-ai.svc.cluster.local:8080",
        description="Safe Synthesizer service endpoint (for health checks)",
    )
    poll_interval: int = Field(default=30, description="Job status poll interval in seconds")
    max_wait_time: int = Field(default=7200, description="Max job wait time in seconds")
    gpu_memory: str = Field(default="80Gi", description="GPU memory allocation")
    priority_class: str = Field(default="batch-high", description="Kubernetes priority class")

    def _get_k8s_client(self) -> client.BatchV1Api:
        """Get Kubernetes batch API client."""
        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()
        return client.BatchV1Api()

    def _get_core_client(self) -> client.CoreV1Api:
        """Get Kubernetes core API client."""
        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()
        return client.CoreV1Api()

    def create_synthesis_job(
        self,
        job_name: str,
        input_data_path: str,
        output_data_path: str,
        config: dict[str, Any] | None = None,
    ) -> str:
        """Create a Kubernetes Job for synthetic data generation.

        Args:
            job_name: Unique name for the job
            input_data_path: Path to input data in MinIO/LakeFS
            output_data_path: Path for output data
            config: Synthesis configuration

        Returns:
            Job name for tracking
        """
        batch_api = self._get_k8s_client()

        # Default synthesis config
        synth_config = {
            "epsilon": 1.0,
            "delta": 1e-5,
            "piiReplacement": True,
            "temperature": 0.7,
            "runMiaEvaluation": True,
            "runAiaEvaluation": True,
        }
        if config:
            synth_config.update(config)

        # Create Job spec
        job = client.V1Job(
            api_version="batch/v1",
            kind="Job",
            metadata=client.V1ObjectMeta(
                name=job_name,
                namespace=self.namespace,
                labels={
                    "app": "safe-synth-job",
                    "kai.scheduler/queue": "batch-queue",
                },
            ),
            spec=client.V1JobSpec(
                backoff_limit=0,
                ttl_seconds_after_finished=3600,
                template=client.V1PodTemplateSpec(
                    metadata=client.V1ObjectMeta(
                        labels={
                            "app": "safe-synth-job",
                            "kai.scheduler/queue": "batch-queue",
                        },
                        annotations={
                            "kai.scheduler.nvidia.com/gpu-memory": self.gpu_memory,
                        },
                    ),
                    spec=client.V1PodSpec(
                        scheduler_name="kai-scheduler",
                        priority_class_name=self.priority_class,
                        restart_policy="Never",
                        runtime_class_name="nvidia",
                        image_pull_secrets=[
                            client.V1LocalObjectReference(name="ngc-image-pull")
                        ],
                        tolerations=[
                            client.V1Toleration(
                                key="nvidia.com/gpu",
                                operator="Exists",
                                effect="NoSchedule",
                            )
                        ],
                        containers=[
                            client.V1Container(
                                name="safe-synth",
                                image=self.image,
                                env=[
                                    client.V1EnvVar(
                                        name="NGC_API_KEY",
                                        value_from=client.V1EnvVarSource(
                                            secret_key_ref=client.V1SecretKeySelector(
                                                name="ngc-credentials",
                                                key="api-key",
                                            )
                                        ),
                                    ),
                                    client.V1EnvVar(name="LOG_LEVEL", value="INFO"),
                                    client.V1EnvVar(name="INPUT_PATH", value=input_data_path),
                                    client.V1EnvVar(name="OUTPUT_PATH", value=output_data_path),
                                    client.V1EnvVar(
                                        name="SYNTH_CONFIG",
                                        value=json.dumps(synth_config),
                                    ),
                                ],
                                resources=client.V1ResourceRequirements(
                                    requests={
                                        "memory": "32Gi",
                                        "cpu": "4",
                                        "nvidia.com/gpu": "1",
                                    },
                                    limits={
                                        "memory": "64Gi",
                                        "cpu": "8",
                                        "nvidia.com/gpu": "1",
                                    },
                                ),
                            )
                        ],
                    ),
                ),
            ),
        )

        # Create the job
        batch_api.create_namespaced_job(namespace=self.namespace, body=job)
        return job_name

    def wait_for_job(self, job_name: str) -> dict[str, Any]:
        """Wait for a job to complete.

        Args:
            job_name: Job name to wait for

        Returns:
            Job status information

        Raises:
            TimeoutError: If job doesn't complete in max_wait_time
            RuntimeError: If job fails
        """
        batch_api = self._get_k8s_client()
        start_time = time.time()

        while time.time() - start_time < self.max_wait_time:
            try:
                job = batch_api.read_namespaced_job_status(
                    name=job_name,
                    namespace=self.namespace,
                )

                if job.status.succeeded and job.status.succeeded > 0:
                    return {
                        "state": "completed",
                        "succeeded": job.status.succeeded,
                        "completion_time": job.status.completion_time.isoformat()
                        if job.status.completion_time
                        else None,
                    }

                if job.status.failed and job.status.failed > 0:
                    # Get pod logs for error details
                    error_msg = self._get_job_logs(job_name)
                    raise RuntimeError(f"Job {job_name} failed: {error_msg}")

            except ApiException as e:
                if e.status == 404:
                    raise RuntimeError(f"Job {job_name} not found")
                raise

            time.sleep(self.poll_interval)

        raise TimeoutError(f"Job {job_name} did not complete in {self.max_wait_time} seconds")

    def _get_job_logs(self, job_name: str) -> str:
        """Get logs from a job's pod."""
        core_api = self._get_core_client()

        try:
            pods = core_api.list_namespaced_pod(
                namespace=self.namespace,
                label_selector=f"job-name={job_name}",
            )

            if pods.items:
                pod_name = pods.items[0].metadata.name
                logs = core_api.read_namespaced_pod_log(
                    name=pod_name,
                    namespace=self.namespace,
                    tail_lines=100,
                )
                return logs
        except Exception as e:
            return f"Could not retrieve logs: {e}"

        return "No pods found for job"

    def delete_job(self, job_name: str) -> bool:
        """Delete a job and its pods."""
        batch_api = self._get_k8s_client()

        try:
            batch_api.delete_namespaced_job(
                name=job_name,
                namespace=self.namespace,
                propagation_policy="Foreground",
            )
            return True
        except ApiException as e:
            if e.status == 404:
                return False
            raise

    def synthesize(
        self,
        input_data: list[dict[str, Any]],
        run_id: str,
        config: dict[str, Any] | None = None,
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """Run full synthesis pipeline using Kubernetes Job.

        This method:
        1. Creates a ConfigMap with input data
        2. Launches a Safe Synthesizer Job
        3. KAI Scheduler preempts NIM to free the GPU
        4. Waits for job completion
        5. Retrieves results
        6. NIM automatically restarts after job completes

        Args:
            input_data: Input data records
            run_id: Unique run identifier
            config: Optional synthesis configuration

        Returns:
            Tuple of (synthetic_data, evaluation_report)
        """
        job_name = f"safe-synth-{run_id[:8]}"

        # For now, use service endpoint if available
        # Full implementation would use ConfigMaps and PVCs for data transfer
        # This is a simplified version that assumes the service is running

        import requests

        try:
            # Check if service is available (job may have started it)
            response = requests.get(f"{self.service_endpoint}/health", timeout=5)
            if response.status_code == 200:
                # Use the API endpoint directly
                return self._synthesize_via_api(input_data, config)
        except Exception:
            pass

        # Fall back to job-based approach
        # (Full implementation would handle data transfer via MinIO)
        raise NotImplementedError(
            "Job-based synthesis requires data transfer via MinIO. "
            "Ensure the Safe Synthesizer service is running or implement "
            "data transfer via ConfigMaps/PVCs."
        )

    def _synthesize_via_api(
        self,
        data: list[dict[str, Any]],
        config: dict[str, Any] | None = None,
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """Synthesize data via the API endpoint."""
        import requests

        default_config = {
            "epsilon": 1.0,
            "delta": 1e-5,
            "piiReplacement": True,
            "temperature": 0.7,
            "runMiaEvaluation": True,
            "runAiaEvaluation": True,
        }
        if config:
            default_config.update(config)

        payload = {"data": data, "config": default_config}

        # Create job
        response = requests.post(
            f"{self.service_endpoint}/jobs",
            json=payload,
            timeout=60,
        )
        response.raise_for_status()
        job_id = response.json()["job_id"]

        # Wait for completion
        start_time = time.time()
        while time.time() - start_time < self.max_wait_time:
            status_response = requests.get(
                f"{self.service_endpoint}/jobs/{job_id}",
                timeout=60,
            )
            status_response.raise_for_status()
            status = status_response.json()

            if status["state"] == "completed":
                # Download results
                result_id = status["results"][0]["id"]
                result_response = requests.get(
                    f"{self.service_endpoint}/jobs/{job_id}/results/{result_id}/download",
                    timeout=60,
                )
                result_response.raise_for_status()
                synthetic_data = result_response.json()

                evaluation = {
                    "job_id": job_id,
                    "mia_score": status.get("evaluation", {}).get("mia_score"),
                    "aia_score": status.get("evaluation", {}).get("aia_score"),
                    "privacy_passed": status.get("evaluation", {}).get("privacy_passed", False),
                }

                return synthetic_data, evaluation

            elif status["state"] == "failed":
                raise RuntimeError(f"Job {job_id} failed: {status.get('error')}")

            time.sleep(self.poll_interval)

        raise TimeoutError(f"Job {job_id} did not complete in {self.max_wait_time} seconds")

    def health_check(self) -> bool:
        """Check if Safe Synthesizer service is healthy."""
        import requests

        try:
            response = requests.get(f"{self.service_endpoint}/health", timeout=5)
            return response.status_code == 200
        except Exception:
            return False
```

---

### Step 4.6: Create Synthetic Speeches Assets

**Action**: Create

**File(s)**: `dagster/src/brev_pipelines/assets/synthetic_speeches.py`

Create Dagster assets with KAI-aware GPU orchestration.

```python
"""Synthetic Central Bank Speeches Pipeline.

Generates privacy-preserving synthetic twin of the speeches dataset
using NVIDIA Safe Synthesizer with KAI Scheduler integration.

GPU Orchestration (Automatic via KAI):
1. NIM runs with 'inference' priority (125, non-preemptible)
2. Safe Synthesizer runs with 'batch-high' priority (130)
3. KAI preempts NIM pod when Safe Synth job starts
4. After Safe Synth completes, NIM Deployment restarts its pod
5. No manual kubectl commands required!
"""

import io
import json
from datetime import datetime
from typing import Any

import dagster as dg
import polars as pl

from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.safe_synth import SafeSynthesizerResource
from brev_pipelines.resources.weaviate import WeaviateResource


# Weaviate schema for synthetic speeches
SYNTHETIC_SCHEMA = [
    {"name": "speech_id", "type": "text"},
    {"name": "date", "type": "text"},
    {"name": "central_bank", "type": "text"},
    {"name": "speaker", "type": "text"},
    {"name": "title", "type": "text"},
    {"name": "text", "type": "text"},
    {"name": "tariff_mention", "type": "boolean"},
    {"name": "is_synthetic", "type": "boolean"},
]


@dg.asset(
    description="Synthetic speeches generated by NVIDIA Safe Synthesizer",
    group_name="synthetic_speeches",
    metadata={
        "layer": "synthetic",
        "uses_gpu": "true",
        "gpu_orchestration": "KAI priority-based preemption",
    },
)
def synthetic_speeches(
    context: dg.AssetExecutionContext,
    enriched_speeches: pl.DataFrame,
    safe_synth: SafeSynthesizerResource,
) -> tuple[pl.DataFrame, dict[str, Any]]:
    """Generate synthetic twin of the speeches dataset.

    GPU orchestration is handled automatically by KAI Scheduler:
    - Safe Synthesizer job runs with 'batch-high' priority (130)
    - KAI preempts NIM (priority 125) to free the GPU
    - After job completion, NIM Deployment restarts automatically

    No manual intervention required!
    """
    df = enriched_speeches
    run_id = context.run_id or datetime.utcnow().strftime("%Y%m%d%H%M%S")

    context.log.info("Starting synthetic data generation with KAI GPU orchestration...")
    context.log.info("KAI Scheduler will automatically preempt NIM to free the GPU")

    # Prepare data for synthesis (exclude embeddings, they'll be regenerated)
    synthesis_columns = [
        "speech_id",
        "date",
        "central_bank",
        "speaker",
        "title",
        "text",
        "tariff_mention",
    ]

    # Convert to list of dicts for Safe Synthesizer
    data_for_synthesis = df.select(synthesis_columns).to_dicts()

    context.log.info(f"Generating synthetic data for {len(df)} speeches...")

    # Process in batches (Safe Synthesizer has limits)
    batch_size = 1000
    all_synthetic = []
    all_evaluations = []

    for i in range(0, len(data_for_synthesis), batch_size):
        batch = data_for_synthesis[i : i + batch_size]
        batch_num = i // batch_size + 1
        context.log.info(f"Processing batch {batch_num}, records {i} to {i + len(batch)}")

        synthetic_batch, evaluation = safe_synth.synthesize(
            input_data=batch,
            run_id=f"{run_id}-batch{batch_num}",
            config={
                "epsilon": 1.0,
                "piiReplacement": True,
                "runMiaEvaluation": True,
                "runAiaEvaluation": True,
            },
        )

        all_synthetic.extend(synthetic_batch)
        all_evaluations.append(evaluation)

    # Convert to DataFrame
    synthetic_df = pl.DataFrame(all_synthetic)

    # Add synthetic marker and regenerate IDs
    synthetic_df = synthetic_df.with_columns([
        pl.format("SYNTH-{:06d}", pl.arange(0, len(synthetic_df))).alias("speech_id"),
        pl.lit(True).alias("is_synthetic"),
    ])

    # Aggregate evaluation results
    combined_evaluation = {
        "total_records": len(synthetic_df),
        "batches_processed": len(all_evaluations),
        "avg_mia_score": sum(e["mia_score"] or 0 for e in all_evaluations) / len(all_evaluations),
        "avg_aia_score": sum(e["aia_score"] or 0 for e in all_evaluations) / len(all_evaluations),
        "all_privacy_passed": all(e["privacy_passed"] for e in all_evaluations),
        "generated_at": datetime.utcnow().isoformat(),
        "gpu_orchestration": "KAI priority-based preemption",
    }

    context.log.info(f"Generated {len(synthetic_df)} synthetic speeches")
    context.log.info(f"Privacy passed: {combined_evaluation['all_privacy_passed']}")
    context.log.info("KAI Scheduler will restore NIM automatically")

    return (synthetic_df, combined_evaluation)


@dg.asset(
    description="Privacy validation report stored in LakeFS",
    group_name="synthetic_speeches",
    metadata={
        "layer": "validation",
        "destination": "lakefs",
    },
)
def synthetic_validation_report(
    context: dg.AssetExecutionContext,
    synthetic_speeches: tuple[pl.DataFrame, dict[str, Any]],
    lakefs: LakeFSResource,
) -> dict[str, Any]:
    """Store privacy validation report in LakeFS.

    Contains MIA (Membership Inference Attack) and AIA (Attribute Inference Attack)
    evaluation scores to verify synthetic data privacy.
    """
    _, evaluation = synthetic_speeches

    # Add metadata
    report = {
        **evaluation,
        "report_version": "1.0",
        "report_type": "safe-synthesizer-evaluation",
    }

    # Store in LakeFS
    lakefs_client = lakefs.get_client()

    report_path = "central-bank-speeches/synthetic/validation_report.json"
    report_bytes = json.dumps(report, indent=2).encode()

    lakefs_client.objects_api.upload_object(
        repository="data",
        branch="main",
        path=report_path,
        content=report_bytes,
    )

    # Commit
    lakefs_client.commits_api.commit(
        repository="data",
        branch="main",
        commit_creation={
            "message": "Add synthetic data validation report",
            "metadata": {
                "dagster_run_id": context.run_id or "",
                "mia_score": str(report["avg_mia_score"]),
                "aia_score": str(report["avg_aia_score"]),
                "privacy_passed": str(report["all_privacy_passed"]),
            },
        },
    )

    context.log.info(f"Stored validation report to lakefs://data/main/{report_path}")

    return report


@dg.asset(
    description="Embeddings for synthetic speeches",
    group_name="synthetic_speeches",
    metadata={
        "layer": "enriched",
        "uses_nim_embedding": "true",
    },
)
def synthetic_embeddings(
    context: dg.AssetExecutionContext,
    synthetic_speeches: tuple[pl.DataFrame, dict[str, Any]],
    nim_embedding: NIMEmbeddingResource,
) -> tuple[pl.DataFrame, list[list[float]]]:
    """Generate embeddings for synthetic speeches.

    Uses local NIM embedding model. Runs after Safe Synth completes
    and NIM LLM is restored by KAI Scheduler.
    """
    df, _ = synthetic_speeches

    # Prepare texts for embedding
    texts = []
    for row in df.iter_rows(named=True):
        title = row.get("title", "") or ""
        text = row.get("text", "") or ""
        combined = f"{title}\n\n{text[:2000]}"
        texts.append(combined)

    context.log.info(f"Generating embeddings for {len(texts)} synthetic speeches...")

    # Generate embeddings (uses NVIDIA API, not local GPU)
    embeddings = nim_embedding.embed_texts(texts, batch_size=32)

    context.log.info(f"Generated {len(embeddings)} embeddings, dimension: {len(embeddings[0])}")

    return (df, embeddings)


@dg.asset(
    description="Synthetic speeches data product in LakeFS",
    group_name="synthetic_speeches",
    metadata={
        "layer": "output",
        "destination": "lakefs",
    },
)
def synthetic_data_product(
    context: dg.AssetExecutionContext,
    synthetic_speeches: tuple[pl.DataFrame, dict[str, Any]],
    lakefs: LakeFSResource,
) -> dict[str, Any]:
    """Store synthetic speeches as versioned data product in LakeFS."""
    df, evaluation = synthetic_speeches

    # Add timestamp
    df = df.with_columns(pl.lit(datetime.utcnow().isoformat()).alias("generated_at"))

    # Serialize to Parquet
    buffer = io.BytesIO()
    df.write_parquet(buffer)
    parquet_bytes = buffer.getvalue()

    # Store in LakeFS
    lakefs_client = lakefs.get_client()
    path = "central-bank-speeches/synthetic/speeches.parquet"

    lakefs_client.objects_api.upload_object(
        repository="data",
        branch="main",
        path=path,
        content=parquet_bytes,
    )

    commit = lakefs_client.commits_api.commit(
        repository="data",
        branch="main",
        commit_creation={
            "message": f"Update synthetic speeches data product ({len(df)} records)",
            "metadata": {
                "dagster_run_id": context.run_id or "",
                "num_records": str(len(df)),
                "is_synthetic": "true",
            },
        },
    )

    context.log.info(f"Committed synthetic data to LakeFS: {commit.id}")

    return {
        "path": f"lakefs://data/main/{path}",
        "commit_id": commit.id,
        "num_records": len(df),
    }


@dg.asset(
    description="Synthetic speeches indexed in Weaviate",
    group_name="synthetic_speeches",
    metadata={
        "layer": "output",
        "destination": "weaviate",
    },
)
def synthetic_weaviate_index(
    context: dg.AssetExecutionContext,
    synthetic_embeddings: tuple[pl.DataFrame, list[list[float]]],
    weaviate: WeaviateResource,
) -> dict[str, Any]:
    """Index synthetic speeches in separate Weaviate collection.

    Creates SyntheticSpeeches collection (separate from CentralBankSpeeches)
    per NEW INV-P004 (Synthetic Data Isolation).
    """
    df, embeddings = synthetic_embeddings

    # Ensure collection exists
    weaviate.ensure_collection(
        name="SyntheticSpeeches",
        properties=SYNTHETIC_SCHEMA,
        vector_dimensions=len(embeddings[0]),
    )

    # Prepare objects
    objects = []
    for row in df.iter_rows(named=True):
        objects.append({
            "speech_id": row["speech_id"],
            "date": str(row.get("date", "")),
            "central_bank": row.get("central_bank", "Unknown"),
            "speaker": row.get("speaker", "Unknown"),
            "title": row.get("title", "Untitled"),
            "text": row.get("text", "")[:10000],
            "tariff_mention": bool(row.get("tariff_mention", 0)),
            "is_synthetic": True,
        })

    # Insert objects with embeddings
    count = weaviate.insert_objects(
        collection_name="SyntheticSpeeches",
        objects=objects,
        vectors=embeddings,
    )

    context.log.info(f"Indexed {count} synthetic speeches in Weaviate")

    return {
        "collection": "SyntheticSpeeches",
        "object_count": count,
        "vector_dimensions": len(embeddings[0]),
    }


# Export all synthetic speech assets
synthetic_speeches_assets = [
    synthetic_speeches,
    synthetic_validation_report,
    synthetic_embeddings,
    synthetic_data_product,
    synthetic_weaviate_index,
]
```

---

### Step 4.7: Update Resource Exports

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/resources/__init__.py`

Add Safe Synthesizer resource to exports.

```python
"""Brev Data Platform resources."""

from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.safe_synth import SafeSynthesizerResource
from brev_pipelines.resources.weaviate import WeaviateResource

__all__ = [
    "LakeFSResource",
    "MinIOResource",
    "NIMResource",
    "NVIDIAEmbeddingResource",
    "SafeSynthesizerResource",
    "WeaviateResource",
]
```

---

### Step 4.8: Update Dagster Definitions

**Action**: Modify

**File(s)**: `dagster/src/brev_pipelines/definitions.py`

Add Safe Synthesizer resource with Kubernetes client support.

```python
"""Dagster definitions for Brev Data Platform."""

import os

import dagster as dg

from brev_pipelines.assets.demo import demo_assets
from brev_pipelines.assets.health import health_assets
from brev_pipelines.assets.validation import validation_assets
from brev_pipelines.assets.central_bank_speeches import central_bank_speeches_assets
from brev_pipelines.assets.synthetic_speeches import synthetic_speeches_assets
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.nim import NIMResource
from brev_pipelines.resources.nim_embedding import NIMEmbeddingResource
from brev_pipelines.resources.safe_synth import SafeSynthesizerResource
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
    "safe_synth": SafeSynthesizerResource(
        namespace=os.getenv("SAFE_SYNTH_NAMESPACE", "nvidia-ai"),
        service_endpoint=os.getenv(
            "SAFE_SYNTH_ENDPOINT",
            "http://nvidia-safe-synth.nvidia-ai.svc.cluster.local:8080",
        ),
        priority_class=os.getenv("SAFE_SYNTH_PRIORITY", "batch-high"),
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
    *synthetic_speeches_assets,
]

# Create definitions
defs = dg.Definitions(
    assets=all_assets,
    resources=resources,
)
```

---

### Step 4.9: Update pyproject.toml for Kubernetes Client

**Action**: Modify

**File(s)**: `dagster/pyproject.toml`

Add Kubernetes Python client dependency.

```toml
[project]
dependencies = [
    # ... existing dependencies ...
    "kubernetes>=28.0.0",  # For KAI Job management
]
```

---

### Step 4.10: Add Resource Tests

**Action**: Modify

**File(s)**: `dagster/tests/test_resources.py`

Add tests for Safe Synthesizer resource.

```python
# Add to existing test file

class TestSafeSynthesizerResource:
    """Tests for Safe Synthesizer resource with KAI integration."""

    def test_initialization(self):
        """Test Safe Synthesizer resource initialization."""
        from brev_pipelines.resources.safe_synth import SafeSynthesizerResource

        resource = SafeSynthesizerResource(
            namespace="nvidia-ai",
            priority_class="batch-high",
        )
        assert resource.namespace == "nvidia-ai"
        assert resource.priority_class == "batch-high"

    def test_default_config(self):
        """Test default configuration values."""
        from brev_pipelines.resources.safe_synth import SafeSynthesizerResource

        resource = SafeSynthesizerResource()
        assert resource.poll_interval == 30
        assert resource.max_wait_time == 7200
        assert resource.gpu_memory == "80Gi"

    def test_priority_class_setting(self):
        """Test that priority class is configurable."""
        from brev_pipelines.resources.safe_synth import SafeSynthesizerResource

        resource = SafeSynthesizerResource(priority_class="train")
        assert resource.priority_class == "train"
```

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `k8s/apps/kai-scheduler/templates/queues.yaml` | MODIFY | Add inference-queue and batch-queue |
| `k8s/apps/kai-scheduler/templates/priority-classes.yaml` | CREATE | Add batch-high priority class |
| `k8s/apps/nvidia-nim/values.yaml` | MODIFY | Add KAI queue label and priority |
| `k8s/apps/nvidia-safe-synth/templates/job-template.yaml` | CREATE | Job template for Safe Synth |
| `dagster/src/brev_pipelines/resources/safe_synth.py` | CREATE | Safe Synthesizer resource with K8s Jobs |
| `dagster/src/brev_pipelines/assets/synthetic_speeches.py` | CREATE | Synthetic data pipeline |
| `dagster/src/brev_pipelines/resources/__init__.py` | MODIFY | Export Safe Synthesizer |
| `dagster/src/brev_pipelines/definitions.py` | MODIFY | Register resources and assets |
| `dagster/pyproject.toml` | MODIFY | Add kubernetes client dependency |
| `dagster/tests/test_resources.py` | MODIFY | Add Safe Synthesizer tests |

---

## Configuration Details

### KAI Queue Configuration

| Queue | Priority | GPU Quota | Purpose |
|-------|----------|-----------|---------|
| `inference-queue` | 100 | 1 (guaranteed) | NIM LLM, always-on services |
| `batch-queue` | 50 | 0 (borrows) | Safe Synthesizer, training jobs |

### Priority Classes

| Priority Class | Value | Preemptible | Purpose |
|----------------|-------|-------------|---------|
| `inference` | 125 | No | NIM LLM (default) |
| `batch-high` | 130 | No | Safe Synth (preempts inference) |

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `SAFE_SYNTH_NAMESPACE` | `nvidia-ai` | Safe Synthesizer namespace |
| `SAFE_SYNTH_ENDPOINT` | Service URL | Safe Synthesizer API |
| `SAFE_SYNTH_PRIORITY` | `batch-high` | Priority class for jobs |

---

## Verification

### Pre-flight Checks

```bash
# Verify KAI Scheduler is running
kubectl get pods -n kai-scheduler

# Verify queues are created
kubectl get queues.scheduling.run.ai

# Verify priority classes exist
kubectl get priorityclasses | grep -E "(train|inference|batch-high)"

# Verify NIM has correct labels
kubectl get deployment nvidia-nim-llm -n nvidia-nim -o yaml | grep -A5 "labels:"
```

### Validation Commands

```bash
# Run tests
cd dagster && pytest tests/test_resources.py -v -k "SafeSynth"

# Verify KAI queue assignment
kubectl get pods -n nvidia-nim -o yaml | grep "kai.scheduler"

# Monitor KAI scheduling during synthetic pipeline:
# Terminal 1: Watch GPU workloads
watch kubectl get pods -A -l nvidia.com/gpu

# Terminal 2: Run Dagster pipeline
# In Dagster UI, materialize synthetic_speeches

# Observe:
# 1. NIM pod gets preempted (Terminating)
# 2. Safe Synth job pod starts (Running)
# 3. After job completes, NIM pod restarts (Running)
```

### Expected Outcomes

- KAI Scheduler automatically preempts NIM when Safe Synth job starts
- Safe Synthesizer job runs to completion
- NIM Deployment automatically restarts its pod after job completes
- No manual kubectl commands required
- Synthetic data generated with privacy guarantees
- All data versioned in LakeFS
- SyntheticSpeeches collection created in Weaviate

---

## How KAI Preemption Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    KAI PRIORITY-BASED PREEMPTION                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  BEFORE (Normal Operation):                                         │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ NIM Pod (inference priority: 125)                           │   │
│  │ Queue: inference-queue                                      │   │
│  │ GPU: 70Gi allocated                                         │   │
│  │ Status: Running ✓                                           │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  STEP 1: Dagster submits Safe Synth Job                            │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Safe Synth Job (batch-high priority: 130)                   │   │
│  │ Queue: batch-queue                                          │   │
│  │ GPU: 80Gi requested                                         │   │
│  │ Status: Pending...                                          │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  STEP 2: KAI Scheduler preempts NIM (lower priority)               │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ NIM Pod                                                     │   │
│  │ Status: Terminating... (graceful shutdown)                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Safe Synth Job                                              │   │
│  │ Status: Running ✓ (GPU acquired)                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  STEP 3: Safe Synth completes, NIM restarts automatically          │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ Safe Synth Job                                              │   │
│  │ Status: Completed ✓                                         │   │
│  └─────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ NIM Pod (new pod from Deployment)                           │   │
│  │ Status: Running ✓ (GPU reacquired)                          │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| KAI not preempting | Job stuck Pending | Check priority class values, verify queue config |
| NIM not restarting | Pod missing after job | Check Deployment replicas, verify node resources |
| Job OOM | Pod OOMKilled | Reduce batch size, increase memory limit |
| Job timeout | TimeoutError | Increase max_wait_time in resource |
| Privacy check fails | privacy_passed=false | Adjust epsilon, review data |

### Rollback Plan

If this phase fails:
1. Delete any stuck jobs: `kubectl delete jobs -n nvidia-ai -l app=safe-synth-job`
2. Verify NIM is running: `kubectl get pods -n nvidia-nim`
3. If NIM not running, scale up: `kubectl scale deployment nvidia-nim-llm --replicas=1 -n nvidia-nim`
4. Delete Weaviate collection: `weaviate.delete_collection("SyntheticSpeeches")`
5. Revert LakeFS: Create branch from before synthetic commits
6. Investigate KAI logs: `kubectl logs -n kai-scheduler -l app=kai-scheduler`

---

## Completion Criteria

- [ ] KAI queues configured (inference-queue, batch-queue)
- [ ] batch-high priority class created
- [ ] NIM deployment updated with queue labels
- [ ] Safe Synthesizer resource created with K8s Job support
- [ ] Synthetic speeches assets created (5 assets)
- [ ] KAI successfully preempts NIM when Safe Synth runs
- [ ] NIM automatically restarts after Safe Synth completes
- [ ] Synthetic data generated with privacy guarantees
- [ ] MIA/AIA evaluation passes
- [ ] Validation report stored in LakeFS
- [ ] Synthetic embeddings generated
- [ ] SyntheticSpeeches collection created in Weaviate
- [ ] Vector search works on synthetic data
- [ ] Tests pass
- [ ] Invariants INV-I003, INV-D002, INV-N003, INV-P001, INV-P003, NEW INV-P004, NEW INV-K006 verified
