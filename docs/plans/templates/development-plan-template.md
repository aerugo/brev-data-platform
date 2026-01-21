# <Feature Name> - Development Plan

**Status**: In Progress
**Created**: <date>
**Branch**: `feature/<feature-name>`
**Spec**: [spec.md](spec.md)

## Summary

<1-2 sentence description of what this implementation accomplishes>

## Critical Invariants to Respect

Reference invariants from `docs/invariants/INVARIANTS.md` by their canonical IDs:

- **INV-Ixxx**: <Name> - <How it applies to this implementation>
- **INV-Kxxx**: <Name> - <How it applies to this implementation>
- **INV-Sxxx**: <Name> - <How it applies to this implementation>

**New invariants introduced** (to be added to INVARIANTS.md after implementation):

- **NEW INV-xxx**: <Proposed Name> - <Description and rationale>

## Current State Analysis

<Describe what exists now and what problem you're solving>

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `terraform/...` | ... | ... |
| `k8s/apps/.../...` | ... | ... |
| `dagster/...` | ... | ... |

### Files to Create

| File | Purpose |
|------|---------|
| `terraform/modules/...` | ... |
| `k8s/apps/<new-app>/` | ... |

## Solution Design

<Describe the solution approach>

```
<ASCII diagram showing architecture/data flow if helpful>
```

### Key Design Decisions

1. **<Decision>**: <Rationale>
2. **<Decision>**: <Rationale>

## Phase Overview

| Phase | Description | Type | Deliverables |
|-------|-------------|------|--------------|
| 1 | <description> | Infrastructure | <key outputs> |
| 2 | <description> | Kubernetes | <key outputs> |
| 3 | <description> | Application | <key outputs> |
| 4 | <description> | Integration | <key outputs> |

## Phase 1: <Name>

**Goal**: <Clear objective>
**Type**: Infrastructure | Kubernetes | Application | Integration
**Detailed Plan**: [phases/phase-1.md](phases/phase-1.md)

### Deliverables

1. <File or component>
2. <File or component>

### Validation Approach

1. `terraform fmt -check` passes
2. `terraform validate` passes
3. `terraform plan` shows expected changes

### Success Criteria

- [ ] Validation passes
- [ ] <Specific criterion>
- [ ] <Specific criterion>

## Phase 2: <Name>

**Goal**: <Clear objective>
**Type**: Infrastructure | Kubernetes | Application | Integration
**Detailed Plan**: [phases/phase-2.md](phases/phase-2.md)

### Deliverables

1. <File or component>
2. <File or component>

### Validation Approach

1. <Validation step>
2. <Validation step>

### Success Criteria

- [ ] <Specific criterion>
- [ ] <Specific criterion>

## Validation Strategy

### Infrastructure Validation

- Terraform format: `terraform fmt -check -recursive terraform/`
- Terraform validate: `terraform validate`
- Terraform plan: Verify expected resources

### Kubernetes Validation

- Helm lint: `helm lint k8s/apps/<app>/`
- Helm template: Verify YAML output
- Dry-run: `helm install --dry-run`

### Application Validation

- Dagster tests: `pytest dagster/`
- Local execution: `dagster dev`

### Integration Validation

- ArgoCD sync: Application syncs successfully
- End-to-end: Data flows through pipeline

## Documentation Updates

After implementation is complete:

- [ ] `docs/invariants/INVARIANTS.md` - Add new invariants (if any)
- [ ] `.CLAUDE.md` - Update if conventions changed
- [ ] README updates (if user-facing changes)

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Pending | | | |
| Phase 2 | Pending | | | |
| ... | ... | | | |
