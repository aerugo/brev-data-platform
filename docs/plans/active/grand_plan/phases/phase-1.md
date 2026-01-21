# Phase 1: Repository Structure

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create the complete repository directory structure, Makefile, and configuration files that form the foundation for all subsequent phases.

---

## Invariants Enforced in This Phase

- **INV-S001**: No plaintext secrets in Git - `.gitignore` must exclude sensitive files
- **INV-K004**: Helm values override pattern - structure supports `values.yaml` + `values-dev.yaml`

---

## Directory Structure to Create

```
brev-data-platform/
├── .github/
│   └── workflows/              # GitHub Actions (Phase 8)
├── scripts/
│   ├── cloud-init/
│   │   └── k3s-gpu.yaml       # K3S bootstrap script
│   ├── setup-kubeconfig.sh    # Fetch kubeconfig from Brev
│   └── port-forward.sh        # Port forward helper
├── k8s/
│   ├── bootstrap/
│   │   └── argocd/            # ArgoCD installation
│   └── apps/
│       ├── argocd-apps/       # App-of-apps definitions
│       ├── minio/             # MinIO chart
│       ├── lakefs/            # LakeFS chart
│       ├── dagster/           # Dagster chart
│       ├── marimo/            # Marimo deployment
│       └── nvidia-ai/         # NIM + Safe Synthesizer
├── dagster/
│   ├── __init__.py
│   ├── definitions.py
│   ├── assets/
│   ├── io_managers/
│   ├── resources/
│   └── tests/
├── marimo/
│   └── notebooks/
├── config/
│   ├── nim/
│   └── safe-synthesizer/
├── Makefile
├── .gitignore
├── .env.example
└── README.md
```

---

## Files to Create

### 1. Makefile

```makefile
# Brev Data Platform - Makefile
.PHONY: help init create-instance delete-instance shell kubeconfig \
        port-forward-argocd port-forward-minio port-forward-lakefs \
        port-forward-dagster port-forward-marimo port-forward-nim \
        encrypt decrypt lint validate build-dagster

INSTANCE_NAME ?= brev-data-platform-dev
GPU_TYPE ?= a2-highgpu-1g:nvidia-a100-40gb:1

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# === Instance Management ===

create-instance: ## Create Brev GPU instance
	brev create $(INSTANCE_NAME) -g "$(GPU_TYPE)"

delete-instance: ## Delete Brev instance
	brev delete $(INSTANCE_NAME)

start-instance: ## Start stopped instance
	brev start $(INSTANCE_NAME)

stop-instance: ## Stop running instance
	brev stop $(INSTANCE_NAME)

shell: ## SSH into Brev instance
	brev shell $(INSTANCE_NAME)

status: ## Show instance status
	brev ls

# === Kubernetes Access ===

kubeconfig: ## Fetch kubeconfig from instance
	./scripts/setup-kubeconfig.sh $(INSTANCE_NAME)

# === Port Forwarding ===

port-forward-argocd: ## Forward ArgoCD UI to localhost:8080
	kubectl port-forward svc/argocd-server -n argocd 8080:443

port-forward-minio: ## Forward MinIO console to localhost:9001
	kubectl port-forward svc/minio-console -n minio 9001:9001

port-forward-lakefs: ## Forward LakeFS UI to localhost:8000
	kubectl port-forward svc/lakefs -n lakefs 8000:8000

port-forward-dagster: ## Forward Dagster UI to localhost:3000
	kubectl port-forward svc/dagster-webserver -n dagster 3000:3000

port-forward-marimo: ## Forward Marimo to localhost:2718
	kubectl port-forward svc/marimo -n marimo 2718:2718

port-forward-nim: ## Forward NIM LLM to localhost:8001
	kubectl port-forward svc/nim-llm -n nvidia-ai 8001:8000

# === Secrets Management ===

encrypt: ## Encrypt a file with SOPS (usage: make encrypt FILE=path/to/file.yaml)
	sops -e $(FILE) > $(FILE:.yaml=.enc.yaml)

decrypt: ## Decrypt a file with SOPS (usage: make decrypt FILE=path/to/file.enc.yaml)
	sops -d $(FILE)

edit-secret: ## Edit encrypted secret in place (usage: make edit-secret FILE=path/to/file.enc.yaml)
	sops $(FILE)

# === Validation ===

lint: ## Lint all code
	@echo "=== Linting Helm charts ==="
	@for chart in k8s/apps/*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "Linting $$chart"; \
			helm lint "$$chart" || exit 1; \
		fi \
	done
	@echo "=== Linting Dagster code ==="
	@if [ -d "dagster" ] && [ -f "dagster/requirements.txt" ]; then \
		cd dagster && ruff check . || true; \
	fi
	@echo "=== Lint complete ==="

validate: ## Validate configurations
	@echo "=== Validating Helm templates ==="
	@for chart in k8s/apps/*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "Templating $$chart"; \
			helm template test "$$chart" > /dev/null || exit 1; \
		fi \
	done
	@echo "=== Checking for plaintext secrets ==="
	@if grep -r "password:" k8s/ --include="*.yaml" | grep -v ".enc.yaml" | grep -v "secretKeyRef" | grep -v "#"; then \
		echo "WARNING: Possible plaintext secrets found!"; \
	fi
	@echo "=== Validation complete ==="

# === Dagster ===

build-dagster: ## Build Dagster Docker image
	docker build -t brev-data-platform/dagster:latest dagster/

dagster-dev: ## Run Dagster locally
	cd dagster && dagster dev

dagster-test: ## Run Dagster tests
	cd dagster && pytest tests/

# === ArgoCD Bootstrap ===

bootstrap-argocd: ## Install ArgoCD (run after kubeconfig is set up)
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	helm upgrade --install argocd argo/argo-cd \
		-n argocd \
		-f k8s/bootstrap/argocd/values.yaml

argocd-password: ## Get ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### 2. .gitignore

```gitignore
# Environment files
.env
.env.local
.env.*.local

# Kubernetes
kubeconfig.yaml
kubeconfig*.yaml
!kubeconfig.example.yaml

# Secrets (unencrypted)
**/secrets.yaml
**/secret.yaml
!**/*.enc.yaml

# Age keys
*.age
keys.txt

# Python
__pycache__/
*.py[cod]
*$py.class
.Python
venv/
.venv/
*.egg-info/
.eggs/
dist/
build/

# IDE
.idea/
.vscode/
*.swp
*.swo
.DS_Store

# Terraform (if used later)
*.tfstate
*.tfstate.*
.terraform/
*.tfvars
!*.tfvars.example

# Logs
*.log
logs/

# Temporary files
tmp/
temp/
*.tmp
```

### 3. .env.example

```bash
# Brev Data Platform - Environment Variables
# Copy this to .env.local and fill in your values
# NEVER commit .env.local to git!

# === NVIDIA NGC ===
# Get from: https://ngc.nvidia.com/setup/api-key
NGC_API_KEY=nvapi-your-key-here

# === GitHub ===
# Get from: https://github.com/settings/tokens
GITHUB_PAT=ghp_your-token-here
GITHUB_REPO=your-username/brev-data-platform

# === MinIO ===
# Generate strong passwords
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=change-me-to-strong-password

# === LakeFS ===
# Generate unique keys
LAKEFS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
LAKEFS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# === Brev Instance ===
BREV_INSTANCE_NAME=brev-data-platform-dev
BREV_GPU_TYPE=a2-highgpu-1g:nvidia-a100-40gb:1
```

### 4. scripts/setup-kubeconfig.sh

```bash
#!/bin/bash
# Fetch kubeconfig from Brev instance and configure for local use

set -e

INSTANCE_NAME="${1:-brev-data-platform-dev}"
KUBECONFIG_PATH="./kubeconfig.yaml"

echo "Fetching kubeconfig from $INSTANCE_NAME..."

# Copy kubeconfig from instance
brev copy "$INSTANCE_NAME:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_PATH"

# Get instance IP
INSTANCE_IP=$(brev ls --json | jq -r ".[] | select(.name==\"$INSTANCE_NAME\") | .dns")

if [ -z "$INSTANCE_IP" ] || [ "$INSTANCE_IP" = "null" ]; then
    echo "Could not determine instance IP. You may need to update the server address manually."
    echo "Use: brev shell $INSTANCE_NAME and run 'hostname -I' to get the IP"
else
    # Update server address in kubeconfig
    sed -i.bak "s|server: https://127.0.0.1:6443|server: https://$INSTANCE_IP:6443|g" "$KUBECONFIG_PATH"
    rm -f "${KUBECONFIG_PATH}.bak"
    echo "Updated kubeconfig server to https://$INSTANCE_IP:6443"
fi

echo ""
echo "Kubeconfig saved to $KUBECONFIG_PATH"
echo ""
echo "To use:"
echo "  export KUBECONFIG=$PWD/kubeconfig.yaml"
echo "  kubectl get nodes"
echo ""
echo "Or add to your shell profile:"
echo "  echo 'export KUBECONFIG=$PWD/kubeconfig.yaml' >> ~/.bashrc"
```

### 5. scripts/cloud-init/k3s-gpu.yaml

```yaml
#cloud-config
# K3S + NVIDIA GPU Setup for Brev Instance

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - jq

runcmd:
  # Install K3S
  - curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

  # Wait for K3S to be ready
  - sleep 30
  - until kubectl get nodes; do sleep 5; done

  # Install NVIDIA container toolkit (if not already present)
  - |
    if ! command -v nvidia-container-toolkit &> /dev/null; then
      distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
      curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | apt-key add -
      curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt-get update
      apt-get install -y nvidia-container-toolkit
    fi

  # Configure containerd for NVIDIA
  - nvidia-ctk runtime configure --runtime=containerd
  - systemctl restart containerd

  # Deploy NVIDIA device plugin
  - kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/nvidia-device-plugin.yml

  # Label node for GPU
  - kubectl label nodes --all nvidia.com/gpu.present=true --overwrite

  # Create namespaces
  - kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  - kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -
  - kubectl create namespace lakefs --dry-run=client -o yaml | kubectl apply -f -
  - kubectl create namespace dagster --dry-run=client -o yaml | kubectl apply -f -
  - kubectl create namespace marimo --dry-run=client -o yaml | kubectl apply -f -
  - kubectl create namespace nvidia-ai --dry-run=client -o yaml | kubectl apply -f -

final_message: "K3S with GPU support is ready! Run 'kubectl get nodes' to verify."
```

### 6. README.md (skeleton)

```markdown
# Brev Data Platform

GPU-accelerated data platform on NVIDIA Brev with K3S, ArgoCD, Dagster, LakeFS, MinIO, and NVIDIA AI Enterprise.

## Quick Start

See [docs/plans/active/grand_plan/development-plan.md](docs/plans/active/grand_plan/development-plan.md) for full setup instructions.

### Prerequisites

- Brev CLI (logged in)
- kubectl, helm, sops, age

### Create Instance

```bash
make create-instance
```

### Access Services

```bash
# Get kubeconfig
make kubeconfig
export KUBECONFIG=$PWD/kubeconfig.yaml

# Port forward services
make port-forward-argocd    # https://localhost:8080
make port-forward-dagster   # http://localhost:3000
make port-forward-minio     # http://localhost:9001
```

## Documentation

- [Development Plan](docs/plans/active/grand_plan/development-plan.md)
- [Invariants](docs/invariants/INVARIANTS.md)
- [Planning Protocol](docs/plans/CLAUDE.md)

## License

Proprietary - Internal Use Only
```

---

## Validation Approach

```bash
# Verify all directories exist
find . -type d | grep -E "(scripts|k8s|dagster|marimo|config)" | sort

# Verify Makefile works
make help

# Verify .gitignore patterns
git status  # Should not show .env.local or secrets

# Verify scripts are executable
ls -la scripts/*.sh
```

---

## Completion Criteria

- [ ] All directories created per structure above
- [ ] Makefile has all documented targets
- [ ] `make help` displays all commands
- [ ] `.gitignore` excludes sensitive files
- [ ] `.env.example` documents all variables
- [ ] Cloud-init script created
- [ ] Setup scripts are executable
- [ ] README.md provides basic overview

---

## Next Phase

Once repository structure is complete, proceed to [Phase 2: Secrets & Encryption Setup](phase-2.md).
