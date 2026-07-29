#!/bin/bash

set -e

############################################
# Kubernetes 1.28 Installation Script
# Supported OS : RHEL 8/9
############################################

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root."
    exit 1
fi

clear
echo "==============================================="
echo " Kubernetes Cluster Installation"
echo "==============================================="
echo

read -p "Enter node type (master/worker): " NODE_TYPE
NODE_TYPE=$(echo "$NODE_TYPE" | tr '[:upper:]' '[:lower:]')

if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "worker" ]]; then
    echo "Invalid node type."
    exit 1
fi

if [[ "$NODE_TYPE" == "master" ]]; then
    read -p "Enter Control Plane Endpoint IP: " CONTROL_PLANE_IP
fi

echo
echo "Starting installation..."
sleep 2

##########################################################
# Common Configuration
##########################################################

echo "Disabling SELinux..."

setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo "Disabling Swap..."

swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

echo "Loading kernel modules..."

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "Applying sysctl settings..."

cat >/etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system

echo
echo "Verification"
echo "-----------------------------"

lsmod | grep overlay || true
lsmod | grep br_netfilter || true

sysctl net.bridge.bridge-nf-call-iptables
sysctl net.bridge.bridge-nf-call-ip6tables
sysctl net.ipv4.ip_forward

##########################################################
# Subscription
##########################################################

echo
echo "RHEL Subscription"

read -p "Is this system already registered? (y/n): " REGISTER

if [[ "$REGISTER" == "n" || "$REGISTER" == "N" ]]; then
    subscription-manager register
    subscription-manager auto-attach
fi

##########################################################
# Packages
##########################################################

echo "Updating packages..."

dnf update -y

dnf install -y iproute-tc yum-utils

##########################################################
# Firewall
##########################################################

echo "Configuring firewall..."

if [[ "$NODE_TYPE" == "master" ]]; then

    firewall-cmd --permanent --add-port=6443/tcp
    firewall-cmd --permanent --add-port=2379-2380/tcp
    firewall-cmd --permanent --add-port=10250/tcp
    firewall-cmd --permanent --add-port=10251/tcp
    firewall-cmd --permanent --add-port=10252/tcp

else

    firewall-cmd --permanent --add-port=10250/tcp
    firewall-cmd --permanent --add-port=30000-32767/tcp

fi

firewall-cmd --reload

##########################################################
# Docker
##########################################################

echo "Installing Docker..."

yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

dnf remove -y podman buildah || true

yum install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin

systemctl enable --now docker

docker ps

##########################################################
# containerd
##########################################################

echo "Configuring containerd..."

mkdir -p /etc/containerd

containerd config default >/etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
/etc/containerd/config.toml

systemctl restart containerd

##########################################################
# Kubernetes Repository
##########################################################

echo "Configuring Kubernetes repository..."

cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

##########################################################
# Kubernetes Packages
##########################################################

echo "Installing Kubernetes packages..."

yum install -y \
kubelet \
kubeadm \
kubectl \
--disableexcludes=kubernetes

systemctl enable --now kubelet

echo
systemctl status docker --no-pager

echo
kubectl version --client
kubeadm version

##########################################################
# Master
##########################################################

if [[ "$NODE_TYPE" == "master" ]]; then

    echo
    echo "Initializing Kubernetes Control Plane..."

    kubeadm init \
        --pod-network-cidr=10.244.0.0/16 \
        --control-plane-endpoint="$CONTROL_PLANE_IP" \
        --ignore-preflight-errors=Mem \
        --cri-socket=/run/containerd/containerd.sock

    mkdir -p $HOME/.kube

    cp -i /etc/kubernetes/admin.conf $HOME/.kube/config

    chown $(id -u):$(id -g) $HOME/.kube/config

    echo
    echo "Nodes"

    kubectl get nodes

    echo
    echo "Installing Flannel..."

    kubectl apply -f \
https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

    echo
    echo "================================================"
    echo "Cluster initialized successfully."
    echo
    echo "Join command:"
    kubeadm token create --print-join-command
    echo "================================================"

fi

##########################################################
# Worker
##########################################################

if [[ "$NODE_TYPE" == "worker" ]]; then

    echo
    echo "=============================================="
    echo "Run the join command generated on the master."
    echo
    echo "Example:"
    echo
    echo "kubeadm join <MASTER-IP>:6443 --token <TOKEN> \\"
    echo "--discovery-token-ca-cert-hash sha256:<HASH>"
    echo "=============================================="

    read -p "Do you want to join now? (y/n): " JOIN

    if [[ "$JOIN" == "y" || "$JOIN" == "Y" ]]; then

        echo
        echo "Paste the complete kubeadm join command below."
        read -r JOIN_COMMAND

        eval "$JOIN_COMMAND"

    fi

fi

echo
echo "=============================================="
echo "Installation Completed Successfully"
echo "=============================================="
