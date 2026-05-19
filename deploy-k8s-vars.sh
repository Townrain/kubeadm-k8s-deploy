#!/bin/bash
###############################################################################
# Kubeadm v1.35.4 部署 Kubernetes 集群 — 变量库
# 用法: source deploy-k8s-vars.sh   (在主脚本 deploy-k8s-cluster.sh 中引入)
# 说明: 集中管理所有可配置变量，修改此文件即可批量调整集群参数
###############################################################################

# ╔══════════════════════════════════════════════════════════════╗
# ║                   1. 颜色常量                                ║
# ╚══════════════════════════════════════════════════════════════╝
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ╔══════════════════════════════════════════════════════════════╗
# ║                   2. 版本常量                                ║
# ╚══════════════════════════════════════════════════════════════╝
K8S_VERSION="v1.35.4"           # Kubernetes 版本
CRICTL_VERSION="v1.35.0"        # cri-tools 版本 (需与 K8s 主版本匹配)
CALICO_VERSION="v3.32.0"        # Calico CNI 插件版本
HELM_VERSION="v3.19.0"          # Helm 包管理器版本
DASHBOARD_VERSION="7.14.0"     # Dashboard 版本 (已于 2026-01-21 归档退役)

# ╔══════════════════════════════════════════════════════════════╗
# ║                   3. 集群节点配置                            ║
# ║   (交互模式下由用户输入覆盖; 可直接填好以跳过交互)          ║
# ╚══════════════════════════════════════════════════════════════╝

# ---- Master 节点 ----
MASTER_HOSTNAME="master"        # Master 主机名
MASTER_IP=""                    # Master IP (交互时自动检测)
MASTER_PREFIX=""                # Master 子网前缀 (默认 24)
MASTER_GW=""                    # Master 网关 (交互时自动检测)
MASTER_IFACE=""                 # Master 网卡名 (交互时自动检测)

# ---- Worker1 节点 ----
WORKER1_HOSTNAME="node1"        # Worker1 主机名
WORKER1_IP=""                   # Worker1 IP (必须手动输入或用 SSH 远程检测)
WORKER1_PREFIX=""               # Worker1 子网前缀 (默认 24)
WORKER1_GW=""                   # Worker1 网关
WORKER1_IFACE=""                # Worker1 网卡名
WORKER1_USER="root"             # Worker1 SSH 用户名

# ---- Worker2 节点 ----
WORKER2_HOSTNAME="node2"        # Worker2 主机名
WORKER2_IP=""                   # Worker2 IP (必须手动输入或用 SSH 远程检测)
WORKER2_PREFIX=""               # Worker2 子网前缀 (默认 24)
WORKER2_GW=""                   # Worker2 网关
WORKER2_IFACE=""                # Worker2 网卡名
WORKER2_USER="root"             # Worker2 SSH 用户名

# ╔══════════════════════════════════════════════════════════════╗
# ║                   4. 网络规划                                ║
# ╚══════════════════════════════════════════════════════════════╝
POD_CIDR="10.244.0.0/16"       # Pod 网段
SVC_CIDR="172.16.32.0/24"       # Service 网段
DNS_DOMAIN="cluster.local"      # 集群 DNS 域
DNS_SERVERS="8.8.8.8;223.5.5.5;"  # 各节点 DNS (nmconnection 格式，分号结尾)
API_BIND_PORT="6443"            # kube-apiserver 绑定端口
EXCLUDE_IFACE_FILTER="lo|virbr|docker|br-|veth|tun|tap|vnet|ovs|cali|kube"
                                # 网卡检测时排除的接口正则

# ╔══════════════════════════════════════════════════════════════╗
# ║                   5. 外部 URL / 仓库地址                     ║
# ╚══════════════════════════════════════════════════════════════╝

# ---- 操作系统仓库 ----
DOCKER_CE_REPO_URL="https://download.docker.com/linux/centos/docker-ce.repo"

KUBERNETES_REPO_BASEURL="https://pkgs.k8s.io/core:/stable:/v1.35/rpm/"
KUBERNETES_REPO_GPGKEY="https://pkgs.k8s.io/core:/stable:/v1.35/rpm/repodata/repomd.xml.key"

# ---- GitHub 下载地址 ----
CRICTL_DOWNLOAD_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download"
CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
HELM_DOWNLOAD_URL="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
DASHBOARD_DOWNLOAD_URL="https://github.com/kubernetes-retired/dashboard/releases/download/kubernetes-dashboard-${DASHBOARD_VERSION}/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"

# ╔══════════════════════════════════════════════════════════════╗
# ║                   6. 容器镜像 & 代理                         ║
# ╚══════════════════════════════════════════════════════════════╝

# ---- kubeadm 镜像仓库 (阿里云) ----
KUBEADM_IMAGE_REPO="registry.aliyuncs.com/google_containers"

# ---- Containerd pause (sandbox) 镜像 ----
DEFAULT_PAUSE_IMAGE="registry.k8s.io/pause:3.10.1"            # 官方 (被墙)
PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.10.1"  # 阿里云替代

# ---- 镜像代理 (Containerd mirrors) ----
# docker.io 代理 — docker.1panel.live 是唯一实测 blob 全量缓存的稳定站
MIRROR_DOCKER_ENDPOINT="https://docker.1panel.live"
MIRROR_K8S_GCR_ENDPOINT="https://registry.k8s.io"
MIRROR_GCR_ENDPOINT="https://gcr.m.daocloud.io"
MIRROR_QUAY_ENDPOINT="https://quay.m.daocloud.io"

# ---- Calico 镜像加速 ----
CALICO_ORIGINAL_REGISTRY="quay.io/"
CALICO_PROXY_REGISTRY="quay.m.daocloud.io/"

# ---- 验证镜像 ----
VERIFY_IMAGE="nginx:1.27"       # 各节点拉取验证用的测试镜像

# ╔══════════════════════════════════════════════════════════════╗
# ║                   7. 文件路径                                ║
# ╚══════════════════════════════════════════════════════════════╝

# ---- SSH ----
SSH_KEYFILE="/root/.ssh/id_rsa"
SSH_KEY_COMMENT="k8s-deploy"
SSH_KEY_BITS="2048"

# ---- 系统 ----
HOSTS_FILE="/etc/hosts"
SELINUX_CONFIG="/etc/selinux/config"
FSTAB_FILE="/etc/fstab"
GRUB_DEFAULT="/etc/default/grub"
GRUB_CFG="/boot/grub2/grub.cfg"
SWAP_DEVICE="/dev/mapper/cs-swap"
SWAP_UNIT="dev-mapper-cs\\x2dswap.swap"

# ---- 内核 ----
MODULES_LOAD_DIR="/etc/modules-load.d"
MODULES_CONF="${MODULES_LOAD_DIR}/k8s.conf"
SYSCTL_DIR="/etc/sysctl.d"
SYSCTL_CONF="${SYSCTL_DIR}/k8s.conf"

# ---- 网络 ----
NM_CONNECTION_DIR="/etc/NetworkManager/system-connections"

# ---- Containerd ----
CONTAINERD_CONFIG="/etc/containerd/config.toml"
CONTAINERD_SOCK="unix:///run/containerd/containerd.sock"

# ---- crictl ----
CRICTL_CONFIG="/etc/crictl.yaml"
CRICTL_BIN="/usr/local/bin/crictl"

# ---- Kubernetes ----
KUBERNETES_REPO_FILE="/etc/yum.repos.d/kubernetes.repo"
KUBELET_EXTRA_ARGS_FILE="/etc/sysconfig/kubelet"
K8S_CONFIG_DIR="/etc/k8s"
KUBEADM_CONFIG="${K8S_CONFIG_DIR}/kubeadm-config.yaml"
KUBEADM_INIT_LOG="${K8S_CONFIG_DIR}/kubeadm-init.log"
JOIN_CMD_FILE="${K8S_CONFIG_DIR}/join-command.sh"
CALICO_YAML="${K8S_CONFIG_DIR}/calico.yaml"
KUBECONFIG_FILE="/etc/kubernetes/admin.conf"
KUBECONFIG_HOME="$HOME/.kube/config"
PROFILE_FILE="/etc/profile"

# ---- 日志 ----
WORKER1_LOG="/tmp/worker1-deploy.log"
WORKER2_LOG="/tmp/worker2-deploy.log"

# ---- Dashboard ----
DASHBOARD_NAMESPACE="kubernetes-dashboard"
DASHBOARD_SA="dashboard-admin"
DASHBOARD_PORT_FORWARD_SERVICE="/etc/systemd/system/dashboard-portforward.service"
DASHBOARD_PORT_FORWARD_LOCAL="8443"
DASHBOARD_PORT_FORWARD_REMOTE="443"
DASHBOARD_KONG_SVC="svc/dashboard-kong-proxy"
DASHBOARD_TOKEN_DURATION="24h"

# ╔══════════════════════════════════════════════════════════════╗
# ║                   8. 软件包名                                ║
# ╚══════════════════════════════════════════════════════════════╝
PKG_DNF_PLUGINS="dnf-plugins-core"
PKG_CONTAINERD="containerd.io"
PKG_KUBEADM="kubeadm-1.35*"
PKG_KUBELET="kubelet-1.35*"
PKG_KUBECTL="kubectl-1.35*"

# ╔══════════════════════════════════════════════════════════════╗
# ║                   9. kubeadm 配置值                           ║
# ╚══════════════════════════════════════════════════════════════╝
KUBEADM_API_VERSION="kubeadm.k8s.io/v1beta4"
KUBEADM_AUTH_MODE="Node,RBAC"
KUBEADM_CONTROLLER_BIND="0.0.0.0"
KUBEADM_SCHEDULER_BIND="0.0.0.0"
KUBEPROXY_MODE="ipvs"
CGROUP_DRIVER="systemd"
KUBEADM_IGNORE_PREFLIGHT="CRI,ContainerRuntimeVersion"

# ╔══════════════════════════════════════════════════════════════╗
# ║                  10. 服务名                                  ║
# ╚══════════════════════════════════════════════════════════════╝
SVC_FIREWALLD="firewalld"
SVC_CONTAINERD="containerd"
SVC_KUBELET="kubelet"
SVC_CHRONYD="chronyd"

# ╔══════════════════════════════════════════════════════════════╗
# ║                  11. 超时 & 等待                             ║
# ╚══════════════════════════════════════════════════════════════╝
SSH_CONNECT_TIMEOUT="10"        # SSH 连接超时 (秒)
CALICO_WAIT_TIMEOUT="300"       # Calico Pods 就绪等待 (秒)
DASHBOARD_WAIT_TIMEOUT="600"    # Dashboard Pods 就绪等待 (秒)
NGINX_WAIT_TIMEOUT="120"        # nginx 测试 Pods 等待 (秒)
CURL_CONNECT_TIMEOUT="3"        # curl 连接超时 (秒)

# ╔══════════════════════════════════════════════════════════════╗
# ║                  12. 离线部署 (本地 ISO)                      ║
# ╚══════════════════════════════════════════════════════════════╝
DEPLOY_MODE="online"            # 部署模式: online | offline
OFFLINE_ISO="/root/k8s-offline-repo.iso"    # 离线 ISO 路径
OFFLINE_MOUNT="/mnt/k8s-offline"            # ISO 挂载点
OFFLINE_REPO_FILE="/etc/yum.repos.d/k8s-offline.repo"  # 本地 DNF 仓库定义

# ISO 内部目录结构 (挂载后相对于 OFFLINE_MOUNT)
OFFLINE_RPMS_DIR="rpms"          # RPM 软件包目录
OFFLINE_IMAGES_DIR="images"      # 容器镜像归档目录
OFFLINE_BINARIES_DIR="binaries"  # 二进制文件目录 (crictl, helm)
OFFLINE_MANIFESTS_DIR="manifests" # YAML 清单/Chart 目录 (calico.yaml, dashboard)

# 镜像归档文件名
OFFLINE_KUBEADM_IMAGES="kubeadm-images.tar"
OFFLINE_CALICO_IMAGES="calico-images.tar"
OFFLINE_DASHBOARD_IMAGES="dashboard-images.tar"

# 本地文件 (相对于 OFFLINE_BINARIES_DIR)
OFFLINE_CRICTL_TGZ="crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
OFFLINE_HELM_TGZ="helm-${HELM_VERSION}-linux-amd64.tar.gz"

# 本地清单 (相对于 OFFLINE_MANIFESTS_DIR)
OFFLINE_CALICO_YAML="calico.yaml"
OFFLINE_DASHBOARD_TGZ="kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"

# ╔══════════════════════════════════════════════════════════════╗
# ║                  13. 功能开关                                ║
# ╚══════════════════════════════════════════════════════════════╝
ENABLE_FIREWALL=false           # 启用防火墙 (默认禁用)
ENABLE_SELINUX=false            # 启用 SELinux (默认禁用)
ENABLE_SWAP=false               # 启用 Swap (默认禁用，K8s 要求)
INSTALL_DASHBOARD=false         # 是否默认安装 Dashboard (交互时可覆盖)

# ╔══════════════════════════════════════════════════════════════╗
# ║                  14. kubelet 参数                           ║
# ╚══════════════════════════════════════════════════════════════╝
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=${CONTAINERD_SOCK}"

# ╔══════════════════════════════════════════════════════════════╗
# ║                  15. Dashboard Helm 安装参数                 ║
# ╚══════════════════════════════════════════════════════════════╝
DASHBOARD_HELM_RELEASE="dashboard"
DASHBOARD_HELM_CHART="./kubernetes-dashboard"
HELM_KONG_ENABLED=true
HELM_CERT_MANAGER_ENABLED=false
HELM_NGINX_ENABLED=false
HELM_METRICS_SERVER_ENABLED=false

# ╔══════════════════════════════════════════════════════════════╗
# ║                  16. SSH 远程部署参数                        ║
# ╚══════════════════════════════════════════════════════════════╝
REMOTE_SCRIPT_NAME="deploy-k8s-cluster.sh"
REMOTE_SCRIPT_PATH="/root/${REMOTE_SCRIPT_NAME}"

# ╔══════════════════════════════════════════════════════════════╗
# ║                  17. 内核模块列表                            ║
# ╚══════════════════════════════════════════════════════════════╝
KERNEL_MODULES=(
    "br_netfilter"
    "overlay"
)

# ╔══════════════════════════════════════════════════════════════╗
# ║                  18. sysctl 内核参数                         ║
# ╚══════════════════════════════════════════════════════════════╝
declare -A SYSCTL_PARAMS=(
    ["net.bridge.bridge-nf-call-iptables"]="1"
    ["net.bridge.bridge-nf-call-ip6tables"]="1"
    ["net.ipv4.ip_forward"]="1"
    ["vm.swappiness"]="0"
    ["vm.overcommit_memory"]="1"
    ["fs.inotify.max_user_instances"]="8192"
    ["fs.inotify.max_user_watches"]="1048576"
)
