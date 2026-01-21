#!/bin/bash
# Bootstrap K3S with NVIDIA GPU support on Brev instance
# Run this script ON the Brev instance after creation

set -e

echo "=== K3S + NVIDIA GPU Bootstrap ==="
echo "This script installs K3S with GPU support on a Brev instance"
echo ""

# Check if running on a GPU instance
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found. Is this a GPU instance?"
    exit 1
fi

echo "GPU detected:"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
echo ""

# -----------------------------------------------------------------------------
# Step 1: Install K3S
# -----------------------------------------------------------------------------
echo "=== Step 1: Installing K3S ==="

if command -v k3s &> /dev/null; then
    echo "K3S already installed, skipping..."
else
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
fi

# Wait for K3S to be ready
echo "Waiting for K3S to start..."
sleep 30
until sudo kubectl get nodes &>/dev/null; do
    echo "Waiting for K3S API..."
    sleep 5
done
echo "K3S is running"
sudo kubectl get nodes

# -----------------------------------------------------------------------------
# Step 2: Install NVIDIA container toolkit
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2: Installing NVIDIA container toolkit ==="

if command -v nvidia-ctk &> /dev/null; then
    echo "NVIDIA container toolkit already installed"
else
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
fi

# -----------------------------------------------------------------------------
# Step 3: Deploy NVIDIA device plugin
# NOTE: We deploy directly without restarting containerd because K3S uses
# embedded containerd and restarting it breaks the CNI plugin
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3: Deploying NVIDIA device plugin ==="

# Apply device plugin with tolerations for control-plane node
cat << 'EOF' | sudo kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      priorityClassName: system-node-critical
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.14.1
        name: nvidia-device-plugin-ctr
        env:
        - name: FAIL_ON_INIT_ERROR
          value: "false"
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        volumeMounts:
        - name: device-plugin
          mountPath: /var/lib/kubelet/device-plugins
      volumes:
      - name: device-plugin
        hostPath:
          path: /var/lib/kubelet/device-plugins
EOF

# Label node for GPU
sudo kubectl label nodes --all nvidia.com/gpu.present=true --overwrite

# -----------------------------------------------------------------------------
# Step 4: Create namespaces
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 4: Creating namespaces ==="

for ns in argocd minio lakefs dagster marimo nvidia-ai; do
    sudo kubectl create namespace $ns --dry-run=client -o yaml | sudo kubectl apply -f -
done

# -----------------------------------------------------------------------------
# Step 5: Verify setup
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 5: Waiting for NVIDIA device plugin ==="
sleep 30

echo ""
echo "=== Verification ==="
echo ""
echo "Node status:"
sudo kubectl get nodes -o wide

echo ""
echo "NVIDIA device plugin pod:"
sudo kubectl get pods -n kube-system | grep nvidia || echo "Warning: NVIDIA pod not found yet"

echo ""
echo "GPU in allocatable resources:"
sudo kubectl describe node | grep -E "nvidia.com/gpu" | head -5 || echo "Warning: GPU not yet in allocatable"

echo ""
echo "Namespaces created:"
sudo kubectl get ns

echo ""
echo "=== Bootstrap complete! ==="
echo ""
echo "From your local machine, run:"
echo "  ./scripts/setup-kubeconfig.sh"
echo "  ssh -F ~/.brev/ssh_config -N -L 6443:127.0.0.1:6443 brev-data-platform-dev-host &"
echo "  export KUBECONFIG=\$PWD/kubeconfig.yaml"
echo "  kubectl get nodes"
echo ""
