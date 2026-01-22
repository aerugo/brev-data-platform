# Phase 3: Brev Instance + RKE2

**Status**: Pending
**Started**:
**Parent Plan**: [development-plan.md](../development-plan.md)

---

## Objective

Create a GPU-enabled Brev instance (H200), bootstrap RKE2 with NVIDIA container toolkit, and configure local kubectl access.

---

## Why RKE2 Instead of K3S?

| Aspect | RKE2 | K3S |
|--------|------|-----|
| Run:AI/KAI Compatibility | ✅ Fully supported | ❌ Not supported |
| Enterprise Support | ✅ SUSE/Rancher | ✅ SUSE/Rancher |
| FIPS Compliance | ✅ Built-in | ❌ Limited |
| GPU Scheduling | ✅ KAI Scheduler | ⚠️ Basic only |
| Resource Overhead | Higher | Lower |

RKE2 is required for KAI Scheduler and any future Run:AI integration.

---

## Invariants Enforced in This Phase

- **INV-I003**: GPU instance type validation - Must have at least NVIDIA A100 GPU (40GB or 80GB)
- **INV-I004**: Cloud-init for RKE2 bootstrap - Automated installation
- **INV-I005**: Configuration as Code - All subsequent configuration automated after instance creation
- **INV-K008**: RKE2 as Kubernetes distribution - Required for KAI Scheduler

---

## Step 3.1: Create Brev Instance (Manual - Documented Exception)

> **Note**: As of January 2026, A100+ GPU instances are only available through non-GCP providers (CRUSOE, DENVR, LAMBDA) via the Brev web console. The Brev CLI only supports GCP which lacks A100 availability. This is a documented exception to INV-I005.

### Via Brev Web Console (Required for A100+)

1. Go to [https://brev.nvidia.com](https://brev.nvidia.com)
2. Ensure you're in the correct organization (e.g., "Riksbank-Org")
3. Click **GPUs** → Select **A100 • 80 GiB VRAM** from **CRUSOE** provider
   - Recommended: CRUSOE offers flexible storage, flexible ports, and stop/start without data loss
   - Instance type: `a100-80gb.1x` (~$1.98/hr)
4. Configure:
   - **Disk Storage**: 256 GiB (minimum)
   - **Software Configuration**: VM Mode w/ Jupyter (we'll install RKE2 manually)
   - **Name Instance**: `brev-data-platform-dev`
5. Click **Deploy**
6. Wait for instance to show "Running" status (~7 minutes)

### Alternative: Using CLI (GCP only - T4 default, NOT recommended)

```bash
# WARNING: This only creates T4 instances on GCP - NOT suitable for this platform
# brev create brev-data-platform-dev -g "A100"  # Only works in orgs with GCP A100 quota
```

### Verify Instance Creation

```bash
# Check instance is running
brev ls

# Expected output:
# NAME                      STATUS
# brev-data-platform-dev    RUNNING
```

---

## Step 3.2: Automated Setup (Recommended)

Once the instance is running, use the interactive setup script that automates everything:

```bash
make setup
```

This script will:
1. Prompt for the instance name (or use `brev-data-platform-dev` by default)
2. Verify the instance is running
3. Wait for SSH to be ready
4. Bootstrap RKE2 with GPU support
5. Fetch kubeconfig to local machine
6. Set up SSH tunnel for kubectl access
7. Verify cluster connectivity and GPU availability

**Or specify the instance name directly:**

```bash
make setup INSTANCE_NAME=brev-data-platform-dev
# Or run the script directly:
./scripts/setup-instance.sh brev-data-platform-dev
```

---

## Step 3.3: Manual Setup (Alternative)

If you prefer to run each step manually:

### Option A: Manual Installation (SSH)

```bash
# SSH into instance
brev shell brev-data-platform-dev

# On the instance, run the bootstrap script:
curl -sfL https://raw.githubusercontent.com/aerugo/brev-data-platform/main/scripts/bootstrap-rke2.sh | sudo bash

# Or manually step-by-step:

# 1. Install RKE2
curl -sfL https://get.rke2.io | sudo sh -

# 2. Enable and start RKE2
sudo systemctl enable rke2-server.service
sudo systemctl start rke2-server.service

# 3. Wait for RKE2 to be ready
sleep 60
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes

# 4. Install NVIDIA container toolkit (if not present)
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# 5. Configure containerd for NVIDIA runtime
CONTAINERD_CONFIG="/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"
sudo mkdir -p $(dirname $CONTAINERD_CONFIG)
sudo nvidia-ctk runtime configure --runtime=containerd --config=$CONTAINERD_CONFIG --set-as-default

# 6. Restart RKE2 to pick up containerd changes
sudo systemctl restart rke2-server.service
sleep 30

# 7. Set up kubectl alias for convenience
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> ~/.bashrc
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> ~/.bashrc

# 8. Deploy NVIDIA device plugin
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml

# 9. Label node for GPU
kubectl label nodes --all nvidia.com/gpu.present=true --overwrite

# 10. Install local-path-provisioner (RKE2 doesn't include it like K3S)
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
# Wait for it to be ready
kubectl wait --for=condition=ready pod -l app=local-path-provisioner -n local-path-storage --timeout=60s
# Set as default storage class
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# 11. Create namespaces
for ns in argocd minio lakefs monitoring dagster marimo nvidia-ai; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
done

# 12. Verify GPU is available
kubectl get nodes -o jsonpath='{.items[*].status.allocatable}' | jq
# Should show "nvidia.com/gpu": "1"
```

### Option B: Cloud-Init (Automated)

If Brev supports custom user-data, use the cloud-init script:

```bash
# The cloud-init script is at: scripts/cloud-init/rke2-gpu.yaml
# Copy its content to Brev instance configuration during creation
```

---

## Step 3.3: Verify RKE2 Installation

Still SSH'd into the instance:

```bash
# Set environment
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin

# Check node status
kubectl get nodes
# Expected: Ready

# Check system pods
kubectl get pods -n kube-system
# All should be Running

# Check NVIDIA device plugin
kubectl get pods -n kube-system | grep nvidia
# Should show nvidia-device-plugin-daemonset running

# Verify GPU is visible to Kubernetes
kubectl describe node | grep -A 5 "Allocatable"
# Should include: nvidia.com/gpu: 1

# Test GPU access from a pod
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0-base \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi
# Should display H200 GPU info with 141GB VRAM
```

---

## Step 3.4: Configure Local Kubeconfig

Exit the SSH session and run from your local machine:

```bash
# Exit SSH
exit

# Fetch kubeconfig (script auto-detects RKE2 vs K3S)
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

### RKE2 vs K3S Kubeconfig Paths

| Distribution | Kubeconfig Path |
|--------------|-----------------|
| RKE2 | `/etc/rancher/rke2/rke2.yaml` |
| K3S | `/etc/rancher/k3s/k3s.yaml` |

The `setup-kubeconfig.sh` script automatically detects which is installed.

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
# - monitoring
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
kubectl get ns | wc -l  # Should be 11+

# Verify NVIDIA device plugin
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds

# Verify RKE2 (not K3S)
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'
# Should show containerd version used by RKE2
```

### Using Brev CLI to Verify

```bash
# Quick GPU check via Brev
brev shell brev-data-platform-dev -c "nvidia-smi"

# Quick RKE2 check
brev shell brev-data-platform-dev -c "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes"
```

---

## Resource Status After This Phase

| Resource | Status | Verification |
|----------|--------|--------------|
| Brev Instance | Running | `brev ls` |
| RKE2 | Ready | `kubectl get nodes` |
| NVIDIA Plugin | Running | `kubectl get pods -n kube-system` |
| H200 GPU Available | Yes | `kubectl describe node \| grep nvidia` |
| Namespaces | Created | `kubectl get ns` |
| Local Access | Working | `kubectl cluster-info` |

---

## Cost Management

The H200 Brev instance costs approximately $4.20/hr while running. To minimize costs:

```bash
# Stop instance when not in use
make down
# or: brev stop brev-data-platform-dev

# Start when needed
make up
# or: brev start brev-data-platform-dev

# Fully destroy (deletes everything)
make destroy
# or: brev delete brev-data-platform-dev
```

**Note**: Stopping preserves the instance and data (~$0.03-0.10/hr for storage). Deleting removes everything.

---

## Completion Criteria

- [ ] `brev ls` shows instance as RUNNING with H200 GPU
- [ ] `nvidia-smi` works inside instance showing H200 (141GB VRAM)
- [ ] RKE2 node is Ready
- [ ] NVIDIA device plugin pods are Running
- [ ] `nvidia.com/gpu: 1` appears in node allocatable resources
- [ ] All 7 namespaces created (argocd, minio, lakefs, monitoring, dagster, marimo, nvidia-ai)
- [ ] Local `kubectl get nodes` works with kubeconfig
- [ ] Can run GPU test pod successfully

---

## Next Phase

Once RKE2 is running with GPU support, proceed to [Phase 4: KAI Scheduler](phase-4.md) to install the GPU workload scheduler.
