#!/bin/bash
###############################################################################
# Kubeadm v1.35.4 一键部署 Kubernetes 集群（SSH 远程模式）
#
# 特性:
#   - 支持 CentOS Stream 9 / 10
#   - 双容器运行时: containerd（默认）或 Docker + cri-dockerd
#   - 1 Master + 1/2 Worker 灵活部署
#   - 在线 / 离线双模式
#   - 国内镜像加速（阿里云/清华/中科大）
#   - 已修复 kubeadm v1.35 super-admin.conf bug
#
# 一键运行:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Townrain/kubeadm-k8s-deploy/main/deploy-k8s-cluster.sh)
#
# 本地运行:
#   bash deploy-k8s-cluster.sh
#   bash deploy-k8s-cluster.sh --offline
###############################################################################

set -euo pipefail

# ==================== 自举: 从 GitHub 下载缺失脚本 ====================
GITHUB_BASE="https://raw.githubusercontent.com/Townrain/kubeadm-k8s-deploy/main"
KEEP_SCRIPTS=0
BOOTSTRAPPED=0

for arg in "$@"; do
    case "$arg" in
        --keep)  KEEP_SCRIPTS=1 ;;
        --remote|--offline|--iso) ;;  # 传给下层
    esac
done

_CANDIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "${_CANDIDATE_DIR:-}" ] && [ -f "${_CANDIDATE_DIR}/deploy-k8s-vars.sh" ]; then
    SCRIPT_DIR="${_CANDIDATE_DIR}"
else
    SCRIPT_DIR="$(mktemp -d /tmp/k8s-deploy-XXXXXX)"
    BOOTSTRAPPED=1

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  检测到通过 curl 管道运行，正在从 GitHub 下载脚本...       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    FILES=(
        deploy-k8s-cluster.sh
        deploy-k8s-vars.sh
    )
    for f in "${FILES[@]}"; do
        printf "  下载 %s ... " "$f"
        if curl -sSL --connect-timeout 10 "${GITHUB_BASE}/${f}" -o "${SCRIPT_DIR}/${f}" 2>/dev/null; then
            echo "OK"
        elif [ "$f" = "deploy-k8s.env" ]; then
            echo "跳过 (.env 可选)"
        else
            echo "失败"
            echo ""
            echo "  无法从 ${GITHUB_BASE} 下载脚本"
            echo "  请检查网络后重试"
            exit 1
        fi
    done
    chmod +x "${SCRIPT_DIR}/deploy-k8s-cluster.sh"
    echo ""
    echo "  所有脚本下载完成，开始部署..."
    echo ""

    # 重新执行下载后的脚本
    if [ "$KEEP_SCRIPTS" -eq 1 ]; then
        echo "  --keep 模式，脚本保留在 ${SCRIPT_DIR}"
        exec bash "${SCRIPT_DIR}/deploy-k8s-cluster.sh" "$@"
    else
        trap "rm -rf '${SCRIPT_DIR}'" EXIT
        exec bash "${SCRIPT_DIR}/deploy-k8s-cluster.sh" "$@"
    fi
fi

# ==================== 以下为正常执行路径 ====================

# 加载变量库 (curl|bash 时自动下载, 本地运行时同级目录)
VARS_URL="${GITHUB_BASE}/deploy-k8s-vars.sh"
if [ ! -f "${SCRIPT_DIR}/deploy-k8s-vars.sh" ]; then
    curl -fsSL "$VARS_URL" -o "${SCRIPT_DIR}/deploy-k8s-vars.sh" 2>/dev/null || true
fi
if [ -f "${SCRIPT_DIR}/deploy-k8s-vars.sh" ]; then
    source "${SCRIPT_DIR}/deploy-k8s-vars.sh"
fi

# 加载环境变量 (可选, 填好可跳过交互)
if [ -f "${SCRIPT_DIR}/deploy-k8s.env" ]; then
    source "${SCRIPT_DIR}/deploy-k8s.env"
    PRELOADED=1
else
    PRELOADED=0
fi

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

# ==================== 运行模式判断 ====================
REMOTE_MODE=0
OFFLINE_MODE=0
OFFLINE_ISO="${OFFLINE_ISO:-/root/k8s-offline-repo.iso}"
OFFLINE_MOUNT="${OFFLINE_MOUNT:-/mnt/k8s-offline}"
OFFLINE_REMOTE_FLAG=""

while [ $# -ge 1 ]; do
    case "$1" in
        --remote)  REMOTE_MODE=1; shift ;;
        --offline) OFFLINE_MODE=1; OFFLINE_REMOTE_FLAG="--offline"; shift ;;
        --iso)     OFFLINE_ISO="$2"; shift 2 ;;
        *)         break ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 账户运行本脚本"
    exit 1
fi

# ==================== 变量库回退默认值 (deploy-k8s-vars.sh 可覆盖) ====================
K8S_VERSION="${K8S_VERSION:-v1.35.4}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.35.0}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"
HELM_VERSION="${HELM_VERSION:-v3.19.0}"
DASHBOARD_VERSION="${DASHBOARD_VERSION:-7.14.0}"
POD_CIDR="${POD_CIDR:-172.16.10.0/24}"
SVC_CIDR="${SVC_CIDR:-172.16.32.0/24}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-containerd}"  # containerd 或 docker

# 镜像与注册表
KUBEADM_IMAGE_REPO="${KUBEADM_IMAGE_REPO:-registry.aliyuncs.com/google_containers}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.aliyuncs.com/google_containers/pause:3.10.1}"
DEFAULT_PAUSE_IMAGE="${DEFAULT_PAUSE_IMAGE:-registry.k8s.io/pause:3.10.1}"
MIRROR_DOCKER="${MIRROR_DOCKER_ENDPOINT:-https://docker.1panel.live}"
MIRROR_QUAY="${MIRROR_QUAY_ENDPOINT:-https://quay.m.daocloud.io}"
MIRROR_GCR="${MIRROR_GCR_ENDPOINT:-https://gcr.m.daocloud.io}"
MIRROR_K8S_GCR="${MIRROR_K8S_GCR_ENDPOINT:-https://registry.k8s.io}"
CALICO_REGISTRY="${CALICO_ORIGINAL_REGISTRY:-quay.io/}"
CALICO_PROXY="${CALICO_PROXY_REGISTRY:-quay.m.daocloud.io/}"
VERIFY_IMAGE="${VERIFY_IMAGE:-nginx:1.27}"

# 下载地址
DASHBOARD_DL="${DASHBOARD_DOWNLOAD_URL:-https://github.com/kubernetes-retired/dashboard/releases/download/kubernetes-dashboard-${DASHBOARD_VERSION}/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz}"
HELM_DL="${HELM_DOWNLOAD_URL:-https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz}"

# 路径
K8S_DIR="${K8S_CONFIG_DIR:-/etc/k8s}"
KUBEADM_YAML="${KUBEADM_CONFIG:-${K8S_DIR}/kubeadm-config.yaml}"
KUBEADM_LOG="${KUBEADM_INIT_LOG:-${K8S_DIR}/kubeadm-init.log}"
JOIN_CMD="${JOIN_CMD_FILE:-${K8S_DIR}/join-command.sh}"
CALICO_YAML="${CALICO_YAML:-${K8S_DIR}/calico.yaml}"
KUBE_CONFIG="${KUBECONFIG_FILE:-/etc/kubernetes/admin.conf}"
KUBE_CONFIG_HOME="${KUBECONFIG_HOME:-$HOME/.kube/config}"
CONTAINERD_CFG="${CONTAINERD_CONFIG:-/etc/containerd/config.toml}"
CONTAINERD_SOCK="${CONTAINERD_SOCK:-unix:///run/containerd/containerd.sock}"
CRICTL_CFG="${CRICTL_CONFIG:-/etc/crictl.yaml}"
K8S_REPO="${KUBERNETES_REPO_FILE:-/etc/yum.repos.d/kubernetes.repo}"
KUBELET_CFG="${KUBELET_EXTRA_ARGS_FILE:-/etc/sysconfig/kubelet}"
DASH_NS="${DASHBOARD_NAMESPACE:-kubernetes-dashboard}"
DASH_SA="${DASHBOARD_SA:-dashboard-admin}"
DASH_TOKEN_TTL="${DASHBOARD_TOKEN_DURATION:-24h}"
NM_DIR="${NM_CONNECTION_DIR:-/etc/NetworkManager/system-connections}"
SELINUX_CFG="${SELINUX_CONFIG:-/etc/selinux/config}"
PROFILE="${PROFILE_FILE:-/etc/profile}"

# 超时
SSH_TMOUT="${SSH_CONNECT_TIMEOUT:-10}"
CALICO_TMOUT="${CALICO_WAIT_TIMEOUT:-300}"
DASH_TMOUT="${DASHBOARD_WAIT_TIMEOUT:-600}"
NGINX_TMOUT="${NGINX_WAIT_TIMEOUT:-120}"
CURL_TMOUT="${CURL_CONNECT_TIMEOUT:-3}"

# kubeadm
K8S_API_VER="${KUBEADM_API_VERSION:-kubeadm.k8s.io/v1beta4}"
K8S_AUTH_MODE="${KUBEADM_AUTH_MODE:-Node,RBAC}"
KUBEPROXY_MODE="${KUBEPROXY_MODE:-ipvs}"
CGROUP="${CGROUP_DRIVER:-systemd}"
K8S_PREFLIGHT="${KUBEADM_IGNORE_PREFLIGHT:-CRI,ContainerRuntimeVersion}"
API_PORT="${API_BIND_PORT:-6443}"
DNS_DOMAIN="${DNS_DOMAIN:-cluster.local}"

# Dashboard Helm 参数
DASH_HELM_RELEASE="${DASHBOARD_HELM_RELEASE:-dashboard}"
DASH_HELM_CHART="${DASHBOARD_HELM_CHART:-./kubernetes-dashboard}"
OFFLINE_RPMS_DIR="${OFFLINE_RPMS_DIR:-rpms}"
OFFLINE_IMAGES_DIR="${OFFLINE_IMAGES_DIR:-images}"
OFFLINE_BINARIES_DIR="${OFFLINE_BINARIES_DIR:-binaries}"
OFFLINE_MANIFESTS_DIR="${OFFLINE_MANIFESTS_DIR:-manifests}"

# ==================== 通用工具函数 ====================

get_active_ifaces() {
    ip -o link show up 2>/dev/null \
        | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs|cali|kube' \
        | awk -F': ' '{print $2}' \
        | tr -d '@'
}

get_iface_ip_cidr() {
    ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | head -1
}

get_iface_ip_only() {
    echo "${1:-}" | cut -d'/' -f1
}

get_iface_prefix() {
    echo "${1:-}" | cut -d'/' -f2
}

get_default_gateway() {
    ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1
}

get_iface_gateway() {
    nmcli -t -f IP4.GATEWAY device show "$1" 2>/dev/null | cut -d':' -f2 | head -1
}

# 通过 SSH 远程获取 Worker 节点活动网卡
get_remote_ifaces() {
    local user="$1" ip="$2"
    ssh -o BatchMode=yes -o ConnectTimeout=${SSH_TMOUT} "${user}@${ip}" \
        "ip -o link show up 2>/dev/null | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs|cali|kube' | awk -F': ' '{print \$2}' | tr -d '@'" 2>/dev/null
}

get_remote_iface_ip() {
    local user="$1" ip="$2" iface="$3"
    ssh -o BatchMode=yes -o ConnectTimeout=${SSH_TMOUT} "${user}@${ip}" \
        "ip -4 -o addr show $iface 2>/dev/null | awk '{print \$4}' | head -1" 2>/dev/null
}

get_remote_iface_gw() {
    local user="$1" ip="$2" iface="$3"
    ssh -o BatchMode=yes -o ConnectTimeout=${SSH_TMOUT} "${user}@${ip}" \
        "nmcli -t -f IP4.GATEWAY device show $iface 2>/dev/null | cut -d':' -f2" 2>/dev/null
}

# ==================== GitHub 下载加速 ====================
github_dl() {
    local url="$1" out="${2:-}"
    local proxies=(
        "https://gh-proxy.com/${url}"
        "https://ghproxy.net/${url}"
        "https://ghfast.top/${url}"
        "${url}"
    )
    for p in "${proxies[@]}"; do
        if [ -n "$out" ]; then
            wget -q --timeout=30 -O "$out" "$p" 2>/dev/null && return 0
        else
            wget -q --timeout=30 "$p" 2>/dev/null && return 0
        fi
    done
    return 1
}

# ==================== CentOS 版本检测 ====================
get_centos_version() {
    # 返回 CentOS Stream 主版本号 (9 或 10)
    if [ -f /etc/os-release ]; then
        local version_id
        version_id=$(grep '^VERSION_ID=' /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)
        echo "${version_id:-9}"
    else
        echo "9"
    fi
}

is_centos_stream_10() {
    local ver
    ver=$(get_centos_version)
    [ "$ver" -ge 10 ] 2>/dev/null && return 0 || return 1
}

get_remote_default_gw_iface() {
    local user="$1" ip="$2"
    ssh -o BatchMode=yes -o ConnectTimeout=${SSH_TMOUT} "${user}@${ip}" \
        "ip -4 route show default 2>/dev/null | awk '{print \$5}' | head -1" 2>/dev/null
}

# ==================== 离线 ISO 挂载/卸载 ====================
mount_offline_iso() {
    local iso="$1" mnt="$2"

    if [ ! -f "$iso" ]; then
        log_error "离线 ISO 不存在: ${iso}"
        exit 1
    fi

    mkdir -p "$mnt"

    if mountpoint -q "$mnt" 2>/dev/null; then
        log_info "ISO 已挂载: ${mnt}"
        return 0
    fi

    log_info "挂载 ISO: ${iso} → ${mnt}"
    mount -o loop "$iso" "$mnt" || log_error "挂载 ISO 失败"
    log_info "挂载成功"
}

umount_offline_iso() {
    local mnt="${1:-$OFFLINE_MOUNT}"
    if mountpoint -q "$mnt" 2>/dev/null; then
        umount "$mnt" 2>/dev/null && log_info "已卸载 ${mnt}" || true
    fi
}

# 配置本地 DNF 仓库 (离线模式)
setup_offline_repo() {
    local mnt="$1"

    log_step "配置离线 DNF 仓库"

    # 探测 repodata 所在目录 (优先 packages/, 其次根目录, 再次递归查找)
    local repo_base=""
    if [ -f "${mnt}/${OFFLINE_RPMS_DIR}/repodata/repomd.xml" ]; then
        repo_base="${mnt}/${OFFLINE_RPMS_DIR}"
    elif [ -f "${mnt}/repodata/repomd.xml" ]; then
        repo_base="${mnt}"
    else
        # 递归查找 repomd.xml
        local found
        found=$(find "$mnt" -name repomd.xml -type f 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            repo_base=$(dirname "$(dirname "$found")")  # repodata/ 的父目录
        fi
    fi

    if [ -z "$repo_base" ]; then
        log_warn "未找到 repodata，尝试用 createrepo 生成..."
        if command -v createrepo_c &>/dev/null; then
            createrepo_c "$mnt" 2>/dev/null
        elif command -v createrepo &>/dev/null; then
            createrepo "$mnt" 2>/dev/null
        else
            dnf install -y createrepo_c 2>/dev/null || true
            if command -v createrepo_c &>/dev/null; then
                createrepo_c "$mnt" 2>/dev/null
            else
                log_error "未找到 repodata 且无法安装 createrepo。请确保 ISO 包含 repodata/ 目录或 RPM 仓库元数据"
                exit 1
            fi
        fi
        repo_base="$mnt"
    fi

    cat > /etc/yum.repos.d/k8s-offline.repo << EOF
[k8s-offline]
name=K8s Offline Repository
baseurl=file://${repo_base}
enabled=1
gpgcheck=0
EOF

    log_info "仓库目录: ${repo_base}"

    # 禁用所有在线仓库（离线模式专用）
    # 备份并禁用系统仓库 (baseos, appstream, crb 等)
    for repo_file in /etc/yum.repos.d/*.repo; do
        [ -f "$repo_file" ] || continue
        [ "$repo_file" = "/etc/yum.repos.d/k8s-offline.repo" ] && continue
        mv "$repo_file" "${repo_file}.bak" 2>/dev/null || true
    done

    dnf makecache
    log_info "离线仓库配置完成: file://${repo_base}"
}

# 从 ISO 加载容器镜像 (离线模式)
# kind: kubeadm | calico | dashboard | all
load_offline_images() {
    local kind="$1"
    local mnt="${OFFLINE_MOUNT}"
    local img_dir="${mnt}/${OFFLINE_IMAGES_DIR}"
    local pattern

    case "$kind" in
        kubeadm)   pattern="registry.aliyuncs.com_google_containers_*.tar" ;;
        calico)    pattern="quay.io_calico_*.tar" ;;
        dashboard) 
            # 先导入 Dashboard 组件镜像，再尝试 Kong
            local count1=0 failed1=0
            for tarfile in "${img_dir}"/docker.io_kubernetesui_*.tar; do
                [ -f "$tarfile" ] || continue
                [ -s "$tarfile" ] || { log_warn "跳过空文件: $(basename "$tarfile")"; continue; }
                local fname=$(basename "$tarfile")
                if ctr -n k8s.io images import "$tarfile" &>/dev/null; then
                    log_info "✓ ${fname}"; count1=$((count1 + 1))
                else
                    log_warn "导入失败: ${fname}"; failed1=$((failed1 + 1))
                fi
            done
            # Kong 镜像 (如果存在)
            local kong_tar="${img_dir}/kong_3.9.tar"
            if [ -f "$kong_tar" ] && [ -s "$kong_tar" ]; then
                if ctr -n k8s.io images import "$kong_tar" &>/dev/null; then
                    log_info "✓ kong_3.9.tar"; count1=$((count1 + 1))
                else
                    log_warn "导入失败: kong_3.9.tar"; failed1=$((failed1 + 1))
                fi
            else
                log_warn "Kong 镜像缺失/为空，Dashboard 网关将无法启动"
            fi
            log_info "dashboard 镜像导入完成 (成功 ${count1}, 失败 ${failed1})"
            return 0
            ;; 
        *)         log_error "未知镜像类型: ${kind}"; return 1 ;;
    esac

    log_info "导入 ${kind} 镜像 (${pattern})..."

    local count=0 failed=0
    for tarfile in "${img_dir}"/${pattern}; do
        [ -f "$tarfile" ] || continue
        [ -s "$tarfile" ] || { log_warn "跳过空文件: $(basename "$tarfile")"; continue; }

        local fname=$(basename "$tarfile")
        if ctr -n k8s.io images import "$tarfile" &>/dev/null; then
            log_info "✓ ${fname}"
            count=$((count + 1))
        else
            log_warn "导入失败: ${fname}"
            failed=$((failed + 1))
        fi
    done

    if [ $count -eq 0 ]; then
        log_error "未成功导入任何 ${kind} 镜像 (${failed} 个失败)"
        return 1
    fi
    log_info "${kind} 镜像导入完成 (成功 ${count}, 失败 ${failed})"
}

# 导出 Master 所有镜像 → SCP 到 Worker (避免 Worker 各自拉取)
sync_images_to_workers() {
    # Docker 运行时跳过 (使用 Docker registry mirrors 拉取)
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        log_info "Docker 运行时: 跳过 ctr 镜像同步 (Worker 将通过 Docker registry mirrors 拉取)"
        return 0
    fi

    local sync_dir="/tmp/k8s-sync-images"
    rm -rf "$sync_dir"; mkdir -p "$sync_dir"

    log_info "导出 Master 镜像供 Worker 使用..."
    ctr -n k8s.io images list -q 2>/dev/null | while read -r img; do
        [ -z "$img" ] && continue
        local fname="${sync_dir}/$(echo "$img" | sed 's|[/:@]|_|g').tar"
        ctr -n k8s.io images export "$fname" "$img" 2>/dev/null || true
    done || true

    local count
    count=$(ls "$sync_dir"/*.tar 2>/dev/null | wc -l)
    [ "$count" -eq 0 ] && { log_info "无镜像需同步"; rm -rf "$sync_dir"; return; }

    # 构建 Worker 列表
    local workers=("${WORKER1_USER}@${WORKER1_IP}")
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        workers+=("${WORKER2_USER}@${WORKER2_IP}")
    fi

    for w in "${workers[@]}"; do
        log_info "同步 ${count} 个镜像到 ${w}..."
        scp -o StrictHostKeyChecking=no "$sync_dir"/*.tar "$w:/tmp/k8s-sync-images/" 2>/dev/null || { log_warn "SCP 失败: ${w}"; continue; }
        ssh -o StrictHostKeyChecking=no "$w" "
            for t in /tmp/k8s-sync-images/*.tar; do
                [ -s \"\$t\" ] && ctr -n k8s.io images import \"\$t\" 2>/dev/null
            done
            rm -rf /tmp/k8s-sync-images
        " 2>/dev/null &
    done
    wait
    rm -rf "$sync_dir"
}

# ==================== SSH 远程部署 Worker ====================
remote_deploy_worker() {
    local user="$1" ip="$2" hostname="$3" iface="$4" wip="$5" prefix="$6" gateway="$7"

    log_step "远程部署 Worker: ${hostname} (${user}@${ip})"

    setup_ssh_keys "$user" "$ip" "$hostname"

    # 复制脚本到 Worker（主脚本 + 变量库）
    local script_path="${SCRIPT_DIR}/deploy-k8s-cluster.sh"
    local vars_path="${SCRIPT_DIR}/deploy-k8s-vars.sh"
    scp -o StrictHostKeyChecking=no "$script_path" "${user}@${ip}:/root/${REMOTE_SCRIPT_NAME:-deploy-k8s-cluster.sh}"
    [ -f "$vars_path" ] && scp -o StrictHostKeyChecking=no "$vars_path" "${user}@${ip}:/root/deploy-k8s-vars.sh"

    # 离线模式: 复制 ISO 到 Worker
    if [ "$OFFLINE_MODE" -eq 1 ]; then
        log_info "离线模式: 复制 ISO 到 ${hostname}..."
        scp -o StrictHostKeyChecking=no "$OFFLINE_ISO" "${user}@${ip}:${OFFLINE_ISO}"
    fi

    log_info "远程执行 Worker 配置 (需 5~15 分钟)..."
    ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
        "bash /root/${REMOTE_SCRIPT_NAME:-deploy-k8s-cluster.sh} --remote ${OFFLINE_REMOTE_FLAG} \
            '${hostname}' '${iface}' '${wip}' '${prefix}' '${gateway}' \
            '${MASTER_HOSTNAME}' '${MASTER_IP}' \
            '${WORKER1_HOSTNAME}' '${WORKER1_IP}' \
            '${WORKER2_HOSTNAME}' '${WORKER2_IP}'"

    log_info "Worker ${hostname} 部署完成"
}

# ==================== 远程模式（Worker 节点执行） ====================
remote_mode_execute() {
    local hostname="$1" iface="$2" wip="$3" prefix="$4" gateway="$5"
    local master_hostname="$6" master_ip="$7"
    local worker1_hostname="$8" worker1_ip="$9"
    local worker2_hostname="${10:-}" worker2_ip="${11:-}"

    # 把变量注入全局，供 common_prep 和 configure_hosts 使用
    MASTER_HOSTNAME="$master_hostname"
    MASTER_IP="$master_ip"
    WORKER1_HOSTNAME="$worker1_hostname"
    WORKER1_IP="$worker1_ip"
    WORKER2_HOSTNAME="$worker2_hostname"
    WORKER2_IP="$worker2_ip"
    # 自动检测 Worker 数量
    if [ -n "$worker2_ip" ]; then
        WORKER_COUNT=2
    else
        WORKER_COUNT=1
    fi

    log_info "远程模式 — Worker 节点: ${hostname} (${wip})"
    [ "$OFFLINE_MODE" -eq 1 ] && log_info "离线模式已启用 (ISO: ${OFFLINE_ISO})"

    common_prep "$hostname" "$iface" "$wip" "$prefix" "$gateway"

    log_info "Worker ${hostname} 配置完成！等待 Master 发起 join..."
}

# ==================== Master 本机网络自动检测 ====================
auto_detect_master_network() {
    echo ""
    log_step "正在检测 Master 本机网络接口..."

    local ifaces
    ifaces=($(get_active_ifaces))

    if [ ${#ifaces[@]} -eq 0 ]; then
        log_warn "未检测到活动网卡，请手动输入"
        return 1
    fi

    echo ""
    echo "检测到 ${#ifaces[@]} 个活动网卡:"
    for i in "${!ifaces[@]}"; do
        local iface="${ifaces[$i]}"
        local ip_cidr=$(get_iface_ip_cidr "$iface")
        local ip_only=$(get_iface_ip_only "$ip_cidr")
        local prefix=$(get_iface_prefix "$ip_cidr")
        local gw=$(get_iface_gateway "$iface")
        [ -z "$ip_only" ] && ip_only="未配置"
        [ -z "$prefix" ]  && prefix="-"
        [ -z "$gw" ]       && gw="未检测到"
        echo "  [$((i+1))] ${iface}   IP: ${ip_only}/${prefix}   网关: ${gw}"
    done

    # 默认选有默认路由的网卡
    local default_iface
    local default_gw=$(get_default_gateway)
    if [ -n "$default_gw" ]; then
        default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
    fi
    [ -z "$default_iface" ] && default_iface="${ifaces[0]}"

    echo ""
    while true; do
        read -r -p "Master 网卡 [$default_iface]: " input
        MASTER_IFACE="${input:-$default_iface}"
        if ip link show "$MASTER_IFACE" &>/dev/null; then break; else log_warn "网卡 $MASTER_IFACE 不存在"; fi
    done

    local ip_cidr=$(get_iface_ip_cidr "$MASTER_IFACE")
    local detected_ip=$(get_iface_ip_only "$ip_cidr")
    local detected_prefix=$(get_iface_prefix "$ip_cidr")
    local detected_gw=$(get_iface_gateway "$MASTER_IFACE")

    read -r -p "Master IP [${detected_ip:-${MASTER_IP}}]: " input
    MASTER_IP="${input:-${detected_ip:-${MASTER_IP}}}"
    read -r -p "子网前缀 [${detected_prefix:-24}]: " input
    MASTER_PREFIX="${input:-${detected_prefix:-24}}"
    read -r -p "网关 [${detected_gw:-无}]: " input
    MASTER_GW="${input:-$detected_gw}"
}

# ==================== Worker 远程网络自动检测 ====================
auto_detect_worker_network() {
    local user="$1" ip="$2" label="$3"
    local var_iface="$4" var_wip="$5" var_prefix="$6" var_gw="$7"

    echo ""
    log_step "SSH 检测 ${label} 网络接口..."

    local ifaces
    ifaces=($(get_remote_ifaces "$user" "$ip"))

    if [ ${#ifaces[@]} -eq 0 ]; then
        log_warn "未检测到 ${label} 活动网卡，请手动输入"
        read -r -p "${label} 网卡名: " eval "$var_iface"
        read -r -p "${label} IP: " eval "$var_wip"
        read -r -p "${label} 子网前缀 [24]: " eval "$var_prefix"
        eval "${var_prefix}:=\${${var_prefix}:-24}"
        read -r -p "${label} 网关: " eval "$var_gw"
        return 0
    fi

    echo ""
    echo "${label} 检测到 ${#ifaces[@]} 个活动网卡:"
    for i in "${!ifaces[@]}"; do
        local iface="${ifaces[$i]}"
        local r_ip_cidr=$(get_remote_iface_ip "$user" "$ip" "$iface")
        local r_ip_only=$(get_iface_ip_only "$r_ip_cidr")
        local r_prefix=$(get_iface_prefix "$r_ip_cidr")
        local r_gw=$(get_remote_iface_gw "$user" "$ip" "$iface")
        [ -z "$r_ip_only" ] && r_ip_only="未配置"
        [ -z "$r_prefix" ]  && r_prefix="-"
        [ -z "$r_gw" ]       && r_gw="未检测到"
        echo "  [$((i+1))] ${iface}   IP: ${r_ip_only}/${r_prefix}   网关: ${r_gw}"
    done

    # 默认选有默认路由的
    local remote_default_iface
    remote_default_iface=$(get_remote_default_gw_iface "$user" "$ip")
    [ -z "$remote_default_iface" ] && remote_default_iface="${ifaces[0]}"

    echo ""
    while true; do
        read -r -p "${label} 网卡 [$remote_default_iface]: " input
        eval "$var_iface=\${input:-$remote_default_iface}"
        local check_iface
        check_iface=$(eval "echo \$$var_iface")
        if ssh -o BatchMode=yes -o ConnectTimeout=${SSH_TMOUT} "${user}@${ip}" "ip link show ${check_iface} &>/dev/null" 2>/dev/null; then
            break
        else
            log_warn "网卡 ${check_iface} 在 ${label} 不存在"
        fi
    done

    local r_iface_val=$(eval "echo \$$var_iface")
    local r_ip_cidr=$(get_remote_iface_ip "$user" "$ip" "$r_iface_val")
    local r_ip=$(get_iface_ip_only "$r_ip_cidr")
    local r_prefix=$(get_iface_prefix "$r_ip_cidr")
    local r_gw=$(get_remote_iface_gw "$user" "$ip" "$r_iface_val")

    read -r -p "${label} IP [${r_ip:-${ip}}]: " input
    eval "$var_wip=\${input:-\${r_ip:-$ip}}"
    read -r -p "${label} 子网前缀 [${r_prefix:-24}]: " input
    eval "$var_prefix=\${input:-\${r_prefix:-24}}"
    read -r -p "${label} 网关 [${r_gw:-${MASTER_GW}}]: " input
    eval "$var_gw=\${input:-\${r_gw:-$MASTER_GW}}"
}

# ==================== ====================
#       交互主模式
# ==================== ====================
interactive_main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   Kubeadm v1.35.4 部署 Kubernetes 集群 (SSH 远程模式)      ║"
    echo "║   Master → SSH → Worker 节点                               ║"
    [ "$PRELOADED" -eq 1 ] && echo "║   deploy-k8s.env 已加载，按回车使用预设值                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if [ "$PRELOADED" -eq 1 ]; then
        # env 文件已预填，跳过交互直接确认
        MASTER_HOSTNAME="${MASTER_HOSTNAME:-master}"
        MASTER_IP="${MASTER_IP:-}"
        WORKER1_HOSTNAME="${WORKER1_HOSTNAME:-node1}"
        WORKER1_IP="${WORKER1_IP:-}"
        WORKER1_USER="${WORKER1_USER:-root}"
        WORKER2_HOSTNAME="${WORKER2_HOSTNAME:-}"
        WORKER2_IP="${WORKER2_IP:-}"
        WORKER2_USER="${WORKER2_USER:-root}"
        # 自动检测 Worker 数量: WORKER2 为空则为 1 Worker 模式
        if [ -n "${WORKER2_IP:-}" ]; then
            WORKER_COUNT="${WORKER_COUNT:-2}"
        else
            WORKER_COUNT=1
        fi
        POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
        SVC_CIDR="${SVC_CIDR:-172.16.32.0/24}"

        echo "========== 部署模式 =========="
        read -r -p "请选择 [${DEPLOY_CHOICE:-1}]: " mode_choice
        mode_choice="${mode_choice:-${DEPLOY_CHOICE:-1}}"

        if [ "$mode_choice" = "2" ]; then
            OFFLINE_MODE=1; OFFLINE_REMOTE_FLAG="--offline"
            read -r -p "ISO 路径 [${OFFLINE_ISO_PATH:-${OFFLINE_ISO}}]: " input
            OFFLINE_ISO="${input:-${OFFLINE_ISO_PATH:-${OFFLINE_ISO}}}"
            [ ! -f "$OFFLINE_ISO" ] && { log_error "ISO 不存在: ${OFFLINE_ISO}"; exit 1; }
        fi
    else
        # ========== 部署模式选择 ==========
        echo "========== 部署模式 =========="
        echo "  [1] 在线模式 (从互联网下载所有组件)"
        echo "  [2] 离线模式 (使用本地 /root/k8s-offline-repo.iso)"
        echo ""
        read -r -p "请选择 [1]: " mode_choice
        mode_choice="${mode_choice:-1}"

        if [ "$mode_choice" = "2" ]; then
            OFFLINE_MODE=1; OFFLINE_REMOTE_FLAG="--offline"
            read -r -p "ISO 路径 [${OFFLINE_ISO}]: " input
            OFFLINE_ISO="${input:-${OFFLINE_ISO}}"
            [ ! -f "$OFFLINE_ISO" ] && { log_error "ISO 不存在: ${OFFLINE_ISO}"; exit 1; }
            log_info "离线模式已启用 (ISO: ${OFFLINE_ISO})"
        fi

        # ========== 容器运行时选择 (仅 CentOS Stream 10) ==========
        if is_centos_stream_10; then
            echo ""
            echo "========== 容器运行时 (CentOS Stream 10) =========="
            echo "  [1] containerd (推荐，内置 CRI)"
            echo "  [2] Docker + cri-dockerd (可选)"
            echo ""
            read -r -p "请选择 [1]: " runtime_choice
            runtime_choice="${runtime_choice:-1}"
            if [ "$runtime_choice" = "2" ]; then
                CONTAINER_RUNTIME="docker"
                log_info "已选择 Docker + cri-dockerd 运行时"
            else
                CONTAINER_RUNTIME="containerd"
                log_info "已选择 containerd 运行时"
            fi
        else
            CONTAINER_RUNTIME="containerd"
        fi
    fi

    if [ "$PRELOADED" -eq 1 ]; then
        log_info "使用 deploy-k8s.env 预设值"
    else
        echo ""
        echo "========== 集群规划 =========="
        read -r -p "Master 主机名 [master]: " MASTER_HOSTNAME
        MASTER_HOSTNAME="${MASTER_HOSTNAME:-master}"
        read -r -p "Worker1 主机名 [node1]: " WORKER1_HOSTNAME
        WORKER1_HOSTNAME="${WORKER1_HOSTNAME:-node1}"

        # 询问是否添加 Worker2
        echo ""
        read -r -p "是否添加第二个 Worker 节点? [y/N]: " add_worker2
        if [[ "$add_worker2" =~ ^[Yy]$ ]]; then
            WORKER_COUNT=2
            read -r -p "Worker2 主机名 [node2]: " WORKER2_HOSTNAME
            WORKER2_HOSTNAME="${WORKER2_HOSTNAME:-node2}"
        else
            WORKER_COUNT=1
            WORKER2_HOSTNAME=""
            WORKER2_IP=""
            log_info "单 Worker 模式: 仅部署 1 Master + 1 Worker"
        fi

        echo ""
        echo "网络规划 (按需修改):"
        read -r -p "Pod 网段 CIDR [${POD_CIDR}]: " input
        POD_CIDR="${input:-${POD_CIDR}}"
        read -r -p "Service 网段 CIDR [${SVC_CIDR}]: " input
        SVC_CIDR="${input:-${SVC_CIDR}}"
    fi

    # ========== 1. Master 网络 ==========
    if [ "$PRELOADED" -eq 1 ] && [ -n "${MASTER_IFACE:-}" ] && [ -n "${MASTER_IP:-}" ]; then
        log_info "使用预设 Master 网络: ${MASTER_IFACE} ${MASTER_IP}/${MASTER_PREFIX:-24} gw:${MASTER_GW:-无}"
    else
        auto_detect_master_network
    fi

    # ========== 2. Worker 节点基本信息 ==========
    if [ "$PRELOADED" -eq 0 ]; then
        echo ""
        echo "========== Worker 节点信息 =========="
        read -r -p "Worker1 IP: " WORKER1_IP
        read -r -p "Worker1 SSH 用户名 [root]: " WORKER1_USER
        WORKER1_USER="${WORKER1_USER:-root}"

        if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_HOSTNAME:-}" ]; then
            echo ""
            read -r -p "Worker2 IP: " WORKER2_IP
            read -r -p "Worker2 SSH 用户名 [root]: " WORKER2_USER
            WORKER2_USER="${WORKER2_USER:-root}"
        fi
    fi

    # ========== 3. 建立 SSH 免密 ==========
    setup_ssh_keys "$WORKER1_USER" "$WORKER1_IP" "$WORKER1_HOSTNAME"
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        setup_ssh_keys "$WORKER2_USER" "$WORKER2_IP" "$WORKER2_HOSTNAME"
    fi

    # ========== 4. 远程检测 Worker 网络 ==========
    if [ "$PRELOADED" -eq 1 ] && [ -n "${WORKER1_IFACE:-}" ]; then
        WORKER1_PREFIX="${WORKER1_PREFIX:-24}"
        if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
            WORKER2_PREFIX="${WORKER2_PREFIX:-24}"
        fi
        log_info "使用预设 Worker 网络"
    else
        auto_detect_worker_network "$WORKER1_USER" "$WORKER1_IP" "$WORKER1_HOSTNAME" \
            "WORKER1_IFACE" "WORKER1_IP" "WORKER1_PREFIX" "WORKER1_GW"

        if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
            auto_detect_worker_network "$WORKER2_USER" "$WORKER2_IP" "$WORKER2_HOSTNAME" \
                "WORKER2_IFACE" "WORKER2_IP" "WORKER2_PREFIX" "WORKER2_GW"
        fi
    fi

    # ========== 5. 确认摘要 ==========
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                     配置摘要                                 ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  [Master] ${MASTER_HOSTNAME}                                "
    echo "║    网卡: ${MASTER_IFACE}   IP: ${MASTER_IP}/${MASTER_PREFIX}   网关: ${MASTER_GW:-无}"
    echo "║                                                             "
    echo "║  [Worker1] ${WORKER1_HOSTNAME}                              "
    echo "║    网卡: ${WORKER1_IFACE}   IP: ${WORKER1_IP}/${WORKER1_PREFIX}   网关: ${WORKER1_GW:-无}"
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        echo "║                                                             "
        echo "║  [Worker2] ${WORKER2_HOSTNAME}                              "
        echo "║    网卡: ${WORKER2_IFACE}   IP: ${WORKER2_IP}/${WORKER2_PREFIX}   网关: ${WORKER2_GW:-无}"
    fi
    echo "║                                                             "
    echo "║  Pod 网段: ${POD_CIDR}     Service 网段: ${SVC_CIDR}        "
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    read -r -p "确认以上配置开始部署? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log_error "用户取消"; exit 1; }

    # 确保基础工具 (离线模式跳过)
    if [ "$OFFLINE_MODE" -eq 0 ]; then
        command -v wget &>/dev/null || dnf install -y wget 2>/dev/null || true
    fi

    # ========== 6. 部署 Master 节点 (先于 Worker，下载的二进制可 SCP 给 Worker) ==========
    log_step "【阶段一】部署 Master 节点"
    common_prep "$MASTER_HOSTNAME" "$MASTER_IFACE" "$MASTER_IP" "$MASTER_PREFIX" "$MASTER_GW"

    # ========== 导出 Master 已拉取的镜像，分发给 Worker ==========
    if [ "$OFFLINE_MODE" -eq 0 ]; then
        log_info "导出 nginx:1.27 镜像供 Worker 使用..."
        mkdir -p /tmp/k8s-images
        if crictl images 2>/dev/null | grep -q "${VERIFY_IMAGE}"; then
            ctr -n k8s.io images export /tmp/k8s-images/nginx-1.27.tar docker.io/library/${VERIFY_IMAGE} 2>/dev/null || true
        fi
        # 也导出 kubeadm 控制平面镜像，避免 Worker 拉取
        for img in $(crictl images -q 2>/dev/null | grep -E "registry.aliyuncs.com|pause"); do
            local fname="/tmp/k8s-images/$(echo $img | sed 's|[/:]|_|g').tar"
            ctr -n k8s.io images export "$fname" "$img" 2>/dev/null || true
        done
    fi

    # ========== 7. SCP 关键文件到 Worker ==========
    log_step "【阶段二】分发二进制到 Worker 节点"
    local script_path="${SCRIPT_DIR}/deploy-k8s-cluster.sh"
    local vars_path="${SCRIPT_DIR}/deploy-k8s-vars.sh"
    local remote_script="/root/${REMOTE_SCRIPT_NAME:-deploy-k8s-cluster.sh}"

    scp -o StrictHostKeyChecking=no "$script_path" "${WORKER1_USER}@${WORKER1_IP}:${remote_script}"
    [ -f "$vars_path" ] && scp -o StrictHostKeyChecking=no "$vars_path" "${WORKER1_USER}@${WORKER1_IP}:/root/deploy-k8s-vars.sh"

    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        scp -o StrictHostKeyChecking=no "$script_path" "${WORKER2_USER}@${WORKER2_IP}:${remote_script}"
        [ -f "$vars_path" ] && scp -o StrictHostKeyChecking=no "$vars_path" "${WORKER2_USER}@${WORKER2_IP}:/root/deploy-k8s-vars.sh"
    fi

    # 离线模式: 复制 ISO
    if [ "$OFFLINE_MODE" -eq 1 ]; then
        log_info "离线模式: 复制 ISO 到 Worker 节点..."
        scp -o StrictHostKeyChecking=no "$OFFLINE_ISO" "${WORKER1_USER}@${WORKER1_IP}:${OFFLINE_ISO}" &
        if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
            scp -o StrictHostKeyChecking=no "$OFFLINE_ISO" "${WORKER2_USER}@${WORKER2_IP}:${OFFLINE_ISO}" &
        fi
        wait
    fi

    # 在线或离线: 把 Master 已下载的二进制和镜像 SCP 给 Worker
    local workers=("${WORKER1_USER}@${WORKER1_IP}")
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        workers+=("${WORKER2_USER}@${WORKER2_IP}")
    fi

    for w in "${workers[@]}"; do
        log_info "分发二进制/镜像到 ${w}..."
        ssh -o StrictHostKeyChecking=no "$w" "mkdir -p /usr/local/bin /tmp/k8s-images" 2>/dev/null || true

        # 二进制
        [ -f /usr/local/bin/crictl ] && scp -o StrictHostKeyChecking=no /usr/local/bin/crictl "$w:/usr/local/bin/crictl" 2>/dev/null || true
        [ -f /usr/local/bin/helm   ] && scp -o StrictHostKeyChecking=no /usr/local/bin/helm   "$w:/usr/local/bin/helm"   2>/dev/null || true
        # cri-dockerd (仅 Docker 运行时)
        if [ "${CONTAINER_RUNTIME}" = "docker" ] && [ -f /usr/local/bin/cri-dockerd ]; then
            log_info "分发 cri-dockerd 到 ${w}..."
            scp -o StrictHostKeyChecking=no /usr/local/bin/cri-dockerd "$w:/usr/local/bin/cri-dockerd" 2>/dev/null || log_warn "SCP cri-dockerd 到 ${w} 失败"
            ssh -o StrictHostKeyChecking=no "$w" "chmod +x /usr/local/bin/cri-dockerd" 2>/dev/null || true
        fi

        # 镜像
        if [ -d /tmp/k8s-images ] && ls /tmp/k8s-images/*.tar &>/dev/null; then
            scp -o StrictHostKeyChecking=no /tmp/k8s-images/*.tar "$w:/tmp/k8s-images/" 2>/dev/null || log_warn "SCP 镜像到 ${w} 失败"
            ssh -o StrictHostKeyChecking=no "$w" "for t in /tmp/k8s-images/*.tar; do [ -s \"\$t\" ] && ctr -n k8s.io images import \"\$t\" 2>/dev/null && echo \"✓ \$(basename \$t)\"; done; rm -f /tmp/k8s-images/*.tar" 2>/dev/null || true
        fi
    done

    # ========== 8. 远程部署 Worker ==========
    log_step "【阶段三】远程部署 Worker 节点"
    log_info "并行部署 Worker 节点 (约 5~10 分钟)..."

    ssh -o StrictHostKeyChecking=no "${WORKER1_USER}@${WORKER1_IP}" \
        "export CONTAINER_RUNTIME='${CONTAINER_RUNTIME}'; bash ${remote_script} --remote ${OFFLINE_REMOTE_FLAG} \
            '${WORKER1_HOSTNAME}' '${WORKER1_IFACE}' '${WORKER1_IP}' '${WORKER1_PREFIX}' '${WORKER1_GW}' \
            '${MASTER_HOSTNAME}' '${MASTER_IP}' \
            '${WORKER1_HOSTNAME}' '${WORKER1_IP}' \
            '${WORKER2_HOSTNAME:-}' '${WORKER2_IP:-}'" > /tmp/worker1-deploy.log 2>&1 &
    PID1=$!

    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        ssh -o StrictHostKeyChecking=no "${WORKER2_USER}@${WORKER2_IP}" \
            "export CONTAINER_RUNTIME='${CONTAINER_RUNTIME}'; bash ${remote_script} --remote ${OFFLINE_REMOTE_FLAG} \
                '${WORKER2_HOSTNAME}' '${WORKER2_IFACE}' '${WORKER2_IP}' '${WORKER2_PREFIX}' '${WORKER2_GW}' \
                '${MASTER_HOSTNAME}' '${MASTER_IP}' \
                '${WORKER1_HOSTNAME}' '${WORKER1_IP}' \
                '${WORKER2_HOSTNAME}' '${WORKER2_IP}'" > /tmp/worker2-deploy.log 2>&1 &
        PID2=$!
    fi

    # ========== 9. 等待 Worker 完成 ==========
    log_step "【等待 Worker 节点部署完成】"
    log_info "等待 Worker1 (PID=$PID1)..."
    wait $PID1 2>/dev/null || log_warn "Worker1 部署可能有异常，请查看 /tmp/worker1-deploy.log"
    log_info "Worker1 完成"

    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ] && [ -n "${PID2:-}" ]; then
        log_info "等待 Worker2 (PID=$PID2)..."
        wait $PID2 2>/dev/null || log_warn "Worker2 部署可能有异常，请查看 /tmp/worker2-deploy.log"
        log_info "Worker2 完成"
    fi

    # ========== 10. Master 初始化集群 ==========
    log_step "【阶段四】Master 初始化 Kubernetes 集群"
    init_master_cluster

    # ========== 11. Worker 加入集群 ==========
    log_step "【阶段五】Worker 加入集群"
    join_workers

    # ========== 11. Calico 网络插件 ==========
    log_step "【阶段六】安装 Calico 网络插件"
    install_calico
    sync_images_to_workers

    # ========== 12. 集群验证 ==========
    log_step "【阶段六】集群功能验证"
    verify_cluster

    # ========== 12. Dashboard ==========
    log_step "【阶段七】安装 Dashboard"
    install_dashboard
    sync_images_to_workers

    # ========== 完成 ==========
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Kubernetes 集群部署完成!                        ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Master:  ${MASTER_IP} (${MASTER_HOSTNAME})                  "
    echo "║  Worker1: ${WORKER1_IP} (${WORKER1_HOSTNAME})                "
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        echo "║  Worker2: ${WORKER2_IP} (${WORKER2_HOSTNAME})                "
    fi
    echo "║                                                             "
    echo "║  常用命令:                                                   "
    echo "║    kubectl get nodes                                         "
    echo "║    kubectl get pods -A                                       "
    echo "║    kubectl get events -A --sort-by='.lastTimestamp'          "
    echo "║                                                             "
    if [ -f ${K8S_DIR}/dashboard-token ]; then
        local dash_port=$(cat ${K8S_DIR}/dashboard-port 2>/dev/null || echo "?")
        echo "║  Dashboard: https://${MASTER_IP}:${dash_port}                       "
        echo "║  Token:     cat ${K8S_DIR}/dashboard-token              "
    fi
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_warn "建议在各节点执行 reboot 验证 Swap 持久禁用"

    # 离线模式: 自动卸载 ISO 并恢复所有仓库
    if [ "$OFFLINE_MODE" -eq 1 ]; then
        umount_offline_iso "$OFFLINE_MOUNT" 2>/dev/null || true
        rm -f /etc/yum.repos.d/k8s-offline.repo 2>/dev/null || true
        # 恢复所有备份的仓库文件
        for repo_bak in /etc/yum.repos.d/*.repo.bak; do
            [ -f "$repo_bak" ] || continue
            mv "$repo_bak" "${repo_bak%.bak}" 2>/dev/null || true
        done
        dnf makecache 2>/dev/null || true
        log_info "已卸载 ISO 并恢复所有在线仓库"
    fi
}

# ==================== Master 专属: 初始化集群 ====================
init_master_cluster() {
    log_step "Master 节点: 初始化 Kubernetes 集群"
    mkdir -p ${K8S_DIR} && cd ${K8S_DIR}

    # 根据容器运行时选择 CRI socket
    local cri_socket
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        cri_socket="unix:///var/run/cri-dockerd.sock"
    else
        cri_socket="${CONTAINERD_SOCK}"
    fi

    cat > kubeadm-config.yaml << EOF
apiVersion: ${K8S_API_VER}
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
imageRepository: ${KUBEADM_IMAGE_REPO}
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SVC_CIDR}"
  dnsDomain: "${DNS_DOMAIN}"
apiServer:
  certSANs:
    - ${MASTER_IP}
    - ${MASTER_HOSTNAME}
    - 127.0.0.1
    - localhost
  extraArgs:
    - name: authorization-mode
      value: ${K8S_AUTH_MODE}
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
---
apiVersion: ${K8S_API_VER}
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: ${API_PORT}
nodeRegistration:
  criSocket: ${cri_socket}
  name: ${MASTER_HOSTNAME}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ${KUBEPROXY_MODE}
ipvs:
  strictARP: true
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: ${CGROUP}
EOF

    if [ "$OFFLINE_MODE" -eq 1 ]; then
        load_offline_images "kubeadm"
    else
        kubeadm config images pull --config ${KUBEADM_YAML} --cri-socket "${cri_socket}"
    fi

    # Docker 运行时: 预拉取 pause 镜像并 tag (registry.k8s.io 被墙)
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        log_info "预拉取 pause 镜像 (使用国内源)..."
        local pause_mirror="${KUBEADM_IMAGE_REPO}/pause:3.10.1"
        local pause_official="${PAUSE_IMAGE}"
        if ! docker pull "${pause_mirror}" 2>/dev/null; then
            # 回退: 尝试多个国内源
            docker pull "registry.aliyuncs.com/google_containers/pause:3.10.1" 2>/dev/null || \
            docker pull "registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10.1" 2>/dev/null || \
            docker pull "pause:3.10.1" 2>/dev/null
        fi
        docker tag "registry.aliyuncs.com/google_containers/pause:3.10.1" "registry.k8s.io/pause:3.10.1" 2>/dev/null || true
        docker tag "registry.aliyuncs.com/google_containers/pause:3.10.1" "registry.k8s.io/pause:3.10" 2>/dev/null || true
        log_info "pause 镜像已准备好"
    fi

    # 重启 cri-dockerd 确保 socket 状态正常 (Docker 运行时)
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        log_info "重启 cri-dockerd 确保 socket 状态正常..."
        systemctl restart cri-dockerd.service 2>/dev/null || true
        sleep 3
    fi

    kubeadm init --config ${KUBEADM_YAML} --upload-certs \
        --ignore-preflight-errors=${K8S_PREFLIGHT} 2>&1 | tee ${KUBEADM_LOG}
    
    # 检查 kubeadm init 是否成功
    if ! grep -q "Your Kubernetes control-plane has initialized successfully" ${KUBEADM_LOG} 2>/dev/null; then
        log_error "kubeadm init 失败，请查看日志: ${KUBEADM_LOG}"
        log_error "可能原因:"
        log_error "  1. CRI socket 配置错误"
        log_error "  2. 容器运行时未正确启动"
        log_error "  3. 镜像拉取失败"
        log_error "  4. 网络问题"
        exit 1
    fi

    mkdir -p $HOME/.kube
    cp -i ${KUBE_CONFIG} ${KUBE_CONFIG_HOME}
    chown $(id -u):$(id -g) ${KUBE_CONFIG_HOME}
    echo "export KUBECONFIG=${KUBE_CONFIG}" >> ${PROFILE}
    export KUBECONFIG=${KUBE_CONFIG}

    local join_cmd token hash
    join_cmd=$(kubeadm token create --print-join-command 2>/dev/null)
    token=$(echo "$join_cmd" | grep -oP -- '--token \K[^ ]+')
    hash=$(echo "$join_cmd" | grep -oP -- 'sha256:[a-f0-9]+')
    echo "$join_cmd" > ${JOIN_CMD}
    printf '%s' "$token" > ${K8S_DIR}/join-token
    printf '%s' "$hash"  > ${K8S_DIR}/join-hash
    log_info "Join Token: ${token}"
    kubectl get nodes
}

# ==================== Master 专属: Worker 加入 ====================
join_workers() {
    log_step "远程加入 Worker 节点"
    local join_token=$(cat ${K8S_DIR}/join-token 2>/dev/null | tr -d '\n' || echo "")
    local join_hash=$(cat ${K8S_DIR}/join-hash 2>/dev/null | tr -d '\n' || echo "")
    [ -z "$join_token" ] && { log_warn "未找到 token"; return 1; }

    # 构建 Worker 列表
    local entries=("${WORKER1_USER}@${WORKER1_IP}|${WORKER1_HOSTNAME}")
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        entries+=("${WORKER2_USER}@${WORKER2_IP}|${WORKER2_HOSTNAME}")
    fi

    for entry in "${entries[@]}"; do
        local conn="${entry%%|*}" hostname="${entry##*|}"
        log_info "加入 ${hostname}..."
        local join_cri_socket=""
        if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
            join_cri_socket="unix:///var/run/cri-dockerd.sock"
        else
            join_cri_socket="${CONTAINERD_SOCK}"
        fi
        ssh -o StrictHostKeyChecking=no "$conn" \
            "export PATH=/usr/local/bin:/usr/bin:\$PATH; kubeadm join ${MASTER_IP}:${API_PORT} --token ${join_token} --discovery-token-ca-cert-hash ${join_hash} --cri-socket ${join_cri_socket} --ignore-preflight-errors=${K8S_PREFLIGHT}" 2>&1 || \
            log_warn "${hostname} 加入失败"
    done
    sleep 5
    kubectl get nodes
    kubectl label node "${WORKER1_HOSTNAME}" node-role.kubernetes.io/worker=worker --overwrite 2>/dev/null || true
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_HOSTNAME:-}" ]; then
        kubectl label node "${WORKER2_HOSTNAME}" node-role.kubernetes.io/worker=worker --overwrite 2>/dev/null || true
    fi
    log_info "Worker 加入完成"
}

# ==================== Calico ====================
install_calico() {
    log_step "安装 Calico"
    mkdir -p ${K8S_DIR} && cd ${K8S_DIR}

    if [ "$OFFLINE_MODE" -eq 1 ]; then
        load_offline_images "calico"
        cp "${OFFLINE_MOUNT}/${OFFLINE_MANIFESTS_DIR}/calico.yaml" calico.yaml
        sed -i 's|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g' calico.yaml 2>/dev/null || true
    else
        if [ -f /root/calico.yaml ]; then
            log_info "使用本地 calico.yaml"
            cp /root/calico.yaml calico.yaml
        else
            wget -q --timeout=30 "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -O calico.yaml 2>/dev/null || \
            wget -q --timeout=30 "https://gh-proxy.com/https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -O calico.yaml 2>/dev/null || \
            wget -q --timeout=30 "https://ghproxy.net/https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -O calico.yaml 2>/dev/null || \
            { log_error "Calico 下载失败 (可手动放到 /root/calico.yaml)"; exit 1; }
        fi
        sed -i "s|${CALICO_REGISTRY}|${CALICO_PROXY}|g" calico.yaml
    fi
    sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' calico.yaml
    sed -i "s|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|" calico.yaml
    kubectl create -f calico.yaml
    kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=${CALICO_TMOUT}s 2>/dev/null || log_warn "Calico 部分未就绪"
    kubectl get nodes
}

# ==================== 验证 ====================
verify_cluster() {
    log_step "集群验证"

    if [ "$OFFLINE_MODE" -eq 1 ]; then
        log_info "离线模式: 跳过 nginx 验证"
        return 0
    fi

    kubectl create deployment nginx --image=${VERIFY_IMAGE} --replicas=3 2>/dev/null || true
    kubectl expose deployment nginx --port=80 --type=NodePort 2>/dev/null || true
    kubectl wait --for=condition=Ready pods -l app=nginx --timeout=${NGINX_TMOUT}s 2>/dev/null || log_warn "nginx 超时"
    kubectl get pods -o wide

    local np=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    [ -n "$np" ] && curl -sI --connect-timeout ${CURL_TMOUT} "http://${WORKER1_IP}:${np}" | head -1 2>/dev/null || log_warn "NodePort 失败"

    kubectl delete deployment nginx 2>/dev/null || true
    kubectl delete svc nginx 2>/dev/null || true
}

# ==================== Dashboard ====================
install_dashboard() {
    log_step "安装 Dashboard"
    mkdir -p ${K8S_DIR} && cd ${K8S_DIR}

    if ! command -v helm &>/dev/null; then
        if [ "$OFFLINE_MODE" -eq 1 ]; then
            local local_bin="${OFFLINE_MOUNT}/${OFFLINE_BINARIES_DIR}/helm"
            local local_tgz="${OFFLINE_MOUNT}/${OFFLINE_BINARIES_DIR}/helm-${HELM_VERSION}-linux-amd64.tar.gz"
            if [ -f "$local_bin" ]; then
                cp "$local_bin" /usr/local/bin/helm && chmod +x /usr/local/bin/helm
            elif [ -f "$local_tgz" ]; then
                tar -zxf "$local_tgz" && mv linux-amd64/helm /usr/local/bin/ && rm -rf linux-amd64
            else
                log_warn "Helm 不存在，跳过 Dashboard"; return 0
            fi
        else
            if [ -x /usr/local/bin/helm ]; then
                log_info "helm 已存在"
            else
                github_dl "${HELM_DL}"
                tar -zxf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
                mv linux-amd64/helm /usr/local/bin/
                rm -rf linux-amd64 helm-*.tar.gz 2>/dev/null || true
            fi
        fi
    fi
    helm version

    if [ "$OFFLINE_MODE" -eq 1 ]; then
        local chart_dir="${OFFLINE_MOUNT}/${OFFLINE_MANIFESTS_DIR}/kubernetes-dashboard"
        if [ -d "$chart_dir" ] && [ -f "${chart_dir}/Chart.yaml" ]; then
            cp -r "$chart_dir" ./kubernetes-dashboard
        elif [ -f "${OFFLINE_MOUNT}/${OFFLINE_MANIFESTS_DIR}/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz" ]; then
            tar -xzf "${OFFLINE_MOUNT}/${OFFLINE_MANIFESTS_DIR}/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"
        else
            local f=$(find "${OFFLINE_MOUNT}/${OFFLINE_MANIFESTS_DIR}" -maxdepth 1 -name '*dashboard*.tgz' 2>/dev/null | head -1)
            [ -n "$f" ] && tar -xzf "$f" || { log_warn "Chart 未找到"; return 0; }
        fi
        load_offline_images "dashboard"
    else
        if [ ! -d "kubernetes-dashboard" ]; then
            local local_tgz="/root/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"
            if [ -f "$local_tgz" ]; then
                log_info "使用本地 Chart: ${local_tgz}"
                cp "$local_tgz" . && tar -xzf "kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"
            else
                log_info "下载 Dashboard Chart..."
                local dl_ok=0
                for u in \
                    "https://gh-proxy.com/${DASHBOARD_DL}" \
                    "https://ghproxy.net/${DASHBOARD_DL}" \
                    "${DASHBOARD_DL}"; do
                    if wget -q --timeout=30 -O "kubernetes-dashboard-${DASHBOARD_VERSION}.tgz" "$u" 2>/dev/null; then
                        dl_ok=1; break
                    fi
                done
                if [ $dl_ok -eq 1 ]; then
                    tar -xzf "kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"
                else
                    log_warn "Dashboard 下载失败 (可手动放 /root/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz)"; return 0
                fi
            fi
        fi
    fi

    helm install ${DASH_HELM_RELEASE} ${DASH_HELM_CHART} \
        --namespace ${DASH_NS} --create-namespace \
        --set kong.enabled=${HELM_KONG_ENABLED:-true} --set cert-manager.enabled=${HELM_CERT_MANAGER_ENABLED:-false} \
        --set nginx.enabled=${HELM_NGINX_ENABLED:-false} --set metrics-server.enabled=${HELM_METRICS_SERVER_ENABLED:-false}

    kubectl wait --for=condition=Ready pods --all -n ${DASH_NS} --timeout=${DASH_TMOUT}s 2>/dev/null || log_warn "Dashboard 部分未就绪"
    kubectl get pods -n ${DASH_NS}

    # 将 Kong proxy 改为 NodePort 直接暴露 (port-forward 对 HTTPS 有问题)
    log_info "配置 Dashboard NodePort 访问..."
    kubectl delete svc dashboard-kong-proxy -n ${DASH_NS} 2>/dev/null || true
    kubectl expose deployment dashboard-kong -n ${DASH_NS} \
        --name=dashboard-kong-proxy \
        --port=443 --target-port=8443 \
        --type=NodePort 2>/dev/null || true
    sleep 3
    local nodePort
    nodePort=$(kubectl get svc dashboard-kong-proxy -n ${DASH_NS} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "30443")
    echo "${nodePort}" > ${K8S_DIR}/dashboard-port
    log_info "Dashboard NodePort: ${nodePort}"
    log_info "Dashboard: https://${MASTER_IP}:${nodePort}"

    # 关闭防火墙确保端口可达
    firewall-cmd --add-port=${nodePort}/tcp 2>/dev/null || true
    firewall-cmd --add-port=${nodePort}/tcp --permanent 2>/dev/null || true
    systemctl stop firewalld 2>/dev/null || true

    kubectl create serviceaccount ${DASH_SA} -n ${DASH_NS} 2>/dev/null || true
    kubectl create clusterrolebinding ${DASH_SA} --clusterrole=cluster-admin --serviceaccount=${DASH_NS}:${DASH_SA} 2>/dev/null || true
    
    # 生成登录 Token
    kubectl create token ${DASH_SA} -n ${DASH_NS} --duration=${DASH_TOKEN_TTL} 2>/dev/null > ${K8S_DIR}/dashboard-token
    log_info "Dashboard Token 已保存到 ${K8S_DIR}/dashboard-token"
}

# ==================== SSH ====================
setup_ssh_keys() {
    local user="$1" ip="$2" label="$3"
    log_info "配置 SSH 免密到 ${label}"
    local keyfile="${SSH_KEYFILE:-/root/.ssh/id_rsa}"
    if [ ! -f "$keyfile" ]; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        ssh-keygen -t rsa -b ${SSH_KEY_BITS:-2048} -N "" -f "$keyfile" -C "${SSH_KEY_COMMENT:-k8s-deploy}" -q
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=${SSH_TMOUT} "${user}@${ip}" "hostname" &>/dev/null; then
        log_info "免密 ${label} 已就绪"; return 0
    fi
    
    # 检查网络连通性
    log_info "检查到 ${label} (${ip}) 的网络连通性..."
    if ! ping -c 3 -W 2 "$ip" &>/dev/null; then
        log_error "无法 ping 通 ${label} (${ip})，请检查网络连接"
        log_error "可能原因: 节点未开机、IP 地址错误、网络配置问题"
        exit 1
    fi
    log_info "网络连通正常"
    
    echo ""
    echo ">>> 输入 ${user}@${ip} 密码:"
    ssh-copy-id -o StrictHostKeyChecking=no "${user}@${ip}"
    if [ $? -eq 0 ]; then
        log_info "免密 ${label} OK"
    else
        log_error "ssh-copy-id 失败，请检查密码是否正确"
        exit 1
    fi
}

# ==================== 网络 ====================
configure_network_interface() {
    local iface="$1" ip="$2" prefix="$3" gateway="$4"
    local cur=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | head -1)
    local cur_ip=$(echo "$cur" | cut -d'/' -f1)
    local cur_pf=$(echo "$cur" | cut -d'/' -f2)
    if [ "$cur_ip" = "$ip" ] && [ "${cur_pf:-24}" = "${prefix:-24}" ]; then
        log_info "网卡 ${iface} IP 已正确，跳过"; return 0
    fi
    local f="${NM_DIR}/${iface}.nmconnection"
    [ -f "$f" ] && cp "$f" "${f}.bak" 2>/dev/null || true
    local uu=$(grep -oP 'uuid=\K.*' "$f" 2>/dev/null | head -1 || uuidgen)
    local gs=""; [ -n "$gateway" ] && gs=",${gateway}"
    cat > "$f" << NMEOF
[connection]
id=${iface}
uuid=${uu}
type=ethernet
autoconnect-priority=-999
interface-name=${iface}
[ethernet]
[ipv4]
address1=${ip}/${prefix}${gs}
dns=${DNS_SERVERS:-8.8.8.8;223.5.5.5;}
method=manual
[ipv6]
addr-gen-mode=eui64
method=auto
[proxy]
NMEOF
    chmod 600 "$f"
    nmcli con reload 2>/dev/null || true
    nmcli con down "${iface}" 2>/dev/null || true
    nmcli con up "${iface}" 2>/dev/null || true
}

# ==================== 主机名/SELinux/Swap/内核 ====================
set_hostname() {
    hostnamectl set-hostname "$1"
    log_info "主机名: $(hostname)"
}

configure_hosts() {
    cp -n /etc/hosts /etc/hosts.bak 2>/dev/null || true
    sed -i "/${MASTER_HOSTNAME}/d; /${WORKER1_HOSTNAME}/d" /etc/hosts 2>/dev/null || true
    [ -n "${WORKER2_HOSTNAME:-}" ] && sed -i "/${WORKER2_HOSTNAME}/d" /etc/hosts 2>/dev/null || true
    cat >> /etc/hosts << EOF
${MASTER_IP}    ${MASTER_HOSTNAME}
${WORKER1_IP}   ${WORKER1_HOSTNAME}
EOF
    if [ "${WORKER_COUNT:-2}" -ge 2 ] && [ -n "${WORKER2_IP:-}" ]; then
        echo "${WORKER2_IP}   ${WORKER2_HOSTNAME}" >> /etc/hosts
    fi
    log_info "hosts 已更新"
}

disable_firewall_selinux() {
    systemctl stop ${SVC_FIREWALLD:-firewalld} 2>/dev/null || true
    systemctl disable ${SVC_FIREWALLD:-firewalld} 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' ${SELINUX_CFG} 2>/dev/null || true
    setenforce 0 2>/dev/null || true
}

disable_swap() {
    swapoff -a 2>/dev/null || true
    sed -i '/swap/s/^/#/' /etc/fstab

    # 自动检测并禁用所有 Swap 设备 (兼容 CentOS Stream 9/10 不同分区方案)
    # 1. 禁用 systemd swap 单元
    for swap_unit in $(systemctl list-units --type=swap --no-legend 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$swap_unit" 2>/dev/null || true
        systemctl mask "$swap_unit" 2>/dev/null || true
    done

    # 2. 禁用 LVM Swap 逻辑卷
    for swap_lv in $(swapon --noheadings --show=NAME 2>/dev/null | grep '/dev/mapper/' || true); do
        lvchange -an "$swap_lv" 2>/dev/null || true
    done

    # 3. 清理 GRUB 中的 swap 相关参数
    sed -i 's/ resume=[^ "]*//g' /etc/default/grub 2>/dev/null || true
    sed -i 's/ rd\.lvm\.lv=[^ ]*swap[^ ]*//g' /etc/default/grub 2>/dev/null || true
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true

    log_info "Swap 已禁用"
}

configure_kernel() {
    modprobe br_netfilter && modprobe overlay
    cat > /etc/modules-load.d/k8s.conf <<< "br_netfilter"$'\n'"overlay"
    cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
vm.swappiness=0
vm.overcommit_memory=1
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
EOF
    sysctl --system > /dev/null 2>&1
}

setup_chrony() { systemctl enable ${SVC_CHRONYD:-chronyd} --now 2>/dev/null || true; }

# ==================== Docker CE + Containerd + crictl + k8s 二进制 ====================
setup_docker_repo() {
    if [ "$OFFLINE_MODE" -eq 1 ]; then return 0; fi
    dnf install -y ${PKG_DNF_PLUGINS:-dnf-plugins-core} 2>/dev/null || true
    rm -f /etc/yum.repos.d/docker-ce*.repo 2>/dev/null || true
    for base in \
        "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/\$releasever/\$basearch/stable" \
        "https://mirrors.ustc.edu.cn/docker-ce/linux/centos/\$releasever/\$basearch/stable" \
        "https://mirrors.aliyun.com/docker-ce/linux/centos/\$releasever/\$basearch/stable"; do
        cat > /etc/yum.repos.d/docker-ce.repo << EOF
[docker-ce-stable]
name=Docker CE
baseurl=${base}
enabled=1
gpgcheck=0
timeout=30
EOF
        if dnf makecache --repo=docker-ce-stable 2>/dev/null; then log_info "Docker CE repo OK"; return 0; fi
    done
    log_warn "Docker CE repo 全部失败"
}

install_containerd() {
    if [ "$OFFLINE_MODE" -eq 1 ]; then
        # 离线模式: 直接根据 OS 版本安装正确的 RPM (跳过 dnf install，避免安装错误版本)
        local d="${OFFLINE_MOUNT}/${OFFLINE_RPMS_DIR}"
        local myarch; myarch=$(uname -m)
        # 根据 CentOS 版本选择正确的 RPM (避免 el10 的 runc 在 CentOS 9 上因 glibc 版本不兼容而失败)
        if is_centos_stream_10; then
            # CentOS 10: 优先 el10，回退 el9
            rpm -ivh --nodeps "${d}"/containerd*.el10.${myarch}.rpm 2>/dev/null || \
            rpm -ivh --nodeps "${d}"/containerd*.el9.${myarch}.rpm 2>/dev/null || \
            rpm -ivh --nodeps "${d}"/containerd*.${myarch}.rpm 2>/dev/null || \
            { log_error "离线安装失败，ISO 中没有兼容的 containerd RPM"; exit 1; }
        else
            # CentOS 9: 只安装 el9 (el10 的 runc 需要 glibc 2.38，CentOS 9 只有 2.34)
            if ls "${d}"/containerd*.el9.${myarch}.rpm &>/dev/null; then
                rpm -ivh --nodeps "${d}"/containerd*.el9.${myarch}.rpm 2>/dev/null || \
                { log_error "el9 RPM 安装失败"; exit 1; }
            else
                log_error "ISO 中没有 el9 的 containerd RPM，请重新构建 ISO (确保包含 el9 和 el10 的 RPM)"
                exit 1
            fi
        fi
    else
        dnf install -y --setopt=timeout=30 --setopt=retries=1 containerd.io
    fi
    containerd --version
    containerd config default > ${CONTAINERD_CFG}
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' ${CONTAINERD_CFG}
    sed -i "s|sandbox = '${DEFAULT_PAUSE_IMAGE}'|sandbox = '${PAUSE_IMAGE}'|g" ${CONTAINERD_CFG}
    local rl=$(grep -n "plugins.'io.containerd.cri.v1.images'.registry" ${CONTAINERD_CFG} | head -1 | cut -d: -f1)
    sed -i "${rl}a\\
    [plugins.'io.containerd.cri.v1.images'.registry.mirrors]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"docker.io\"]\\
        endpoint = [\"${MIRROR_DOCKER}\", \"https://docker.m.daocloud.io\", \"https://hub-mirror.c.163.com\", \"https://dockerhub.icu\", \"https://dockerproxy.com\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"k8s.gcr.io\"]\\
        endpoint = [\"${MIRROR_K8S_GCR}\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"gcr.io\"]\\
        endpoint = [\"${MIRROR_GCR}\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"quay.io\"]\\
        endpoint = [\"${MIRROR_QUAY}\"]" ${CONTAINERD_CFG}
    containerd config dump > /dev/null 2>&1 || { log_error "TOML 错误"; exit 1; }
    systemctl daemon-reload; systemctl enable ${SVC_CONTAINERD:-containerd} --now; systemctl restart ${SVC_CONTAINERD:-containerd}
}

# ==================== Docker Engine 安装 (仅 Docker 运行时) ====================
install_docker() {
    if [ "${CONTAINER_RUNTIME}" != "docker" ]; then
        return 0
    fi

    log_step "安装 Docker Engine"

    if [ "$OFFLINE_MODE" -eq 1 ]; then
        # 离线模式: 直接根据 OS 版本安装正确的 RPM (跳过 dnf install，避免安装错误版本)
        local d="${OFFLINE_MOUNT}/${OFFLINE_RPMS_DIR}"
        local myarch; myarch=$(uname -m)
        # 根据 CentOS 版本选择正确的 RPM
        if is_centos_stream_10; then
            # CentOS 10: 优先 el10，回退 el9
            rpm -ivh --nodeps "${d}"/docker-ce*.el10.${myarch}.rpm "${d}"/container*.el10.${myarch}.rpm 2>/dev/null || \
            rpm -ivh --nodeps "${d}"/docker-ce*.el9.${myarch}.rpm "${d}"/container*.el9.${myarch}.rpm 2>/dev/null || \
            { log_error "Docker 安装失败"; exit 1; }
        else
            # CentOS 9: 只安装 el9
            if ls "${d}"/docker-ce*.el9.${myarch}.rpm &>/dev/null; then
                rpm -ivh --nodeps "${d}"/docker-ce*.el9.${myarch}.rpm "${d}"/container*.el9.${myarch}.rpm 2>/dev/null || \
                { log_error "Docker 安装失败"; exit 1; }
            else
                log_error "ISO 中没有 el9 的 Docker RPM，请重新构建 ISO (确保包含 el9 和 el10 的 RPM)"
                exit 1
            fi
        fi
    else
        dnf install -y --setopt=timeout=30 --setopt=retries=1 docker-ce docker-ce-cli docker-ce-rootless-extras
    fi

    # 配置 Docker daemon (使用 systemd cgroup driver + 镜像加速)
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m"
    },
    "storage-driver": "overlay2",
    "registry-mirrors": [
        "${MIRROR_DOCKER}",
        "https://docker.m.daocloud.io",
        "https://hub-mirror.c.163.com",
        "https://dockerhub.icu",
        "https://docker.rainbond.cc",
        "https://dockerproxy.com",
        "https://registry.cn-hangzhou.aliyuncs.com"
    ]
}
EOF

    systemctl daemon-reload
    systemctl enable docker --now
    systemctl restart docker
    docker --version
    log_info "Docker Engine 安装完成 (已配置镜像加速)"
}

# ==================== cri-dockerd 安装 (仅 Docker 运行时) ====================
install_cri_dockerd() {
    if [ "${CONTAINER_RUNTIME}" != "docker" ]; then
        return 0
    fi

    log_step "安装 cri-dockerd"

    CRI_DOCKERD_VERSION="${CRI_DOCKERD_VERSION:-0.3.21}"
    local bin="/usr/local/bin/cri-dockerd"
    local need_download=0

    # 检查是否已安装二进制
    if [ -x "$bin" ] && "$bin" --version 2>/dev/null | grep -q "${CRI_DOCKERD_VERSION}"; then
        log_info "cri-dockerd ${CRI_DOCKERD_VERSION} 二进制已存在"
    else
        need_download=1
    fi

    # 下载 cri-dockerd (如果需要)
    if [ $need_download -eq 1 ]; then
        local dl_url="${CRI_DOCKERD_DOWNLOAD_URL:-https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz}"
        local tgz="cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"

        if [ "$OFFLINE_MODE" -eq 1 ]; then
            local offline_bin="${OFFLINE_MOUNT}/${OFFLINE_BINARIES_DIR}/cri-dockerd"
            if [ -f "$offline_bin" ] && [ ! -d "$offline_bin" ]; then
                cp "$offline_bin" "$bin" && chmod +x "$bin"
            else
                log_warn "离线模式: cri-dockerd 不存在于 ISO 中"; return 0
            fi
        else
            log_info "下载 cri-dockerd v${CRI_DOCKERD_VERSION}..."
            github_dl "$dl_url" "$tgz" || { log_error "cri-dockerd 下载失败"; return 1; }
            tar -xzf "$tgz"
            # cri-dockerd 解压后可能是目录或文件，需要正确处理
            if [ -f "cri-dockerd" ] && [ ! -d "cri-dockerd" ]; then
                mv cri-dockerd "$bin"
            elif [ -d "cri-dockerd" ]; then
                local found_bin
                found_bin=$(find cri-dockerd -name "cri-dockerd" -type f 2>/dev/null | head -1) || true
                if [ -n "$found_bin" ]; then
                    mv "$found_bin" "$bin"
                else
                    log_error "cri-dockerd 二进制文件未找到"; return 1
                fi
            else
                log_error "cri-dockerd 解压失败"; return 1
            fi
            chmod +x "$bin"
            rm -rf "$tgz" cri-dockerd 2>/dev/null || true
        fi

        # 验证安装
        "$bin" --version || { log_error "cri-dockerd 安装失败"; return 1; }
    fi

    # 创建 systemd 服务
    cat > /etc/systemd/system/cri-dockerd.service << 'EOF'
[Unit]
Description=CRI Docker Daemon
Documentation=https://github.com/Mirantis/cri-dockerd
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=cri-dockerd.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --container-runtime-endpoint fd://
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/cri-dockerd.socket << 'EOF'
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-dockerd.service

[Socket]
ListenStream=/var/run/cri-dockerd.sock
SocketMode=0660
SocketUser=root

[Install]
WantedBy=sockets.target
EOF

    # 确保 Docker 已启动并就绪
    log_info "确保 Docker 服务已启动..."
    systemctl enable docker --now 2>/dev/null || true
    
    # 等待 Docker socket 就绪
    local docker_retries=0
    while [ $docker_retries -lt 30 ]; do
        if [ -S "/var/run/docker.sock" ]; then
            log_info "Docker socket 已就绪"
            break
        fi
        systemctl start docker 2>/dev/null || true
        sleep 1
        docker_retries=$((docker_retries + 1))
    done
    
    # 验证 Docker 运行状态
    if ! systemctl is-active docker &>/dev/null; then
        log_error "Docker 服务未运行，尝试启动..."
        systemctl start docker 2>/dev/null || true
        sleep 3
    fi
    
    docker --version 2>/dev/null && log_info "Docker 已就绪" || log_warn "Docker 未正确安装"
    
    # 确保 cri-dockerd 有权限访问 Docker socket
    chmod 666 /var/run/docker.sock 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable cri-dockerd.socket --now 2>/dev/null || true
    systemctl enable cri-dockerd.service --now 2>/dev/null || true

    # 等待 cri-dockerd socket 就绪
    log_info "等待 cri-dockerd socket 就绪..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if [ -S "/var/run/cri-dockerd.sock" ]; then
            log_info "cri-dockerd socket 已就绪"
            break
        fi
        sleep 1
        retries=$((retries + 1))
    done

    # 验证服务状态
    if systemctl is-active cri-dockerd.service &>/dev/null && [ -S "/var/run/cri-dockerd.sock" ]; then
        log_info "cri-dockerd v${CRI_DOCKERD_VERSION} 安装完成"
        # 测试连接 (不使用 set -e，避免测试失败导致脚本退出)
        local test_output
        test_output=$(crictl --runtime-endpoint unix:///var/run/cri-dockerd.sock version 2>&1) || true
        if echo "$test_output" | grep -q "RuntimeName"; then
            log_info "cri-dockerd 连接测试成功"
        else
            log_warn "cri-dockerd 连接测试输出: $test_output"
            # 尝试重启服务
            log_info "尝试重启 cri-dockerd 服务..."
            systemctl restart cri-dockerd.service 2>/dev/null || true
            sleep 3
            test_output=$(crictl --runtime-endpoint unix:///var/run/cri-dockerd.sock version 2>&1) || true
            if echo "$test_output" | grep -q "RuntimeName"; then
                log_info "cri-dockerd 连接测试成功 (重启后)"
            else
                log_warn "cri-dockerd 连接仍然失败: $test_output"
                log_warn "请手动检查: journalctl -xeu cri-dockerd.service"
            fi
        fi
    else
        log_warn "cri-dockerd 服务启动失败，请检查: journalctl -xeu cri-dockerd.service"
        log_warn "Docker 状态: $(systemctl is-active docker 2>/dev/null || echo '未运行')"
        log_warn "Docker socket: $(ls -la /var/run/docker.sock 2>/dev/null || echo '不存在')"
        log_warn "cri-dockerd socket: $(ls -la /var/run/cri-dockerd.sock 2>/dev/null || echo '不存在')"
    fi
}

install_crictl() {
    if [ -x /usr/local/bin/crictl ]; then
        log_info "crictl 已存在"
    else
        local arch; arch=$(uname -m); case $arch in x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; esac
        if [ "$OFFLINE_MODE" -eq 1 ]; then
            local b="${OFFLINE_MOUNT}/${OFFLINE_BINARIES_DIR}/crictl"
            [ -f "$b" ] && { cp "$b" /usr/local/bin/crictl; chmod +x /usr/local/bin/crictl; }
        else
            github_dl "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${arch}.tar.gz" || { log_warn "crictl 下载失败"; return 0; }
            tar -zxf "crictl-${CRICTL_VERSION}-linux-${arch}.tar.gz"
            mv crictl /usr/local/bin/; rm -f crictl-*.tar.gz
        fi
    fi
    # 根据容器运行时配置 crictl (总是更新配置)
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        cat > ${CRICTL_CFG} << EOF
runtime-endpoint: unix:///var/run/cri-dockerd.sock
image-endpoint: unix:///var/run/cri-dockerd.sock
timeout: 10
debug: false
EOF
    else
        cat > ${CRICTL_CFG} << EOF
runtime-endpoint: ${CONTAINERD_SOCK}
image-endpoint: ${CONTAINERD_SOCK}
timeout: 10
debug: false
EOF
    fi
    log_info "crictl OK"
}

verify_image_pull() {
    if [ "$OFFLINE_MODE" -eq 1 ]; then return 0; fi
    
    # 根据容器运行时选择正确的 endpoint
    local runtime_endpoint=""
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        runtime_endpoint="--runtime-endpoint unix:///var/run/cri-dockerd.sock"
    fi
    
    if crictl images 2>/dev/null | grep -q "${VERIFY_IMAGE}" 2>/dev/null; then
        log_info "${VERIFY_IMAGE} 镜像已存在"
        return 0
    fi
    timeout 60 crictl $runtime_endpoint pull ${VERIFY_IMAGE} > /dev/null 2>&1 || log_warn "拉取超时"
}

install_k8s_binaries() {
    if [ "$OFFLINE_MODE" -eq 1 ]; then
        local myarch; myarch=$(uname -m)
        dnf install -y kubeadm kubelet kubectl 2>/dev/null || {
            local d="${OFFLINE_MOUNT}/${OFFLINE_RPMS_DIR}"
            rpm -ivh --nodeps "${d}"/kubeadm-*."${myarch}".rpm "${d}"/kubelet-*."${myarch}".rpm "${d}"/kubectl-*."${myarch}".rpm 2>/dev/null || { log_error "安装失败"; exit 1; }
        }
    else
        # 尝试多个 Kubernetes 镜像源 (国内优先)
        local k8s_repo_ok=0
        for baseurl in \
            "https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.35/rpm/" \
            "https://mirrors.tuna.tsinghua.edu.cn/kubernetes/core:/stable:/v1.35/rpm/" \
            "https://mirrors.ustc.edu.cn/kubernetes/core:/stable:/v1.35/rpm/" \
            "https://pkgs.k8s.io/core:/stable:/v1.35/rpm/"; do
            cat > ${K8S_REPO} << EOF
[kubernetes]
name=Kubernetes
baseurl=${baseurl}
enabled=1
gpgcheck=0
timeout=30
EOF
            if dnf makecache --repo=kubernetes 2>/dev/null; then
                log_info "Kubernetes 仓库 OK: ${baseurl}"
                k8s_repo_ok=1
                break
            fi
        done
        [ "$k8s_repo_ok" -eq 0 ] && { log_error "所有 Kubernetes 镜像源失败"; exit 1; }
        log_info "安装 Kubernetes 组件..."
        
        # 先检查可用的包
        log_info "检查可用的 Kubernetes 包..."
        dnf list available kubeadm kubelet kubectl 2>/dev/null | grep -E "kubeadm|kubelet|kubectl" | head -10 || true
        
        # 尝试安装，如果失败则尝试不带版本通配符
        if ! dnf install -y ${PKG_KUBEADM:-kubeadm-1.35*} ${PKG_KUBELET:-kubelet-1.35*} ${PKG_KUBECTL:-kubectl-1.35*} 2>/dev/null; then
            log_warn "带版本通配符安装失败，尝试不带版本..."
            dnf install -y kubeadm kubelet kubectl || {
                log_error "Kubernetes 组件安装失败"
                log_error "可能原因:"
                log_error "  1. 网络问题"
                log_error "  2. 仓库配置错误"
                log_error "  3. 包名不匹配"
                exit 1
            }
        fi
    fi
    # 根据容器运行时设置 kubelet CRI 端点
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        cat > ${KUBELET_CFG} << 'EOF'
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///var/run/cri-dockerd.sock"
EOF
    else
        cat > ${KUBELET_CFG} << 'EOF'
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
    fi
    systemctl daemon-reload; systemctl enable ${SVC_KUBELET:-kubelet} --now
}

# ==================== pause 镜像预拉取 (Docker 运行时, registry.k8s.io 被墙) ====================
prep_pause_image() {
    if [ "${CONTAINER_RUNTIME}" != "docker" ]; then
        return 0
    fi

    log_info "预拉取 pause 镜像 (使用国内源)..."

    # 先检查是否已存在
    if docker images registry.k8s.io/pause:3.10 2>/dev/null | grep -q "pause"; then
        log_info "pause 镜像已存在"
        return 0
    fi

    # 从国内源拉取并 tag
    local pulled=0
    for mirror in \
        "registry.aliyuncs.com/google_containers/pause:3.10.1" \
        "registry.cn-hangzhou.aliyuncs.com/google_containers/pause:3.10.1" \
        "docker.1panel.live/google_containers/pause:3.10.1" \
        "docker.1panel.live/pause:3.10.1"; do
        if docker pull "$mirror" 2>/dev/null; then
            log_info "从 ${mirror} 拉取 pause 镜像成功"
            pulled=1
            break
        fi
    done

    if [ $pulled -eq 0 ]; then
        log_warn "pause 镜像拉取失败，将使用 Docker Hub"
        return 0
    fi

    # tag 为 kubelet 需要的镜像名
    docker tag "registry.aliyuncs.com/google_containers/pause:3.10.1" "registry.k8s.io/pause:3.10.1" 2>/dev/null || true
    docker tag "registry.aliyuncs.com/google_containers/pause:3.10.1" "registry.k8s.io/pause:3.10" 2>/dev/null || true
    log_info "pause 镜像已 tag 为 registry.k8s.io/pause:3.10"
}

# ==================== 所有节点通用入口 ====================
common_prep() {
    local hostname="$1" iface="$2" ip="$3" prefix="$4" gateway="$5"
    set_hostname "$hostname"
    configure_network_interface "$iface" "$ip" "$prefix" "$gateway"
    disable_firewall_selinux
    configure_hosts
    disable_swap
    configure_kernel
    setup_chrony
    if [ "$OFFLINE_MODE" -eq 1 ]; then
        mount_offline_iso "$OFFLINE_ISO" "$OFFLINE_MOUNT"
        setup_offline_repo "$OFFLINE_MOUNT"
    fi
    setup_docker_repo
    if [ "${CONTAINER_RUNTIME}" = "docker" ]; then
        install_docker      # Docker 运行时
        install_cri_dockerd # Docker 运行时
    else
        install_containerd  # containerd 运行时
    fi
    install_crictl
    verify_image_pull
    install_k8s_binaries
    prep_pause_image   # Docker 运行时: 预拉取 pause 镜像
    log_info "[${hostname}] 通用准备完成"
}

# ==================== 入口 ====================
if [ "$REMOTE_MODE" -eq 1 ]; then
    remote_mode_execute "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}"
else
    interactive_main
fi
