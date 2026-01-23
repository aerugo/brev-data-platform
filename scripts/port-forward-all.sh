#!/bin/bash
# Port forward all services with SSH tunnel management and health checks
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Source .env.local if it exists (for BREV_INSTANCE_NAME)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
if [[ -f "$PROJECT_DIR/.env.local" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env.local"
fi

# Configuration - use BREV_INSTANCE_NAME from .env.local, or INSTANCE_NAME, or default
INSTANCE_NAME="${BREV_INSTANCE_NAME:-${INSTANCE_NAME:-brev-data-platform}}"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.brev/ssh_config}"
KUBECONFIG_FILE="$HOME/.kube/config-${INSTANCE_NAME}"

# Service definitions: name:namespace:service:local_port:remote_port:protocol
SERVICES=(
    "ArgoCD:argocd:argocd-server:8080:80:http"
    "JupyterHub:jupyterhub:proxy-public:8000:80:http"
    "Dagster:dagster:dagster-dagster-webserver:3000:80:http"
    "LakeFS:lakefs:lakefs:8001:8000:http"
    "MinIO:minio:minio-console:9001:9001:http"
    "NIM-LLM:nvidia-ai:nim-llm:8002:8000:http"
    "Weaviate:weaviate:weaviate:8003:80:http"
    "Grafana:monitoring:monitoring-grafana:3001:80:http"
    "Prometheus:monitoring:monitoring-kube-prometheus-prometheus:9090:9090:http"
)

# Track background processes
PIDS=()

cleanup() {
    echo ""
    echo -e "${YELLOW}Stopping all port forwards...${NC}"
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    # Also kill any lingering kubectl port-forward processes from this script
    pkill -f "kubectl port-forward" 2>/dev/null || true
    echo -e "${GREEN}Cleanup complete${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

print_header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  BREV DATA PLATFORM - PORT FORWARD${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_ssh_tunnel() {
    echo -e "${YELLOW}[1/4] Checking SSH tunnel...${NC}"

    if pgrep -f "ssh.*6443:127.0.0.1:6443.*${INSTANCE_NAME}" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} SSH tunnel already running"
        return 0
    fi

    echo -e "  ${YELLOW}→${NC} Starting SSH tunnel..."

    # Kill any stale tunnels first
    pkill -f "ssh.*6443:127.0.0.1:6443" 2>/dev/null || true
    sleep 1

    # Start new tunnel
    ssh -F "$SSH_CONFIG" -N -L 6443:127.0.0.1:6443 "${INSTANCE_NAME}-host" &
    SSH_PID=$!
    PIDS+=("$SSH_PID")

    # Wait for tunnel to establish
    for i in {1..10}; do
        if nc -z localhost 6443 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} SSH tunnel established"
            return 0
        fi
        sleep 1
    done

    echo -e "  ${RED}✗${NC} Failed to establish SSH tunnel"
    return 1
}

check_cluster() {
    echo -e "${YELLOW}[2/4] Verifying cluster connectivity...${NC}"

    # Check if kubeconfig file exists
    if [[ ! -f "$KUBECONFIG_FILE" ]]; then
        echo -e "  ${RED}✗${NC} Kubeconfig not found: $KUBECONFIG_FILE"
        echo -e "  ${YELLOW}→${NC} Run 'make kubeconfig' to fetch it"
        return 1
    fi

    export KUBECONFIG="$KUBECONFIG_FILE"

    if ! kubectl cluster-info &>/dev/null; then
        echo -e "  ${RED}✗${NC} Cannot connect to cluster"
        echo -e "  ${YELLOW}→${NC} SSH tunnel may not be ready, retrying..."
        sleep 2
        if ! kubectl cluster-info &>/dev/null; then
            echo -e "  ${RED}✗${NC} Still cannot connect"
            return 1
        fi
    fi

    echo -e "  ${GREEN}✓${NC} Cluster accessible (using $KUBECONFIG_FILE)"
    return 0
}

start_port_forwards() {
    echo -e "${YELLOW}[3/4] Starting port forwards...${NC}"

    export KUBECONFIG="$KUBECONFIG_FILE"

    for service_def in "${SERVICES[@]}"; do
        IFS=':' read -r name namespace svc local_port remote_port protocol <<< "$service_def"

        # Check if service exists
        if ! kubectl get svc "$svc" -n "$namespace" &>/dev/null; then
            echo -e "  ${YELLOW}○${NC} $name - service not ready (skipping)"
            continue
        fi

        # Kill any existing port-forward on this port
        lsof -ti :"$local_port" 2>/dev/null | xargs kill 2>/dev/null || true

        # Start port-forward
        kubectl port-forward "svc/$svc" -n "$namespace" "${local_port}:${remote_port}" &>/dev/null &
        PID=$!
        PIDS+=("$PID")

        # Brief pause to let it start
        sleep 0.5

        # Check if process is still running
        if kill -0 "$PID" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $name → localhost:$local_port"
        else
            echo -e "  ${RED}✗${NC} $name - failed to start"
        fi
    done
}

verify_services() {
    echo -e "${YELLOW}[4/4] Verifying service accessibility...${NC}"
    echo ""

    # Wait a moment for all port-forwards to stabilize
    sleep 2

    local all_ok=true

    printf "  %-14s %-25s %s\n" "SERVICE" "URL" "STATUS"
    printf "  %-14s %-25s %s\n" "-------" "---" "------"

    for service_def in "${SERVICES[@]}"; do
        IFS=':' read -r name namespace svc local_port remote_port protocol <<< "$service_def"

        url="${protocol}://localhost:${local_port}"

        # Quick connectivity check
        if nc -z localhost "$local_port" 2>/dev/null; then
            # Try HTTP request for HTTP services
            if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 2 "$url" 2>/dev/null | grep -qE "^[23]"; then
                printf "  ${GREEN}%-14s${NC} %-25s ${GREEN}✓ OK${NC}\n" "$name" "$url"
            else
                # Port open but HTTP might not respond (could be starting up)
                printf "  ${YELLOW}%-14s${NC} %-25s ${YELLOW}○ Connecting${NC}\n" "$name" "$url"
            fi
        else
            printf "  ${RED}%-14s${NC} %-25s ${RED}✗ Not available${NC}\n" "$name" "$url"
            all_ok=false
        fi
    done

    echo ""
    return 0
}

show_credentials() {
    export KUBECONFIG="$KUBECONFIG_FILE"

    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  SERVICE CREDENTIALS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # ArgoCD
    ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
    echo -e "${GREEN}ArgoCD${NC}        http://localhost:8080"
    echo "              User: admin"
    echo "              Pass: $ARGOCD_PWD"
    echo ""

    # JupyterHub
    echo -e "${GREEN}JupyterHub${NC}    http://localhost:8000"
    echo "              User: any username"
    echo "              Pass: any password"
    echo ""

    # Dagster
    echo -e "${GREEN}Dagster${NC}       http://localhost:3000"
    echo "              (no auth required)"
    echo ""

    # LakeFS
    LAKEFS_KEY=$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.access-key-id}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
    LAKEFS_SECRET=$(kubectl -n lakefs get secret lakefs-credentials -o jsonpath="{.data.secret-access-key}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
    echo -e "${GREEN}LakeFS${NC}        http://localhost:8001"
    echo "              Access Key: $LAKEFS_KEY"
    echo "              Secret Key: $LAKEFS_SECRET"
    echo ""

    # MinIO
    MINIO_USER=$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootUser}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
    MINIO_PASS=$(kubectl -n minio get secret minio-credentials -o jsonpath="{.data.rootPassword}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
    echo -e "${GREEN}MinIO${NC}         http://localhost:9001"
    echo "              User: $MINIO_USER"
    echo "              Pass: $MINIO_PASS"
    echo ""

    # NIM LLM
    echo -e "${GREEN}NIM LLM${NC}       http://localhost:8002"
    echo "              OpenAI-compatible API (no auth)"
    echo ""

    # Weaviate
    echo -e "${GREEN}Weaviate${NC}      http://localhost:8003"
    echo "              Vector DB REST API (no auth)"
    echo "              GraphQL: http://localhost:8003/v1/graphql"
    echo ""

    # Grafana
    GRAFANA_PWD=$(kubectl -n monitoring get secret monitoring-grafana -o jsonpath="{.data.admin-password}" 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")
    echo -e "${GREEN}Grafana${NC}       http://localhost:3001"
    echo "              User: admin"
    echo "              Pass: $GRAFANA_PWD"
    echo ""

    # Prometheus
    echo -e "${GREEN}Prometheus${NC}    http://localhost:9090"
    echo "              (no auth required)"
    echo ""

    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to stop all port forwards${NC}"
    echo ""
}

main() {
    print_header

    # Check dependencies
    if ! command -v nc &>/dev/null; then
        echo -e "${RED}Error: 'nc' (netcat) is required but not installed${NC}"
        exit 1
    fi

    # Run setup steps
    check_ssh_tunnel || exit 1
    check_cluster || exit 1
    start_port_forwards
    verify_services
    show_credentials

    # Keep running until Ctrl+C
    wait
}

main "$@"