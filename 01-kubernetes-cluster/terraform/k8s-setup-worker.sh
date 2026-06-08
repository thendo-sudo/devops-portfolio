#!/bin/bash
set -eu

# ══════════════════════════════════════════════════════════════════════════════
# k8s-setup-worker.sh
# Kubernetes 1.28 worker node setup — Ubuntu 22.04
# ══════════════════════════════════════════════════════════════════════════════

LOG_FILE="/var/log/k8s-setup-worker.log"
K8S_VERSION="1.28"
JOIN_COMMAND="kubeadm join 10.0.1.5:6443 --token 4kal23.5qqpix4gptxxm352 --discovery-token-ca-cert-hash sha256:0924f0a47a6e5c628d292df330c3334aa188d14c5bb228d83ed9a96dbcfbcd18"

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
# 1 / 6  Disable swap
# ══════════════════════════════════════════════════════════════════════════════
section "1/6  Disabling swap"

swapoff -a
sed -i '/\bswap\b/s/^/#/' /etc/fstab

log "Swap disabled (runtime + fstab)"

# ══════════════════════════════════════════════════════════════════════════════
# 2 / 6  Load kernel modules
# ══════════════════════════════════════════════════════════════════════════════
section "2/6  Loading kernel modules"

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

lsmod | grep -E '^(overlay|br_netfilter)' | awk '{print "  loaded: "$1}'
log "Modules overlay and br_netfilter loaded and made persistent"

# ══════════════════════════════════════════════════════════════════════════════
# 3 / 6  Sysctl parameters
# ══════════════════════════════════════════════════════════════════════════════
section "3/6  Applying sysctl parameters"

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system | grep -E 'k8s|ip_forward|bridge' | sed 's/^/  /'
log "Sysctl parameters applied"

# ══════════════════════════════════════════════════════════════════════════════
# 4 / 6  Install and configure containerd
# ══════════════════════════════════════════════════════════════════════════════
section "4/6  Installing containerd"

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
# 5 / 6  Install kubeadm, kubelet, kubectl 1.28
# ══════════════════════════════════════════════════════════════════════════════
section "5/6  Installing Kubernetes ${K8S_VERSION} components"

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
# 6 / 6  Enable kubelet and join the cluster
# ══════════════════════════════════════════════════════════════════════════════
section "6/6  Joining the cluster"

systemctl enable --now kubelet
log "kubelet enabled"

log "Running: $JOIN_COMMAND"
$JOIN_COMMAND

# ══════════════════════════════════════════════════════════════════════════════
# Status
# ══════════════════════════════════════════════════════════════════════════════
section "Status"

log "Worker node setup complete"
log "Full log: $LOG_FILE"
log "Verify the node joined by running on the control plane: kubectl get nodes"
