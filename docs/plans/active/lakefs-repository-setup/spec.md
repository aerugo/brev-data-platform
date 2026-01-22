# LakeFS Repository Auto-Setup - Specification

**Status**: Pending
**Created**: 2026-01-22

## Goal

Automate LakeFS repository and branch creation during platform setup so users don't need manual post-deployment steps.

## Background

Currently, after deploying the platform:
- LakeFS is running and connected to MinIO
- The admin user is auto-created by the setup job
- **But** no repository exists - users must manually run `lakectl repo create`

This creates friction and violates **INV-I005** (Configuration as Code).

## Acceptance Criteria

1. After `helm install lakefs`, a default repository exists in LakeFS
2. The repository points to MinIO storage (`s3://lakefs/data`)
3. A `staging` branch exists in addition to `main`
4. The setup is idempotent (re-running doesn't cause errors)
5. Repository name and branches are configurable via Helm values

## Technical Requirements

### Helm Values

New configuration section:
```yaml
repository:
  enabled: true
  name: data
  defaultBranch: main
  storageNamespace: s3://lakefs/data
  branches:
    - staging
```

### Setup Job

Extend `setup-job.yaml` to:
1. Create repository via LakeFS REST API
2. Create additional branches via LakeFS REST API
3. Handle "already exists" responses gracefully

### API Endpoints Used

- `POST /api/v1/repositories` - Create repository
- `POST /api/v1/repositories/{repo}/branches` - Create branch

## Dependencies

- LakeFS must be healthy (existing health check)
- MinIO must be running with `lakefs` bucket (existing dependency)
- Admin credentials must be available (existing secret)

## Security Considerations

- Uses existing `lakefs-credentials` secret for API authentication
- No new secrets required
- Repository storage is within existing MinIO bucket

## Out of Scope

- Multiple repositories (single default repo only)
- Repository policies or access control
- Data seeding or initial content
