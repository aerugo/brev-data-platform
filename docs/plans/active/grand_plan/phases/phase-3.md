# Phase 3: Brev Instance + K3S

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create a GPU-enabled Brev instance, bootstrap K3S with NVIDIA container toolkit, and configure local kubectl access.

---

## Invariants Enforced in This Phase

- **INV-I003**: GPU instance type validation - Must have NVIDIA GPU
- **INV-I004**: Cloud-init for K3S bootstrap - Automated installation
- **NEW INV-I005**: Brev instance naming convention - `brev-data-platform-dev`

---

## Step 3.1: Create Brev Instance

### Using Make

```bash
make create-instance
```

### Or directly with Brev CLI

```bash
brev create brev-data-platform-dev -g "a2-highgpu-1g:nvidia-a100-40gb:1"
```

### Monitor Instance Creation

```bash
# Watch instance status
watch -n 5 brev ls

# Wait until status shows "RUNNING"
```

**Expected output after creation:**

```
NAME                      STATUS    GPU
brev-data-platform-dev    RUNNING   a2-highgpu-1g:nvidia-a100-40gb:1
```

---

## Step 3.2: Bootstrap K3S with GPU Support

### Option A: Manual Installation (SSH)

```bash
# SSH into instance
brev shell brev-data-platform-dev

# On the instance, run these commands:

# 1. Install K3S
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# 2. Wait for K3S
sleep 30
sudo kubectl get nodes

# 3. Install NVIDIA container toolkit (if not present)
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# 4. Configure containerd
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd

# 5. Deploy NVIDIA device plugin
sudo kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/nvidia-device-plugin.yml

# 6. Label node for GPU
sudo kubectl label nodes --all nvidia.com/gpu.present=true --overwrite

# 7. Create namespaces
for ns in argocd minio lakefs dagster marimo nvidia-ai; do
  sudo kubectl create namespace $ns --dry-run=client -o yaml | sudo kubectl apply -f -
done

# 8. Verify GPU is available
sudo kubectl get nodes -o jsonpath='{.items[*].status.allocatable}' | jq
# Should show "nvidia.com/gpu": "1"
```

### Option B: Cloud-Init (if Brev supports custom user-data)

Copy `scripts/cloud-init/k3s-gpu.yaml` content to Brev instance configuration.

---

## Step 3.3: Verify K3S Installation

Still SSH'd into the instance:

```bash
# Check node status
sudo kubectl get nodes
# Expected: Ready

# Check system pods
sudo kubectl get pods -n kube-system
# All should be Running

# Check NVIDIA device plugin
sudo kubectl get pods -n kube-system | grep nvidia
# Should show nvidia-device-plugin-daemonset running

# Verify GPU is visible to Kubernetes
sudo kubectl describe node | grep -A 5 "Allocatable"
# Should include: nvidia.com/gpu: 1

# Test GPU access from a pod
sudo kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi
# Should display GPU info
```

---

## Step 3.4: Configure Local Kubeconfig

Exit the SSH session and run from your local machine:

```bash
# Exit SSH
exit

# Fetch kubeconfig
make kubeconfig

# Or manually:
./scripts/setup-kubeconfig.sh brev-data-platform-dev

# Set KUBECONFIG
export KUBECONFIG=$PWD/kubeconfig.yaml

# Verify connection
kubectl get nodes
```

### Troubleshooting Kubeconfig

If connection fails, the server address may need updating:

```bash
# Get instance info
brev ls --json | jq '.[] | select(.name=="brev-data-platform-dev")'

# SSH and get IP
brev shell brev-data-platform-dev
hostname -I
# Note the IP address

# Exit and update kubeconfig
exit
sed -i "s|server: https://127.0.0.1:6443|server: https://INSTANCE_IP:6443|g" kubeconfig.yaml
```

---

## Step 3.5: Verify Remote Access

From your local machine:

```bash
# Set kubeconfig
export KUBECONFIG=$PWD/kubeconfig.yaml

# Test connection
kubectl cluster-info

# List nodes
kubectl get nodes

# List all pods
kubectl get pods -A

# Check namespaces were created
kubectl get namespaces

# Expected namespaces:
# - default
# - kube-system
# - kube-public
# - kube-node-lease
# - argocd
# - minio
# - lakefs
# - dagster
# - marimo
# - nvidia-ai
```

---

## Validation Approach

### From Local Machine

```bash
# Verify instance running
brev ls | grep brev-data-platform-dev | grep RUNNING

# Verify kubectl works
kubectl get nodes

# Verify GPU available
kubectl describe node | grep "nvidia.com/gpu"

# Verify namespaces
kubectl get ns | wc -l  # Should be 10+

# Verify NVIDIA device plugin
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds
```

### Using Brev CLI to Verify

```bash
# Quick GPU check via Brev
brev shell brev-data-platform-dev -c "nvidia-smi"

# Quick K3S check
brev shell brev-data-platform-dev -c "sudo kubectl get nodes"
```

---

## Resource Status After This Phase

| Resource | Status | Verification |
|----------|--------|--------------|
| Brev Instance | Running | `brev ls` |
| K3S | Ready | `kubectl get nodes` |
| NVIDIA Plugin | Running | `kubectl get pods -n kube-system` |
| GPU Available | Yes | `kubectl describe node \| grep nvidia` |
| Namespaces | Created | `kubectl get ns` |
| Local Access | Working | `kubectl cluster-info` |

---

## Cost Management

The Brev instance incurs costs while running. To minimize costs:

```bash
# Stop instance when not in use
make stop-instance
# or: brev stop brev-data-platform-dev

# Start when needed
make start-instance
# or: brev start brev-data-platform-dev
```

**Note**: Stopping preserves the instance and data. Deleting removes everything.

---

## Completion Criteria

- [ ] `brev ls` shows instance as RUNNING
- [ ] `nvidia-smi` works inside instance
- [ ] K3S node is Ready
- [ ] NVIDIA device plugin pods are Running
- [ ] `nvidia.com/gpu: 1` appears in node allocatable resources
- [ ] All 6 namespaces created (argocd, minio, lakefs, dagster, marimo, nvidia-ai)
- [ ] Local `kubectl get nodes` works with kubeconfig
- [ ] Can run GPU test pod successfully

---

## Next Phase

Once K3S is running with GPU support, proceed to [Phase 4: ArgoCD Bootstrap](phase-4.md).
