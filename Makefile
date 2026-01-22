# Brev Data Platform - Makefile
.PHONY: help setup delete-instance start-instance stop-instance shell status \
        kubeconfig ssh-tunnel ssh-tunnel-bg bootstrap-rke2 bootstrap-kai apply-secrets \
        port-forward-all port-forward-argocd port-forward-minio port-forward-lakefs \
        port-forward-dagster port-forward-jupyterhub port-forward-nim \
        port-forward-grafana port-forward-prometheus port-forward-loki \
        encrypt decrypt edit-secret create-secrets lint validate \
        validate-platform validate-quick validate-k8s \
        build-dagster dagster-dev dagster-test \
        bootstrap-argocd argocd-password grafana-password \
        minio-credentials lakefs-credentials all-credentials \
        down destroy full-setup

INSTANCE_NAME ?= brev-data-platform-dev
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

setup: ## Interactive setup - guides through instance creation, bootstraps RKE2 + kubeconfig + tunnel
	@./scripts/setup-instance.sh $(if $(INSTANCE_NAME),$(INSTANCE_NAME),)

full-setup: setup ## Alias for setup (interactive full stack setup)

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
	@echo "Keep this running in the background or use: make ssh-tunnel-bg"
	@echo ""
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo "$(CYAN)  BREV DATA PLATFORM - SERVICE ACCESS$(RESET)"
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo ""
	@echo "Run $(YELLOW)make port-forward-all$(RESET) in another terminal to access services:"
	@echo ""
	@echo "$(GREEN)ArgoCD$(RESET)       https://localhost:8080"
	@echo "             User: admin"
	@echo "             Pass: $(YELLOW)make argocd-password$(RESET)"
	@echo ""
	@echo "$(GREEN)JupyterHub$(RESET)   http://localhost:8000"
	@echo "             User: any username"
	@echo "             Pass: any password (dummy auth)"
	@echo ""
	@echo "$(GREEN)Dagster$(RESET)      http://localhost:3000"
	@echo "             No authentication required"
	@echo ""
	@echo "$(GREEN)LakeFS$(RESET)       http://localhost:8001"
	@echo "             User: $(YELLOW)make lakefs-credentials$(RESET)"
	@echo ""
	@echo "$(GREEN)MinIO$(RESET)        http://localhost:9001"
	@echo "             User: $(YELLOW)make minio-credentials$(RESET)"
	@echo ""
	@echo "$(GREEN)NIM LLM$(RESET)      http://localhost:8002"
	@echo "             OpenAI-compatible API (no auth)"
	@echo ""
	@echo "$(GREEN)Grafana$(RESET)      http://localhost:3001"
	@echo "             User: admin"
	@echo "             Pass: $(YELLOW)make grafana-password$(RESET)"
	@echo ""
	@echo "$(GREEN)Prometheus$(RESET)   http://localhost:9090"
	@echo "             No authentication required"
	@echo ""
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo ""
	ssh -F $(SSH_CONFIG) -N -L 6443:127.0.0.1:6443 $(INSTANCE_NAME)-host

ssh-tunnel-bg: ## Start SSH tunnel in background and show service info
	@pkill -f 'ssh.*6443:127.0.0.1:6443' 2>/dev/null || true
	@ssh -F $(SSH_CONFIG) -N -L 6443:127.0.0.1:6443 $(INSTANCE_NAME)-host &
	@sleep 2
	@echo "$(GREEN)SSH tunnel started in background$(RESET)"
	@echo "To stop: pkill -f 'ssh.*6443:127.0.0.1:6443'"
	@echo ""
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo "$(CYAN)  BREV DATA PLATFORM - SERVICE CREDENTIALS$(RESET)"
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo ""
	@ARGOCD_PWD=$$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	GRAFANA_PWD=$$(kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	MINIO_USER=$$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	MINIO_PASS=$$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	LAKEFS_KEY=$$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.access-key-id}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	LAKEFS_SECRET=$$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.secret-access-key}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	echo "$(GREEN)ArgoCD$(RESET)       https://localhost:8080"; \
	echo "             User: admin"; \
	echo "             Pass: $$ARGOCD_PWD"; \
	echo ""; \
	echo "$(GREEN)JupyterHub$(RESET)   http://localhost:8000"; \
	echo "             User: any username"; \
	echo "             Pass: any password"; \
	echo ""; \
	echo "$(GREEN)Dagster$(RESET)      http://localhost:3000"; \
	echo "             (no auth)"; \
	echo ""; \
	echo "$(GREEN)LakeFS$(RESET)       http://localhost:8001"; \
	echo "             Access Key: $$LAKEFS_KEY"; \
	echo "             Secret Key: $$LAKEFS_SECRET"; \
	echo ""; \
	echo "$(GREEN)MinIO$(RESET)        http://localhost:9001"; \
	echo "             User: $$MINIO_USER"; \
	echo "             Pass: $$MINIO_PASS"; \
	echo ""; \
	echo "$(GREEN)NIM LLM$(RESET)      http://localhost:8002"; \
	echo "             (OpenAI-compatible, no auth)"; \
	echo ""; \
	echo "$(GREEN)Grafana$(RESET)      http://localhost:3001"; \
	echo "             User: admin"; \
	echo "             Pass: $$GRAFANA_PWD"; \
	echo ""; \
	echo "$(GREEN)Prometheus$(RESET)   http://localhost:9090"; \
	echo "             (no auth)"; \
	echo ""
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo ""
	@echo "Run $(YELLOW)make port-forward-all$(RESET) to access these services."

apply-secrets: ## Apply encrypted secrets to cluster
	@./scripts/apply-secrets.sh

# =============================================================================
# Port Forwarding
# =============================================================================

port-forward-all: ## Forward all services (Ctrl+C to stop)
	@echo "$(GREEN)Starting port forwards for all services...$(RESET)"
	@echo ""
	@ARGOCD_PWD=$$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "run 'make argocd-password'"); \
	GRAFANA_PWD=$$(kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "run 'make grafana-password'"); \
	echo "$(CYAN)Services:$(RESET)"; \
	echo "  ArgoCD:      https://localhost:8080"; \
	echo "               User: admin  Password: $$ARGOCD_PWD"; \
	echo ""; \
	echo "  JupyterHub:  http://localhost:8000"; \
	echo "               User: any    Password: any"; \
	echo ""; \
	echo "  Dagster:     http://localhost:3000"; \
	echo ""; \
	echo "  LakeFS:      http://localhost:8001"; \
	echo "               (credentials in .env.local)"; \
	echo ""; \
	echo "  MinIO:       http://localhost:9001"; \
	echo "               (credentials in .env.local)"; \
	echo ""; \
	echo "  NIM API:     http://localhost:8002"; \
	echo "               (OpenAI-compatible endpoint)"; \
	echo ""; \
	echo "  Grafana:     http://localhost:3001"; \
	echo "               User: admin  Password: $$GRAFANA_PWD"; \
	echo ""; \
	echo "  Prometheus:  http://localhost:9090"; \
	echo ""; \
	echo "$(YELLOW)Press Ctrl+C to stop all port forwards$(RESET)"; \
	echo ""; \
	trap 'kill $$(jobs -p) 2>/dev/null' EXIT; \
	kubectl port-forward svc/argocd-server -n argocd 8080:443 2>/dev/null & \
	kubectl port-forward svc/proxy-public -n jupyterhub 8000:80 2>/dev/null & \
	kubectl port-forward svc/dagster-webserver -n dagster 3000:3000 2>/dev/null & \
	kubectl port-forward svc/lakefs -n lakefs 8001:8000 2>/dev/null & \
	kubectl port-forward svc/minio-console -n minio 9001:9001 2>/dev/null & \
	kubectl port-forward svc/nim-llm -n nvidia-ai 8002:8000 2>/dev/null & \
	kubectl port-forward svc/monitoring-grafana -n monitoring 3001:80 2>/dev/null & \
	kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090 2>/dev/null & \
	wait

port-forward-argocd: ## Forward ArgoCD UI to localhost:8080
	@echo "ArgoCD UI: https://localhost:8080"
	@echo "Username: admin"
	@echo "Password: run 'make argocd-password'"
	kubectl port-forward svc/argocd-server -n argocd 8080:443

port-forward-minio: ## Forward MinIO console to localhost:9001
	@echo "MinIO Console: http://localhost:9001"
	kubectl port-forward svc/minio-console -n minio 9001:9001

port-forward-lakefs: ## Forward LakeFS UI to localhost:8001
	@echo "LakeFS UI: http://localhost:8001"
	kubectl port-forward svc/lakefs -n lakefs 8001:8000

port-forward-dagster: ## Forward Dagster UI to localhost:3000
	@echo "Dagster UI: http://localhost:3000"
	kubectl port-forward svc/dagster-webserver -n dagster 3000:3000

port-forward-jupyterhub: ## Forward JupyterHub to localhost:8000
	@echo "JupyterHub: http://localhost:8000"
	@echo "Login with any username and any password (dummy auth)"
	kubectl port-forward svc/proxy-public -n jupyterhub 8000:80

port-forward-nim: ## Forward NIM LLM to localhost:8002
	@echo "NIM LLM API: http://localhost:8002"
	kubectl port-forward svc/nim-llm -n nvidia-ai 8002:8000

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

validate-platform: ## Run full platform validation (K8s, pods, services, Dagster)
	@./scripts/validate-platform.sh

validate-quick: ## Quick health check (K8s cluster and pods only)
	@./scripts/validate-platform.sh --quick

validate-k8s: ## Kubernetes validation only (no Dagster tests)
	@./scripts/validate-platform.sh --k8s

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

minio-credentials: ## Get MinIO root credentials
	@echo "MinIO Credentials:"
	@echo -n "  User: " && kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootUser}" | base64 -d && echo
	@echo -n "  Pass: " && kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootPassword}" | base64 -d && echo

lakefs-credentials: ## Get LakeFS access credentials
	@echo "LakeFS Credentials:"
	@echo -n "  Access Key: " && kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.access-key-id}" | base64 -d && echo
	@echo -n "  Secret Key: " && kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.secret-access-key}" | base64 -d && echo

all-credentials: ## Show all service credentials
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo "$(CYAN)  ALL SERVICE CREDENTIALS$(RESET)"
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"
	@echo ""
	@ARGOCD_PWD=$$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	GRAFANA_PWD=$$(kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	MINIO_USER=$$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	MINIO_PASS=$$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	LAKEFS_KEY=$$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.access-key-id}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	LAKEFS_SECRET=$$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.secret-access-key}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A"); \
	echo "$(GREEN)ArgoCD$(RESET)       https://localhost:8080"; \
	echo "             User: admin"; \
	echo "             Pass: $$ARGOCD_PWD"; \
	echo ""; \
	echo "$(GREEN)JupyterHub$(RESET)   http://localhost:8000"; \
	echo "             User: any username"; \
	echo "             Pass: any password"; \
	echo ""; \
	echo "$(GREEN)Dagster$(RESET)      http://localhost:3000"; \
	echo "             (no auth)"; \
	echo ""; \
	echo "$(GREEN)LakeFS$(RESET)       http://localhost:8001"; \
	echo "             Access Key: $$LAKEFS_KEY"; \
	echo "             Secret Key: $$LAKEFS_SECRET"; \
	echo ""; \
	echo "$(GREEN)MinIO$(RESET)        http://localhost:9001"; \
	echo "             User: $$MINIO_USER"; \
	echo "             Pass: $$MINIO_PASS"; \
	echo ""; \
	echo "$(GREEN)NIM LLM$(RESET)      http://localhost:8002"; \
	echo "             (OpenAI-compatible, no auth)"; \
	echo ""; \
	echo "$(GREEN)Grafana$(RESET)      http://localhost:3001"; \
	echo "             User: admin"; \
	echo "             Pass: $$GRAFANA_PWD"; \
	echo ""; \
	echo "$(GREEN)Prometheus$(RESET)   http://localhost:9090"; \
	echo "             (no auth)"; \
	echo ""
	@echo "$(CYAN)══════════════════════════════════════════════════════════════$(RESET)"

# =============================================================================
# Instance Lifecycle
# =============================================================================

down: stop-instance ## Stop instance to save costs
	@echo "Instance stopped. Start with 'make start-instance'"

destroy: delete-instance ## Delete instance completely (DESTRUCTIVE)
	@echo "Instance deleted."
