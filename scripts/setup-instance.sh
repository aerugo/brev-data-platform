#!/bin/bash
# =============================================================================
# Brev Data Platform - Instance Setup Script
# =============================================================================
# This script automates Phase 3 setup after manual instance creation.
#
# Prerequisites:
# 1. Create A100+ instance via Brev web console (https://brev.nvidia.com)
# 2. Wait for instance to show "Running" status
# 3. Run this script
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
NC='\033[0m' # No Color

# Configuration
SSH_CONFIG="${HOME}/.brev/ssh_config"
KUBECONFIG_DIR="${HOME}/.kube"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Brev Data Platform - Instance Setup${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# =============================================================================
# Step 1: Get or prompt for instance name
# =============================================================================

if [ -n "$1" ]; then
    INSTANCE_NAME="$1"
    echo -e "${GREEN}Using provided instance name: ${INSTANCE_NAME}${NC}"
else
    echo -e "${YELLOW}Available Brev instances:${NC}"
    echo ""
    brev ls 2>/dev/null || {
        echo -e "${RED}Error: Could not list Brev instances. Are you logged in?${NC}"
        echo "Run: brev login"
        exit 1
    }
    echo ""

    # Check if any instances exist (look for status keywords in output)
    INSTANCE_COUNT=$(brev ls 2>/dev/null | grep -cE "RUNNING|STARTING|STOPPED" || echo "0")
    if [ "$INSTANCE_COUNT" -eq 0 ]; then
        echo -e "${RED}No instances found!${NC}"
        echo ""
        echo "Please create an A100+ instance first:"
        echo "  1. Go to https://brev.nvidia.com"
        echo "  2. Select A100 (80GB) from CRUSOE provider"
        echo "  3. Name it: brev-data-platform-dev"
        echo "  4. Click Deploy and wait for Running status"
        echo ""
        echo "Then run this script again."
        exit 1
    fi

    echo -e "${YELLOW}Enter the name of the instance to set up:${NC}"
    read -r -p "> " INSTANCE_NAME

    if [ -z "$INSTANCE_NAME" ]; then
        echo -e "${RED}Error: Instance name cannot be empty${NC}"
        exit 1
    fi
fi

# =============================================================================
# Step 2: Verify instance exists and is running
# =============================================================================

echo ""
echo -e "${CYAN}Verifying instance: ${INSTANCE_NAME}${NC}"

# Parse brev ls output - format: NAME STATUS BUILD SHELL ID MACHINE
# The instance name is in column 1, status in column 2
INSTANCE_LINE=$(brev ls 2>/dev/null | grep -E "^\s*${INSTANCE_NAME}\s+" || echo "")

if [ -z "$INSTANCE_LINE" ]; then
    echo -e "${RED}Error: Instance '${INSTANCE_NAME}' not found${NC}"
    echo ""
    echo "Available instances:"
    brev ls
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
# Step 3: Wait for SSH to be ready
# =============================================================================

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
# Step 4: Check if RKE2 is already installed
# =============================================================================

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

# =============================================================================
# Step 5: Bootstrap RKE2
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
# Step 6: Fetch kubeconfig
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
# Step 7: Setup SSH tunnel
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
# Step 8: Verify cluster access
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
# Step 9: Save configuration
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
# Summary
# =============================================================================

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  Setup Complete!${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${GREEN}Instance:${NC} ${INSTANCE_NAME}"
echo -e "${GREEN}Kubeconfig:${NC} ${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"
echo -e "${GREEN}SSH Tunnel:${NC} localhost:6443 -> ${INSTANCE_NAME}:6443"
echo ""
echo -e "${YELLOW}To use kubectl:${NC}"
echo "  export KUBECONFIG=${KUBECONFIG_DIR}/config-${INSTANCE_NAME}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. make bootstrap-kai      # Deploy KAI Scheduler (Phase 4)"
echo "  2. make bootstrap-argocd   # Deploy ArgoCD (Phase 5)"
echo ""
echo -e "${YELLOW}To reconnect SSH tunnel later:${NC}"
echo "  make ssh-tunnel"
echo ""
