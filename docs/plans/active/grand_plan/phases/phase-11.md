# Phase 11: Sample Pipeline & Validation

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Validate the entire platform by running programmatic validation tests that verify all integrations work: Dagster orchestration, MinIO storage, LakeFS versioning, NIM LLM inference, and JupyterHub notebook access.

This phase provides **three levels of validation**:
1. **Quick** - Kubernetes cluster and pod health check
2. **Full** - Above + ArgoCD apps + Dagster validation pipeline
3. **Dagster Assets** - Comprehensive component tests via `validate_platform` asset

---

## Prerequisites

- Phase 10.1 complete (Dagster pipelines repo set up, image deployed)
- All services running and healthy in cluster
- SSH tunnel active: `make ssh-tunnel`
- KUBECONFIG set: `export KUBECONFIG=~/.kube/config-brev-data-platform-dev`

---

## Validation Methods

### Method 1: CLI Validation Script (Recommended)

Run comprehensive validation from the command line:

```bash
# Full validation (recommended)
make validate-platform

# Quick health check (K8s cluster + pods only)
make validate-quick

# Kubernetes validation (no Dagster tests)
make validate-k8s
```

**What `make validate-platform` tests:**
- Kubernetes node health
- GPU resource availability
- KAI Scheduler status
- Pod status in all namespaces (argocd, minio, lakefs, dagster, jupyterhub, nvidia-nim, monitoring)
- ArgoCD application sync status
- Dagster webserver/daemon/user-code health
- Service connectivity (MinIO, LakeFS, NIM)
- Dagster `quick_health_check` asset execution

### Method 2: Dagster Validation Assets

Run validation directly through Dagster UI or CLI:

```bash
# Via Dagster CLI (requires env vars)
dagster asset materialize -m brev_pipelines.definitions --select validate_platform
```

**Or via Dagster UI:**
1. Open Dagster: `make port-forward-dagster` → http://localhost:3000
2. Navigate to **Assets** → **validation** group
3. Materialize `validate_platform`

**Available Validation Assets:**

| Asset | Description | Tests |
|-------|-------------|-------|
| `validate_minio` | MinIO object storage | Connection, list/create/delete buckets, read/write objects |
| `validate_lakefs` | LakeFS versioning | Connection, list repositories, API health |
| `validate_nim` | NVIDIA NIM LLM | Health check, text completion, response quality |
| `validate_platform` | Full validation | Aggregates all above, stores report to MinIO |
| `quick_health_check` | Quick connectivity | Lightweight health check of all services |

### Method 3: Manual Validation

Step-by-step manual validation for troubleshooting.

---

## Detailed Validation Steps

### Step 11.1: Quick Cluster Health

```bash
# Quick validation
make validate-quick

# Expected output:
# ✓ Node is Ready
# ✓ GPU available: 1
# ✓ KAI Scheduler running (7 pods)
# ✓ argocd: 5/5 pods running
# ✓ minio: 1/1 pods running
# ...
```

### Step 11.2: Full Platform Validation

```bash
# Full validation
make validate-platform

# This runs:
# 1. Kubernetes cluster health
# 2. Pod status for all namespaces
# 3. ArgoCD application sync status
# 4. Dagster deployment checks
# 5. Service health via Dagster quick_health_check
```

### Step 11.3: Dagster Asset Validation

**Via UI:**
1. Open http://localhost:3000 (after `make port-forward-dagster`)
2. Navigate to **Assets** tab
3. Select **validation** group
4. Click `validate_platform` → **Materialize**
5. Wait for completion (~30 seconds)
6. View results in the materialization panel

**Expected Result:**
```json
{
  "validation_run": {
    "timestamp": "2026-01-22T12:00:00Z",
    "overall_status": "PASSED",
    "passed_components": 3,
    "total_components": 3
  },
  "summary": {
    "minio": "✅ PASSED",
    "lakefs": "✅ PASSED",
    "nim": "✅ PASSED"
  },
  "report_location": "data-products/validation/report_20260122_120000.json"
}
```

### Step 11.4: Run Demo Pipeline

After validation passes, run the demo pipeline:

1. In Dagster UI, navigate to **Assets** → **demo** group
2. Select `raw_sample_data`
3. Click **Materialize**
4. Watch downstream assets execute automatically

**Pipeline Flow:**
```
raw_sample_data (100 records)
        ↓
cleaned_data (normalized, tier added)
        ↓
nim_enriched_data (10 AI-generated profiles)
        ↓
data_summary (stored to MinIO)
```

### Step 11.5: Verify MinIO Output

```bash
# Open MinIO console
make port-forward-minio
# http://localhost:9001

# Or via validation report
# Check: data-products/validation/latest.json
# Check: data-products/demo/summary.json
```

### Step 11.6: Test from JupyterHub

1. Open JupyterHub: `make port-forward-jupyterhub` → http://localhost:8000
2. Login with any username/password
3. Start a **Standard (CPU only)** server
4. Create a new Python notebook

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

# Read validation report
response = client.get_object("data-products", "validation/latest.json")
report = json.loads(response.read())
print("Validation Report:")
print(json.dumps(report, indent=2))

# Read demo output
response = client.get_object("data-products", "demo/summary.json")
summary = json.loads(response.read())
print("\nDemo Pipeline Summary:")
print(json.dumps(summary, indent=2))
```

---

## Validation Asset Details

### validate_minio

Tests MinIO S3-compatible storage with 7 comprehensive tests:

1. **Connection** - Can connect to MinIO endpoint
2. **List buckets** - Can enumerate existing buckets
3. **Create bucket** - Can create `validation-test-bucket`
4. **Write object** - Can write JSON data to bucket
5. **Read object** - Can read data back and verify integrity
6. **Delete object** - Can delete test object
7. **Delete bucket** - Can cleanup test bucket

### validate_lakefs

Tests LakeFS data versioning:

1. **Connection** - Health endpoint responds
2. **List repositories** - Can enumerate repositories
3. **API version** - API is accessible

### validate_nim

Tests NVIDIA NIM LLM inference:

1. **Health check** - `/v1/health/ready` responds
2. **Simple completion** - Can generate text from prompt
3. **Structured response** - Can produce semi-structured output

### validate_platform

Aggregates all component validations:
- Runs all individual validation assets
- Calculates overall pass/fail status
- Stores timestamped report to MinIO (`data-products/validation/`)
- Updates `validation/latest.json` for easy access

---

## Troubleshooting

### Validation script fails to connect

```bash
# Ensure SSH tunnel is running
make ssh-tunnel

# In another terminal, set KUBECONFIG
export KUBECONFIG=~/.kube/config-brev-data-platform-dev

# Test connection
kubectl get nodes
```

### MinIO validation fails

```bash
# Check MinIO pods
kubectl get pods -n minio

# Check MinIO logs
kubectl logs -f deployment/minio -n minio

# Verify secrets exist
kubectl get secret minio-credentials -n minio
kubectl get secret dagster-env-secrets -n dagster
```

### LakeFS validation fails

```bash
# Check LakeFS pods
kubectl get pods -n lakefs

# Check LakeFS logs
kubectl logs -f deployment/lakefs -n lakefs

# Verify MinIO credentials for LakeFS
kubectl get secret minio-credentials -n lakefs
```

### NIM validation fails

NIM may take several minutes to become ready (model loading):

```bash
# Check NIM pod status
kubectl get pods -n nvidia-nim

# Watch NIM logs for model loading
kubectl logs -f deployment/nvidia-nim-llm -n nvidia-nim

# Test health endpoint directly
kubectl port-forward svc/nvidia-nim-llm -n nvidia-nim 8000:8000 &
curl http://localhost:8000/v1/health/ready
```

### Dagster validation asset fails

```bash
# Check Dagster user code logs
kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster --tail=100

# Look for import errors
kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster | grep -i error

# Check environment variables are set
kubectl exec -it $(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-user-deployments -o jsonpath='{.items[0].metadata.name}') -n dagster -- env | grep -E "MINIO|LAKEFS|NIM"
```

---

## Completion Criteria

### Infrastructure
- [ ] `make validate-quick` passes all checks
- [ ] All ArgoCD applications show Synced/Healthy
- [ ] GPU is visible in node resources

### Dagster Validation
- [ ] `validate_minio` asset: All 7 tests pass
- [ ] `validate_lakefs` asset: All tests pass
- [ ] `validate_nim` asset: Health and completion tests pass
- [ ] `validate_platform` asset: Overall status PASSED

### Demo Pipeline
- [ ] `raw_sample_data` materializes (100 records)
- [ ] `cleaned_data` materializes (100 records with tier)
- [ ] `nim_enriched_data` materializes (10 AI profiles)
- [ ] `data_summary` stored to MinIO

### JupyterHub
- [ ] Can spawn Standard server
- [ ] Environment variables are set
- [ ] Can read MinIO data from notebook

### Validation Report
- [ ] Report stored at `data-products/validation/latest.json`
- [ ] Report shows all components passed

---

## Phase Completion

Once all criteria are met:

```bash
# 1. Update submodule to latest
cd /path/to/brev-data-platform
git submodule update --remote dagster

# 2. Update this file's status
# Edit phase-11.md: Status: Complete, Started: date, Completed: date

# 3. Update development-plan.md progress table

# 4. Commit
git add -A
git commit -m "Complete Phase 11: Platform validation - All systems operational

- All validation assets passing
- Demo pipeline runs successfully
- JupyterHub access verified
- Validation report stored to MinIO

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
git push origin main
```

---

## Summary

The Brev Data Platform is fully deployed and validated:

| Component | Validation Method | Status |
|-----------|-------------------|--------|
| **RKE2 Cluster** | `make validate-quick` | |
| **KAI Scheduler** | Pod health check | |
| **ArgoCD** | App sync status | |
| **MinIO** | `validate_minio` asset (7 tests) | |
| **LakeFS** | `validate_lakefs` asset (3 tests) | |
| **NIM LLM** | `validate_nim` asset (3 tests) | |
| **Dagster** | User code deployment + demo pipeline | |
| **JupyterHub** | Notebook MinIO access test | |
| **Monitoring** | Pod health check | |

---

## What's Next?

### Immediate Next Steps
1. **Add real data sources** - Replace sample data with actual ingestion
2. **Build domain pipelines** - Create assets for your specific use cases
3. **Create Grafana dashboards** - Visualize pipeline metrics and GPU usage

### Future Enhancements
- **LakeFS branching** - Add data versioning to pipeline outputs
- **Safe Synthesizer** - Integrate when GPU allows (NIM uses GPU)
- **Data quality** - Add Great Expectations validation
- **Alerting** - Configure alerts for pipeline failures
- **Multi-environment** - Add staging/production configurations
