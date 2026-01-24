# NVIDIA Safe Synthesizer: Best Practices for Large-Scale Synthetic Data Generation

**Date:** 2026-01-24
**Context:** Central Bank Speeches Pipeline (7721 records)
**Status:** Analysis Complete - Fixes Implemented

## Executive Summary

Our implementation had **two critical flaws**:

1. **Architectural flaw**: Training 8 separate models on different data batches instead of training once on the full dataset
2. **Context length error**: Text truncation at 8000 chars exceeded the 2048 token limit (RoPE scaling is NOT applied by Safe Synthesizer)

The job failed with "model underfitting" after training completed because **0% of generated records were valid** - the context window was too small for our prompts.

### Error Evidence (from job logs)
```
Using max model len 2048  ← NOT 12K with RoPE!
Number of prompts submitted: 100
Number of valid records generated: 0
Percentage of records that are valid: 0.00%
🛑 Stopping generation prematurely. No valid records were generated due to model underfitting.
```

This report analyzes the correct approach based on NVIDIA's official documentation and provides concrete recommendations for fixing our pipeline.

---

## 1. Current Implementation Analysis

### What Our Code Does

Location: [synthetic_speeches.py:106-128](dagster/src/brev_pipelines/assets/synthetic_speeches.py#L106-L128)

```python
# Current (FLAWED) approach
batch_size = 1000
for i in range(0, len(data_for_synthesis), batch_size):
    batch = data_for_synthesis[i : i + batch_size]
    synthetic_batch, evaluation = safe_synth.synthesize(
        input_data=batch,
        run_id=f"{run_id}-batch{batch_num}",
        config={...},
    )
```

### The Problem

For our 7721 speeches, this creates **8 separate synthesis jobs**:

| Batch | Records | What Happens |
|-------|---------|--------------|
| 1 | 1000 | Train TinyLlama-1.1B on records 0-999, generate 1000 synthetic |
| 2 | 1000 | Train **new** model on records 1000-1999, generate 1000 synthetic |
| 3 | 1000 | Train **new** model on records 2000-2999, generate 1000 synthetic |
| ... | ... | ... |
| 8 | 721 | Train **new** model on records 7000-7720, generate 721 synthetic |

**Each batch triggers a complete training cycle:**
1. Fine-tune TinyLlama-1.1B with LoRA adapters
2. Apply DP-SGD differential privacy
3. Run MIA/AIA evaluation
4. Generate synthetic data

### Why This Is Wrong

1. **Statistical Fragmentation**: Each model only learns patterns from ~1000 records. Cross-batch correlations (e.g., how ECB speeches differ from Fed speeches) are lost.

2. **Privacy Budget Waste**: Differential privacy (ε=1.0) is applied 8 times independently. The effective privacy guarantee is weaker than training once.

3. **Computational Waste**: 8× the GPU time for training, model loading, and evaluation.

4. **Model Quality**: Smaller training sets produce lower-quality synthetic data. NVIDIA recommends 1000+ records minimum, but 10,000+ for best DP results.

---

## 2. NVIDIA Documentation: Correct Approach

### Official Recommendations

From [NVIDIA NeMo Safe Synthesizer Documentation](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/tabular-fine-tuning.html):

> "Tabular Fine-Tuning can train on datasets of various sizes (we recommend 1,000 or more records) and generate synthetic datasets with **unlimited records**."

Key insight: **Train once, generate many.**

### Correct Configuration

```python
synth_config = {
    "training": {
        "pretrained_model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "num_input_records_to_sample": "auto",  # Uses all data
    },
    "generation": {
        "num_records": 7721,  # Generate ANY number of records
        "temperature": 0.8,
        "use_structured_generation": True,
    },
    "privacy": {
        "dp_enabled": True,
        "epsilon": 6.0,  # Recommended: 4.0-12.0 for large datasets
        "delta": "auto",  # Calculates as 1/n^1.2
    },
}
```

### Key Parameters

| Parameter | Purpose | Recommendation |
|-----------|---------|----------------|
| `num_records` | Output count (independent of training size) | Set to desired output (7721) |
| `epsilon` | Privacy-utility tradeoff | 4.0-12.0 for large datasets |
| `delta` | Privacy failure probability | "auto" (1/n^1.2) |
| `num_input_records_to_sample` | Subset for training | "auto" or explicit number |

---

## 3. Differential Privacy Considerations

### Privacy Budget with Large Datasets

From [DP Documentation](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/differential-privacy.html):

> "More training data helps with DP synthetic data quality. Generally 10,000+ records is recommended."

Our 7721 records are close to this threshold. Single training is essential for:

1. **Proper noise calibration**: DP-SGD noise is calibrated based on dataset size
2. **Delta calculation**: `delta = 1/(7721)^1.2 ≈ 2.6e-5` (appropriate for our scale)
3. **Gradient clipping**: Works correctly across full data distribution

### Recommended Epsilon for Our Use Case

| Epsilon | Privacy Level | Quality Impact | Recommended For |
|---------|--------------|----------------|-----------------|
| 1.0 | Very strong | High noise | Sensitive PII |
| 4.0-6.0 | Strong | Moderate noise | **Financial/speeches** |
| 8.0-12.0 | Moderate | Low noise | Non-sensitive data |

**Recommendation**: Increase epsilon to 6.0 for better quality while maintaining strong privacy.

---

## 4. Context Window and RoPE Scaling

### Context Window Constraint (CRITICAL FIX)

From documentation:
> "All of the data related to a single example must fit inside the context window."

**Important Discovery**: Safe Synthesizer uses **2048 tokens** (TinyLlama base) by default, NOT 12K with RoPE scaling!

From job logs:
```
INFO [model.py:1745] Using max model len 2048
```

Our original 8000 character truncation (≈2000 tokens) was at or beyond the limit, causing 0% valid generation.

**Initial Fix**: Reduced to 2000 characters (~500 tokens), leaving room for:
- Other fields (speech_id, date, central_bank, speaker, title, tariff_mention): ~200 tokens
- Generation prompt overhead: ~300 tokens
- Actual text content: ~1000 tokens

### Extending Context with `rope_scaling_factor` (RECOMMENDED IMPROVEMENT)

NVIDIA's documentation reveals the `rope_scaling_factor` parameter that can **extend the context window up to 6×**:

From [Tabular Fine-Tuning Documentation](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/tabular-fine-tuning.html):

> "You can increase the `rope_scaling_factor` in order to scale up the context window size (integer between 1 and 6; maximum value is 6). This can be effective, but note that it typically increases the runtime."

#### Context Window Sizes with RoPE Scaling

| `rope_scaling_factor` | Context Window | Max Chars (est.) | Use Case |
|----------------------|----------------|------------------|----------|
| 1 (default) | 2,048 tokens | ~2,000 chars | Short text fields |
| 2 | 4,096 tokens | ~4,000 chars | Medium documents |
| 4 | 8,192 tokens | ~8,000 chars | Long articles |
| **6** | **12,288 tokens** | **~12,000 chars** | **Full speeches** |

#### Recommended Configuration for Central Bank Speeches

With `rope_scaling_factor: 6`, we can increase `MAX_TEXT_LENGTH` from 2,000 to **8,000+ characters**:

```python
# In safe_synth.py training config
"training": {
    "pretrained_model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
    "rope_scaling_factor": 6,  # Extend context to ~12K tokens
    "num_input_records_to_sample": "auto",
    "max_vram_fraction": 0.6,
    "batch_size": 1,
    "gradient_accumulation_steps": 8,
}
```

```python
# In synthetic_speeches.py
MAX_TEXT_LENGTH = 8000  # Can now use longer text with RoPE scaling
```

#### Trade-offs

| Aspect | Impact | Mitigation |
|--------|--------|------------|
| **Runtime** | Increases with higher factor | Accept for better quality |
| **Memory** | Higher VRAM usage | Use `max_vram_fraction: 0.5` if needed |
| **Quality** | Better with more text context | Primary benefit |

#### When to Use RoPE Scaling

From NVIDIA documentation:
> "The default context length can handle datasets with roughly 50 columns (less if modeling inter-row correlations). Similarly, the default context length can handle event-driven data with sequences up to roughly 20 rows. **To go beyond that, increase `rope_scaling_factor`.**"

Our speeches dataset has:
- 7 columns (lightweight)
- 1 text column with long content (heavyweight)

The long `text` field is the primary consumer of context window. RoPE scaling is appropriate.

#### Alternative Approaches (If RoPE Increases Runtime Too Much)

1. **Reduce column names**: Shorten `central_bank` → `bank`, `tariff_mention` → `tariff`
2. **Truncate more aggressively**: Use 1,500-2,000 chars if context is tight
3. **Remove columns**: Drop `speech_id` (can regenerate), `title` if redundant with text

### Training Memory Optimization

The issue isn't dataset size but per-record size. Our current settings are correct:

```python
"training": {
    "max_vram_fraction": 0.6,  # Leave room for evaluation
    "batch_size": 1,
    "gradient_accumulation_steps": 8,
}
```

### If Memory Issues Persist

Use `num_input_records_to_sample` to subsample for training (not batching!):

```python
"training": {
    "num_input_records_to_sample": 5000,  # Train on subset
},
"generation": {
    "num_records": 7721,  # Still generate full count
}
```

This is fundamentally different from our batch approach:
- **Subsampling**: Random sample from full distribution, single model
- **Batching**: Disjoint slices, multiple models (wrong!)

---

## 5. Recommended Code Changes

### Option A: Single Synthesis Call (Preferred)

```python
@dg.asset(...)
def synthetic_speeches(
    context: dg.AssetExecutionContext,
    enriched_speeches: pl.DataFrame,
    safe_synth: SafeSynthesizerResource,
) -> tuple[pl.DataFrame, dict[str, Any]]:
    """Generate synthetic twin of the speeches dataset."""
    df = enriched_speeches
    run_id = context.run_id or datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")

    # Prepare data (with truncation)
    synthesis_columns = ["speech_id", "date", "central_bank", "speaker", "title", "text", "tariff_mention"]
    available_columns = [c for c in synthesis_columns if c in df.columns]
    df_for_synthesis = df.select(available_columns)
    data_for_synthesis = df_for_synthesis.to_dicts()

    # Truncate long texts
    MAX_TEXT_LENGTH = 8000
    for record in data_for_synthesis:
        if "text" in record and record["text"] and len(record["text"]) > MAX_TEXT_LENGTH:
            record["text"] = record["text"][:MAX_TEXT_LENGTH] + "..."

    context.log.info(f"Training on {len(data_for_synthesis)} records, generating {len(data_for_synthesis)} synthetic...")

    # SINGLE synthesis call with all data
    synthetic_data, evaluation = safe_synth.synthesize(
        input_data=data_for_synthesis,
        run_id=run_id,
        config={
            "epsilon": 6.0,  # Better epsilon for large dataset
            "piiReplacement": True,
            "runMiaEvaluation": True,
            "runAiaEvaluation": True,
        },
    )

    synthetic_df = pl.DataFrame(synthetic_data)
    # ... rest of processing

    return (synthetic_df, evaluation)
```

### Option B: With Memory-Conscious Subsampling

If the full 7721 records cause memory issues:

```python
# In safe_synth.py - update synth_config
synth_config = {
    "training": {
        "pretrained_model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "num_input_records_to_sample": 5000,  # Subsample for training
        "max_vram_fraction": 0.6,
        "batch_size": 1,
        "gradient_accumulation_steps": 8,
    },
    "generation": {
        "num_records": len(data),  # Generate full dataset
        "temperature": 0.9,
    },
    # ... privacy config
}
```

### Changes to SafeSynthesizerResource

Update [safe_synth.py:637](dagster/src/brev_pipelines/resources/safe_synth.py#L637):

```python
"generation": {
    "num_records": config.get("num_records", len(data)),  # Allow override
    "temperature": config.get("temperature", 0.9),
    "use_structured_generation": True,  # Add for better quality
},
```

---

## 6. Testing Strategy

### Validation Approach

1. **Trial Run First**: Use `full_pipeline_trial_run` (10 records) to verify changes work
2. **Compare Metrics**: MIA/AIA scores should be similar or better than batched approach
3. **Check Quality**: Synthetic data quality score should improve with full-dataset training

### Expected Improvements

| Metric | Batched (Current) | Single Training (Expected) |
|--------|-------------------|---------------------------|
| Training time | 8× model loads | 1× model load |
| Privacy guarantee | Fragmented | Proper DP-SGD |
| Cross-record patterns | Lost | Preserved |
| MIA protection | Per-batch only | Global |

---

## 7. Action Items

### Immediate (Before Next Full Run)

1. [x] **Stop current job** if still running (it's using flawed approach)
2. [x] **Update epsilon** from 1.0 to 6.0 in synthesis config
3. [x] **Remove batch loop** in synthetic_speeches.py
4. [ ] **Test with trial run** (10 records)

### Context Window Enhancement (Implemented)

5. [x] **Add `rope_scaling_factor: 6`** to training config in safe_synth.py
6. [x] **Increase `MAX_TEXT_LENGTH`** from 2000 to 10000 in synthetic_speeches.py
7. [ ] **Test with trial run** to verify extended context works

### Code Changes Required

1. **synthetic_speeches.py**: Remove batch loop, single `synthesize()` call ✅
2. **safe_synth.py**: Add `rope_scaling_factor: 6` to training config ✅
3. **synthetic_speeches.py**: Update `MAX_TEXT_LENGTH = 10000` ✅
4. **jobs.py**: No changes needed (jobs are correct)

### Verification

After implementing changes:
```bash
# Run trial to verify
# In Dagster UI, launch: full_pipeline_trial_run

# Check logs for single training message instead of batch messages
# Verify evaluation metrics are present
```

---

## 8. References

- [NVIDIA Safe Synthesizer - Tabular Fine-Tuning](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/tabular-fine-tuning.html)
- [NVIDIA Safe Synthesizer - Differential Privacy](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/differential-privacy.html)
- [NeMo Safe Synthesizer REST API Reference](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/sdk/high-level-api.html)
- [About Generating Private Synthetic Data](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/index.html)

---

## Appendix: Full Job Configuration Example

From NVIDIA documentation, a complete synthesis job request with RoPE scaling for extended context:

```json
{
  "name": "dagster-synth-full",
  "spec": {
    "data_source": "hf://datasets/default/central-bank-speeches/input.parquet",
    "config": {
      "enable_synthesis": true,
      "enable_replace_pii": true,
      "data": {
        "holdout": 0.05,
        "max_holdout": 500
      },
      "training": {
        "pretrained_model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
        "rope_scaling_factor": 6,
        "num_input_records_to_sample": "auto",
        "max_vram_fraction": 0.6,
        "batch_size": 1,
        "gradient_accumulation_steps": 8
      },
      "generation": {
        "num_records": 7721,
        "temperature": 0.8,
        "use_structured_generation": true
      },
      "privacy": {
        "dp_enabled": true,
        "epsilon": 6.0,
        "delta": "auto"
      },
      "evaluation": {
        "mia_enabled": true,
        "aia_enabled": true,
        "sqs_report_rows": 1000
      }
    }
  }
}
```

### Key Parameters Explained

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `rope_scaling_factor` | 6 | Extends context from 2K to ~12K tokens |
| `epsilon` | 6.0 | Balanced privacy for large datasets |
| `num_input_records_to_sample` | "auto" | Use all training data |
| `max_vram_fraction` | 0.6 | Leave GPU memory for evaluation |
| `use_structured_generation` | true | Better JSON/tabular output quality |
