# AI Agent Implementation Planning Guide

This directory is where AI agents create and track implementation plans for infrastructure and application features.

**Invariants Reference**: See [docs/invariants/INVARIANTS.md](../invariants/INVARIANTS.md)
**Project Overview**: See [.CLAUDE.md](../../.CLAUDE.md)
**Agent Guides**: See [.claude/agents/](../../.claude/agents/)

---

## Directory Structure

```
docs/plans/
├── CLAUDE.md                    # This file - planning protocol
├── active/                      # Plans currently being implemented
│   └── <feature-name>/
│       ├── spec.md              # Feature specification (required)
│       ├── development-plan.md  # Phased implementation plan (required)
│       ├── work-notes.md        # Progress tracking and session notes (required)
│       └── phases/
│           ├── phase-1.md       # Detailed plan for phase 1
│           ├── phase-2.md       # Detailed plan for phase 2
│           └── ...
├── completed/                   # Finished plans (for reference)
│   └── <feature-name>/
│       └── ...
└── templates/
    ├── spec-template.md
    ├── development-plan-template.md
    ├── phase-template.md
    └── work-notes-template.md
```

---

## Starting a New Implementation

### 1. Understand the Project Context

Before writing any code:

- **Read `docs/invariants/INVARIANTS.md`** to understand ALL project invariants
- **Read `.CLAUDE.md`** for project conventions and code style
- **Review relevant `.claude/agents/`** guides for specialized patterns
- **Study existing implementations** that solve similar problems
- **Analyze the current state** of files you'll modify

### 2. Create the Feature Specification

Save to `docs/plans/active/<feature-name>/spec.md` using the template at `templates/spec-template.md`.

Key sections:
- Goal and background
- Acceptance criteria (testable)
- Technical requirements (Terraform, Helm, Dagster changes)
- Dependencies
- Security considerations

### 3. Create the Development Plan

Save to `docs/plans/active/<feature-name>/development-plan.md` using the template at `templates/development-plan-template.md`.

Key sections:
- Critical invariants to respect (reference by INV-xxx ID)
- Current state analysis
- Solution design
- Phase breakdown with deliverables
- Testing strategy

### 4. Create Work Notes

Save to `docs/plans/active/<feature-name>/work-notes.md` using the template at `templates/work-notes-template.md`.

Purpose:
- Track session-by-session progress
- Document decisions and rationale
- Record blockers and resolutions
- Maintain continuity between sessions

### 5. Create Phase Plans

For each phase, create `docs/plans/active/<feature-name>/phases/phase-X.md` using the template at `templates/phase-template.md`.

---

## Phase Types for This Project

Given the infrastructure + application nature of this project, phases typically fall into these categories:

### Infrastructure Phases
- Terraform module development
- Cloud resource provisioning
- Network configuration
- Storage setup

### Kubernetes Phases
- Helm chart development
- Deployment configuration
- Service and ingress setup
- Secret management

### Application Phases
- Dagster pipeline development
- Marimo notebook creation
- Configuration files

### Integration Phases
- ArgoCD application setup
- CI/CD workflow development
- End-to-end testing

---

## Execution Workflow

### Starting Each Session

1. **Read `work-notes.md`** to understand current state
2. **Review the current phase plan** in `phases/phase-X.md`
3. **Re-read `docs/invariants/INVARIANTS.md`** if working on invariant-sensitive code
4. **Check infrastructure state**: `terraform plan` or `kubectl get pods`
5. **Continue from the documented next step**

### Working Through Each Phase

1. **Create the detailed phase plan** before starting
2. **Follow the validation approach**:
   - For Terraform: `terraform fmt`, `terraform validate`, `terraform plan`
   - For Helm: `helm lint`, `helm template`, dry-run install
   - For Dagster: Unit tests, local execution
3. **Update `work-notes.md` continuously**:
   - What was completed
   - Decisions made and rationale
   - Issues encountered and resolutions
   - Next steps when resuming
4. **Run validation at major milestones**

### Completing a Phase

1. **Verify all phase deliverables are working**
2. **Run linting/validation**: `make lint && make validate`
3. **Update phase status** in `development-plan.md`
4. **Add completion notes** to `work-notes.md`
5. **Create next phase plan** in `phases/phase-X+1.md`

### Completing the Implementation

1. **Verify full stack is operational**
2. **Verify all invariants are preserved**
3. **Update `docs/invariants/INVARIANTS.md`**:
   - Add any new invariants with appropriate INV-xxx ID
   - Update version number and date
4. **Update other documentation** as needed
5. **Move plan to `completed/`** directory

---

## Invariant Management

### Referencing Existing Invariants

Always reference invariants by their canonical ID from `docs/invariants/INVARIANTS.md`:

```markdown
## Critical Invariants to Respect

- **INV-I001**: Terraform state must be remote
- **INV-K002**: All apps deploy to dedicated namespaces
- **INV-S001**: No plaintext secrets in Git
```

### Introducing New Invariants

If your implementation introduces a constraint that must be maintained project-wide:

1. **Document it in your development plan** as a proposed new invariant
2. **Create validation that enforces the invariant** (lint rule, CI check, etc.)
3. **Add to `docs/invariants/INVARIANTS.md`** after implementation:
   - Use appropriate category prefix (INV-I for infrastructure, INV-K for Kubernetes, etc.)
   - Use next available number in that category
   - Include: Rule, Requirements, Where it applies

---

## Validation Approaches by Technology

### Terraform Validation

```bash
# Format check
terraform fmt -check -recursive terraform/

# Validate configuration
terraform -chdir=terraform/environments/dev validate

# Plan (catch issues before apply)
terraform -chdir=terraform/environments/dev plan
```

### Helm Chart Validation

```bash
# Lint chart
helm lint k8s/apps/<app>/

# Template rendering (catch YAML errors)
helm template <release-name> k8s/apps/<app>/ -f k8s/apps/<app>/values-dev.yaml

# Dry-run install
helm install <release-name> k8s/apps/<app>/ --dry-run --debug
```

### Dagster Validation

```bash
# Run tests
pytest dagster/

# Local dev server
dagster dev -f dagster/pipelines/

# Type checking
mypy dagster/
```

### SOPS/Secrets Validation

```bash
# Verify file is encrypted
sops -d <file>.enc.yaml > /dev/null && echo "Valid encrypted file"

# Check for plaintext secrets (CI check)
grep -r "password:" k8s/ --include="*.yaml" | grep -v ".enc.yaml"
```

---

## Agent Handoff Commands

### Start New Feature

```
Plan this feature according to the template in docs/plans/CLAUDE.md
and then implement following the validation approaches for each technology.
```

### Check Progress

```
Did you follow the plan so far, or did you diverge?
If you diverged, how and why?
```

### Resume Work

```
Keep implementing the plan in docs/plans/active/<feature>/development-plan.md
following the protocol defined in docs/plans/CLAUDE.md
```

### Infrastructure Blocker

```
The infrastructure provisioning failed. Document the error in work-notes.md
and propose a resolution.
```

### After PR Merged

```
The PR was merged. Update the work-notes.md with completion status
and move the plan to docs/plans/completed/ if fully done.
```

---

## Checklists

### Pre-Implementation Checklist

- [ ] Read `docs/invariants/INVARIANTS.md` for all invariants
- [ ] Read `.CLAUDE.md` for project conventions
- [ ] Read relevant `.claude/agents/` for specialized patterns
- [ ] Identify all applicable invariants (list by INV-xxx)
- [ ] Analyze current state of files to modify
- [ ] Study similar existing implementations
- [ ] Create spec.md
- [ ] Create development-plan.md (with invariants section)
- [ ] Create work-notes.md
- [ ] Create first phase plan

### Phase Completion Checklist

- [ ] All phase deliverables working
- [ ] Linting passes (`make lint`)
- [ ] Validation passes (`make validate`)
- [ ] Work notes updated with session log
- [ ] Phase status updated in development plan

### Implementation Completion Checklist

- [ ] Full stack operational
- [ ] All validation passes
- [ ] `docs/invariants/INVARIANTS.md` updated (if new invariants)
- [ ] Other documentation updated
- [ ] Work notes reflect final state
- [ ] Plan moved to `completed/` directory

---

*Last Updated: 2026-01-21*
