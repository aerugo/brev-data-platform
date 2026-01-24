# NVIDIA Safe Synthesizer Documentation Notes

**Date:** 2026-01-24
**Source:** NVIDIA NeMo Microservices Documentation (v25.12.0)
**Status:** Early Access Release

## 1. Overview and Purpose

### What is Safe Synthesizer?

NVIDIA NeMo Safe Synthesizer creates **private versions of sensitive tabular datasets** where the resulting data is entirely synthetic with no one-to-one mapping to original records. It addresses privacy compliance and data protection while maintaining data utility for AI applications.

**Key Distinction from Data Designer:**
- **Safe Synthesizer**: Use when you have the data you need, but it's private/sensitive. Interpolates from existing data.
- **Data Designer**: Use when generating from scratch or minimal seed data.

### Complete Job Workflow

The service operates through four sequential phases:

1. **Data Upload** - Add tabular data to NeMo Data Store
2. **Data Preparation** - Configure PII replacement and training organization (grouping, ordering, holdout)
3. **Synthesis Configuration** - Set training parameters, generation settings, and evaluation metrics
4. **Execution & Review** - Monitor job progress and retrieve synthetic data with evaluation reports

---

## 2. Core Technology: Tabular Fine-Tuning

### How It Works

Safe Synthesizer combines a Large Language Model pre-trained on tabular datasets with learned schema-based rules:

1. Converts structured data into text sequences
2. Fine-tunes the model on these sequences using LoRA adapters
3. Generates new structured data from the trained model

### Model Capabilities

The model excels at matching:
- Correlations within individual records
- Cross-record correlations
- Distributions across training data
- Multiple tabular data types simultaneously

### Recommended Dataset Requirements

| Requirement | Value |
|-------------|-------|
| Minimum records | 1,000+ |
| Optimal for DP | 10,000+ |
| Maximum columns (default context) | ~50 |
| Maximum rows per sequence (event-driven) | ~20 |

### Known Limitations

1. **Context Window**: Default model handles ~50 columns. With inter-row correlations, fewer. Event-driven sequences: ~20 rows per sequence.

2. **Column Persistence**: Mappings from training may persist but offer no guarantees. Use pre/post-processing for required correlations.

3. **Content Safety**: LLMs may generate untrue or offensive content. Human curation before release is recommended.

---

## 3. PII Replacement System

### Detection Methods

Safe Synthesizer uses three detection methods in parallel:

1. **Named Entity Recognition (NER)**
   - Transformer-based contextual recognition
   - Best for unstructured text (emails, documents, chat logs)
   - GPU-accelerated, context-aware
   - Configurable confidence threshold (default: 0.3)

2. **Regex Detection**
   - Pattern-matching for structured identifiers
   - High-precision, fast-processing, low-memory
   - Good for SSN, phone numbers, credit cards

3. **LLM Column Classification**
   - AI-powered column type analysis
   - Uses sample-based approach
   - Classifies entire columns by entity type

### Transformation Methods

| Method | Description | Example |
|--------|-------------|---------|
| `fake` | Synthetic replacement | "Sally" → "Lucy" |
| `redact` | Entity type masking | "Sally" → "<first_name>" |
| `label` | Redaction with value retention | For audit trails |
| `hash` | Alphanumeric anonymization | "Sally" → "a75e4r" |

### Supported Entity Types

**True Identifiers (50+ types):**
- Names, addresses, contact details
- SSN, medical records, financial accounts
- Government IDs, device/biometric identifiers
- URLs, IP addresses, credentials

**Quasi-identifiers:**
- Dates, blood type, gender, sexuality
- Political views, race, ethnicity, religion
- Language, education, job title
- Employment status, company information

### Best Practice

> "It is generally best practice to redact and replace any PII **prior to** synthesizing your data."

---

## 4. Differential Privacy (DP)

### Mathematical Guarantee

DP provides mathematical guarantees protecting individual records:

**P[M(D1) ∈ S] ≤ exp(ε) × P[M(D2) ∈ S] + δ**

Where:
- `ε` (epsilon) = privacy budget (lower = stronger privacy)
- `δ` (delta) = failure probability
- D1, D2 = neighboring datasets differing by one record

### DP-SGD Implementation

Safe Synthesizer modifies training through:

1. **Per-sample gradient computation** for each mini-batch item
2. **Gradient clipping** to maximum L2 norm
3. **Gaussian noise injection** into aggregated gradients
4. **Privacy accounting** using Rényi Differential Privacy

### Configuration Parameters

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `dp` | bool | False | Enable/disable DP |
| `epsilon` | float | 8.0 | Privacy budget |
| `delta` | float/"auto" | "auto" | Failure probability |
| `per_sample_max_grad_norm` | float | 1.0 | Gradient clipping threshold |

### Epsilon Selection Guidelines

| Epsilon | Privacy Level | Quality Impact | Use Case |
|---------|--------------|----------------|----------|
| 1.0-4.0 | Very strong | High noise | Highly sensitive PII |
| 4.0-8.0 | Strong | Moderate noise | Financial/medical |
| 8.0-12.0 | Moderate | Low noise | Less sensitive data |

### Trade-offs

- **Quality Impact**: Lower epsilon → more noise → reduced synthetic data quality
- **Performance Cost**: DP training operates 2-3x slower than standard training
- **Data Size**: Benefits from larger datasets (10,000+ records recommended)

### Best Practices

- Start with epsilon 8-12, decrease based on sensitivity
- Use automatic delta calculation (`delta = 1/n^1.2`)
- Use larger batch sizes (reduces noise variance)
- Monitor training/validation loss convergence

---

## 5. Configuration Reference

### Data Preparation Config

| Parameter | Type | Default | Purpose |
|-----------|------|---------|---------|
| `group_training_examples_by` | str/None | None | Group related records |
| `order_training_examples_by` | str/None | None | Order within groups |
| `max_sequences_per_example` | int/"auto"/None | "auto" | Limit sequences per example |
| `holdout` | float/int | 0.05 | Evaluation data fraction |
| `max_holdout` | int | 2000 | Maximum holdout records |
| `random_state` | int/None | Auto | Reproducibility seed |

**Use Cases:**
- Grouping: Event-driven or multi-record-per-entity datasets
- Ordering: Temporal dependencies (e.g., customer transactions)
- Holdout: For datasets <500 records, consider disabling

### Training Config

#### Core Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `pretrained_model` | "TinyLlama/TinyLlama-1.1B-Chat-v1.0" | Base model |
| `num_input_records_to_sample` | "auto" | Training data volume |
| `batch_size` | 1 | Per-device batch size |
| `gradient_accumulation_steps` | 8 | Steps before gradient update |
| `rope_scaling_factor` | "auto" | Context window extension (1-6) |

#### Learning Parameters

| Parameter | Default | Range |
|-----------|---------|-------|
| `learning_rate` | 0.0005 | 0 < value < 1 |
| `weight_decay` | 0.01 | 0 < value < 1 |
| `warmup_ratio` | 0.05 | > 0 |
| `lr_scheduler` | "cosine" | cosine/linear/polynomial/constant |

#### LoRA Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `lora_r` | 32 | LoRA rank |
| `lora_alpha_over_r` | 1.0 | Scaling factor |
| `use_rslora` | True | Use Rank-Stabilized LoRA |
| `lora_target_modules` | attention-only | Which layers to adapt |
| `use_unsloth` | True | Enable 2-5x speedup (incompatible with DP) |

### Generation Config

| Parameter | Type | Default | Valid Range |
|-----------|------|---------|-------------|
| `num_records` | int | 1000 | 0 < value ≤ 130,000 |
| `temperature` | float | 0.9 | > 0 |
| `repetition_penalty` | float | 1.0 | ≥ 1.0 |
| `top_p` | float | 1.0 | 0 < value ≤ 1 |
| `patience` | int | 1 | ≥ 1 |
| `invalid_fraction_threshold` | float | 0.8 | 0.0-1.0 |
| `use_structured_generation` | bool | False | True/False |

**Note:** Maximum 130,000 records per generation job. For larger datasets, use batch processing via REST API.

### Evaluation Config

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `enabled` | True | Toggle evaluation |
| `mia_enabled` | True | Membership Inference Attack test |
| `aia_enabled` | True | Attribute Inference Attack test |
| `sqs_report_columns` | 250 | Columns in quality reports |
| `sqs_report_rows` | 5000 | Rows in quality reports |
| `pii_replay_enabled` | True | Track PII in output |
| `quasi_identifier_count` | 3 | QI count for AIA testing |

---

## 6. Evaluation Reports

### Executive Summary Metrics

Two composite scores (0-10 scale):
- **Synthetic Quality Score (SQS)**: Measures data utility preservation
- **Data Privacy Score (DPS)**: Indicates privacy protection level

### SQS Components

1. **Column Correlation Stability** - Compares correlation matrices between original and synthetic data

2. **Deep Structure Stability** - Uses PCA to verify multi-field distributions; compares Jensen-Shannon distance

3. **Column Distribution Stability** - Jensen-Shannon Distance for field distributions

4. **Text Structure Similarity** - Sentence, word, character count divergence

5. **Text Semantic Similarity** - Cosine similarity between sentence embeddings (5% holdout prevents replay)

### DPS Components

1. **Membership Inference Protection** - 360 simulated attacks testing if samples were in training set

2. **Attribute Inference Protection** - Measures resistance to predicting sensitive attributes

3. **PII Replay Analysis** - Tracks original PII appearing in synthetic output

### Privacy Enhancement Recommendations

To increase DPS:
- Reduce model epochs (underfit intentionally)
- Apply Differential Privacy with lower epsilon
- Increase training dataset size

---

## 7. Python SDK Usage

### Client Initialization

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(base_url="http://localhost:8080")

# DataStore for data upload
datastore_config = {
    "endpoint": "http://localhost:3000/v1/hf",
}
```

### Builder Pattern (High-Level API)

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(base_url="http://localhost:8080")

# Simple synthesis with DataFrame
job = client.beta.safe_synthesizer.SafeSynthesizerJobBuilder() \
    .data_source(df, datastore_config) \
    .replace_pii() \
    .synthesize(num_records=1000) \
    .build_and_start()

# Wait for completion
job.wait()

# Retrieve results
synthetic_df = job.fetch_data()
job.save_report("report.html")
```

### REST API (Low-Level)

```python
# Create job
job = client.beta.safe_synthesizer.jobs.create(
    name="my-synthesis-job",
    project="default",
    spec={
        "data_source": "hf://datasets/default/my-data/input.csv",
        "config": {
            "enable_synthesis": True,
            "enable_replace_pii": True,
            "training": {...},
            "generation": {...},
            "privacy": {...},
            "evaluation": {...}
        }
    }
)

# Monitor status
while True:
    status = client.beta.safe_synthesizer.jobs.get_status(job.id)
    if status in ("completed", "error", "cancelled"):
        break
    time.sleep(30)

# List and download results
results = client.beta.safe_synthesizer.jobs.results.list(job.id)
for result in results.data:
    content = client.beta.safe_synthesizer.jobs.results.download(
        result.id, job.id
    )
```

### Job Status Values

| Status | Description |
|--------|-------------|
| `created` | Initial state after creation |
| `pending` | Awaiting resource allocation |
| `active` | Currently processing |
| `completed` | Successfully finished |
| `error` | Processing failed |
| `cancelled` | User terminated |
| `cancelling` | Termination in progress |
| `paused` | Execution suspended |
| `pausing`/`resuming` | Transition states |

---

## 8. Industry-Specific Configurations

### GDPR Compliance

```python
config = {
    "replace_pii": {
        "locales": ["en_GB", "de_DE", "fr_FR"],
        "ner_threshold": 0.9,  # High confidence
        "entities": ["name", "email", "phone", "address", "iban"],
    },
    "privacy": {
        "dp": True,
        "epsilon": 2.0,  # Strong privacy
        "delta": 1e-6,
    }
}
```

### HIPAA Healthcare

```python
config = {
    "replace_pii": {
        "ner_threshold": 0.95,  # Very high confidence for PHI
        "entities": ["medical_record_number", "ssn", "date_of_birth"],
    },
    "privacy": {
        "dp": True,
        "epsilon": 1.0,  # Very strong privacy
        "delta": 1e-7,
    },
    "generation": {
        "temperature": 0.6,  # Lower for consistency
    }
}
```

### Financial Services

```python
config = {
    "data": {
        "group_training_examples_by": "account_type",
        "order_training_examples_by": "transaction_date",
    },
    "replace_pii": {
        "entities": ["account_number", "routing_number", "credit_card", "ssn"],
    },
    "privacy": {
        "dp": True,
        "epsilon": 4.0,
    },
    "generation": {
        "num_records": 50000,
        "use_structured_generation": True,
    }
}
```

---

## 9. Job Management Operations

### Create Job

```python
job = client.beta.safe_synthesizer.jobs.create(
    name="synthesis-job",
    project="default",
    spec={...}
)
```

### Monitor Status

```python
status = client.beta.safe_synthesizer.jobs.get_status(job_id)
```

### Retrieve Logs

```python
logs = client.beta.safe_synthesizer.jobs.logs(job_id)
for entry in logs.data:
    print(f"[{entry.timestamp}] {entry.job_step}: {entry.message}")
```

### Cancel Job

```python
if status in ("active", "created", "pending"):
    client.beta.safe_synthesizer.jobs.cancel(job_id)
```

### List Jobs

```python
jobs = client.beta.safe_synthesizer.jobs.list()
for job in jobs.data:
    print(f"{job.id}: {job.name} - {job.status}")
```

### Delete Job

```python
# Only for completed/failed jobs
client.beta.safe_synthesizer.jobs.delete(job_id)
```

### Retrieve Results

```python
# List available results
results = client.beta.safe_synthesizer.jobs.results.list(job_id)

# Download specific result
for result in results.data:
    content = client.beta.safe_synthesizer.jobs.results.download(
        result.id, job_id
    )
    if result.format == "csv":
        # Save synthetic data
        with open("synthetic.csv", "wb") as f:
            f.write(content)
    elif result.format == "html":
        # Save evaluation report
        with open("report.html", "wb") as f:
            f.write(content)
```

---

## 10. Troubleshooting

### Common Issues

#### Context Window Exceeded

**Symptoms:** Job fails before fine-tuning begins.

**Solutions:**
1. Increase `rope_scaling_factor` (1-6, max 6)
2. Reduce sequence row counts to 8-10 max
3. Trim columns to ~20, prioritize removing long-text fields
4. Remove uncorrelated columns

#### Dataset Too Small

**Error:** "Dataset must have at least 200 records to use holdout"

**Solutions:**
- Disable holdout: `holdout: 0`
- Expand dataset

#### Model Underfitting

**Symptoms:** 0% valid records generated.

**Root Causes:**
- Context window too small for prompts
- Temperature too low
- Training data too limited

**Solutions:**
- Use `rope_scaling_factor: 6`
- Truncate text fields
- Increase training records
- Adjust temperature (0.8-1.0)

#### Memory Issues

**Solutions:**
- Set `batch_size: 1`
- Increase `gradient_accumulation_steps`
- Reduce `lora_r`
- Enable `use_unsloth`
- Lower `max_vram_fraction`

### Performance Optimization

#### Speed Optimization

- Enable `use_unsloth` (2-5x speedup, incompatible with DP)
- Increase `batch_size` if memory allows
- Lower `lora_r` (32 → 16)
- Minimize `lora_target_modules`

#### Quality Optimization

- Increase `lora_r` (32 → 64)
- Expand `lora_target_modules` to include MLP
- Raise `num_input_records_to_sample`
- Reduce `learning_rate` for stability

---

## 11. Integration with Our Stack

### With Dagster

Safe Synthesizer integrates via the `SafeSynthesizerResource`:

```python
from dagster import asset, ConfigurableResource
from pydantic import Field

class SafeSynthesizerResource(ConfigurableResource):
    endpoint: str = Field(default="http://safe-synthesizer.nvidia-nim.svc.cluster.local:8080")
    datastore_endpoint: str = Field(default="http://safe-synthesizer.nvidia-nim.svc.cluster.local:3000/v1/hf")

    def synthesize(
        self,
        input_data: list[dict],
        run_id: str,
        config: dict,
    ) -> tuple[list[dict], dict]:
        # Implementation using NeMoMicroservices client
        ...

@asset(group_name="synthetic")
def synthetic_data(
    context: AssetExecutionContext,
    source_data: pl.DataFrame,
    safe_synth: SafeSynthesizerResource,
) -> pl.DataFrame:
    synthetic, evaluation = safe_synth.synthesize(
        input_data=source_data.to_dicts(),
        run_id=context.run_id,
        config={...},
    )
    return pl.DataFrame(synthetic)
```

### With LakeFS

Store synthetic data as versioned parquet files:

```python
# Write synthetic data to LakeFS branch
lakefs_client.objects.upload(
    repository="main-repo",
    branch="main",
    path="synthetic/speeches.parquet",
    content=synthetic_df.to_parquet(),
)

# Commit with metadata
lakefs_client.commits.commit(
    repository="main-repo",
    branch="main",
    commit_creation=CommitCreation(
        message="Add synthetic speeches dataset",
        metadata={
            "job_id": job.id,
            "epsilon": "6.0",
            "sqs_score": str(evaluation["sqs"]),
            "dps_score": str(evaluation["dps"]),
        }
    ),
)
```

---

## 12. Key Takeaways

### Critical Points

1. **Train Once, Generate Many** - Never batch training. Single model on full dataset, generate any number of records.

2. **Context Window is Critical** - Default is 2048 tokens. Use `rope_scaling_factor` up to 6 for longer text.

3. **PII Before Synthesis** - Replace PII before training for best privacy.

4. **Epsilon Selection Matters** - 4.0-8.0 for most use cases. Lower for highly sensitive data.

5. **Evaluation is Automatic** - SQS and DPS scores generated with every job.

### Production Checklist

- [ ] Dataset has 1000+ records (10000+ for DP)
- [ ] PII replacement configured
- [ ] Epsilon selected based on sensitivity
- [ ] Context window sufficient for data (`rope_scaling_factor`)
- [ ] Structured generation enabled for tabular output
- [ ] Evaluation metrics reviewed
- [ ] Results versioned in LakeFS