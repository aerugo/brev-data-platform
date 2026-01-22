# LakeFS Repository Auto-Setup - Development Plan

**Status**: Complete
**Created**: 2026-01-22
**Branch**: `feature/lakefs-repo-setup`

## Summary

Extend the existing LakeFS setup job to automatically create the default repository and branch structure after admin user initialization, making the platform ready to use without manual steps.

## Critical Invariants to Respect

- **INV-I005**: Configuration as Code - Repository setup must be automated, not manual
- **INV-D001**: Standard Bucket Structure - Repository uses the `lakefs` bucket in MinIO
- **INV-D002**: LakeFS for Data Versioning - Repository enables the versioning workflow
- **INV-G003**: Source of Truth is Git - Configuration defined in Helm values
- **INV-K002**: Resource Limits on All Pods - Setup job must have resource limits

## Current State Analysis

The LakeFS setup job (`k8s/apps/lakefs/templates/setup-job.yaml`) currently:
1. Waits for LakeFS to be ready via health check
2. Creates the admin user via the `/api/v1/setup_lakefs` endpoint
3. Handles idempotency (ignores "already initialized" errors)

**Gap**: After admin setup, there is no repository or branch structure. Users must manually run `lakectl repo create` commands.

### Files to Modify

| File | Current State | Planned Changes |
|------|---------------|-----------------|
| `k8s/apps/lakefs/templates/setup-job.yaml` | Creates admin user only | Add repository and branch creation |
| `k8s/apps/lakefs/values.yaml` | No repository config | Add configurable repository settings |

### Files to Create

None - all changes are to existing files.

## Solution Design

Extend the setup job's shell script to:
1. Create admin user (existing)
2. Create default repository pointing to MinIO `s3://lakefs/data`
3. Create standard branches (`staging`)

```
Setup Job Flow:
┌─────────────────────────────────────────────────────────────┐
│  1. Wait for LakeFS health check                            │
│  2. Create admin user (existing, idempotent)                │
│  3. Create repository via API (NEW, idempotent)             │
│  4. Create staging branch via API (NEW, idempotent)         │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **Use LakeFS REST API directly**: The setup job already uses `wget` for API calls. Continue this pattern rather than introducing `lakectl` CLI (avoids needing a different container image).

2. **Make repository name configurable**: Add `repository.name` and `repository.storagePath` to values.yaml so users can customize if needed.

3. **Idempotent operations**: LakeFS API returns 409 Conflict if repository/branch already exists. Handle this gracefully (same pattern as admin setup).

4. **Single branch by default**: Create only `staging` branch initially. The `main` branch is created automatically with the repository.

## Phase Overview

| Phase | Description | Type | Deliverables |
|-------|-------------|------|--------------|
| 1 | Add repository configuration to values.yaml | Kubernetes | Updated values.yaml |
| 2 | Extend setup job to create repository and branches | Kubernetes | Updated setup-job.yaml |
| 3 | Validation | Integration | Helm lint, template verification |

## Phase 1: Add Repository Configuration

**Goal**: Make repository settings configurable via Helm values
**Type**: Kubernetes

### Deliverables

1. Updated `k8s/apps/lakefs/values.yaml` with repository configuration section

### Implementation

Add to `values.yaml`:

```yaml
# Repository auto-setup configuration
repository:
  # Whether to auto-create repository on setup
  enabled: true
  # Repository name in LakeFS
  name: data
  # Default branch (created with repository)
  defaultBranch: main
  # Storage location in MinIO (s3://bucket/path)
  storageNamespace: s3://lakefs/data
  # Additional branches to create after repository
  branches:
    - staging
```

### Validation Approach

1. `helm lint k8s/apps/lakefs/`
2. `helm template lakefs k8s/apps/lakefs/` renders without errors

### Success Criteria

- [ ] values.yaml contains repository configuration
- [ ] Helm lint passes
- [ ] Template renders correctly

## Phase 2: Extend Setup Job

**Goal**: Create repository and branches after admin setup
**Type**: Kubernetes

### Deliverables

1. Updated `k8s/apps/lakefs/templates/setup-job.yaml` with repository creation logic

### Implementation

Extend the setup job script to:

```bash
# After admin setup...

{{- if .Values.repository.enabled }}
echo "Creating LakeFS repository..."
# Create repository (returns 409 if exists)
REPO_RESULT=$(wget -q -O- --post-data='{
  "name": "{{ .Values.repository.name }}",
  "storage_namespace": "{{ .Values.repository.storageNamespace }}",
  "default_branch": "{{ .Values.repository.defaultBranch }}"
}' \
  --header='Content-Type: application/json' \
  --header="Authorization: Basic $(echo -n $LAKEFS_ACCESS_KEY_ID:$LAKEFS_SECRET_ACCESS_KEY | base64)" \
  http://lakefs.{{ .Release.Namespace }}.svc.cluster.local:8000/api/v1/repositories 2>&1 || true)

if echo "$REPO_RESULT" | grep -q '"id"'; then
  echo "Repository '{{ .Values.repository.name }}' created successfully!"
elif echo "$REPO_RESULT" | grep -q "already exists"; then
  echo "Repository '{{ .Values.repository.name }}' already exists."
else
  echo "Repository result: $REPO_RESULT"
fi

# Create additional branches
{{- range .Values.repository.branches }}
echo "Creating branch '{{ . }}'..."
BRANCH_RESULT=$(wget -q -O- --post-data='{
  "name": "{{ . }}",
  "source": "{{ $.Values.repository.defaultBranch }}"
}' \
  --header='Content-Type: application/json' \
  --header="Authorization: Basic $(echo -n $LAKEFS_ACCESS_KEY_ID:$LAKEFS_SECRET_ACCESS_KEY | base64)" \
  http://lakefs.{{ $.Release.Namespace }}.svc.cluster.local:8000/api/v1/repositories/{{ $.Values.repository.name }}/branches 2>&1 || true)

if echo "$BRANCH_RESULT" | grep -q '"id"\|"commit_id"'; then
  echo "Branch '{{ . }}' created successfully!"
elif echo "$BRANCH_RESULT" | grep -q "already exists"; then
  echo "Branch '{{ . }}' already exists."
else
  echo "Branch result: $BRANCH_RESULT"
fi
{{- end }}
{{- end }}
```

### Validation Approach

1. `helm lint k8s/apps/lakefs/`
2. `helm template lakefs k8s/apps/lakefs/` - verify job YAML is valid
3. Review rendered script logic

### Success Criteria

- [ ] Helm lint passes
- [ ] Template renders valid Kubernetes Job YAML
- [ ] Script includes repository creation with auth header
- [ ] Script includes branch creation loop
- [ ] All operations are idempotent (handle 409 errors)

## Phase 3: Validation

**Goal**: Verify the implementation works correctly
**Type**: Integration

### Validation Approach

1. **Helm Validation**:
   ```bash
   helm lint k8s/apps/lakefs/
   helm template lakefs k8s/apps/lakefs/ --debug
   ```

2. **Script Review**: Verify the rendered script:
   - Correct API endpoints
   - Proper JSON payloads
   - Auth header format
   - Error handling

3. **Dry Run** (if cluster available):
   ```bash
   helm upgrade --install lakefs k8s/apps/lakefs/ -n lakefs --dry-run
   ```

### Success Criteria

- [ ] All Helm validations pass
- [ ] Rendered YAML is valid Kubernetes manifest
- [ ] API calls use correct LakeFS endpoints
- [ ] Configuration is properly templated from values

## Validation Strategy

### Kubernetes Validation

```bash
# Lint chart
helm lint k8s/apps/lakefs/

# Template rendering (verify YAML)
helm template lakefs k8s/apps/lakefs/

# Dry-run (if cluster access available)
helm upgrade --install lakefs k8s/apps/lakefs/ -n lakefs --dry-run --debug
```

### Integration Validation (Post-Deploy)

After deployment to a cluster:
1. Check job logs: `kubectl logs -n lakefs job/lakefs-setup`
2. Verify repository exists: Access LakeFS UI or use `lakectl repo list`
3. Verify branches exist: `lakectl branch list lakefs://data`

## Documentation Updates

After implementation:

- [ ] Update `.claude/agents/minio-lakefs-specialist.md` to note auto-setup behavior
- [ ] Consider updating README if user-facing behavior changes

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| Phase 1 | Complete | 2026-01-22 | 2026-01-22 | Added repository config to values.yaml |
| Phase 2 | Complete | 2026-01-22 | 2026-01-22 | Extended setup-job.yaml with API calls |
| Phase 3 | Complete | 2026-01-22 | 2026-01-22 | Helm lint and template passed |

## API Reference

### Create Repository
```
POST /api/v1/repositories
Content-Type: application/json
Authorization: Basic <base64(access_key:secret_key)>

{
  "name": "data",
  "storage_namespace": "s3://lakefs/data",
  "default_branch": "main"
}
```

### Create Branch
```
POST /api/v1/repositories/{repository}/branches
Content-Type: application/json
Authorization: Basic <base64(access_key:secret_key)>

{
  "name": "staging",
  "source": "main"
}
```
