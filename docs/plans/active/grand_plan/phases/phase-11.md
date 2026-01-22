# Phase 11: Sample Pipeline & Validation

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Validate the entire platform by running the demo pipeline from the `brev-dagster-pipelines` repository. Verify all integrations work: Dagster orchestration, MinIO storage, LakeFS versioning, NIM LLM enrichment, and JupyterHub notebook access.

---

## Prerequisites

- Phase 10.1 complete (Dagster pipelines repo set up, image deployed)
- All services running and healthy in cluster
- Port forwarding available via `make port-forward-all`

---

## Invariants Enforced in This Phase

- **INV-P001**: Assets over ops - Pipeline uses `@asset` pattern
- **INV-P003**: Type annotations on assets - Full type hints
- **INV-D002**: LakeFS for data versioning - Data stored via LakeFS
- **INV-D003**: Parquet/JSON for structured data - Standard formats

---

## Demo Pipeline Overview

The demo pipeline from `brev-dagster-pipelines` demonstrates the full stack:

```
┌─────────────────────┐
│   raw_sample_data   │  ← Generate 100 sample customer records
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│    cleaned_data     │  ← Clean, normalize, add tier classification
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  nim_enriched_data  │  ← NIM LLM generates customer profiles (10 samples)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│    data_summary     │  ← Statistics stored to MinIO
└─────────────────────┘

┌─────────────────────┐
│   platform_health   │  ← Health check for MinIO, LakeFS, NIM
└─────────────────────┘
```

---

## Validation Steps

### Step 11.1: Verify Dagster Deployment

```bash
# Check Dagster pods are running
kubectl get pods -n dagster

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# dagster-daemon-xxx                      1/1     Running   0          ...
# dagster-webserver-xxx                   1/1     Running   0          ...
# brev-pipelines-xxx                      1/1     Running   0          ...
# dagster-postgresql-0                    1/1     Running   0          ...

# Check user code logs for import errors
kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster --tail=50
```

### Step 11.2: Access Dagster UI

```bash
# Start all port forwards
make port-forward-all

# Open Dagster UI
open http://localhost:3000
```

**Verify in UI:**
- Navigate to **Assets** tab
- Confirm you see **demo** group with assets:
  - `raw_sample_data`
  - `cleaned_data`
  - `nim_enriched_data`
  - `data_summary`
- Confirm you see **health** group with:
  - `platform_health`

### Step 11.3: Run Platform Health Check

1. In Dagster UI, click on `platform_health` asset
2. Click **Materialize**
3. Wait for completion
4. Click on the materialization to view the result

**Expected result:**
```json
{
  "minio": "healthy",
  "lakefs": "healthy (1 repos)" or similar,
  "nim": "healthy"
}
```

If any service shows "error", troubleshoot that service before proceeding.

### Step 11.4: Run Demo Pipeline

1. In Dagster UI, navigate to **Assets** → **demo** group
2. Select `raw_sample_data` asset
3. Click **Materialize**
4. Watch the pipeline execute through downstream assets automatically

**Alternative: Materialize all at once**
1. Select all 4 demo assets
2. Click **Materialize selected**

### Step 11.5: Verify Pipeline Results

**Check Dagster logs:**
```bash
kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster --tail=100 | grep -E "(Generated|Cleaned|Calling NIM|Enriched|Stored)"
```

**Expected log entries:**
- "Generated 100 sample records"
- "Cleaned 100 records"
- "Calling NIM for CUST-XXXX..." (10 times)
- "Enriched X/100 records"
- "Stored summary to data-products/demo/summary.json"

### Step 11.6: Verify MinIO Storage

```bash
# Port forward MinIO console
make port-forward-minio

# Open MinIO UI
open http://localhost:9001
```

**Login and verify:**
1. Login with credentials from `.env.local`
2. Navigate to **data-products** bucket
3. Browse to **demo/** folder
4. Verify `summary.json` exists
5. Download and inspect the file

**Or via CLI:**
```bash
# If mc (MinIO client) is configured
mc ls minio/data-products/demo/
mc cat minio/data-products/demo/summary.json
```

### Step 11.7: Test from JupyterHub

1. Open JupyterHub: `make port-forward-jupyterhub` → http://localhost:8000
2. Login with any username/password
3. Start a **Standard (CPU only)** server
4. Open a Python notebook or terminal

**Test MinIO connectivity:**
```python
import os
import json
from minio import Minio

# Create client using injected environment variables
client = Minio(
    os.getenv("MINIO_ENDPOINT"),
    access_key=os.getenv("MINIO_ACCESS_KEY"),
    secret_key=os.getenv("MINIO_SECRET_KEY"),
    secure=False,
)

# List buckets
print("Buckets:")
for bucket in client.list_buckets():
    print(f"  - {bucket.name}")

# Read the demo output
response = client.get_object("data-products", "demo/summary.json")
summary = json.loads(response.read())
print("\nPipeline Summary:")
print(json.dumps(summary, indent=2))
```

**Test with Marimo:**
1. In JupyterHub, open the Marimo launcher
2. Create a new Marimo notebook
3. Run the same MinIO connectivity test
4. Verify reactive updates work

### Step 11.8: Verify NIM Enrichment

Check that AI-generated profiles are meaningful:

1. In Dagster UI, click on `nim_enriched_data` materialization
2. View the logs to see generated profiles
3. Profiles should be coherent customer descriptions, not error messages

**Example valid profile:**
```
"A 45-year-old customer from the North region in the Premium category, representing a High Value tier with significant spending history."
```

**Example error (indicates NIM issue):**
```
"LLM error: Connection refused"
```

---

## Full Stack Health Check Script

Run this script to validate all components:

```bash
#!/bin/bash
set -e

echo "=== Brev Data Platform - Full Stack Validation ==="
echo ""

echo "1. Kubernetes Cluster:"
kubectl get nodes -o wide
echo ""

echo "2. GPU Status:"
kubectl describe nodes | grep -A2 "nvidia.com/gpu" || echo "No GPU info found"
echo ""

echo "3. ArgoCD Applications:"
kubectl get applications -n argocd \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
echo ""

echo "4. All Pods Status:"
for ns in argocd minio lakefs dagster jupyterhub nvidia-nim monitoring; do
  echo "--- $ns ---"
  kubectl get pods -n $ns --no-headers 2>/dev/null || echo "Namespace not found"
done
echo ""

echo "5. Service Endpoints (internal):"
echo "   MinIO:      minio.minio.svc.cluster.local:9000"
echo "   LakeFS:     lakefs.lakefs.svc.cluster.local:8000"
echo "   Dagster:    dagster-webserver.dagster.svc.cluster.local:80"
echo "   NIM:        nvidia-nim-llm.nvidia-nim.svc.cluster.local:8000"
echo "   JupyterHub: proxy-public.jupyterhub.svc.cluster.local:80"
echo ""

echo "6. Dagster User Code:"
kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-user-deployments -o wide
echo ""

echo "7. Recent Dagster Runs:"
kubectl logs -n dagster -l app.kubernetes.io/name=dagster-webserver --tail=20 2>/dev/null | grep -i "run" | tail -5 || echo "No recent runs"
echo ""

echo "=== Validation Complete ==="
```

---

## Troubleshooting

### Dagster can't connect to MinIO

```bash
# Check secret exists in dagster namespace
kubectl get secret dagster-env-secrets -n dagster

# If missing, create from minio namespace
kubectl get secret minio-credentials -n minio -o yaml | \
  sed 's/namespace: minio/namespace: dagster/' | \
  sed 's/name: minio-credentials/name: dagster-env-secrets/' | \
  kubectl apply -f -
```

### NIM returns errors

```bash
# Check NIM pod status
kubectl get pods -n nvidia-nim

# Check NIM logs
kubectl logs -f deployment/nvidia-nim-llm -n nvidia-nim --tail=50

# Test NIM directly
kubectl port-forward svc/nvidia-nim-llm -n nvidia-nim 8000:8000 &
curl http://localhost:8000/v1/health/ready
```

### Assets not visible in Dagster UI

```bash
# Check user code container logs
kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster

# Look for import errors like:
# "ModuleNotFoundError: No module named 'brev_pipelines'"

# If image is wrong, check the deployment
kubectl get deployment -n dagster -o yaml | grep image:
```

### JupyterHub environment variables missing

```bash
# Check if secrets are mounted in singleuser pods
kubectl exec -it <singleuser-pod> -n jupyterhub -- env | grep MINIO

# If missing, check JupyterHub values.yaml envFromSecret configuration
```

---

## Completion Criteria

### Infrastructure
- [ ] All ArgoCD applications show Synced/Healthy
- [ ] All pods in all namespaces are Running
- [ ] GPU is available (visible in node resources)

### Dagster
- [ ] Dagster webserver accessible at http://localhost:3000
- [ ] User code deployment running with custom image
- [ ] All demo assets visible in UI
- [ ] `platform_health` shows all services healthy

### Demo Pipeline
- [ ] `raw_sample_data` materializes (100 records)
- [ ] `cleaned_data` materializes (100 records with tier)
- [ ] `nim_enriched_data` materializes with actual AI profiles (10 enriched)
- [ ] `data_summary` materializes and stores to MinIO
- [ ] `summary.json` exists in MinIO `data-products/demo/`

### JupyterHub
- [ ] JupyterHub accessible at http://localhost:8000
- [ ] Can spawn Standard server
- [ ] Environment variables (MINIO_*, LAKEFS_*) are set
- [ ] Can read pipeline output from MinIO in notebook
- [ ] Marimo works in JupyterHub

### End-to-End
- [ ] Full stack health check script passes
- [ ] Data flows from Dagster → MinIO → JupyterHub

---

## Phase Completion

Once all criteria are met:

1. Update this file's status to **Complete**
2. Update `development-plan.md` status table
3. Commit completion:
   ```bash
   git add docs/plans/active/grand_plan/phases/phase-11.md
   git add docs/plans/active/grand_plan/development-plan.md
   git commit -m "Complete Phase 11: Sample Pipeline & Validation - Platform fully operational"
   git push origin main
   ```

---

## Congratulations!

The Brev Data Platform is now fully deployed and validated. You have:

| Component | Status | Description |
|-----------|--------|-------------|
| **Infrastructure** | ✅ | GPU-enabled RKE2 cluster on Brev |
| **GitOps** | ✅ | ArgoCD managing all applications |
| **Storage** | ✅ | MinIO S3-compatible object storage |
| **Versioning** | ✅ | LakeFS for data versioning |
| **Orchestration** | ✅ | Dagster running data pipelines |
| **Notebooks** | ✅ | JupyterHub with Marimo extension |
| **AI/LLM** | ✅ | NVIDIA NIM for LLM inference |
| **Monitoring** | ✅ | Prometheus, Grafana, Loki |
| **CI/CD** | ✅ | GitHub Actions for automation |

---

## What's Next?

### Immediate Next Steps
1. **Add real data sources** - Replace sample data with actual ingestion
2. **Build domain pipelines** - Create assets for your specific use cases
3. **Create Grafana dashboards** - Visualize pipeline metrics and GPU usage

### Future Enhancements
- **LakeFS integration** - Add branching/versioning to pipeline outputs
- **Safe Synthesizer** - Integrate when GPU allows (currently NIM uses the GPU)
- **Data quality** - Add Great Expectations or similar validation
- **Alerting** - Configure PagerDuty/Slack alerts for pipeline failures
- **Multi-environment** - Add staging/production configurations
