#!/bin/bash
set -eu

# ══════════════════════════════════════════════════════════════════════════════
# k8s-setup-controlplane.sh
# Kubernetes 1.28 control plane setup — Ubuntu 22.04
# ══════════════════════════════════════════════════════════════════════════════

LOG_FILE="/var/log/k8s-setup-controlplane.log"
POD_CIDR="192.168.0.0/16"
K8S_VERSION="1.28"
CALICO_VERSION="v3.27.3"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
section() {
  echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') ${CYAN}══════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${CYAN}  $*${NC}" | tee -a "$LOG_FILE"
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${CYAN}══════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}


# ── Pre-flight checks ─────────────────────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && error "Run this script as root: sudo $0"

. /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "22.04" ]] \
  || warn "Script tested on Ubuntu 22.04; detected $PRETTY_NAME — proceed with caution"

exec > >(tee -a "$LOG_FILE") 2>&1
log "Setup started. Full log: $LOG_FILE"

# ══════════════════════════════════════════════════════════════════════════════
# 1 / 9  Disable swap
# ══════════════════════════════════════════════════════════════════════════════
section "1/9  Disabling swap"

swapoff -a
# Comment out any swap entries in fstab
sed -i '/\bswap\b/s/^/#/' /etc/fstab

log "Swap disabled (runtime + fstab)"

# ══════════════════════════════════════════════════════════════════════════════
# 2 / 9  Load kernel modules
# ══════════════════════════════════════════════════════════════════════════════
section "2/9  Loading kernel modules"

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

lsmod | grep -E '^(overlay|br_netfilter)' | awk '{print "  loaded: "$1}'
log "Modules overlay and br_netfilter loaded and made persistent"

# ══════════════════════════════════════════════════════════════════════════════
# 3 / 9  Sysctl parameters
# ══════════════════════════════════════════════════════════════════════════════
section "3/9  Applying sysctl parameters"

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system | grep -E 'k8s|ip_forward|bridge' | sed 's/^/  /'
log "Sysctl parameters applied"

# ══════════════════════════════════════════════════════════════════════════════
# 4 / 9  Install and configure containerd
# ══════════════════════════════════════════════════════════════════════════════
section "4/9  Installing containerd"

apt-get update -q
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -q
apt-get install -y containerd.io
log "containerd.io installed: $(containerd --version)"

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup so kubelet and containerd use the same cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

grep 'SystemdCgroup' /etc/containerd/config.toml | sed 's/^/  /'

systemctl restart containerd
systemctl enable containerd
log "containerd configured with SystemdCgroup=true and enabled"

# ══════════════════════════════════════════════════════════════════════════════
# 5 / 9  Install kubeadm, kubelet, kubectl 1.28
# ══════════════════════════════════════════════════════════════════════════════
section "5/9  Installing Kubernetes ${K8S_VERSION} components"

apt-get install -y apt-transport-https gpg

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt-get update -q
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

log "Installed and held:"
log "  $(kubeadm version --output short)"
log "  $(kubelet --version)"
log "  $(kubectl version --client --output=yaml | grep gitVersion | head -1 | awk '{print $2}')"

# ══════════════════════════════════════════════════════════════════════════════
# 6 / 9  Enable kubelet
# ══════════════════════════════════════════════════════════════════════════════
section "6/9  Enabling kubelet"

systemctl enable --now kubelet
log "kubelet enabled (will fully start after kubeadm init)"

# ══════════════════════════════════════════════════════════════════════════════
# 7 / 9  Initialize Kubernetes cluster
# ══════════════════════════════════════════════════════════════════════════════
section "7/9  Initializing cluster with kubeadm"

ADVERTISE_ADDR=$(ip route get 1.1.1.1 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')

[[ -z "$ADVERTISE_ADDR" ]] && error "Could not detect node IP address"
log "API server advertise address: $ADVERTISE_ADDR"

kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address="${ADVERTISE_ADDR}" \
  2>&1 | tee /root/kubeadm-init.log

# Extract and save the worker join command
awk '/kubeadm join/,/--discovery-token-ca-cert-hash/' /root/kubeadm-init.log \
  | sed 's/^\s*//' > /root/worker-join-command.sh
chmod 600 /root/worker-join-command.sh

log "Cluster initialized"
log "Worker join command saved to /root/worker-join-command.sh"

# ══════════════════════════════════════════════════════════════════════════════
# 8 / 9  Configure kubeconfig
# ══════════════════════════════════════════════════════════════════════════════
section "8/9  Configuring kubeconfig"

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
log "kubeconfig set up for root"

if [[ -n "${SUDO_USER:-}" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  mkdir -p "${USER_HOME}/.kube"
  cp /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
  chown -R "${SUDO_USER}:${SUDO_USER}" "${USER_HOME}/.kube"
  log "kubeconfig set up for ${SUDO_USER} at ${USER_HOME}/.kube/config"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# ══════════════════════════════════════════════════════════════════════════════
# 9 / 9  Install Calico CNI
# ══════════════════════════════════════════════════════════════════════════════
section "9/9  Installing Calico CNI ${CALICO_VERSION}"

kubectl apply -f \
  "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

log "Calico manifest applied — waiting for pods to become Ready (up to 3 min)..."

kubectl wait pod \
  --all \
  --for=condition=Ready \
  --namespace=kube-system \
  --timeout=180s \
  || warn "Some pods not yet Ready — this is normal on first boot, check again in a minute"

# ══════════════════════════════════════════════════════════════════════════════
# Status
# ══════════════════════════════════════════════════════════════════════════════
section "Cluster Status"

kubectl get nodes -o wide
echo ""
kubectl get pods -A

echo ""
log "Control plane setup complete"
log "Full log:           $LOG_FILE"
log "kubeadm init log:   /root/kubeadm-init.log"
log "Worker join cmd:    /root/worker-join-command.sh"
