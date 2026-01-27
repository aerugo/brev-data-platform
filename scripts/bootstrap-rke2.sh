#!/bin/bash
# RKE2 Bootstrap Script for GPU-enabled Brev Instance
# This script installs RKE2 with NVIDIA GPU support
#
# Usage: ./bootstrap-rke2.sh
# Run as root or with sudo

set -e

echo "=============================================="
echo "  RKE2 + GPU Bootstrap for Brev Data Platform"
echo "=============================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo"
  exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
  VERSION=$VERSION_ID
else
  echo "Cannot detect OS"
  exit 1
fi

echo "Detected OS: $OS $VERSION"
echo ""

# =============================================================================
# Step 1: Install RKE2
# =============================================================================
echo "=== Step 1: Installing RKE2 ==="

# Create RKE2 config directory
mkdir -p /etc/rancher/rke2

# Configure RKE2
cat > /etc/rancher/rke2/config.yaml <<EOF
# RKE2 Server Configuration
# Disable built-in ingress (we'll use ArgoCD-managed if needed)
disable:
  - rke2-ingress-nginx

# Write kubeconfig with correct permissions
write-kubeconfig-mode: "0644"

# Note: DevicePlugins feature gate is GA since Kubernetes 1.26 and removed in 1.28+
# No need to explicitly enable it - GPU device plugins work out of the box
EOF

# Install RKE2
curl -sfL https://get.rke2.io | sh -

# Enable and start RKE2
systemctl enable rke2-server.service
systemctl start rke2-server.service

echo "Waiting for RKE2 to initialize..."
sleep 30

# Wait for RKE2 to be ready
echo "Waiting for node to be ready..."
until /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  Still waiting..."
  sleep 10
done

echo "RKE2 node is ready!"
echo ""

# =============================================================================
# Step 2: Setup kubectl access
# =============================================================================
echo "=== Step 2: Setting up kubectl access ==="

# Add RKE2 kubectl to PATH
mkdir -p /usr/local/bin
ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
ln -sf /var/lib/rancher/rke2/bin/crictl /usr/local/bin/crictl

# Setup kubeconfig for root
mkdir -p /root/.kube
cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
chmod 600 /root/.kube/config

# Setup kubeconfig for brev user (if exists)
if id "brev" &>/dev/null; then
  mkdir -p /home/brev/.kube
  cp /etc/rancher/rke2/rke2.yaml /home/brev/.kube/config
  chown -R brev:brev /home/brev/.kube
  chmod 600 /home/brev/.kube/config
fi

export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

echo "kubectl configured!"
kubectl get nodes
echo ""

# =============================================================================
# Step 3: Install NVIDIA Container Toolkit
# =============================================================================
echo "=== Step 3: Installing NVIDIA Container Toolkit ==="

# Check if NVIDIA GPU is present
if ! command -v nvidia-smi &> /dev/null; then
  echo "WARNING: nvidia-smi not found. GPU drivers may not be installed."
  echo "Continuing anyway - Brev instances should have drivers pre-installed."
fi

# Add NVIDIA Container Toolkit repository
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
  # Ubuntu/Debian
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  apt-get update
  apt-get install -y nvidia-container-toolkit

elif [ "$OS" = "rhel" ] || [ "$OS" = "centos" ] || [ "$OS" = "rocky" ] || [ "$OS" = "almalinux" ]; then
  # RHEL-based
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
    tee /etc/yum.repos.d/nvidia-container-toolkit.repo

  yum install -y nvidia-container-toolkit
else
  echo "Unsupported OS: $OS"
  echo "Please install nvidia-container-toolkit manually"
fi

echo "NVIDIA Container Toolkit installed!"
echo ""

# =============================================================================
# Step 4: Configure containerd for NVIDIA
# =============================================================================
echo "=== Step 4: Configuring containerd for NVIDIA ==="

# RKE2 uses containerd, configure it for NVIDIA
CONTAINERD_CONFIG="/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"

# Create containerd config template directory if it doesn't exist
mkdir -p /var/lib/rancher/rke2/agent/etc/containerd

# Use nvidia-ctk to configure containerd
nvidia-ctk runtime configure --runtime=containerd --config="$CONTAINERD_CONFIG" --set-as-default 2>/dev/null || true

# Alternative: Create config manually if nvidia-ctk doesn't work
if [ ! -f "$CONTAINERD_CONFIG" ]; then
  cat > "$CONTAINERD_CONFIG" <<'EOF'
version = 2

[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "nvidia"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
  BinaryName = "/usr/bin/nvidia-container-runtime"
EOF
fi

# Restart RKE2 to pick up containerd changes
echo "Restarting RKE2 to apply containerd configuration..."
systemctl restart rke2-server.service

sleep 30

# Wait for node to be ready again
echo "Waiting for node to be ready after restart..."
until kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  Still waiting..."
  sleep 10
done

echo "containerd configured for NVIDIA!"
echo ""

# =============================================================================
# Step 5: Install NVIDIA Device Plugin
# =============================================================================
echo "=== Step 5: Installing NVIDIA Device Plugin ==="

# Apply NVIDIA device plugin
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml

echo "Waiting for NVIDIA device plugin to be ready..."
sleep 20

# Wait for device plugin pod to be running
until kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds 2>/dev/null | grep -q "Running"; do
  echo "  Waiting for device plugin pod..."
  sleep 10
done

echo "NVIDIA Device Plugin installed!"
echo ""

# =============================================================================
# Step 5b: Configure GPU Time-Slicing for sharing
# =============================================================================
echo "=== Step 5b: Configuring GPU Device Plugin ==="

# Create device plugin config with 2-way time-slicing
# Time-slicing is TEMPORAL sharing, NOT memory partitioning:
# - All workloads see the full GPU memory (143GB on H200)
# - Workloads take turns executing on the GPU (context switching)
# - nim-reasoning (120B, ~131GB) + nim-embedding (~3GB) = ~134GB < 143GB
# - Both can coexist in memory; time-slicing handles compute scheduling
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: kube-system
data:
  config.yaml: |
    version: v1
    sharing:
      timeSlicing:
        renameByDefault: false
        resources:
          - name: nvidia.com/gpu
            replicas: 2
EOF

# Patch device plugin to use the config (skip if already patched)
if ! kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -q nvidia-config; then
  kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='json' -p='[
    {"op": "add", "path": "/spec/template/spec/containers/0/args", "value": ["--config-file=/etc/nvidia/config.yaml"]},
    {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "nvidia-config", "mountPath": "/etc/nvidia"}},
    {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "nvidia-config", "configMap": {"name": "nvidia-device-plugin-config", "items": [{"key": "config.yaml", "path": "config.yaml"}]}}}
  ]'
else
  echo "Device plugin config patch already applied, skipping..."
fi

# Wait for device plugin to restart
echo "Waiting for device plugin to restart..."
kubectl rollout status daemonset nvidia-device-plugin-daemonset -n kube-system --timeout=60s

echo "GPU Device Plugin configured with 2-way time-slicing!"
echo ""

# =============================================================================
# Step 6: Create RuntimeClass for NVIDIA
# =============================================================================
echo "=== Step 6: Creating NVIDIA RuntimeClass ==="

kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

echo "RuntimeClass 'nvidia' created!"
echo ""

# =============================================================================
# Step 7: Label node for GPU scheduling
# =============================================================================
echo "=== Step 7: Labeling node for GPU scheduling ==="

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl label nodes "$NODE_NAME" nvidia.com/gpu.present=true --overwrite

echo "Node labeled with nvidia.com/gpu.present=true"
echo ""

# =============================================================================
# Step 8: Install local-path-provisioner (RKE2 doesn't include it by default)
# =============================================================================
echo "=== Step 8: Installing local-path-provisioner ==="

# RKE2 doesn't include local-path-provisioner like K3S does
# Install it manually for persistent volume support
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml

# Wait for the provisioner to be ready
echo "Waiting for local-path-provisioner to be ready..."
sleep 10
until kubectl get pods -n local-path-storage 2>/dev/null | grep -q "Running"; do
  echo "  Waiting for provisioner pod..."
  sleep 5
done

# Set local-path as the default storage class
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "local-path-provisioner installed and set as default!"
echo ""

# =============================================================================
# Step 9: Create namespaces
# =============================================================================
echo "=== Step 9: Creating namespaces ==="

for ns in argocd minio lakefs dagster marimo nvidia-ai monitoring jupyterhub kube-system; do
  kubectl create namespace $ns 2>/dev/null || echo "  Namespace $ns already exists"
done

echo "Namespaces created!"
echo ""

# =============================================================================
# Step 10: Verify GPU availability
# =============================================================================
echo "=== Step 10: Verifying GPU availability ==="

echo "Node resources:"
kubectl describe node "$NODE_NAME" | grep -A 10 "Allocatable:" | head -15

echo ""
echo "GPU resources:"
kubectl describe node "$NODE_NAME" | grep nvidia.com/gpu || echo "  GPU not yet visible (may take a minute)"

echo ""

# =============================================================================
# Final Summary
# =============================================================================
echo "=============================================="
echo "  RKE2 + GPU Bootstrap Complete!"
echo "=============================================="
echo ""
echo "RKE2 Version:"
/var/lib/rancher/rke2/bin/kubectl version --short 2>/dev/null || kubectl version --client
echo ""
echo "Node Status:"
kubectl get nodes -o wide
echo ""
echo "GPU Status (if available):"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv 2>/dev/null || echo "  Run 'nvidia-smi' to check GPU"
echo ""
echo "Kubeconfig location: /etc/rancher/rke2/rke2.yaml"
echo ""
echo "Next steps:"
echo "  1. Copy kubeconfig to local machine"
echo "  2. Setup SSH tunnel for kubectl access"
echo "  3. Deploy ArgoCD: make bootstrap-argocd"
echo ""
