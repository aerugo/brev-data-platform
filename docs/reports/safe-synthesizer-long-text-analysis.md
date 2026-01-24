# Enabling Long Text Generation in NVIDIA Safe Synthesizer

**Date:** 2026-01-24
**Author:** Claude (AI Assistant)
**Status:** Research Complete - Action Items Pending

## Executive Summary

Our goal is to generate synthetic central bank speeches with **10,000+ character** text fields. Current attempts fail because:

1. **vLLM generation uses 2048 token context** regardless of `rope_scaling_factor` in training config
2. **Generation prompts include multiple example rows**, multiplying context usage
3. The `rope_scaling_factor` parameter only applies to training, not the vLLM inference engine

This report analyzes all options for enabling longer text generation.

---

## 1. Understanding the Training Architecture

### How Safe Synthesizer Training Works

A critical question: **Does switching the pretrained model mean we lose fine-tuning on our data?**

**Answer: No.** Safe Synthesizer uses **LoRA (Low-Rank Adaptation)** fine-tuning, which works as follows:

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRAINING PHASE                               │
│                                                                 │
│   ┌─────────────────────┐     ┌─────────────────────┐          │
│   │   PRETRAINED MODEL  │     │   LoRA ADAPTERS     │          │
│   │   (e.g., TinyLlama) │     │   (Trained on YOUR  │          │
│   │                     │     │    data)            │          │
│   │   Weights: FROZEN   │  +  │   Weights: LEARNED  │          │
│   │   (not updated)     │     │   (updated via SGD) │          │
│   └─────────────────────┘     └─────────────────────┘          │
│            │                           │                        │
│            └───────────┬───────────────┘                        │
│                        ▼                                        │
│              ┌─────────────────────┐                           │
│              │   FINE-TUNED MODEL  │                           │
│              │   Pretrained +      │                           │
│              │   LoRA adapters     │                           │
│              │   (learns YOUR data)│                           │
│              └─────────────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

### Key Components

| Component | Role | Updated During Training? |
|-----------|------|-------------------------|
| **Pretrained Model** | Base language understanding, context window | ❌ Frozen |
| **LoRA Adapters** | Learn patterns specific to YOUR dataset | ✅ Trained |
| **DP-SGD** | Adds differential privacy noise during training | N/A |

### LoRA Parameters in Safe Synthesizer

From the [training configuration](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/configuration/training-config.html):

```python
"training": {
    "lora_r": 32,              # LoRA rank (complexity)
    "lora_alpha_over_r": 1.0,  # Scaling factor
    # Target modules: query, key, value projections
}
```

- **Higher `lora_r`** = More trainable parameters = Better expressiveness
- **LoRA inserts low-rank matrices** into each layer's attention mechanisms
- **Only these matrices are trained** on your data; base model weights stay frozen

### What This Means for Model Switching

When you change `pretrained_model` from `TinyLlama/TinyLlama-1.1B-Chat-v1.0` to `Qwen/Qwen2.5-1.5B-Instruct`:

| Aspect | What Happens |
|--------|--------------|
| **Base Language Capability** | Changes to Qwen's (potentially better) |
| **Context Window** | Changes from 2K → 32K tokens |
| **Training on YOUR Data** | ✅ **Still happens!** LoRA adapters trained on your speeches |
| **Pattern Learning** | ✅ Model still learns correlations, distributions from your data |
| **Privacy (DP-SGD)** | ✅ Still applied during training |

### Evidence from Documentation

From [NVIDIA's Tabular Fine-Tuning docs](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/tabular-fine-tuning.html):

> "Tabular Fine-Tuning is an AI system combining a Large-Language Model pre-trained specifically on tabular datasets with **learned schema based rules**."

> "The technology **excels at matching the correlations and distributions in its training data** across multiple tabular modalities."

This confirms:
1. The base model is pre-trained (the `pretrained_model` parameter)
2. The system **learns from your specific dataset** (LoRA fine-tuning)
3. Patterns and correlations from YOUR data are captured

### Why Switching Models Preserves Data Specificity

```
CURRENT:
  TinyLlama (2K context) + LoRA trained on speeches = Fails (context too small)

PROPOSED:
  Qwen2.5 (32K context) + LoRA trained on speeches = Should work!
                          ↑
                    Same training process,
                    same data patterns learned
```

The pretrained model provides:
- **Foundation**: General language understanding, tokenization, attention patterns
- **Context Window**: How many tokens can be processed at once

LoRA training provides:
- **Specialization**: Patterns specific to central bank speeches
- **Privacy**: DP-SGD noise ensures synthetic data doesn't leak training data
- **Quality**: Statistical fidelity to your dataset's distributions

### Memory and Efficiency Benefits

From [NVIDIA's documentation on LoRA](https://docs.nvidia.com/nim/large-language-models/latest/peft.html):

> "Parameter-efficient fine-tuning works by freezing most pretrained model parameters while training small additional components. The approach **reduces memory requirements by 10-20x** compared to full fine-tuning while retaining **90-95% of quality**."

This is why Safe Synthesizer can fine-tune on a single GPU:
- Full TinyLlama fine-tuning: ~6 GB VRAM
- LoRA fine-tuning: ~1 GB additional VRAM for adapters
- Full Qwen2.5-1.5B fine-tuning: ~8 GB VRAM
- LoRA fine-tuning: ~1.5 GB additional VRAM for adapters

### Summary: Safe Synthesizer Training Flow

```
1. Load pretrained model (TinyLlama or Qwen2.5 or Phi-3)
2. Initialize LoRA adapter matrices (small, trainable)
3. Freeze pretrained model weights
4. Train LoRA adapters on YOUR tabular data:
   a. Convert records to text sequences
   b. Apply DP-SGD for privacy
   c. Update only LoRA weights
5. Save fine-tuned model (base + adapters)
6. Use for generation with vLLM
```

**Conclusion**: Switching `pretrained_model` to Qwen2.5-1.5B does NOT lose training specificity. The LoRA adapters will still be trained on your central bank speeches data. The only difference is the base model's context window and language capabilities.

---

## 2. The Problem

### Current Architecture

Safe Synthesizer uses a two-phase process:

```
┌─────────────────┐     ┌─────────────────┐
│   TRAINING      │     │   GENERATION    │
│                 │     │                 │
│ TinyLlama 1.1B  │────▶│ vLLM Engine     │
│ + LoRA + RoPE   │     │ max_seq_len=2048│
│                 │     │                 │
└─────────────────┘     └─────────────────┘
       ✓                       ✗
  RoPE scaling            NO RoPE scaling
    applied                  applied
```

### Evidence from Logs

Training config shows `rope_scaling_factor: 6`:
```json
"training": {
  "rope_scaling_factor": 6,
  "pretrained_model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0"
}
```

But vLLM initialization shows:
```
INFO [core.py:93] Initializing a V1 LLM engine with config:
  model='TinyLlama/TinyLlama-1.1B-Chat-v1.0'
  max_seq_len=2048  ← NOT 12K with RoPE!
```

### Generation Prompt Structure

Safe Synthesizer generation prompts include **multiple example rows**:

```
[Schema description]
[Column: speech_id, date, central_bank, speaker, title, text, tariff_mention]

[Example Row 1]: {"speech_id": "...", "text": "1500 chars...", ...}
[Example Row 2]: {"speech_id": "...", "text": "1500 chars...", ...}
[Example Row 3]: {"speech_id": "...", "text": "1500 chars...", ...}

[Generate Row]: {"speech_id": "...", "text": "
```

With 3-5 example rows plus output, even 1500 chars/row exceeds 2048 tokens.

---

## 3. Options Analysis

### Option A: Alternative Model with Larger Context (Recommended)

Replace TinyLlama (2K context) with a model that has a larger native context window:

| Model | Parameters | Native Context | VRAM Required | Notes |
|-------|------------|----------------|---------------|-------|
| **TinyLlama-1.1B** | 1.1B | 2,048 | ~3 GB | Current default |
| **Qwen2.5-1.5B-Instruct** | 1.5B | **32,768** | ~4 GB | 16x larger context |
| **Phi-3-mini-4k** | 3.8B | 4,096 | ~8 GB | 2x context |
| **Phi-3-mini-128k** | 3.8B | **131,072** | ~8 GB | 64x context! |
| **Qwen2.5-3B-Instruct** | 3B | **32,768** | ~7 GB | Good balance |

**Recommendation**: Try `Qwen/Qwen2.5-1.5B-Instruct` - similar size to TinyLlama but 16x larger context.

**Implementation**:
```python
# In safe_synth.py
"training": {
    "pretrained_model": "Qwen/Qwen2.5-1.5B-Instruct",
    # No need for rope_scaling_factor with 32K native context
    "num_input_records_to_sample": "auto",
    "max_vram_fraction": 0.6,
}
```

**Unknown**: Whether Safe Synthesizer supports models other than TinyLlama. Testing required.

---

### Option B: Configure vLLM Generation with RoPE Scaling

The vLLM engine supports `--rope-scaling` at startup:

```bash
vllm serve TinyLlama/TinyLlama-1.1B-Chat-v1.0 \
  --rope-scaling '{"type": "dynamic", "factor": 6.0}' \
  --max-model-len 12288
```

**Problem**: Safe Synthesizer doesn't expose this configuration. The vLLM engine is started internally without passing `rope_scaling`.

**Potential Solutions**:

1. **Environment Variable**: Check if `VLLM_ROPE_SCALING` or similar env var is supported
2. **Safe Synthesizer Config**: Look for `generation.vllm_config` or similar
3. **Helm Values Override**: Modify Safe Synthesizer deployment to pass vLLM args
4. **Feature Request**: Ask NVIDIA to pass `rope_scaling_factor` to vLLM generation

**Status**: No known configuration option exists. Feature request to NVIDIA needed.

---

### Option C: Reduce Data Complexity

If longer context isn't achievable, optimize what fits in 2048 tokens:

| Optimization | Impact | Trade-off |
|-------------|--------|-----------|
| **Shorter column names** | ~50 tokens saved | Minor code change |
| **Remove redundant columns** | ~100 tokens saved | Less data fidelity |
| **Aggressive text truncation** | Fits in context | Loss of speech content |
| **Summarize text before synthesis** | Semantic preservation | Extra processing step |

**Column Name Optimization**:
```python
# Before
synthesis_columns = ["speech_id", "date", "central_bank", "speaker", "title", "text", "tariff_mention"]

# After
synthesis_columns = ["id", "dt", "bank", "spkr", "ttl", "txt", "tariff"]
```

Saves ~50 tokens per row, but requires mapping back after generation.

**Text Summarization Approach**:
```python
# Pre-process: summarize speeches before synthesis
for record in data:
    if len(record["text"]) > 1500:
        record["text_summary"] = summarize(record["text"])[:1500]
        record["full_text_length"] = len(record["text"])
```

This preserves semantic content but loses verbatim text.

---

### Option D: Two-Stage Generation

Generate short synthetic records, then expand them:

**Stage 1**: Generate synthetic metadata + short text excerpts
```python
MAX_TEXT_LENGTH = 500  # Very short
synthetic_records = safe_synth.synthesize(data, config={...})
```

**Stage 2**: Expand text using separate LLM
```python
for record in synthetic_records:
    expanded_text = llm.expand(
        record["text"],
        style=record["central_bank"],
        topic=record["title"]
    )
    record["text"] = expanded_text
```

**Pros**: Works within current constraints
**Cons**: Requires additional LLM infrastructure, may lose statistical fidelity

---

### Option E: Contact NVIDIA Support

File a bug report or feature request:

**Issue**: `rope_scaling_factor` not applied to vLLM generation engine

**Request**:
1. Apply RoPE scaling consistently to training AND generation
2. Or expose `generation.vllm_config` for custom vLLM settings
3. Or document which models are supported for larger context

**NVIDIA Support**: https://developer.nvidia.com/support

---

## 4. Testing Matrix

To validate options, test with these configurations:

| Test | Model | MAX_TEXT_LENGTH | rope_scaling | Expected |
|------|-------|-----------------|--------------|----------|
| T1 | TinyLlama | 1500 | 6 | Baseline (may work) |
| T2 | TinyLlama | 1000 | 6 | Should work |
| T3 | Qwen2.5-1.5B | 8000 | N/A | **Target test** |
| T4 | Phi-3-mini-4k | 3000 | N/A | Medium context |

---

## 5. Recommended Action Plan

### Immediate (Today)

1. **Reduce MAX_TEXT_LENGTH to 1000 chars** - Ensure baseline works
2. **Shorten column names** - Save tokens per row
3. **Remove non-essential columns** - e.g., drop `speech_id` (regenerate after)

### Short-term (This Week)

4. **Test Qwen2.5-1.5B-Instruct model** - Change `pretrained_model` and test
5. **Test Phi-3-mini-4k-instruct model** - Alternative with 4K context
6. **Document what works** - Update best practices

### Medium-term

7. **File NVIDIA feature request** - For vLLM RoPE scaling propagation
8. **Implement text summarization fallback** - For speeches that exceed limits
9. **Evaluate two-stage generation** - If model changes don't work

---

## 6. Code Changes for Testing

### Test 1: Aggressive Truncation + Short Column Names

```python
# In synthetic_speeches.py

# Use shorter column names
COLUMN_MAP = {
    "speech_id": "id",
    "date": "dt",
    "central_bank": "bank",
    "speaker": "spkr",
    "title": "ttl",
    "text": "txt",
    "tariff_mention": "tariff",
}

# Truncate to 1000 chars
MAX_TEXT_LENGTH = 1000

# Rename columns before synthesis
df_for_synthesis = df.rename(COLUMN_MAP)
```

### Test 2: Alternative Model

```python
# In safe_synth.py

"training": {
    "pretrained_model": "Qwen/Qwen2.5-1.5B-Instruct",  # 32K context
    "num_input_records_to_sample": "auto",
    "max_vram_fraction": 0.5,  # May need more VRAM
    "batch_size": 1,
    "gradient_accumulation_steps": 8,
}
```

---

## 7. Key Findings Summary

| Finding | Impact | Solution Status |
|---------|--------|-----------------|
| `rope_scaling_factor` ignored by vLLM | Critical | Unsolved - NVIDIA issue |
| Multiple rows in generation prompt | Critical | Reduce text length |
| TinyLlama has 2048 native context | Architectural | Switch models |
| Qwen2.5-1.5B has 32K context | Potential solution | Testing required |
| Safe Synthesizer model support unclear | Blocker for Option A | Testing required |

---

## 8. References

- [NVIDIA Safe Synthesizer - Tabular Fine-Tuning](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/synthesize/tabular-fine-tuning.html)
- [vLLM Engine Arguments - rope-scaling](https://docs.vllm.ai/en/latest/configuration/engine_args.html)
- [Qwen2.5-1.5B-Instruct on HuggingFace](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct)
- [Phi-3-mini-128k-instruct on HuggingFace](https://huggingface.co/microsoft/Phi-3-mini-128k-instruct)
- [TinyLlama GitHub](https://github.com/jzhang38/TinyLlama)
- [vLLM RoPE Scaling Issue #10537](https://github.com/vllm-project/vllm/issues/10537)
- [NVIDIA NIM Parameter-Efficient Fine-Tuning (PEFT)](https://docs.nvidia.com/nim/large-language-models/latest/peft.html)
- [NeMo Safe Synthesizer REST API Reference](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/sdk/high-level-api.html)
- [Safe Synthesizer Training Configuration](https://docs.nvidia.com/nemo/microservices/latest/generate-private-synthetic-data/configuration/training-config.html)

---

## Appendix A: Model Context Window Comparison

```
TinyLlama-1.1B:     ████ 2K tokens
Phi-3-mini-4k:      ████████ 4K tokens
Qwen2.5-1.5B:       ████████████████████████████████████████████████ 32K tokens
Phi-3-mini-128k:    ████████████████████████████████████████████████████████████████ 128K tokens
```

For 10,000 character speeches (~2,500 tokens), we need at least:
- 2,500 tokens × 4 example rows = 10,000 tokens minimum
- Plus schema overhead ~500 tokens
- **Total needed: ~10,500 tokens**

**Conclusion**: TinyLlama (2K) and Phi-3-mini-4k (4K) are insufficient. Need Qwen2.5 (32K) or Phi-3-128k.

---

## Appendix B: Error Log Analysis

### Error 1: Invalid JSON (0% valid)
```
Number of valid records generated: 0
Percentage of records that are valid: 0.00%
Error Category: Invalid JSON 100.0%
```
**Cause**: Text truncated mid-generation due to context overflow.

### Error 2: CUDA OOM during training
```
RuntimeError: CUDA error: CUBLAS_STATUS_ALLOC_FAILED
```
**Cause**: Model + optimizer + gradients exceed GPU memory. Need to reduce `max_vram_fraction`.

### Error 3: Model underfitting
```
Stopping generation prematurely. No valid records were generated due to model underfitting.
```
**Cause**: Training succeeded but generation failed. Mismatch between training and generation context.
