# Brev Data Platform - Makefile
.PHONY: help setup create-instance create-instance-help delete-instance start-instance stop-instance shell status \
        kubeconfig ssh-tunnel bootstrap-rke2 bootstrap-k3s bootstrap-kai apply-secrets \
        port-forward-argocd port-forward-minio port-forward-lakefs \
        port-forward-dagster port-forward-marimo port-forward-nim \
        port-forward-grafana port-forward-prometheus port-forward-loki \
        encrypt decrypt edit-secret create-secrets lint validate \
        build-dagster dagster-dev dagster-test \
        bootstrap-argocd argocd-password grafana-password \
        up down destroy full-setup

INSTANCE_NAME ?= brev-data-platform-dev
# GPU type - NOTE: The Brev CLI only supports GCP which has limited GPU availability.
# For A100+ GPUs, use the Brev web console (https://brev.nvidia.com) instead.
# Recommended: CRUSOE provider "a100-80gb.1x" ($1.98/hr, flexible storage, stop/start safe)
#
# CLI-supported GCP types (limited availability):
#   T4 (16GB):     n1-highmem-4:nvidia-tesla-t4:1  (NOT sufficient for this platform!)
#   A100:          A100 (if org has GCP A100 quota)
GPU_TYPE ?= A100
SSH_CONFIG ?= $(HOME)/.brev/ssh_config

# SOPS Age key file (default location for Age encryption key)
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

setup: ## Interactive setup - prompts for instance name, then bootstraps RKE2 + kubeconfig + tunnel
	@./scripts/setup-instance.sh $(if $(INSTANCE_NAME),$(INSTANCE_NAME),)

create-instance: ## Create Brev GPU instance (CLI - GCP only, see create-instance-help for A100+)
	@echo "$(YELLOW)NOTE: Brev CLI only supports GCP. For A100+ GPUs, use web console.$(RESET)"
	@echo "$(YELLOW)Run 'make create-instance-help' for web console instructions.$(RESET)"
	@echo ""
	@echo "$(GREEN)Attempting to create Brev instance with GPU: $(GPU_TYPE)$(RESET)"
	brev create $(INSTANCE_NAME) -g "$(GPU_TYPE)"
	@echo ""
	@echo "$(YELLOW)Wait for instance to be ready, then run:$(RESET)"
	@echo "  make bootstrap-rke2"

create-instance-help: ## Show instructions for creating A100+ instances via web console
	@echo "$(GREEN)Creating A100+ Instance via Brev Web Console$(RESET)"
	@echo ""
	@echo "The Brev CLI only supports GCP which has limited GPU availability."
	@echo "For A100+ GPUs, use the web console:"
	@echo ""
	@echo "1. Go to https://brev.nvidia.com"
	@echo "2. Select your organization"
	@echo "3. Click GPUs → Select A100 • 80 GiB VRAM from CRUSOE provider"
	@echo "   - Instance type: a100-80gb.1x (~\$$1.98/hr)"
	@echo "   - Flexible storage, flexible ports, stop/start without data loss"
	@echo "4. Configure:"
	@echo "   - Disk Storage: 256 GiB"
	@echo "   - Software: VM Mode w/ Jupyter"
	@echo "   - Name: $(INSTANCE_NAME)"
	@echo "5. Click Deploy and wait ~7 minutes"
	@echo ""
	@echo "$(YELLOW)After instance is running:$(RESET)"
	@echo "  make setup              # Interactive setup (recommended)"
	@echo "  # OR manually:"
	@echo "  make bootstrap-rke2"
	@echo "  make kubeconfig"
	@echo "  make ssh-tunnel"

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

bootstrap-rke2: ## Bootstrap RKE2 with GPU support on remote instance (recommended)
	@echo "$(GREEN)Bootstrapping RKE2 on $(INSTANCE_NAME)...$(RESET)"
	@echo "RKE2 is required for KAI Scheduler and Run:AI compatibility."
	@echo "This will take a few minutes..."
	scp -F $(SSH_CONFIG) scripts/bootstrap-rke2.sh $(INSTANCE_NAME)-host:/tmp/
	ssh -F $(SSH_CONFIG) $(INSTANCE_NAME)-host 'chmod +x /tmp/bootstrap-rke2.sh && sudo /tmp/bootstrap-rke2.sh'
	@echo ""
	@echo "$(GREEN)RKE2 bootstrap complete!$(RESET)"
	@echo "Next steps:"
	@echo "  make kubeconfig"
	@echo "  make bootstrap-kai"

bootstrap-k3s: ## Bootstrap K3S with GPU support (deprecated, use bootstrap-rke2)
	@echo "$(YELLOW)WARNING: K3S is deprecated. Use 'make bootstrap-rke2' for KAI Scheduler support.$(RESET)"
	@echo "$(GREEN)Bootstrapping K3S on $(INSTANCE_NAME)...$(RESET)"
	@echo "This will take a few minutes..."
	scp -F $(SSH_CONFIG) scripts/bootstrap-k3s.sh $(INSTANCE_NAME)-host:/tmp/
	ssh -F $(SSH_CONFIG) $(INSTANCE_NAME)-host 'chmod +x /tmp/bootstrap-k3s.sh && /tmp/bootstrap-k3s.sh'

bootstrap-kai: ## Deploy KAI Scheduler for GPU workload scheduling
	@echo "$(GREEN)Deploying KAI Scheduler v0.12.9 from NVIDIA OCI registry...$(RESET)"
	helm upgrade -i kai-scheduler oci://ghcr.io/nvidia/kai-scheduler/kai-scheduler \
		-n kai-scheduler --create-namespace \
		--version v0.12.9 \
		--wait --timeout 5m
	@echo ""
	@echo "$(GREEN)KAI Scheduler deployed!$(RESET)"
	@echo "Verify with: kubectl get pods -n kai-scheduler"

kubeconfig: ## Fetch kubeconfig from instance
	@./scripts/setup-kubeconfig.sh $(INSTANCE_NAME)

ssh-tunnel: ## Start SSH tunnel for kubectl access (runs in foreground)
	@echo "$(GREEN)Starting SSH tunnel to RKE2 API...$(RESET)"
	@echo "Keep this running in the background or use: make ssh-tunnel &"
	@echo "Then in another terminal: export KUBECONFIG=$$PWD/kubeconfig.yaml"
	ssh -F $(SSH_CONFIG) -N -L 6443:127.0.0.1:6443 $(INSTANCE_NAME)-host

ssh-tunnel-bg: ## Start SSH tunnel in background
	@pkill -f 'ssh.*6443:127.0.0.1:6443' 2>/dev/null || true
	@ssh -F $(SSH_CONFIG) -N -L 6443:127.0.0.1:6443 $(INSTANCE_NAME)-host &
	@sleep 2
	@echo "$(GREEN)SSH tunnel started in background$(RESET)"
	@echo "To stop: pkill -f 'ssh.*6443:127.0.0.1:6443'"

apply-secrets: ## Apply encrypted secrets to cluster
	@./scripts/apply-secrets.sh

# =============================================================================
# Port Forwarding
# =============================================================================

port-forward-argocd: ## Forward ArgoCD UI to localhost:8080
	@echo "ArgoCD UI: https://localhost:8080"
	@echo "Username: admin"
	@echo "Password: run 'make argocd-password'"
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
	@echo "Username: admin"
	@echo "Password: run 'make grafana-password'"
	kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80

port-forward-prometheus: ## Forward Prometheus to localhost:9090
	@echo "Prometheus UI: http://localhost:9090"
	kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090

port-forward-loki: ## Forward Loki API to localhost:3100
	@echo "Loki API: http://localhost:3100"
	kubectl port-forward svc/loki -n monitoring 3100:3100

# =============================================================================
# Secrets Management
# =============================================================================

encrypt: ## Encrypt a file with SOPS (usage: make encrypt FILE=path/to/file.yaml)
ifndef FILE
	$(error FILE is required. Usage: make encrypt FILE=path/to/file.yaml)
endif
	sops -e $(FILE) > $(FILE:.yaml=.enc.yaml)
	@echo "Encrypted to $(FILE:.yaml=.enc.yaml)"
	@echo "Remember to delete the plaintext file: rm $(FILE)"

decrypt: ## Decrypt a file with SOPS (usage: make decrypt FILE=path/to/file.enc.yaml)
ifndef FILE
	$(error FILE is required. Usage: make decrypt FILE=path/to/file.enc.yaml)
endif
	sops -d $(FILE)

edit-secret: ## Edit encrypted secret in place (usage: make edit-secret FILE=path/to/file.enc.yaml)
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
		cd dagster && python -m ruff check . 2>/dev/null || echo "Ruff not installed or no Python files"; \
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
	@echo ""
	@echo "Step 1/6: Creating Brev instance..."
	@$(MAKE) create-instance
	@echo ""
	@echo "$(YELLOW)Waiting 90s for instance to be ready...$(RESET)"
	@sleep 90
	@echo ""
	@echo "Step 2/6: Bootstrapping RKE2 with GPU support..."
	@$(MAKE) bootstrap-rke2
	@echo ""
	@echo "Step 3/6: Fetching kubeconfig..."
	@$(MAKE) kubeconfig
	@echo ""
	@echo "Step 4/6: Starting SSH tunnel..."
	@$(MAKE) ssh-tunnel-bg
	@echo ""
	@echo "Step 5/6: Deploying KAI Scheduler..."
	@export KUBECONFIG=$$PWD/kubeconfig.yaml && $(MAKE) bootstrap-kai
	@echo ""
	@echo "Step 6/6: Applying secrets to cluster..."
	@export KUBECONFIG=$$PWD/kubeconfig.yaml && $(MAKE) apply-secrets
	@echo ""
	@echo "$(GREEN)=== Setup Complete! ===$(RESET)"
	@echo ""
	@echo "Next steps:"
	@echo "  export KUBECONFIG=$$PWD/kubeconfig.yaml"
	@echo "  kubectl get nodes"
	@echo "  make bootstrap-argocd"

up: create-instance ## Create instance and wait for it to be ready
	@echo "Waiting for instance to be ready..."
	@sleep 30
	@brev ls
	@echo ""
	@echo "$(YELLOW)Next: make bootstrap-rke2$(RESET)"

down: stop-instance ## Stop instance to save costs
	@echo "Instance stopped. Start with 'make start-instance'"

destroy: delete-instance ## Delete instance completely (DESTRUCTIVE)
	@echo "Instance deleted."
