# Phase X: <Name>

**Status**: Pending | In Progress | Complete
**Type**: Infrastructure | Kubernetes | Application | Integration
**Started**: <date>
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

<What this phase accomplishes>

---

## Invariants Enforced in This Phase

- **INV-Ixxx**: <How this phase respects/enforces this invariant>
- **INV-Kxxx**: <How this phase respects/enforces this invariant>

---

## Implementation Steps

### Step X.1: <Description>

**Action**: Create | Modify | Configure

**File(s)**: `<path/to/file>`

<Detailed description of what to do>

```hcl
# Example Terraform code (or YAML, Python, etc.)
resource "example" "name" {
  ...
}
```

**Validation**:
```bash
<command to validate this step>
```

---

### Step X.2: <Description>

**Action**: Create | Modify | Configure

**File(s)**: `<path/to/file>`

<Detailed description of what to do>

**Validation**:
```bash
<command to validate this step>
```

---

### Step X.3: <Description>

...

---

## Files

| File | Action | Purpose |
|------|--------|---------|
| `<path>` | CREATE | <purpose> |
| `<path>` | MODIFY | <what changes> |

---

## Configuration Details

### Environment Variables

| Variable | Value | Purpose |
|----------|-------|---------|
| `VAR_NAME` | `value` | <purpose> |

### Secrets Required

| Secret | Source | How to Create |
|--------|--------|---------------|
| `secret-name` | SOPS | `sops --encrypt ...` |

---

## Verification

### Pre-flight Checks

```bash
# Ensure prerequisites are met
<commands>
```

### Validation Commands

```bash
# Terraform (if Infrastructure phase)
terraform fmt -check terraform/
terraform validate

# Helm (if Kubernetes phase)
helm lint k8s/apps/<app>/
helm template <release> k8s/apps/<app>/

# Dagster (if Application phase)
pytest dagster/tests/

# General
make lint
make validate
```

### Expected Outcomes

- <Specific observable outcome>
- <Specific observable outcome>

---

## Edge Cases and Error Handling

### Potential Issues

| Issue | Detection | Resolution |
|-------|-----------|------------|
| <issue> | <how to detect> | <how to fix> |

### Rollback Plan

If this phase fails:
1. <rollback step>
2. <rollback step>

---

## Completion Criteria

- [ ] All files created/modified as specified
- [ ] Validation commands pass
- [ ] No lint errors
- [ ] Expected outcomes observed
- [ ] Invariants INV-xxx verified
