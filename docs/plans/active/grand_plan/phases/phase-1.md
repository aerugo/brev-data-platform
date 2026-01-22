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
- **INV-K008**: RKE2 as Kubernetes distribution - Bootstrap scripts use RKE2

---

## Directory Structure to Create

```
brev-data-platform/
├── .github/
│   └── workflows/              # GitHub Actions (Phase 10)
├── scripts/
│   ├── cloud-init/
│   │   └── rke2-gpu.yaml       # RKE2 bootstrap cloud-init
│   ├── bootstrap-rke2.sh       # RKE2 bootstrap script
│   ├── setup-kubeconfig.sh     # Fetch kubeconfig from Brev
│   ├── apply-secrets.sh        # Apply SOPS-encrypted secrets
│   └── create-secrets.sh       # Generate encrypted secrets
├── k8s/
│   ├── bootstrap/
│   │   └── argocd/             # ArgoCD installation
│   └── apps/
│       ├── argocd-apps/        # App-of-apps definitions
│       ├── kai-scheduler/      # KAI GPU Scheduler chart
│       ├── minio/              # MinIO chart
│       ├── lakefs/             # LakeFS chart
│       ├── monitoring/         # Prometheus/Grafana/Loki stack
│       ├── dagster/            # Dagster chart
│       ├── marimo/             # Marimo deployment
│       ├── nvidia-nim/         # NIM LLM chart
│       └── nvidia-safe-synth/  # Safe Synthesizer chart
├── dagster/
│   ├── __init__.py
│   ├── assets/
│   │   └── __init__.py
│   ├── io_managers/
│   │   └── __init__.py
│   ├── resources/
│   │   └── __init__.py
│   └── tests/
│       └── __init__.py
├── marimo/
│   └── notebooks/
├── config/
│   ├── nim/
│   └── safe-synthesizer/
├── Makefile
├── .gitignore
├── .env.example
├── .sops.yaml
└── README.md
```

---

## Files to Create

### 1. Makefile

The Makefile provides automation for instance management, RKE2 bootstrap, KAI Scheduler deployment, and development workflows.

```makefile
# Brev Data Platform - Makefile
.PHONY: help create-instance delete-instance start-instance stop-instance shell status \
        kubeconfig ssh-tunnel bootstrap-rke2 bootstrap-kai apply-secrets \
        port-forward-argocd port-forward-minio port-forward-lakefs \
        port-forward-dagster port-forward-marimo port-forward-nim \
        port-forward-grafana port-forward-prometheus port-forward-loki \
        encrypt decrypt edit-secret create-secrets lint validate \
        build-dagster dagster-dev dagster-test \
        bootstrap-argocd argocd-password grafana-password \
        up down destroy full-setup

INSTANCE_NAME ?= brev-data-platform-dev
# H200 GPU - 141GB VRAM, sufficient for NIM LLMs and Safe Synthesizer
GPU_TYPE ?= gpu-h200-sxm.1gpu-16vcpu-200gb
SSH_CONFIG ?= $(HOME)/.brev/ssh_config

# SOPS Age key file (default location)
export SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

# Colors for output
CYAN := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RESET := \033[0m

help: ## Show this help
	@echo "Brev Data Platform - Available Commands"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(CYAN)%-25s$(RESET) %s\n", $$1, $$2}'

# =============================================================================
# Instance Management
# =============================================================================

create-instance: ## Create Brev GPU instance
	@echo "$(GREEN)Creating Brev instance with GPU: $(GPU_TYPE)$(RESET)"
	brev create $(INSTANCE_NAME) -g "$(GPU_TYPE)"
	@echo ""
	@echo "$(YELLOW)Wait for instance to be ready, then run:$(RESET)"
	@echo "  make bootstrap-rke2"

delete-instance: ## Delete Brev instance (DESTRUCTIVE)
	brev delete $(INSTANCE_NAME)

start-instance: ## Start stopped instance
	brev start $(INSTANCE_NAME)

stop-instance: ## Stop running instance (saves cost)
	brev stop $(INSTANCE_NAME)

shell: ## SSH into Brev instance
	brev shell $(INSTANCE_NAME)

status: ## Show instance status
	brev ls

# =============================================================================
# Kubernetes Bootstrap & Access
# =============================================================================

bootstrap-rke2: ## Bootstrap RKE2 with GPU support on remote instance
	@echo "$(GREEN)Bootstrapping RKE2 on $(INSTANCE_NAME)...$(RESET)"
	@echo "RKE2 is required for KAI Scheduler and Run:AI compatibility."
	scp -F $(SSH_CONFIG) scripts/bootstrap-rke2.sh $(INSTANCE_NAME)-host:/tmp/
	ssh -F $(SSH_CONFIG) $(INSTANCE_NAME)-host 'chmod +x /tmp/bootstrap-rke2.sh && sudo /tmp/bootstrap-rke2.sh'
	@echo ""
	@echo "$(GREEN)RKE2 bootstrap complete!$(RESET)"
	@echo "Next steps:"
	@echo "  make kubeconfig"
	@echo "  make bootstrap-kai"

bootstrap-kai: ## Deploy KAI Scheduler for GPU workload scheduling
	@echo "$(GREEN)Deploying KAI Scheduler...$(RESET)"
	helm repo add nvidia https://nvidia.github.io/KAI-Scheduler 2>/dev/null || true
	helm repo update
	helm upgrade --install kai-scheduler k8s/apps/kai-scheduler \
		-n kube-system \
		-f k8s/apps/kai-scheduler/values.yaml \
		-f k8s/apps/kai-scheduler/values-dev.yaml
	@echo ""
	@echo "$(GREEN)KAI Scheduler deployed!$(RESET)"

kubeconfig: ## Fetch kubeconfig from instance
	@./scripts/setup-kubeconfig.sh $(INSTANCE_NAME)

ssh-tunnel: ## Start SSH tunnel for kubectl access (runs in foreground)
	@echo "$(GREEN)Starting SSH tunnel to RKE2 API...$(RESET)"
	ssh -F $(SSH_CONFIG) -N -L 6443:127.0.0.1:6443 $(INSTANCE_NAME)-host

ssh-tunnel-bg: ## Start SSH tunnel in background
	@pkill -f 'ssh.*6443:127.0.0.1:6443' 2>/dev/null || true
	@ssh -F $(SSH_CONFIG) -N -L 6443:127.0.0.1:6443 $(INSTANCE_NAME)-host &
	@sleep 2
	@echo "$(GREEN)SSH tunnel started in background$(RESET)"

apply-secrets: ## Apply encrypted secrets to cluster
	@./scripts/apply-secrets.sh

# =============================================================================
# Port Forwarding
# =============================================================================

port-forward-argocd: ## Forward ArgoCD UI to localhost:8080
	@echo "ArgoCD UI: https://localhost:8080"
	kubectl port-forward svc/argocd-server -n argocd 8080:443

port-forward-minio: ## Forward MinIO console to localhost:9001
	@echo "MinIO Console: http://localhost:9001"
	kubectl port-forward svc/minio-console -n minio 9001:9001

port-forward-lakefs: ## Forward LakeFS UI to localhost:8000
	@echo "LakeFS UI: http://localhost:8000"
	kubectl port-forward svc/lakefs -n lakefs 8000:8000

port-forward-dagster: ## Forward Dagster UI to localhost:3000
	@echo "Dagster UI: http://localhost:3000"
	kubectl port-forward svc/dagster-webserver -n dagster 3000:3000

port-forward-marimo: ## Forward Marimo to localhost:2718
	@echo "Marimo: http://localhost:2718"
	kubectl port-forward svc/marimo -n marimo 2718:2718

port-forward-nim: ## Forward NIM LLM to localhost:8001
	@echo "NIM LLM API: http://localhost:8001"
	kubectl port-forward svc/nim-llm -n nvidia-ai 8001:8000

port-forward-grafana: ## Forward Grafana to localhost:3001
	@echo "Grafana UI: http://localhost:3001"
	kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80

port-forward-prometheus: ## Forward Prometheus to localhost:9090
	@echo "Prometheus UI: http://localhost:9090"
	kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

# =============================================================================
# Secrets Management
# =============================================================================

encrypt: ## Encrypt a file with SOPS (usage: make encrypt FILE=path/to/file.yaml)
ifndef FILE
	$(error FILE is required. Usage: make encrypt FILE=path/to/file.yaml)
endif
	sops -e $(FILE) > $(FILE:.yaml=.enc.yaml)
	@echo "Encrypted to $(FILE:.yaml=.enc.yaml)"

decrypt: ## Decrypt a file with SOPS (usage: make decrypt FILE=path/to/file.enc.yaml)
ifndef FILE
	$(error FILE is required. Usage: make decrypt FILE=path/to/file.enc.yaml)
endif
	sops -d $(FILE)

edit-secret: ## Edit encrypted secret in place
ifndef FILE
	$(error FILE is required. Usage: make edit-secret FILE=path/to/file.enc.yaml)
endif
	sops $(FILE)

create-secrets: ## Create all encrypted secrets from .env.local
	@./scripts/create-secrets.sh

# =============================================================================
# Validation
# =============================================================================

lint: ## Lint all code (Helm, Python)
	@echo "=== Linting Helm charts ==="
	@for chart in k8s/apps/*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "Linting $$chart"; \
			helm lint "$$chart" || exit 1; \
		fi \
	done
	@echo ""
	@echo "=== Linting Dagster code ==="
	@if [ -f "dagster/requirements.txt" ]; then \
		cd dagster && python -m ruff check . 2>/dev/null || echo "Ruff not installed"; \
	fi
	@echo ""
	@echo "=== Lint complete ==="

validate: ## Validate configurations
	@echo "=== Validating Helm templates ==="
	@for chart in k8s/apps/*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "Templating $$chart"; \
			helm dependency update "$$chart" 2>/dev/null || true; \
			helm template test "$$chart" > /dev/null || exit 1; \
		fi \
	done
	@echo ""
	@echo "=== Checking for plaintext secrets ==="
	@if grep -r "stringData:" k8s/ --include="*.yaml" 2>/dev/null | grep -v ".enc.yaml" | grep -v "#"; then \
		echo "WARNING: Possible plaintext secrets found!"; \
	else \
		echo "No plaintext secrets detected."; \
	fi
	@echo ""
	@echo "=== Validation complete ==="

# =============================================================================
# Dagster
# =============================================================================

build-dagster: ## Build Dagster Docker image
	docker build -t brev-data-platform/dagster:latest dagster/

dagster-dev: ## Run Dagster locally (requires dependencies installed)
	cd dagster && dagster dev

dagster-test: ## Run Dagster tests
	cd dagster && pytest tests/ -v

# =============================================================================
# ArgoCD Bootstrap
# =============================================================================

bootstrap-argocd: ## Install ArgoCD (run after kubeconfig is set up)
	@./scripts/bootstrap-argocd.sh

argocd-password: ## Get ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

grafana-password: ## Get Grafana admin password
	@kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 -d && echo

# =============================================================================
# Full Stack Operations
# =============================================================================

full-setup: ## Complete setup: create instance, bootstrap RKE2 + KAI, configure kubectl
	@echo "$(GREEN)=== Full Stack Setup ===$(RESET)"
	@echo "Step 1/6: Creating Brev instance..."
	@$(MAKE) create-instance
	@echo "$(YELLOW)Waiting 90s for instance to be ready...$(RESET)"
	@sleep 90
	@echo "Step 2/6: Bootstrapping RKE2 with GPU support..."
	@$(MAKE) bootstrap-rke2
	@echo "Step 3/6: Fetching kubeconfig..."
	@$(MAKE) kubeconfig
	@echo "Step 4/6: Starting SSH tunnel..."
	@$(MAKE) ssh-tunnel-bg
	@echo "Step 5/6: Deploying KAI Scheduler..."
	@export KUBECONFIG=$$PWD/kubeconfig.yaml && $(MAKE) bootstrap-kai
	@echo "Step 6/6: Applying secrets to cluster..."
	@export KUBECONFIG=$$PWD/kubeconfig.yaml && $(MAKE) apply-secrets
	@echo "$(GREEN)=== Setup Complete! ===$(RESET)"
	@echo "Next: make bootstrap-argocd"

up: create-instance ## Create instance and wait for it to be ready
	@echo "Waiting for instance to be ready..."
	@sleep 30
	@brev ls
	@echo "$(YELLOW)Next: make bootstrap-rke2$(RESET)"

down: stop-instance ## Stop instance to save costs
	@echo "Instance stopped. Start with 'make start-instance'"

destroy: delete-instance ## Delete instance completely (DESTRUCTIVE)
	@echo "Instance deleted."
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

# Helm
**/charts/*.tgz
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
# H200 141GB VRAM - $4.20/hr
BREV_GPU_TYPE=gpu-h200-sxm.1gpu-16vcpu-200gb
```

### 4. scripts/setup-kubeconfig.sh

```bash
#!/bin/bash
# Fetch kubeconfig from Brev instance and configure for local use
# Supports both RKE2 and K3S (auto-detects)

set -e

INSTANCE_NAME="${1:-brev-data-platform-dev}"
KUBECONFIG_PATH="./kubeconfig.yaml"
SSH_CONFIG="${HOME}/.brev/ssh_config"

echo "Fetching kubeconfig from $INSTANCE_NAME..."

# Try RKE2 first (preferred), then K3S
if ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" 'test -f /etc/rancher/rke2/rke2.yaml' 2>/dev/null; then
    echo "Detected RKE2 cluster"
    ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" 'sudo cat /etc/rancher/rke2/rke2.yaml' > "$KUBECONFIG_PATH"
elif ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" 'test -f /etc/rancher/k3s/k3s.yaml' 2>/dev/null; then
    echo "Detected K3S cluster"
    ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" 'sudo cat /etc/rancher/k3s/k3s.yaml' > "$KUBECONFIG_PATH"
else
    echo "ERROR: No kubeconfig found. Run 'make bootstrap-rke2' first."
    exit 1
fi

# Update server address to localhost (for SSH tunnel)
sed -i.bak 's|server: https://127.0.0.1:6443|server: https://127.0.0.1:6443|g' "$KUBECONFIG_PATH"
rm -f "${KUBECONFIG_PATH}.bak"

echo ""
echo "Kubeconfig saved to $KUBECONFIG_PATH"
echo ""
echo "To use with SSH tunnel:"
echo "  1. Start tunnel: make ssh-tunnel-bg"
echo "  2. Set kubeconfig: export KUBECONFIG=\$PWD/kubeconfig.yaml"
echo "  3. Test: kubectl get nodes"
```

### 5. scripts/cloud-init/rke2-gpu.yaml

```yaml
#cloud-config
# RKE2 + NVIDIA GPU Setup for Brev Instance
# Use this with: brev create --cloud-init scripts/cloud-init/rke2-gpu.yaml

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - jq

runcmd:
  # Install RKE2
  - curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE=server sh -

  # Configure RKE2
  - mkdir -p /etc/rancher/rke2
  - |
    cat > /etc/rancher/rke2/config.yaml <<EOF
    write-kubeconfig-mode: "0644"
    cni: calico
    disable:
      - rke2-ingress-nginx
    EOF

  # Start RKE2
  - systemctl enable rke2-server.service
  - systemctl start rke2-server.service

  # Wait for RKE2 to be ready
  - sleep 60
  - until /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes; do sleep 10; done

  # Set up kubectl for root
  - mkdir -p /root/.kube
  - cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
  - export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

  # Install NVIDIA GPU Operator (handles driver + device plugin)
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://raw.githubusercontent.com/NVIDIA/gpu-operator/v23.9.1/deployments/gpu-operator/crds/nvidia.com_clusterpolicies.yaml
  - /var/lib/rancher/rke2/bin/helm --kubeconfig /etc/rancher/rke2/rke2.yaml repo add nvidia https://helm.ngc.nvidia.com/nvidia
  - /var/lib/rancher/rke2/bin/helm --kubeconfig /etc/rancher/rke2/rke2.yaml repo update
  - /var/lib/rancher/rke2/bin/helm --kubeconfig /etc/rancher/rke2/rke2.yaml upgrade --install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace --wait

  # Label node for GPU
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml label nodes --all nvidia.com/gpu.present=true --overwrite

  # Install local-path-provisioner (RKE2 doesn't include it by default)
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
  - sleep 10
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  # Create namespaces
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace argocd --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace minio --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace lakefs --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace dagster --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace marimo --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace nvidia-ai --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -
  - /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml create namespace monitoring --dry-run=client -o yaml | /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml apply -f -

final_message: "RKE2 with GPU support is ready! Run 'kubectl get nodes' to verify."
```

### 6. README.md (skeleton)

```markdown
# Brev Data Platform

GPU-accelerated data platform on NVIDIA Brev with RKE2, KAI Scheduler, ArgoCD, Dagster, LakeFS, MinIO, and NVIDIA AI Enterprise (NIM LLM + Safe Synthesizer).

## Quick Start

See [docs/plans/active/grand_plan/development-plan.md](docs/plans/active/grand_plan/development-plan.md) for full setup instructions.

### Prerequisites

- Brev CLI (logged in)
- kubectl, helm, sops, age

### Create Instance

```bash
# Full automated setup
make full-setup

# Or step by step:
make create-instance
make bootstrap-rke2
make kubeconfig
make ssh-tunnel-bg
make bootstrap-kai
make bootstrap-argocd
```

### Access Services

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml

# Port forward services
make port-forward-argocd    # https://localhost:8080
make port-forward-dagster   # http://localhost:3000
make port-forward-minio     # http://localhost:9001
make port-forward-grafana   # http://localhost:3001
```

## Architecture

- **RKE2**: Enterprise Kubernetes (Run:AI compatible)
- **KAI Scheduler**: GPU workload scheduling (fractional GPUs, gang scheduling)
- **ArgoCD**: GitOps continuous deployment
- **MinIO + LakeFS**: Versioned data lake storage
- **Dagster**: Data pipeline orchestration
- **Marimo**: Interactive notebooks
- **NVIDIA NIM**: LLM inference
- **NVIDIA Safe Synthesizer**: Synthetic data generation
- **Prometheus/Grafana/Loki**: Full observability stack

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
- [ ] Makefile has all documented targets including RKE2 bootstrap
- [ ] `make help` displays all commands
- [ ] `.gitignore` excludes sensitive files
- [ ] `.env.example` documents all variables with H200 GPU
- [ ] RKE2 cloud-init script created (`scripts/cloud-init/rke2-gpu.yaml`)
- [ ] Setup scripts are executable
- [ ] README.md provides basic overview

---

## Next Phase

Once repository structure is complete, proceed to [Phase 2: Secrets & Encryption Setup](phase-2.md).
