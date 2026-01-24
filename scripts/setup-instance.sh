#!/bin/bash
# =============================================================================
# Brev Data Platform - Interactive Setup Script
# =============================================================================
# This script guides you through the complete setup process:
# 1. Instance creation (manual via Brev web console) or selection
# 2. Stack status check (for existing instances)
# 3. RKE2 + GPU bootstrap (if needed)
# 4. Kubeconfig setup
# 5. SSH tunnel configuration
#
# For existing instances with stack already deployed, the script detects this
# and offers to skip directly to kubeconfig/tunnel setup.
#
# Usage:
#   ./scripts/setup-instance.sh
#   ./scripts/setup-instance.sh <instance-name>
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
DEFAULT_INSTANCE_NAME="brev-data-platform"
SSH_CONFIG="${HOME}/.brev/ssh_config"
KUBECONFIG_DIR="${HOME}/.kube"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Brev Data Platform - Interactive Setup${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# =============================================================================
# Step 0: Check Brev login
# =============================================================================

echo -e "${CYAN}Checking Brev CLI...${NC}"
if ! brev ls &>/dev/null; then
    echo -e "${RED}Error: Could not connect to Brev. Are you logged in?${NC}"
    echo ""
    echo "Run: brev login"
    exit 1
fi
echo -e "${GREEN}Brev CLI connected!${NC}"
echo ""

# =============================================================================
# Step 1: Get or prompt for instance name
# =============================================================================

if [ -n "$1" ]; then
    INSTANCE_NAME="$1"
    echo -e "${GREEN}Using provided instance name: ${INSTANCE_NAME}${NC}"
else
    # Check if any instances exist
    echo -e "${YELLOW}Checking for existing instances...${NC}"
    echo ""

    INSTANCE_COUNT=$(brev ls 2>/dev/null | grep -cE "RUNNING|STARTING|STOPPED" || echo "0")

    if [ "$INSTANCE_COUNT" -eq 0 ]; then
        # No instances - guide user through creation
        NEW_INSTANCE=true
        echo -e "${YELLOW}No instances found. Let's create one!${NC}"
        echo ""
        echo -e "${CYAN}Step 1: Set Instance Name${NC}"
        echo -e "Enter instance name [${GREEN}${DEFAULT_INSTANCE_NAME}${NC}]: "
        read -r -p "> " INPUT_NAME
        INSTANCE_NAME="${INPUT_NAME:-$DEFAULT_INSTANCE_NAME}"
        echo ""

        echo -e "${CYAN}=========================================${NC}"
        echo -e "${CYAN}  Create Instance via Brev Web Console${NC}"
        echo -e "${CYAN}=========================================${NC}"
        echo ""
        echo -e "${BOLD}Follow these steps:${NC}"
        echo ""
        echo "  1. Go to ${GREEN}https://brev.nvidia.com${NC}"
        echo "  2. Select your organization"
        echo "  3. Click ${BOLD}GPUs${NC} → Select ${BOLD}H200 • 141 GiB VRAM${NC} from ${BOLD}CRUSOE${NC} provider"
        echo "     - Instance type: h200-141gb.1x (REQUIRED for GPU sharing)"
        echo "     - 141GB VRAM enables NIM + JupyterHub GPU concurrently"
        echo "  4. Configure:"
        echo "     - ${BOLD}Disk Storage${NC}: 256 GiB"
        echo "     - ${BOLD}Software${NC}: VM Mode w/ Jupyter"
        echo "     - ${BOLD}Name${NC}: ${GREEN}${INSTANCE_NAME}${NC}"
        echo "  5. Click ${BOLD}Deploy${NC}"
        echo ""
        echo -e "${YELLOW}Wait for the instance to show 'Running' status (~7 minutes)${NC}"
        echo ""
        read -r -p "Press Enter when the instance is running... "
        echo ""
    else
        # Instances exist - show them and ask which one to use
        echo -e "${GREEN}Found existing instances:${NC}"
        echo ""
        brev ls
        echo ""
        echo -e "${CYAN}Enter instance name [${GREEN}${DEFAULT_INSTANCE_NAME}${NC}]: ${NC}"
        read -r -p "> " INPUT_NAME
        INSTANCE_NAME="${INPUT_NAME:-$DEFAULT_INSTANCE_NAME}"
    fi

    if [ -z "$INSTANCE_NAME" ]; then
        INSTANCE_NAME="$DEFAULT_INSTANCE_NAME"
    fi
fi

echo -e "${GREEN}Using instance: ${INSTANCE_NAME}${NC}"
echo ""

# =============================================================================
# Step 2: Verify instance exists and is running
# =============================================================================

echo -e "${CYAN}Verifying instance: ${INSTANCE_NAME}${NC}"

# Parse brev ls output - format: NAME STATUS BUILD SHELL ID MACHINE
# The instance name is in column 1, status in column 2
INSTANCE_LINE=$(brev ls 2>/dev/null | grep -E "^\s*${INSTANCE_NAME}\s+" || echo "")

if [ -z "$INSTANCE_LINE" ]; then
    echo -e "${RED}Error: Instance '${INSTANCE_NAME}' not found${NC}"
    echo ""
    echo "Available instances:"
    brev ls
    echo ""
    echo -e "${YELLOW}Did you create the instance in the Brev web console?${NC}"
    echo "Make sure the name matches exactly: ${INSTANCE_NAME}"
    exit 1
fi

# Extract status (second column)
INSTANCE_STATUS=$(echo "$INSTANCE_LINE" | awk '{print $2}')
echo -e "Found instance with status: ${INSTANCE_STATUS}"

if [ "$INSTANCE_STATUS" != "RUNNING" ]; then
    echo -e "${YELLOW}Instance status: ${INSTANCE_STATUS}${NC}"

    if [ "$INSTANCE_STATUS" = "STOPPED" ]; then
        echo -e "${YELLOW}Starting instance...${NC}"
        brev start "$INSTANCE_NAME"
        echo "Waiting for instance to start..."
        sleep 30
    elif [ "$INSTANCE_STATUS" = "STARTING" ]; then
        echo "Instance is starting, waiting..."
        sleep 30
    else
        echo -e "${RED}Unexpected status. Please check the Brev console.${NC}"
        exit 1
    fi

    # Re-check status
    INSTANCE_LINE=$(brev ls 2>/dev/null | grep -E "^\s*${INSTANCE_NAME}\s+" || echo "")
    INSTANCE_STATUS=$(echo "$INSTANCE_LINE" | awk '{print $2}')
    if [ "$INSTANCE_STATUS" != "RUNNING" ]; then
        echo -e "${RED}Instance is not running. Current status: ${INSTANCE_STATUS}${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}Instance is running!${NC}"

# =============================================================================
# Step 3: Check stack status (for existing instances)
# =============================================================================

check_stack_status() {
    echo ""
    echo -e "${CYAN}Checking stack status...${NC}"

    local rke2_status="not installed"
    local kai_status="not deployed"
    local argocd_status="not deployed"
    local apps_status="not deployed"

    # Check RKE2
    if ssh -F "$SSH_CONFIG" -o ConnectTimeout=5 "${INSTANCE_NAME}-host" "test -f /var/lib/rancher/rke2/bin/kubectl" 2>/dev/null; then
        rke2_status="installed"

        # Check if kubectl works (API server running)
        if ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes" &>/dev/null; then
            rke2_status="running"

            # Check KAI Scheduler
            if ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get ns kai-scheduler" &>/dev/null; then
                kai_pods=$(ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n kai-scheduler --no-headers 2>/dev/null | grep -c Running" | tr -d '[:space:]' || echo "0")
                if [ "$kai_pods" -gt 0 ]; then
                    kai_status="running ($kai_pods pods)"
                else
                    kai_status="deployed (not running)"
                fi
            fi

            # Check ArgoCD
            if ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get ns argocd" &>/dev/null; then
                argocd_pods=$(ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -n argocd --no-headers 2>/dev/null | grep -c Running" | tr -d '[:space:]' || echo "0")
                if [ "$argocd_pods" -gt 0 ]; then
                    argocd_status="running ($argocd_pods pods)"

                    # Check deployed apps
                    app_count=$(ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get applications -n argocd --no-headers 2>/dev/null | wc -l" | tr -d '[:space:]' || echo "0")
                    if [ "$app_count" -gt 0 ]; then
                        apps_status="$app_count apps"
                    fi
                else
                    argocd_status="deployed (not running)"
                fi
            fi
        fi
    fi

    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${CYAN}  Stack Status${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo ""
    echo -e "  RKE2 Kubernetes:  ${GREEN}${rke2_status}${NC}"
    echo -e "  KAI Scheduler:    ${GREEN}${kai_status}${NC}"
    echo -e "  ArgoCD:           ${GREEN}${argocd_status}${NC}"
    echo -e "  ArgoCD Apps:      ${GREEN}${apps_status}${NC}"
    echo ""

    # Determine what's needed
    if [ "$rke2_status" = "not installed" ]; then
        echo -e "${YELLOW}RKE2 needs to be installed. Full setup required.${NC}"
        STACK_STATUS="fresh"
    elif [ "$argocd_status" = "not deployed" ]; then
        echo -e "${YELLOW}ArgoCD not deployed. Bootstrap required.${NC}"
        STACK_STATUS="needs_bootstrap"
    else
        echo -e "${GREEN}Stack appears to be fully deployed!${NC}"
        STACK_STATUS="complete"
    fi

    echo ""
    echo -e "${CYAN}What would you like to do?${NC}"
    echo ""
    echo "  1) Run full setup (re-bootstrap everything)"
    echo "  2) Skip to kubeconfig + SSH tunnel only"
    echo "  3) Exit"
    echo ""
    read -r -p "Choice [2]: " SETUP_CHOICE
    SETUP_CHOICE="${SETUP_CHOICE:-2}"

    case "$SETUP_CHOICE" in
        1)
            SKIP_BOOTSTRAP=false
            echo -e "${GREEN}Will run full setup...${NC}"
            ;;
        2)
            SKIP_BOOTSTRAP=true
            echo -e "${GREEN}Skipping to kubeconfig setup...${NC}"
            ;;
        3)
            echo -e "${YELLOW}Exiting.${NC}"
            exit 0
            ;;
        *)
            SKIP_BOOTSTRAP=true
            echo -e "${GREEN}Skipping to kubeconfig setup...${NC}"
            ;;
    esac
}

# =============================================================================
# Step 4: Wait for SSH to be ready
# =============================================================================

# Track if this is a new instance (user just created it)
NEW_INSTANCE="${NEW_INSTANCE:-false}"

echo ""
echo -e "${CYAN}Waiting for SSH to be ready...${NC}"

# Refresh SSH config
brev refresh 2>/dev/null || true
sleep 5

MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if ssh -F "$SSH_CONFIG" -o ConnectTimeout=5 -o BatchMode=yes "${INSTANCE_NAME}-host" "echo 'SSH ready'" 2>/dev/null; then
        echo -e "${GREEN}SSH connection established!${NC}"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for SSH... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 10
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Error: Could not establish SSH connection${NC}"
    echo "Try running: brev shell ${INSTANCE_NAME}"
    exit 1
fi

# =============================================================================
# Step 5: Check stack status (for existing instances)
# =============================================================================

if [ "$NEW_INSTANCE" != "true" ]; then
    check_stack_status
fi

# =============================================================================
# Step 6: Check if RKE2 is already installed (for new instances)
# =============================================================================

# Only check RKE2 if SKIP_BOOTSTRAP wasn't already set by stack status check
if [ -z "$SKIP_BOOTSTRAP" ]; then
    echo ""
    echo -e "${CYAN}Checking for existing RKE2 installation...${NC}"

    RKE2_INSTALLED=$(ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "test -f /var/lib/rancher/rke2/bin/kubectl && echo 'yes' || echo 'no'" 2>/dev/null)

    if [ "$RKE2_INSTALLED" = "yes" ]; then
        echo -e "${GREEN}RKE2 is already installed!${NC}"
        echo ""
        read -r -p "Re-run bootstrap script? (y/N): " RERUN
        if [ "$RERUN" != "y" ] && [ "$RERUN" != "Y" ]; then
            echo "Skipping bootstrap, continuing with kubeconfig setup..."
            SKIP_BOOTSTRAP=true
        fi
    fi
fi

# =============================================================================
# Step 7: Bootstrap RKE2
# =============================================================================

if [ "$SKIP_BOOTSTRAP" != "true" ]; then
    echo ""
    echo -e "${CYAN}Bootstrapping RKE2 with GPU support...${NC}"
    echo "This will take several minutes..."
    echo ""

    # Copy bootstrap script
    scp -F "$SSH_CONFIG" "${PROJECT_ROOT}/scripts/bootstrap-rke2.sh" "${INSTANCE_NAME}-host:/tmp/"

    # Run bootstrap script
    ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "chmod +x /tmp/bootstrap-rke2.sh && sudo /tmp/bootstrap-rke2.sh"

    echo ""
    echo -e "${GREEN}RKE2 bootstrap complete!${NC}"
fi

# =============================================================================
# Step 8: Fetch kubeconfig
# =============================================================================

echo ""
echo -e "${CYAN}Fetching kubeconfig...${NC}"

mkdir -p "$KUBECONFIG_DIR"

# Get kubeconfig from instance
ssh -F "$SSH_CONFIG" "${INSTANCE_NAME}-host" "sudo cat /etc/rancher/rke2/rke2.yaml" > "${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"

# Update server address to use localhost (for SSH tunnel)
sed -i.bak "s|server: https://127.0.0.1:6443|server: https://127.0.0.1:6443|g" "${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"
rm -f "${KUBECONFIG_DIR}/config-${INSTANCE_NAME}.bak"

echo -e "${GREEN}Kubeconfig saved to: ${KUBECONFIG_DIR}/config-${INSTANCE_NAME}${NC}"

# =============================================================================
# Step 9: Setup SSH tunnel
# =============================================================================

echo ""
echo -e "${CYAN}Setting up SSH tunnel for kubectl access...${NC}"

# Check if tunnel is already running
if pgrep -f "ssh.*6443:localhost:6443.*${INSTANCE_NAME}" > /dev/null; then
    echo -e "${YELLOW}SSH tunnel already running${NC}"
else
    # Start SSH tunnel in background
    ssh -F "$SSH_CONFIG" -f -N -L 6443:localhost:6443 "${INSTANCE_NAME}-host"
    echo -e "${GREEN}SSH tunnel started (localhost:6443 -> ${INSTANCE_NAME}:6443)${NC}"
fi

# =============================================================================
# Step 10: Verify cluster access
# =============================================================================

echo ""
echo -e "${CYAN}Verifying cluster access...${NC}"

export KUBECONFIG="${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"

# Wait for API server
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if kubectl get nodes &>/dev/null; then
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Waiting for Kubernetes API... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo -e "${RED}Error: Could not connect to Kubernetes API${NC}"
    echo "Check if SSH tunnel is running: pgrep -f 'ssh.*6443'"
    exit 1
fi

echo ""
echo -e "${GREEN}Cluster nodes:${NC}"
kubectl get nodes

echo ""
echo -e "${GREEN}GPU availability:${NC}"
kubectl describe nodes | grep -A 5 "nvidia.com/gpu" || echo "  GPU resources not yet visible (may take a minute)"

# =============================================================================
# Step 11: Deploy KAI Scheduler
# =============================================================================

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Deploying KAI Scheduler${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Check if KAI is already installed
if kubectl get ns kai-scheduler &>/dev/null && kubectl get pods -n kai-scheduler --no-headers 2>/dev/null | grep -q Running; then
    echo -e "${YELLOW}KAI Scheduler already deployed, skipping...${NC}"
else
    echo -e "${CYAN}Installing KAI Scheduler v0.12.9...${NC}"
    helm upgrade -i kai-scheduler oci://ghcr.io/nvidia/kai-scheduler/kai-scheduler \
        -n kai-scheduler --create-namespace \
        --version v0.12.9 \
        --wait --timeout 5m
    echo -e "${GREEN}KAI Scheduler deployed!${NC}"
fi

# Verify KAI pods
echo ""
echo "KAI Scheduler pods:"
kubectl get pods -n kai-scheduler

# =============================================================================
# Step 12: Save configuration (before secrets so .env.local is updated)
# =============================================================================

echo ""
echo -e "${CYAN}Saving instance configuration...${NC}"

# Save instance name to .env.local for other scripts
if [ -f "${PROJECT_ROOT}/.env.local" ]; then
    # Update existing BREV_INSTANCE_NAME
    if grep -q "^BREV_INSTANCE_NAME=" "${PROJECT_ROOT}/.env.local"; then
        sed -i.bak "s|^BREV_INSTANCE_NAME=.*|BREV_INSTANCE_NAME=${INSTANCE_NAME}|" "${PROJECT_ROOT}/.env.local"
        rm -f "${PROJECT_ROOT}/.env.local.bak"
    else
        echo "BREV_INSTANCE_NAME=${INSTANCE_NAME}" >> "${PROJECT_ROOT}/.env.local"
    fi
else
    echo "BREV_INSTANCE_NAME=${INSTANCE_NAME}" > "${PROJECT_ROOT}/.env.local"
fi

echo -e "${GREEN}Instance name saved to .env.local${NC}"

# =============================================================================
# Step 13: Create and Apply Secrets
# =============================================================================

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Creating Kubernetes Secrets${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Check if .env.local has required credentials
HAS_CREDENTIALS=false
if [ -f "${PROJECT_ROOT}/.env.local" ]; then
    source "${PROJECT_ROOT}/.env.local"
    if [ -n "$MINIO_ROOT_USER" ] && [ -n "$MINIO_ROOT_PASSWORD" ]; then
        HAS_CREDENTIALS=true
    fi
fi

if [ "$HAS_CREDENTIALS" = "true" ]; then
    echo -e "${CYAN}Creating secrets from .env.local...${NC}"
    echo ""

    # MinIO secrets
    echo "  Creating MinIO secrets..."
    kubectl create secret generic minio-credentials -n minio \
        --from-literal=rootUser="$MINIO_ROOT_USER" \
        --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    # LakeFS secrets
    echo "  Creating LakeFS secrets..."
    AUTH_KEY=$(openssl rand -base64 32)
    kubectl create secret generic lakefs-credentials -n lakefs \
        --from-literal=auth-encrypt-secret-key="$AUTH_KEY" \
        --from-literal=access-key-id="${LAKEFS_ACCESS_KEY_ID:-admin}" \
        --from-literal=secret-access-key="${LAKEFS_SECRET_ACCESS_KEY:-$(openssl rand -base64 32)}" \
        --from-literal=minio-access-key="$MINIO_ROOT_USER" \
        --from-literal=minio-secret-key="$MINIO_ROOT_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic minio-credentials -n lakefs \
        --from-literal=rootUser="$MINIO_ROOT_USER" \
        --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    # NVIDIA AI secrets (if NGC key provided)
    if [ -n "$NGC_API_KEY" ]; then
        echo "  Creating NVIDIA AI secrets..."
        kubectl create secret generic ngc-credentials -n nvidia-ai \
            --from-literal=api-key="$NGC_API_KEY" \
            --dry-run=client -o yaml | kubectl apply -f -

        kubectl create secret docker-registry ngc-image-pull -n nvidia-ai \
            --docker-server=nvcr.io \
            --docker-username='$oauthtoken' \
            --docker-password="$NGC_API_KEY" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Dagster secrets
    echo "  Creating Dagster secrets..."
    kubectl create secret generic dagster-env-secrets -n dagster \
        --from-literal=MINIO_ENDPOINT="minio.minio.svc.cluster.local:9000" \
        --from-literal=MINIO_ACCESS_KEY="$MINIO_ROOT_USER" \
        --from-literal=MINIO_SECRET_KEY="$MINIO_ROOT_PASSWORD" \
        --from-literal=LAKEFS_ENDPOINT="http://lakefs.lakefs.svc.cluster.local:8000" \
        --from-literal=LAKEFS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY_ID:-admin}" \
        --from-literal=LAKEFS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_ACCESS_KEY:-}" \
        --from-literal=NIM_ENDPOINT="http://nim-llm.nvidia-ai.svc.cluster.local:8000" \
        --from-literal=NGC_API_KEY="${NGC_API_KEY:-}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # NDS credentials (for NeMo Data Store access, optional)
    kubectl create secret generic nds-credentials -n dagster \
        --from-literal=NDS_TOKEN="${HF_TOKEN:-}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # JupyterHub secrets (for user notebook environment)
    echo "  Creating JupyterHub secrets..."
    kubectl create secret generic jupyterhub-env-secrets -n jupyterhub \
        --from-literal=MINIO_ENDPOINT="http://minio.minio.svc.cluster.local:9000" \
        --from-literal=MINIO_ACCESS_KEY="$MINIO_ROOT_USER" \
        --from-literal=MINIO_SECRET_KEY="$MINIO_ROOT_PASSWORD" \
        --from-literal=LAKEFS_ENDPOINT="http://lakefs.lakefs.svc.cluster.local:8000" \
        --from-literal=LAKEFS_ACCESS_KEY_ID="${LAKEFS_ACCESS_KEY_ID:-admin}" \
        --from-literal=LAKEFS_SECRET_ACCESS_KEY="${LAKEFS_SECRET_ACCESS_KEY:-}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # ArgoCD repo credentials (if GitHub PAT provided)
    if [ -n "$GITHUB_PAT" ]; then
        echo "  Creating ArgoCD repo credentials..."
        kubectl create secret generic repo-credentials -n argocd \
            --from-literal=type=git \
            --from-literal=url="https://github.com/${GITHUB_REPO:-aerugo/brev-data-platform}.git" \
            --from-literal=username=git \
            --from-literal=password="$GITHUB_PAT" \
            --dry-run=client -o yaml | kubectl apply -f -
        kubectl label secret repo-credentials -n argocd argocd.argoproj.io/secret-type=repository --overwrite
    fi

    echo ""
    echo -e "${GREEN}Secrets created!${NC}"
else
    echo -e "${YELLOW}No credentials found in .env.local${NC}"
    echo "To configure secrets later:"
    echo "  1. Copy .env.example to .env.local"
    echo "  2. Fill in your credentials"
    echo "  3. Run: make apply-secrets"
    echo ""
fi

# =============================================================================
# Step 14: Install ArgoCD
# =============================================================================

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Installing ArgoCD${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Check if ArgoCD is already installed
if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    echo -e "${YELLOW}ArgoCD already installed, skipping...${NC}"
else
    echo -e "${CYAN}Adding ArgoCD Helm repo...${NC}"
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update

    echo -e "${CYAN}Installing ArgoCD...${NC}"
    VALUES_FILE="${PROJECT_ROOT}/k8s/bootstrap/argocd/values.yaml"
    if [ -f "$VALUES_FILE" ]; then
        helm upgrade --install argocd argo/argo-cd \
            --namespace argocd \
            --create-namespace \
            -f "$VALUES_FILE" \
            --set server.extraArgs="{--insecure}" \
            --wait \
            --timeout 5m
    else
        helm upgrade --install argocd argo/argo-cd \
            --namespace argocd \
            --create-namespace \
            --set server.extraArgs="{--insecure}" \
            --wait \
            --timeout 5m
    fi

    echo -e "${CYAN}Waiting for ArgoCD to be ready...${NC}"
    kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
    echo -e "${GREEN}ArgoCD installed!${NC}"
fi

# =============================================================================
# Step 15: Deploy App-of-Apps
# =============================================================================

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Deploying App-of-Apps${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

APP_OF_APPS="${PROJECT_ROOT}/k8s/bootstrap/argocd/app-of-apps.yaml"

if [ -f "$APP_OF_APPS" ]; then
    # Check if already deployed
    if kubectl get application brev-data-platform -n argocd &>/dev/null; then
        echo -e "${YELLOW}App-of-apps already deployed, syncing...${NC}"
        kubectl apply -f "$APP_OF_APPS"
    else
        echo -e "${CYAN}Deploying app-of-apps...${NC}"
        kubectl apply -f "$APP_OF_APPS"
    fi
    echo -e "${GREEN}App-of-apps deployed!${NC}"
    echo ""
    echo "ArgoCD will now automatically deploy all applications."
    echo "This may take several minutes for all pods to start."
else
    echo -e "${YELLOW}App-of-apps not found at $APP_OF_APPS${NC}"
    echo "You can deploy manually later with:"
    echo "  kubectl apply -f k8s/bootstrap/argocd/app-of-apps.yaml"
fi

# =============================================================================
# Step 16: Final Summary
# =============================================================================

# Get credentials for display
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
MINIO_USER=$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
MINIO_PASS=$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
LAKEFS_KEY=$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.access-key-id}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
LAKEFS_SECRET=$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.secret-access-key}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    SETUP COMPLETE!                            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}Instance Configuration:${NC}"
echo "  Instance:    ${INSTANCE_NAME}"
echo "  Kubeconfig:  ${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"
echo "  SSH Tunnel:  localhost:6443 -> ${INSTANCE_NAME}:6443"
echo ""
echo -e "${CYAN}Deployed Stack:${NC}"
echo "  ✓ RKE2 Kubernetes with GPU support"
echo "  ✓ KAI Scheduler for fractional GPU workloads"
echo "  ✓ ArgoCD for GitOps deployments"
echo "  ✓ App-of-Apps (all services deploying via ArgoCD)"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                     NEXT STEPS                                ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}1. Set your kubeconfig:${NC}"
echo "   export KUBECONFIG=${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"
echo ""
echo -e "${YELLOW}2. Wait for ArgoCD to deploy all applications (~5-10 min):${NC}"
echo "   kubectl get applications -n argocd -w"
echo ""
echo -e "${YELLOW}3. Access services via port-forward:${NC}"
echo "   make port-forward-all"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                  SERVICE CREDENTIALS                          ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}ArgoCD${NC}       https://localhost:8080"
echo "             User: admin"
echo "             Pass: ${ARGOCD_PWD}"
echo ""
echo -e "${GREEN}Dagster${NC}      http://localhost:3000"
echo "             (no auth required)"
echo ""
echo -e "${GREEN}JupyterHub${NC}   http://localhost:8000"
echo "             User: any username"
echo "             Pass: any password"
echo ""
echo -e "${GREEN}MinIO${NC}        http://localhost:9001"
echo "             User: ${MINIO_USER}"
echo "             Pass: ${MINIO_PASS}"
echo ""
echo -e "${GREEN}LakeFS${NC}       http://localhost:8001"
echo "             Access Key: ${LAKEFS_KEY}"
echo "             Secret Key: ${LAKEFS_SECRET}"
echo ""
echo -e "${GREEN}Grafana${NC}      http://localhost:3001"
echo "             User: admin"
echo "             Pass: (run: make grafana-password)"
echo ""
echo -e "${GREEN}NIM LLM${NC}      http://localhost:8002"
echo "             OpenAI-compatible API (no auth)"
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}                   USEFUL COMMANDS                             ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  make port-forward-all     # Forward all services to localhost"
echo "  make all-credentials      # Show all service credentials"
echo "  make validate-platform    # Run full platform validation"
echo "  make ssh-tunnel           # Reconnect SSH tunnel"
echo "  make stop-instance        # Stop instance (save costs)"
echo "  make start-instance       # Restart stopped instance"
echo ""
