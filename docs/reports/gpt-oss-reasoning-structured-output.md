# GPT-OSS-120B: Reasoning Tokens and Structured Output Analysis

**Date:** 2026-01-27
**Context:** NVIDIA NIM Reasoning Model Integration
**Status:** Research Complete

## Executive Summary

This report documents the research findings and solutions for two issues with GPT-OSS-120B:

1. **Reasoning tokens appearing in content**: The model's chain-of-thought reasoning is appearing in the main content response instead of being properly separated
2. **Structured output not working**: When using `json_schema` response format, the model produces malformed output

### Root Causes

| Issue | Root Cause | Solution |
|-------|------------|----------|
| Reasoning in content | Harmony format parser not properly separating `analysis` channel from `final` channel | Use `include_reasoning: false` or parse channels client-side |
| Structured output failing | vLLM bug: structured generation conflicts with reasoning parser state machine | Use `json_object` mode instead of `json_schema` strict mode |

---

## 1. GPT-OSS Architecture Overview

### 1.1 Model Characteristics

GPT-OSS-120B is OpenAI's open-weight reasoning model:

| Attribute | Value |
|-----------|-------|
| Total Parameters | 117B |
| Active Parameters | ~5.1B (MoE) |
| Context Window | 128K tokens |
| Quantization | MXFP4 |
| VRAM Required | ~80GB |
| Response Format | Harmony |

### 1.2 The Harmony Response Format

GPT-OSS uses the **Harmony response format**, which is fundamentally different from ChatML used by other models. Harmony supports multi-channel output:

```
┌─────────────────────────────────────────────────────────────┐
│                    Harmony Format                            │
├─────────────────────────────────────────────────────────────┤
│  <|start|>assistant<|channel|>analysis<|message|>           │
│     [Chain-of-thought reasoning here...]                    │
│  <|end|>                                                    │
│                                                              │
│  <|start|>assistant<|channel|>final<|message|>              │
│     [Final response here...]                                │
│  <|return|>                                                  │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Channel Types

| Channel | Purpose | Visibility |
|---------|---------|------------|
| `analysis` | Chain-of-thought reasoning | Internal (should not be shown to users) |
| `final` | User-facing response | External |
| `commentary` | Tool calls and function invocations | Internal |

---

## 2. Problem Analysis

### 2.1 Issue: Reasoning Tokens in Content

**Symptom:** The model's reasoning appears before or within the main response content.

**Root Cause:** The NIM's vLLM-based parser is not correctly separating the `analysis` channel from the `final` channel. This is a [documented issue](https://forums.developer.nvidia.com/t/model-returns-return-and-missing-reasoning-content-with-openai-gpt-oss-120b/346808) where:

1. The `<|return|>` control token leaks into the visible content
2. The `reasoning_content` field is missing from the response
3. Analysis channel content is concatenated with final channel content

**Evidence from experiments:**

```json
// Expected (OpenRouter with Groq provider)
{
  "content": "{\"monetary_stance\":\"hawkish\"}",
  "reasoning": "The Fed raising rates is hawkish...",
  "reasoning_details": [...]
}

// Actual (some NIM deployments)
{
  "content": "The Fed raising rates is hawkish...\n{\"monetary_stance\":\"hawkish\"}<|return|>"
}
```

### 2.2 Issue: Structured Output Failing

**Symptom:** When using `response_format: { type: "json_schema", ... }`, the model produces malformed output with excessive whitespace and incomplete fields.

**Root Cause:** [vLLM bug #23120](https://github.com/vllm-project/vllm/issues/23120) - The structured output engine (xgrammar) conflicts with the reasoning parser:

1. The reasoning parser expects freeform text in the `analysis` channel
2. The structured output engine tries to enforce JSON schema on ALL output
3. The state machine termination logic fails on edge cases

**Evidence from experiments:**

```json
// With json_schema (BROKEN)
{
  "content": "{\n    \"economic_outlook\":\"neutral\"\n   ,\"monetary_stance\":\"dovish\" \n, \"summary\"\n\n\n\n \n..."
}

// With json_object (WORKS)
{
  "content": "{\"monetary_stance\":\"hawkish\",\"economic_outlook\":\"negative\",\"tariff_mention\":0}"
}
```

---

## 3. Solutions

### 3.1 Solution for Reasoning Tokens

#### Option A: Use `include_reasoning: false` Parameter

```python
response = requests.post(
    f"{NIM_ENDPOINT}/v1/chat/completions",
    json={
        "model": "openai/gpt-oss-120b",
        "messages": messages,
        "max_tokens": 500,
        "include_reasoning": False  # Suppress reasoning in response
    }
)
```

**Pros:** Simple, works with OpenRouter providers
**Cons:** Loses debugging visibility into model reasoning

#### Option B: Parse Channels Client-Side

If the NIM returns raw Harmony format, parse it manually:

```python
import re

def parse_harmony_response(raw_response: str) -> dict:
    """Parse Harmony format response into channels."""

    # Extract analysis channel (reasoning)
    analysis_match = re.search(
        r'<\|channel\|>analysis<\|message\|>(.*?)(?:<\|end\|>|<\|channel\|>)',
        raw_response,
        re.DOTALL
    )
    reasoning = analysis_match.group(1).strip() if analysis_match else None

    # Extract final channel (response)
    final_match = re.search(
        r'<\|channel\|>final<\|message\|>(.*?)(?:<\|return\|>|<\|end\|>|$)',
        raw_response,
        re.DOTALL
    )
    content = final_match.group(1).strip() if final_match else raw_response

    # Clean control tokens from content
    content = re.sub(r'<\|[^|]+\|>', '', content)

    return {
        "content": content,
        "reasoning": reasoning
    }
```

#### Option C: Use Reasoning Effort Configuration

Set reasoning effort to `low` for simpler tasks:

```python
messages = [
    {
        "role": "system",
        "content": "Reasoning: low\nYou are a speech classifier..."
    },
    {"role": "user", "content": "Classify this speech..."}
]
```

### 3.2 Solution for Structured Output

#### Recommended: Use `json_object` Mode Instead of `json_schema`

```python
# DON'T DO THIS with GPT-OSS
response_format = {
    "type": "json_schema",
    "json_schema": {
        "name": "classification",
        "strict": True,
        "schema": {...}
    }
}

# DO THIS INSTEAD
response_format = {
    "type": "json_object"
}

# And specify schema in the system prompt
system_prompt = """You are a speech classifier. Return JSON with these exact fields:
- monetary_stance: one of ["very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"]
- economic_outlook: one of ["very_negative", "negative", "neutral", "positive", "very_positive"]
- tariff_mention: 0 if no tariffs mentioned, 1 if tariffs mentioned

Return ONLY valid JSON, no other text."""
```

#### Validation Approach

Since `json_object` doesn't enforce schema, validate client-side:

```python
from pydantic import BaseModel, ValidationError
from typing import Literal

class SpeechClassification(BaseModel):
    monetary_stance: Literal["very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"]
    economic_outlook: Literal["very_negative", "negative", "neutral", "positive", "very_positive"]
    tariff_mention: Literal[0, 1]

def classify_speech(response: str) -> SpeechClassification:
    """Parse and validate classification response."""
    import json

    # Extract JSON from response (may contain reasoning prefix)
    json_match = re.search(r'\{[^}]+\}', response)
    if not json_match:
        raise ValueError("No JSON found in response")

    data = json.loads(json_match.group())
    return SpeechClassification(**data)
```

---

## 4. Recommended Implementation Pattern

### 4.1 Updated NIM Resource

```python
class NIMLLMResource(ConfigurableResource):
    """NVIDIA NIM LLM resource with GPT-OSS support."""

    endpoint: str = Field(
        default="http://nvidia-nim-reasoning.nvidia-nim.svc.cluster.local:8000"
    )

    def generate_json(
        self,
        prompt: str,
        system_prompt: str,
        schema_description: str,
        max_tokens: int = 500,
        temperature: float = 0.1,
        include_reasoning: bool = False,
    ) -> dict:
        """Generate structured JSON output.

        Args:
            prompt: User prompt
            system_prompt: Base system instructions
            schema_description: JSON schema description for prompt
            max_tokens: Maximum tokens to generate
            temperature: Sampling temperature
            include_reasoning: Whether to include reasoning in response

        Returns:
            Parsed JSON dictionary
        """
        full_system = f"""Reasoning: low
{system_prompt}

{schema_description}

Return ONLY valid JSON, no other text."""

        payload = {
            "model": "openai/gpt-oss-120b",
            "messages": [
                {"role": "system", "content": full_system},
                {"role": "user", "content": prompt}
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "response_format": {"type": "json_object"},
            "include_reasoning": include_reasoning,
        }

        response = requests.post(
            f"{self.endpoint}/v1/chat/completions",
            json=payload,
            timeout=60,
        )
        response.raise_for_status()

        result = response.json()
        content = result["choices"][0]["message"]["content"]

        # Parse JSON from content (handles any residual reasoning prefix)
        return self._extract_json(content)

    def _extract_json(self, content: str) -> dict:
        """Extract JSON from response, handling Harmony format artifacts."""
        import json
        import re

        # Remove Harmony control tokens if present
        content = re.sub(r'<\|[^|]+\|>', '', content)

        # Find JSON object
        json_match = re.search(r'\{[^{}]*\}', content)
        if not json_match:
            raise ValueError(f"No JSON found in response: {content[:200]}")

        return json.loads(json_match.group())
```

### 4.2 Updated Classification Asset

```python
@dg.asset(
    deps=[cleaned_speeches],
    io_manager_key="minio_parquet_io_manager",
)
def speech_classification(
    context: dg.AssetExecutionContext,
    cleaned_speeches: pl.DataFrame,
    nim_reasoning: NIMLLMResource,
) -> pl.DataFrame:
    """Classify speeches using GPT-OSS-120B."""

    SCHEMA_DESCRIPTION = """Output JSON with these exact fields:
- monetary_stance: one of ["very_dovish", "dovish", "neutral", "hawkish", "very_hawkish"]
- trade_stance: one of ["very_protectionist", "protectionist", "neutral", "globalist", "very_globalist"]
- tariff_mention: 0 if no tariffs mentioned, 1 if tariffs mentioned
- economic_outlook: one of ["very_negative", "negative", "neutral", "positive", "very_positive"]"""

    def classify_row(row: dict) -> dict:
        text = row.get("text", "")[:8000]
        reference = row["reference"]

        try:
            result = nim_reasoning.generate_json(
                prompt=f"Analyze this speech:\n\n{text}",
                system_prompt="You are a central bank speech classifier.",
                schema_description=SCHEMA_DESCRIPTION,
                max_tokens=200,
                temperature=0.1,
            )

            return {
                "reference": reference,
                **result,
                "_llm_status": "success",
                "_llm_error": None,
            }

        except Exception as e:
            context.log.warning(f"Classification failed for {reference}: {e}")
            return {
                "reference": reference,
                "monetary_stance": "neutral",
                "trade_stance": "neutral",
                "tariff_mention": 0,
                "economic_outlook": "neutral",
                "_llm_status": "failed",
                "_llm_error": str(e),
            }

    # Process with retry and checkpointing
    results = [classify_row(row) for row in cleaned_speeches.to_dicts()]
    return pl.DataFrame(results)
```

---

## 5. Experimental Results

### 5.1 OpenRouter API Tests

| Test | Configuration | Result |
|------|--------------|--------|
| Basic completion | Default | Reasoning in separate `reasoning` field |
| JSON mode | `type: json_object` | Valid JSON in content, reasoning separated |
| Strict schema | `type: json_schema` | **BROKEN** - malformed output |
| Low reasoning | System: "Reasoning: low" | Less reasoning, faster response |
| No reasoning | `include_reasoning: false` | Clean content, no reasoning |

### 5.2 Token Usage Analysis

```
Without reasoning suppression:
  - Prompt tokens: 125
  - Reasoning tokens: 138
  - Completion tokens: 153
  - Total: 278

With include_reasoning: false:
  - Prompt tokens: 116
  - Reasoning tokens: 78 (hidden)
  - Completion tokens: 174
  - Total: 290
```

Note: Reasoning tokens are still generated internally but not returned in response.

---

## 6. Provider Comparison

Different providers handle GPT-OSS differently:

| Provider | Reasoning Handling | JSON Schema | JSON Object |
|----------|-------------------|-------------|-------------|
| Groq | Separate `reasoning` field + `reasoning_details` | Unknown | Works |
| Amazon Bedrock | Separate `reasoning` field | Unknown | Works |
| SiliconFlow | Sometimes leaks into content | Broken | Works |
| Novita | Separate `reasoning` field | Unknown | Works |
| NVIDIA NIM | Known bug - leaks `<\|return\|>` | Broken | Should work |

---

## 7. Implementation Checklist

### Immediate Actions

- [ ] Update NIM resource to use `json_object` instead of `json_schema`
- [ ] Add `include_reasoning: false` to classification requests
- [ ] Add client-side JSON extraction with Harmony token cleanup
- [ ] Add Pydantic validation for structured outputs
- [ ] Update system prompts to include schema description

### Future Considerations

- [ ] Monitor vLLM releases for bug fixes ([#23120](https://github.com/vllm-project/vllm/issues/23120))
- [ ] Consider upgrading to NIM version with fixed Harmony parser
- [ ] Implement reasoning logging for debugging (separate from content)

---

## 8. References

### Official Documentation

- [OpenAI GPT-OSS Model Card](https://openai.com/index/gpt-oss-model-card/)
- [OpenAI Harmony Response Format](https://cookbook.openai.com/articles/openai-harmony)
- [How to Handle Raw CoT in GPT-OSS](https://cookbook.openai.com/articles/gpt-oss/handle-raw-cot)
- [NVIDIA NIM GPT-OSS-120B](https://build.nvidia.com/openai/gpt-oss-120b/modelcard)

### vLLM Documentation

- [vLLM Reasoning Outputs](https://docs.vllm.ai/en/latest/features/reasoning_outputs/)
- [vLLM GPT-OSS Recipe](https://docs.vllm.ai/projects/recipes/en/latest/OpenAI/GPT-OSS.html)
- [GPT-OSS Reasoning Parser](https://docs.vllm.ai/en/latest/api/vllm/reasoning/gptoss_reasoning_parser/)

### Known Issues

- [NVIDIA Forum: Missing reasoning_content](https://forums.developer.nvidia.com/t/model-returns-return-and-missing-reasoning-content-with-openai-gpt-oss-120b/346808)
- [vLLM Issue #23120: Structured output not enforced](https://github.com/vllm-project/vllm/issues/23120)
- [vLLM Discussion #17638: Structured generation with reasoning](https://github.com/vllm-project/vllm/discussions/17638)

### OpenRouter

- [GPT-OSS-120B on OpenRouter](https://openrouter.ai/openai/gpt-oss-120b)

---

## Appendix A: Harmony Format Specification

### Control Tokens

| Token | Purpose |
|-------|---------|
| `<\|start\|>` | Begin message |
| `<\|end\|>` | End message (continue conversation) |
| `<\|return\|>` | End generation (final answer) |
| `<\|call\|>` | End for tool call |
| `<\|channel\|>` | Specify output channel |
| `<\|message\|>` | Begin message content |
| `<\|constrain\|>` | Constrain output format |

### Example Full Response

```
<|start|>assistant<|channel|>analysis<|message|>
Let me analyze this speech. The Fed raised rates by 25bp, indicating hawkish stance.
They cite persistent inflation - negative economic signal. No tariff mention.
<|end|>
<|start|>assistant<|channel|>final<|message|>
{"monetary_stance":"hawkish","economic_outlook":"negative","tariff_mention":0}
<|return|>
```

## Appendix B: Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `NIM_MODEL_PROFILE` | `fc1df044c94b466d...` | Single-GPU TP=1 profile for H200 |
| `NIM_LOG_LEVEL` | `INFO` | Logging verbosity |
| `NIM_LOG_REQUESTS` | `true` | Log prompts and responses |
| `NIM_ENABLE_METRICS` | `true` | Prometheus metrics |
