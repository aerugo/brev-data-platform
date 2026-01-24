# Phase 4.1: Safe Synthesizer Fixes and Re-run

**Status**: Ready to Execute
**Type**: Bug Fix + Re-run
**Started**: 2026-01-24
**Parent Plan**: [development-plan.md](../development-plan.md)
**Analysis Report**: [safe-synthesizer-best-practices.md](../../../reports/safe-synthesizer-best-practices.md)

---

## Objective

Fix critical issues discovered during Phase 4 execution and prepare for a successful synthetic data generation run.

---

## Issues Discovered

### Issue 1: Context Length Error (Root Cause of Job Failure)

**Symptom**: Job failed with "model underfitting" after training completed. 0% of generated records were valid.

**Evidence from logs**:
```
Using max model len 2048  ← NOT 12K with RoPE!
Number of prompts submitted: 100
Number of valid records generated: 0
Percentage of records that are valid: 0.00%
🛑 Stopping generation prematurely. No valid records were generated due to model underfitting.
```

**Root Cause**: Safe Synthesizer uses TinyLlama's **base 2048 token context** by default. Our 8000 character truncation (≈2000 tokens) exceeded the context limit, causing generation failures.

**Fix Applied**:
1. Added `rope_scaling_factor: 6` in [safe_synth.py](../../../../../dagster/src/brev_pipelines/resources/safe_synth.py) to extend context to ~12K tokens
2. Updated `MAX_TEXT_LENGTH` to 10000 characters in [synthetic_speeches.py](../../../../../dagster/src/brev_pipelines/assets/synthetic_speeches.py)

### Issue 2: Flawed Batching Architecture

**Symptom**: Training 8 separate models on 1000-record batches instead of training once on all 7721 records.

**Evidence**: Each batch triggered a complete training cycle:
1. Fine-tune TinyLlama-1.1B with LoRA adapters
2. Apply DP-SGD differential privacy
3. Run MIA/AIA evaluation
4. Generate synthetic data

This caused:
- Statistical fragmentation (cross-batch correlations lost)
- Privacy budget waste (ε applied 8 times independently)
- Computational waste (8× GPU time)
- Lower quality (smaller training sets)

**Fix Applied**: Removed batch loop, using single `synthesize()` call with all data.

### Issue 3: Suboptimal Epsilon

**Symptom**: Using ε=1.0 for 7721 records, which is overly strict for this dataset size.

**Best Practice**: NVIDIA recommends ε=4.0-12.0 for large datasets (>1000 records).

**Fix Applied**: Updated epsilon from 1.0 to 6.0.

---

## Fixes Implemented

### Code Changes (Already Applied)

| File | Change | Rationale |
|------|--------|-----------|
| [safe_synth.py](../../../../../dagster/src/brev_pipelines/resources/safe_synth.py) | `rope_scaling_factor: 6` | Extend context to ~12K tokens |
| [synthetic_speeches.py](../../../../../dagster/src/brev_pipelines/assets/synthetic_speeches.py) | `MAX_TEXT_LENGTH = 10000` | Allow longer speech text (with RoPE scaling) |
| [synthetic_speeches.py](../../../../../dagster/src/brev_pipelines/assets/synthetic_speeches.py) | Removed batch loop | Train once on all data |
| [synthetic_speeches.py](../../../../../dagster/src/brev_pipelines/assets/synthetic_speeches.py) | `epsilon: 6.0` | Better quality for large dataset |
| [synthetic_speeches.py](../../../../../dagster/src/brev_pipelines/assets/synthetic_speeches.py) | Updated evaluation handling | Single result (no aggregation) |

### Before vs After

```python
# BEFORE (Flawed)
MAX_TEXT_LENGTH = 8000  # Too long for 2048 token context
batch_size = 1000
for i in range(0, len(data_for_synthesis), batch_size):
    batch = data_for_synthesis[i : i + batch_size]
    safe_synth.synthesize(batch, config={"epsilon": 1.0, ...})

# AFTER (Fixed with RoPE scaling)
# In safe_synth.py:
"training": {
    "rope_scaling_factor": 6,  # Extends context to ~12K tokens
    ...
}

# In synthetic_speeches.py:
MAX_TEXT_LENGTH = 10000  # Now fits in extended context
safe_synth.synthesize(data_for_synthesis, config={"epsilon": 6.0, ...})
```

---

## Execution Steps

### Step 4.1.1: Verify Fixes Are Applied

**Action**: Verify code changes

```bash
# Check RoPE scaling in safe_synth.py
grep -n "rope_scaling_factor" dagster/src/brev_pipelines/resources/safe_synth.py
# Expected: "rope_scaling_factor": 6

# Check text truncation
grep -n "MAX_TEXT_LENGTH" dagster/src/brev_pipelines/assets/synthetic_speeches.py
# Expected: MAX_TEXT_LENGTH = 10000

# Check no batch loop
grep -n "batch_size" dagster/src/brev_pipelines/assets/synthetic_speeches.py
# Expected: No matches (batch loop removed)

# Check epsilon
grep -n "epsilon" dagster/src/brev_pipelines/assets/synthetic_speeches.py
# Expected: "epsilon": 6.0
```

---

### Step 4.1.2: Commit and Push Changes

**Action**: Commit fixes

```bash
cd dagster
git add src/brev_pipelines/assets/synthetic_speeches.py
git commit -m "fix(synthetic): Fix Safe Synthesizer context length and batching

- Reduce MAX_TEXT_LENGTH from 8000 to 2000 chars
  (Safe Synth uses 2048 token context, not 12K RoPE)
- Remove batch loop - train once on all 7721 records
- Update epsilon from 1.0 to 6.0 (recommended for large datasets)
- Simplify evaluation handling for single run

See docs/reports/safe-synthesizer-best-practices.md for analysis.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

git push origin main
```

---

### Step 4.1.3: Wait for CI Build

**Action**: Monitor GitHub Actions

```bash
# Check latest workflow
gh run list --limit 5

# Wait for completion
gh run watch
```

---

### Step 4.1.4: Restart Dagster Deployments

**Action**: Restart to pick up new code

```bash
# Restart user deployments to pull new image
kubectl rollout restart deployment -n dagster -l component=dagster-user-deployments

# Wait for rollout
kubectl rollout status deployment -n dagster -l component=dagster-user-deployments

# Verify new pod is running
kubectl get pods -n dagster | grep brev-pipelines
```

---

### Step 4.1.5: Run Trial Pipeline (Optional but Recommended)

**Action**: Test with 10 records first

In Dagster UI:
1. Navigate to Jobs
2. Launch `full_pipeline_trial_run`
3. Monitor execution
4. Verify:
   - Single training message (no batch messages)
   - Training completes with >0% valid records
   - Synthetic data stored in LakeFS trial path
   - Weaviate trial collection created

---

### Step 4.1.6: Run Full Pipeline

**Action**: Execute full synthesis run

In Dagster UI:
1. Navigate to Jobs
2. Launch `full_pipeline_full_run`
3. Monitor execution (~2 hours for training)

Expected log messages:
```
Training on 7721 records (single run, no batching)
Text truncated to 10000 chars (RoPE scaling factor 6 = ~12K token context)
...
Training 100.0% complete
...
Generated 7721 synthetic speeches
Privacy passed: True
MIA score: X.XX, AIA score: X.XX
```

---

### Step 4.1.7: Verify Results

**Action**: Check outputs

```bash
# Check LakeFS for synthetic data
lakectl fs ls lakefs://data/main/central-bank-speeches/synthetic/

# Check Weaviate collection
kubectl exec -n weaviate deployment/weaviate -- \
  curl -s localhost:8080/v1/schema/SyntheticSpeeches | jq '.vectorIndexConfig'

# Check validation report in LakeFS
lakectl fs cat lakefs://data/main/central-bank-speeches/synthetic/validation_report.json | jq
```

---

## Validation Checklist

### Code Fixes
- [x] `rope_scaling_factor: 6` added to safe_synth.py training config
- [x] `MAX_TEXT_LENGTH` updated to 10000 (with RoPE scaling)
- [x] Batch loop removed (single `synthesize()` call)
- [x] Epsilon updated to 6.0
- [x] Evaluation handling updated for single run

### Pipeline Execution
- [ ] CI build completed successfully
- [ ] Dagster deployments restarted
- [ ] Trial run completed (optional)
- [ ] Full pipeline run completed
- [ ] Training reached 100% with >0% valid records
- [ ] Synthetic data stored in LakeFS
- [ ] Validation report generated
- [ ] SyntheticSpeeches collection in Weaviate

### Quality Metrics
- [ ] MIA score reported
- [ ] AIA score reported
- [ ] `privacy_passed: true`
- [ ] 7721 synthetic records generated

---

## Success Criteria

1. **Training succeeds** with >0% valid records generated
2. **7721 synthetic records** stored in LakeFS at `central-bank-speeches/synthetic/speeches.parquet`
3. **Validation report** shows `privacy_passed: true`
4. **Weaviate index** created with 7721 objects in `SyntheticSpeeches` collection
5. **GPU restored** to NIM automatically after job completion

---

## Rollback Plan

If the fixed pipeline still fails:

1. Check logs for new error messages
2. If context still too long: reduce `MAX_TEXT_LENGTH` (try 8000, 6000, or 4000)
3. If RoPE scaling causes issues: reduce `rope_scaling_factor` from 6 to 4 or 2
4. If CUDA OOM: reduce `max_vram_fraction` in safe_synth.py (try 0.5 or 0.4)
5. If training too slow: consider using `num_input_records_to_sample` to subsample training data
6. Restore NIM: `kubectl scale deployment nvidia-nim-llm -n nvidia-nim --replicas=1`

---

## Documentation Created

- [safe-synthesizer-best-practices.md](../../../reports/safe-synthesizer-best-practices.md) - Comprehensive analysis of Safe Synthesizer usage
