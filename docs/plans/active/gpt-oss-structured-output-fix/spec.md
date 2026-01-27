# Feature: GPT-OSS Structured Output Fix

**Status**: Approved
**Created**: 2026-01-27
**Category**: Application

## Goal

Fix GPT-OSS-120B reasoning token handling and structured output generation in the Dagster pipeline to eliminate malformed responses and reasoning token leakage.

## Background

GPT-OSS-120B uses the Harmony response format which outputs to multiple channels (analysis, final, commentary). Two issues have been identified:

1. **Reasoning tokens appearing in content**: The NIM's vLLM parser fails to properly separate the `analysis` channel (chain-of-thought) from the `final` channel (response), causing reasoning to leak into user-visible content.

2. **Structured output failing**: vLLM bug #23120 causes the structured generation engine to conflict with GPT-OSS's reasoning parser when using `json_schema` strict mode, producing malformed output.

**Research Report**: [docs/reports/gpt-oss-reasoning-structured-output.md](../../reports/gpt-oss-reasoning-structured-output.md)

## Acceptance Criteria

- [ ] AC1: All NIM classification calls use `json_object` response format (not `json_schema`)
- [ ] AC2: All NIM calls include `include_reasoning: false` parameter
- [ ] AC3: Client-side JSON extraction handles Harmony control token cleanup
- [ ] AC4: Response validation uses Pydantic models with proper error handling
- [ ] AC5: Unit tests cover all NIM call scenarios with 90%+ coverage
- [ ] AC6: Integration test validates end-to-end classification pipeline
- [ ] AC7: All tests pass with mocked NIM responses

## Technical Requirements

### Infrastructure Changes (Terraform)
- None required

### Kubernetes Changes (Helm)
- None required (NIM deployment already configured correctly)

### Application Changes

**NIM Resource Updates:**
- Add `include_reasoning` parameter support to NIM resource
- Add `generate_json()` method with Harmony token cleanup
- Add response format configuration option
- Add Pydantic model validation

**Asset Updates:**
- Update `speech_classification` to use new `generate_json()` method
- Update `speech_summaries` to handle reasoning tokens properly
- Add proper error handling with fallback values

**Type Definitions:**
- Add `NIMChatCompletionRequest` TypedDict
- Add `NIMChatCompletionResponse` TypedDict
- Add `SpeechClassificationResult` Pydantic model (if not exists)

### GitOps Changes
- None required

## Dependencies

- NVIDIA NIM deployment with GPT-OSS-120B
- Dagster pipeline infrastructure
- Pydantic v2 for response validation

## Out of Scope

- NIM/vLLM version upgrades (wait for upstream fix to #23120)
- Switching to json_schema mode (blocked by vLLM bug)
- Exposing reasoning to end users (per OpenAI guidance)

## Security Considerations

- No new secrets required
- Chain-of-thought reasoning must NOT be exposed to end users
- LLM responses must be validated before use

## Resource Requirements

- No additional GPU requirements
- No additional memory requirements
- Existing H200 deployment sufficient

## Open Questions

- [x] Q1: Should we use `json_object` or `json_schema`? **Answer: `json_object` (json_schema is broken)**
- [x] Q2: How to handle reasoning tokens? **Answer: `include_reasoning: false` + client-side cleanup**
