# Feature: <Name>

**Status**: Draft | Approved | In Progress | Complete
**Created**: <date>
**Category**: Infrastructure | Kubernetes | Application | Integration

## Goal

<One sentence describing the outcome>

## Background

<Context: why this feature is needed, what problem it solves>

## Acceptance Criteria

- [ ] AC1: <Specific, testable criterion>
- [ ] AC2: <Specific, testable criterion>
- [ ] AC3: <Specific, testable criterion>

## Technical Requirements

### Infrastructure Changes (Terraform)
- <Module additions or modifications>
- <Resource provisioning needed>

### Kubernetes Changes (Helm)
- <New charts or chart modifications>
- <Namespace requirements>
- <Resource limits and requests>

### Application Changes
- <Dagster pipeline changes>
- <Configuration file changes>

### GitOps Changes
- <ArgoCD application definitions>
- <Sync policy requirements>

## Dependencies

- <What must exist before this can be built>
- <External services or APIs required>
- <Other features that must be completed first>

## Out of Scope

- <What this feature explicitly does NOT include>
- <Future enhancements deferred>

## Security Considerations

- <Secret management requirements>
- <Network policy requirements>
- <RBAC requirements>

## Resource Requirements

- <GPU requirements (if applicable)>
- <Memory/CPU requirements>
- <Storage requirements>

## Open Questions

- [ ] Q1: <Unresolved question>
- [ ] Q2: <Unresolved question>
