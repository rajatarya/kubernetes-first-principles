#!/bin/bash
set -euo pipefail

# =============================================================================
# Kubernetes Node Bootstrap Script (Ubuntu 22.04)
# =============================================================================
# Prepares a fresh Ubuntu machine to join a Kubernetes cluster.
# Run this as root (or via user-data on EC2) on ALL nodes (control plane + workers).
#
# After this script completes:
#   - On the control plane:  kubeadm init --apiserver-advertise-address=<IP> --pod-network-cidr=10.244.0.0/16
#   - On workers:            kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash>
# =============================================================================

echo ">>> [1/8] Disabling swap"
# Kubernetes requires swap to be off. The kubelet will refuse to start if swap
# is detected. We disable it at runtime and remove any swap entries from fstab
# so it stays off after reboot.
swapoff -a
sed -i '/\sswap\s/d' /etc/fstab

echo ">>> [2/8] Loading kernel modules for container networking"
# overlay:       Required by containerd to use the overlay2 storage driver.
# br_netfilter:  Required for iptables to see bridged traffic. Without this,
#                kube-proxy and CNI plugins (Flannel, Calico) can't route
#                pod-to-pod traffic through Linux bridges.
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo ">>> [3/8] Configuring sysctl for Kubernetes networking"
# net.bridge.bridge-nf-call-iptables:  Makes iptables rules apply to bridged
#   traffic. Required by kube-proxy for Service routing to work.
# net.bridge.bridge-nf-call-ip6tables: Same as above but for IPv6.
# net.ipv4.ip_forward:                 Allows the kernel to forward packets
#   between interfaces. Essential for pod networking — without this, pods
#   can't reach other pods or the outside world.
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Verify the settings took effect
echo "--- Verifying sysctl settings ---"
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward

echo ">>> [4/8] Installing containerd"
# We install containerd from Docker's official repo to get a recent version.
# Kubernetes talks to containerd via CRI (Container Runtime Interface) — it
# does NOT need the full Docker engine, just the container runtime.
apt-get update
apt-get install -y ca-certificates curl gnupg

# Add Docker's official GPG key using the modern keyring approach
# (apt-key is deprecated since Ubuntu 22.04)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y containerd.io

echo ">>> [5/8] Configuring containerd for Kubernetes"
# CRITICAL: The default containerd config on Ubuntu ships with:
#   disabled_plugins = ["cri"]
# This disables the Container Runtime Interface plugin, which is exactly what
# Kubernetes needs to manage containers. Without fixing this, kubeadm will fail
# with: "container runtime is not running ... unknown service runtime.v1.RuntimeService"
#
# We generate a fresh default config and then enable SystemdCgroup. Kubernetes
# v1.22+ defaults to the systemd cgroup driver, and containerd must match.
# If they disagree, kubelet will fail to start pods because the cgroup hierarchy
# is inconsistent (containers get created in one cgroup tree, kubelet expects another).
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup in the containerd config.
# This changes: SystemdCgroup = false  ->  SystemdCgroup = true
# under the [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options] section.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo ">>> [6/8] Installing CNI plugins"
# Containerd needs the CNI (Container Network Interface) plugin binaries to set
# up networking for each container sandbox. Without these, containerd can create
# containers but can't configure their network namespaces.
# These are the low-level binaries (bridge, host-local, loopback, etc.) that
# the higher-level CNI provider (Flannel/Calico) builds on top of.
CNI_VERSION="v1.9.1"
mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
  | tar -C /opt/cni/bin -xz

echo ">>> [7/8] Installing kubeadm, kubelet, and kubectl"
# Add the Kubernetes apt repository. We pin to v1.31 (latest stable as of 2025).
# The pkgs.k8s.io repository is the official source, replacing the old
# packages.cloud.google.com which is no longer updated.
apt-get install -y apt-transport-https
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y kubelet kubeadm kubectl conntrack

# Hold these packages to prevent accidental upgrades that could break the cluster.
# Kubernetes components must be upgraded in a specific order (control plane first,
# then workers) using kubeadm upgrade — apt upgrading them randomly will break things.
apt-mark hold kubelet kubeadm kubectl

# Enable kubelet so it starts on boot. It will crash-loop until kubeadm init/join
# configures it — that's normal and expected.
systemctl enable kubelet

echo ">>> [8/8] Installing NFS utilities"
# nfs-common is needed if you plan to use NFS-backed PersistentVolumes.
# Safe to install even if you don't — it's a small package.
apt-get install -y nfs-common

echo ""
echo "============================================="
echo " Node is ready for Kubernetes!"
echo "============================================="
echo ""
echo " Next steps:"
echo ""
echo " CONTROL PLANE:"
echo "   sudo kubeadm init \\"
echo "     --apiserver-advertise-address=<THIS_NODE_IP> \\"
echo "     --pod-network-cidr=10.244.0.0/16"
echo ""
echo "   mkdir -p \$HOME/.kube"
echo "   sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config"
echo "   sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"
echo ""
echo "   # Install Flannel CNI:"
echo "   kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
echo ""
echo " WORKERS:"
echo "   sudo kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash <hash>"
echo ""
