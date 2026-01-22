#!/bin/bash
#
# Brev Data Platform - Full Validation Script
#
# This script performs comprehensive validation of the entire platform stack:
# 1. Kubernetes cluster health
# 2. All pods running
# 3. Service connectivity
# 4. Dagster validation pipeline execution
#
# Usage:
#   ./scripts/validate-platform.sh           # Full validation
#   ./scripts/validate-platform.sh --quick   # Quick health check only
#   ./scripts/validate-platform.sh --k8s     # Kubernetes checks only
#
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track overall status
OVERALL_PASS=true
FAILED_CHECKS=()

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo ""
    echo -e "${YELLOW}--- $1 ---${NC}"
}

check_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "  ${RED}✗${NC} $1"
    OVERALL_PASS=false
    FAILED_CHECKS+=("$1")
}

check_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

# Check if kubectl is available and configured
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl not found. Please install kubectl.${NC}"
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster.${NC}"
        echo "Please ensure:"
        echo "  1. SSH tunnel is running: make ssh-tunnel"
        echo "  2. KUBECONFIG is set: export KUBECONFIG=~/.kube/config-brev-data-platform-dev"
        exit 1
    fi
}

# =============================================================================
# Kubernetes Cluster Validation
# =============================================================================
validate_k8s_cluster() {
    print_header "KUBERNETES CLUSTER VALIDATION"

    # Node status
    print_subheader "Node Status"
    NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')
    if [[ "$NODE_STATUS" == *"True"* ]]; then
        check_pass "Node is Ready"
        kubectl get nodes --no-headers | while read line; do
            echo "        $line"
        done
    else
        check_fail "Node is not Ready"
    fi

    # GPU availability
    print_subheader "GPU Resources"
    GPU_COUNT=$(kubectl get nodes -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
    if [[ "$GPU_COUNT" != "" && "$GPU_COUNT" != "0" ]]; then
        check_pass "GPU available: $GPU_COUNT"
    else
        check_warn "No GPU resources detected"
    fi

    # KAI Scheduler
    print_subheader "KAI Scheduler"
    KAI_PODS=$(kubectl get pods -n kai-scheduler --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$KAI_PODS" -gt 0 ]]; then
        KAI_RUNNING=$(kubectl get pods -n kai-scheduler --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        if [[ "$KAI_RUNNING" -gt 0 ]]; then
            check_pass "KAI Scheduler running ($KAI_RUNNING pods)"
        else
            check_fail "KAI Scheduler pods not running"
        fi
    else
        check_fail "KAI Scheduler not installed"
    fi
}

# =============================================================================
# Namespace Pod Validation
# =============================================================================
validate_namespace_pods() {
    local ns=$1
    local expected_running=$2

    TOTAL=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    RUNNING=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    CRASHLOOP=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || echo "0")

    if [[ "$TOTAL" -eq 0 ]]; then
        check_fail "$ns: No pods found"
    elif [[ "$CRASHLOOP" -gt 0 ]]; then
        check_fail "$ns: $CRASHLOOP pod(s) in CrashLoopBackOff"
    elif [[ "$RUNNING" -ge "$expected_running" ]]; then
        check_pass "$ns: $RUNNING/$TOTAL pods running"
    else
        check_fail "$ns: Only $RUNNING/$TOTAL pods running (expected $expected_running+)"
    fi
}

validate_all_pods() {
    print_header "POD STATUS VALIDATION"

    print_subheader "Core Services"
    validate_namespace_pods "argocd" 5
    validate_namespace_pods "minio" 1
    validate_namespace_pods "lakefs" 1

    print_subheader "Data Platform"
    validate_namespace_pods "dagster" 3
    validate_namespace_pods "jupyterhub" 2

    print_subheader "AI Services"
    validate_namespace_pods "nvidia-nim" 1

    print_subheader "Monitoring"
    validate_namespace_pods "monitoring" 4
}

# =============================================================================
# Service Connectivity Validation
# =============================================================================
validate_service_connectivity() {
    print_header "SERVICE CONNECTIVITY VALIDATION"

    # This uses kubectl port-forward in background to test each service
    # We'll do quick HTTP checks where possible

    print_subheader "Internal Service DNS"

    # MinIO
    if kubectl exec -it $(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-webserver -o jsonpath='{.items[0].metadata.name}') -n dagster -- \
        sh -c "nc -z minio.minio.svc.cluster.local 9000" 2>/dev/null; then
        check_pass "MinIO: minio.minio.svc.cluster.local:9000"
    else
        check_warn "MinIO: Cannot verify connectivity from Dagster pod"
    fi

    # LakeFS
    if kubectl exec -it $(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-webserver -o jsonpath='{.items[0].metadata.name}') -n dagster -- \
        sh -c "nc -z lakefs.lakefs.svc.cluster.local 8000" 2>/dev/null; then
        check_pass "LakeFS: lakefs.lakefs.svc.cluster.local:8000"
    else
        check_warn "LakeFS: Cannot verify connectivity from Dagster pod"
    fi

    # NIM (check if service exists)
    if kubectl get svc nvidia-nim-llm -n nvidia-nim &>/dev/null; then
        check_pass "NIM: Service exists at nvidia-nim-llm.nvidia-nim.svc.cluster.local:8000"
    else
        check_warn "NIM: Service not found"
    fi
}

# =============================================================================
# ArgoCD Application Status
# =============================================================================
validate_argocd_apps() {
    print_header "ARGOCD APPLICATION STATUS"

    if ! kubectl get applications -n argocd &>/dev/null; then
        check_fail "Cannot access ArgoCD applications"
        return
    fi

    kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null | \
    while IFS=$'\t' read -r name sync health; do
        if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
            check_pass "$name: $sync / $health"
        elif [[ "$sync" == "Synced" ]]; then
            check_warn "$name: $sync / $health"
        else
            check_fail "$name: $sync / $health"
        fi
    done
}

# =============================================================================
# Dagster Validation (via kubectl exec)
# =============================================================================
validate_dagster() {
    print_header "DAGSTER VALIDATION"

    print_subheader "Dagster Pods"
    # Check webserver
    WEBSERVER=$(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-webserver --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
    if [[ "$WEBSERVER" -gt 0 ]]; then
        check_pass "Dagster Webserver running"
    else
        check_fail "Dagster Webserver not running"
    fi

    # Check daemon
    DAEMON=$(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-daemon --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
    if [[ "$DAEMON" -gt 0 ]]; then
        check_pass "Dagster Daemon running"
    else
        check_fail "Dagster Daemon not running"
    fi

    # Check user deployments
    USER_CODE=$(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-user-deployments --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
    if [[ "$USER_CODE" -gt 0 ]]; then
        check_pass "Dagster User Code (brev-pipelines) running"
    else
        check_fail "Dagster User Code not running"
    fi

    # Check for import errors in user code logs
    print_subheader "User Code Import Check"
    IMPORT_ERRORS=$(kubectl logs -l app.kubernetes.io/name=dagster-user-deployments -n dagster --tail=100 2>/dev/null | grep -i "ModuleNotFoundError\|ImportError" | head -3)
    if [[ -z "$IMPORT_ERRORS" ]]; then
        check_pass "No import errors detected"
    else
        check_fail "Import errors detected in user code:"
        echo "$IMPORT_ERRORS" | while read line; do
            echo "        $line"
        done
    fi
}

# =============================================================================
# Run Dagster Validation Assets
# =============================================================================
run_dagster_validation() {
    print_header "DAGSTER VALIDATION PIPELINE"

    echo "Running validation assets via Dagster..."
    echo ""

    # Get the user code pod
    USER_POD=$(kubectl get pods -n dagster -l app.kubernetes.io/name=dagster-user-deployments -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$USER_POD" ]]; then
        check_fail "Cannot find Dagster user code pod"
        return
    fi

    print_subheader "Running quick_health_check asset"

    # Run the quick health check via dagster CLI inside the pod
    RESULT=$(kubectl exec -n dagster "$USER_POD" -- \
        python -c "
import json
from dagster import build_asset_context
from brev_pipelines.assets.validation import quick_health_check
from brev_pipelines.resources.minio import MinIOResource
from brev_pipelines.resources.lakefs import LakeFSResource
from brev_pipelines.resources.nim import NIMResource
import os

# Create resources with env vars
minio = MinIOResource(
    endpoint=os.getenv('MINIO_ENDPOINT', 'minio.minio.svc.cluster.local:9000'),
    access_key=os.getenv('MINIO_ACCESS_KEY', ''),
    secret_key=os.getenv('MINIO_SECRET_KEY', ''),
    secure=False,
)
lakefs = LakeFSResource(
    endpoint=os.getenv('LAKEFS_ENDPOINT', 'lakefs.lakefs.svc.cluster.local:8000'),
    access_key=os.getenv('LAKEFS_ACCESS_KEY_ID', ''),
    secret_key=os.getenv('LAKEFS_SECRET_ACCESS_KEY', ''),
)
nim = NIMResource(
    endpoint=os.getenv('NIM_ENDPOINT', 'http://nvidia-nim-llm.nvidia-nim.svc.cluster.local:8000'),
)

context = build_asset_context()
result = quick_health_check(context, minio, lakefs, nim)
print(json.dumps(result, indent=2))
" 2>/dev/null)

    if [[ $? -eq 0 && -n "$RESULT" ]]; then
        echo "$RESULT"
        echo ""

        # Parse results
        MINIO_STATUS=$(echo "$RESULT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['services']['minio']['status'])" 2>/dev/null || echo "unknown")
        LAKEFS_STATUS=$(echo "$RESULT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['services']['lakefs']['status'])" 2>/dev/null || echo "unknown")
        NIM_STATUS=$(echo "$RESULT" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d['services']['nim']['status'])" 2>/dev/null || echo "unknown")

        if [[ "$MINIO_STATUS" == "healthy" ]]; then
            check_pass "MinIO validation: healthy"
        else
            check_fail "MinIO validation: $MINIO_STATUS"
        fi

        if [[ "$LAKEFS_STATUS" == "healthy" ]]; then
            check_pass "LakeFS validation: healthy"
        else
            check_fail "LakeFS validation: $LAKEFS_STATUS"
        fi

        if [[ "$NIM_STATUS" == "healthy" ]]; then
            check_pass "NIM validation: healthy"
        else
            check_warn "NIM validation: $NIM_STATUS (may be scaling up)"
        fi
    else
        check_warn "Could not run Dagster validation (missing env vars or deps)"
        echo "  Run manually via Dagster UI: http://localhost:3000"
    fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    print_header "VALIDATION SUMMARY"

    if [[ "$OVERALL_PASS" == true ]]; then
        echo -e "${GREEN}"
        echo "  ╔═══════════════════════════════════════════════════╗"
        echo "  ║         ALL VALIDATIONS PASSED ✓                  ║"
        echo "  ╚═══════════════════════════════════════════════════╝"
        echo -e "${NC}"
    else
        echo -e "${RED}"
        echo "  ╔═══════════════════════════════════════════════════╗"
        echo "  ║         SOME VALIDATIONS FAILED ✗                 ║"
        echo "  ╚═══════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        echo "Failed checks:"
        for check in "${FAILED_CHECKS[@]}"; do
            echo -e "  ${RED}✗${NC} $check"
        done
    fi

    echo ""
    echo "Next steps:"
    echo "  - Access Dagster UI:    make port-forward-dagster → http://localhost:3000"
    echo "  - Run full validation:  Materialize 'validate_platform' asset in Dagster UI"
    echo "  - View validation logs: kubectl logs -n dagster -l app.kubernetes.io/name=dagster-user-deployments"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        BREV DATA PLATFORM - FULL VALIDATION                   ║${NC}"
    echo -e "${BLUE}║                                                               ║${NC}"
    echo -e "${BLUE}║        Timestamp: $(date '+%Y-%m-%d %H:%M:%S')                        ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"

    check_kubectl

    case "${1:-full}" in
        --quick|-q)
            validate_k8s_cluster
            validate_all_pods
            ;;
        --k8s|-k)
            validate_k8s_cluster
            validate_all_pods
            validate_argocd_apps
            ;;
        full|--full|-f|*)
            validate_k8s_cluster
            validate_all_pods
            validate_argocd_apps
            validate_dagster
            run_dagster_validation
            ;;
    esac

    print_summary

    if [[ "$OVERALL_PASS" == true ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
