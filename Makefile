# Brev Data Platform - Makefile
.PHONY: help init create-instance delete-instance start-instance stop-instance shell status \
        kubeconfig port-forward-argocd port-forward-minio port-forward-lakefs \
        port-forward-dagster port-forward-marimo port-forward-nim \
        encrypt decrypt edit-secret lint validate build-dagster dagster-dev dagster-test \
        bootstrap-argocd argocd-password

INSTANCE_NAME ?= brev-data-platform-dev
GPU_TYPE ?= a2-highgpu-1g:nvidia-a100-40gb:1

# Colors for output
CYAN := \033[36m
RESET := \033[0m

help: ## Show this help
	@echo "Brev Data Platform - Available Commands"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "$(CYAN)%-25s$(RESET) %s\n", $$1, $$2}'

# =============================================================================
# Instance Management
# =============================================================================

create-instance: ## Create Brev GPU instance
	brev create $(INSTANCE_NAME) -g "$(GPU_TYPE)"

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
# Kubernetes Access
# =============================================================================

kubeconfig: ## Fetch kubeconfig from instance
	@./scripts/setup-kubeconfig.sh $(INSTANCE_NAME)

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

# =============================================================================
# Full Stack
# =============================================================================

up: create-instance ## Create instance and wait for it to be ready
	@echo "Waiting for instance to be ready..."
	@sleep 30
	@brev ls

down: stop-instance ## Stop instance to save costs
	@echo "Instance stopped. Start with 'make start-instance'"

destroy: delete-instance ## Delete instance completely (DESTRUCTIVE)
	@echo "Instance deleted."
