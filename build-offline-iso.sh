#!/bin/bash
###############################################################################
# 构建 K8s 离线 ISO 脚本
# 运行条件: 需要互联网连接 + root 权限 + 至少 5GB 磁盘空间
# 执行方式: bash build-offline-iso.sh
# 输出:     /root/k8s-offline-repo.iso
###############################################################################
set -euo pipefail

# 尝试加载变量库
if [ -f "$(dirname "$0")/deploy-k8s-vars.sh" ]; then
    source "$(dirname "$0")/deploy-k8s-vars.sh"
fi

# ==================== 版本配置 ====================
K8S_VERSION="${K8S_VERSION:-v1.35.4}"
CRICTL_VERSION="${CRICTL_VERSION:-v1.35.0}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.0}"
HELM_VERSION="${HELM_VERSION:-v3.19.0}"
DASHBOARD_VERSION="${DASHBOARD_VERSION:-7.14.0}"

MIRROR_DOCKER="${MIRROR_DOCKER_ENDPOINT:-https://docker.1panel.live}"
MIRROR_QUAY="${MIRROR_QUAY_ENDPOINT:-https://quay.m.daocloud.io}"

# ==================== 路径配置 ====================
WORK_DIR="/tmp/k8s-offline-build"
ISO_DIR="${WORK_DIR}/k8s-offline"
RPMS_DIR="${ISO_DIR}/rpms"
IMAGES_DIR="${ISO_DIR}/images"
BINARIES_DIR="${ISO_DIR}/binaries"
MANIFESTS_DIR="${ISO_DIR}/manifests"
OUTPUT_ISO="/root/k8s-offline-repo.iso"

# ==================== 颜色 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 运行"
    exit 1
fi

# ==================== 1. 准备环境 ====================
prepare_env() {
    log_step "准备构建环境"

    rm -rf "$WORK_DIR"
    mkdir -p "$RPMS_DIR" "$IMAGES_DIR" "$BINARIES_DIR" "$MANIFESTS_DIR"

    dnf install -y dnf-plugins-core createrepo_c genisoimage wget tar gzip 2>/dev/null || true
    log_info "环境准备完成"
}

# ==================== GitHub 加速下载 ====================
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

# ==================== 2. 下载 RPM ====================
download_rpms() {
    log_step "下载 RPM 包"

    # Docker CE 仓库 (清华镜像)
    cat > /etc/yum.repos.d/docker-ce.repo << EOF
[docker-ce-stable]
name=Docker CE
baseurl=https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=0
timeout=30
EOF

    # Kubernetes 仓库 (无 GPG 检查，避免交互)
    cat > /etc/yum.repos.d/kubernetes-build.repo << 'EOF'
[kubernetes-build]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/
enabled=1
gpgcheck=0
EOF

    dnf makecache

    local pkg_list=(
        "containerd.io"
        "kubeadm"
        "kubelet"
        "kubectl"
    )

    for pkg in "${pkg_list[@]}"; do
        log_info "下载: ${pkg}"
        dnf download --destdir="$RPMS_DIR" "${pkg}.$(uname -m)" 2>/dev/null || \
        dnf download --destdir="$RPMS_DIR" "$pkg" 2>/dev/null || \
            log_warn "${pkg} 下载失败，跳过"
    done

    # 清理临时仓库
    rm -f /etc/yum.repos.d/kubernetes-build.repo
    dnf makecache

    log_info "RPM 下载完成 ($(ls "$RPMS_DIR"/*.rpm 2>/dev/null | wc -l) 个文件)"
}

# ==================== 3. 下载二进制 ====================
download_binaries() {
    log_step "下载二进制文件"

    cd "$BINARIES_DIR"

    # crictl
    log_info "下载 crictl ${CRICTL_VERSION}..."
    github_dl "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    tar -zxf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    cp crictl /usr/local/bin/crictl    # 当前系统用
    rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"

    # helm
    log_info "下载 helm ${HELM_VERSION}..."
    github_dl "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
    tar -zxf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
    cp linux-amd64/helm /usr/local/bin/helm
    mv linux-amd64/helm .
    rm -rf linux-amd64 "helm-${HELM_VERSION}-linux-amd64.tar.gz"
}

# ==================== 4. 下载清单 ====================
download_manifests() {
    log_step "下载 YAML 清单和 Chart"

    cd "$MANIFESTS_DIR"

    # Calico
    log_info "下载 Calico ${CALICO_VERSION}..."
    github_dl "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

    # Dashboard Chart (tgz + 解压)
    log_info "下载 Dashboard ${DASHBOARD_VERSION}..."
    local dashboard_url="https://github.com/kubernetes-retired/dashboard/releases/download/kubernetes-dashboard-${DASHBOARD_VERSION}/kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"
    local out="kubernetes-dashboard-${DASHBOARD_VERSION}.tgz"
    local dl_ok=0
    for u in \
        "https://gh-proxy.com/${dashboard_url}" \
        "https://ghproxy.net/${dashboard_url}" \
        "${dashboard_url}"; do
        if wget -q --timeout=30 -O "$out" "$u" 2>/dev/null; then dl_ok=1; break; fi
    done
    if [ $dl_ok -eq 1 ]; then
        tar -xzf "$out"
    else
        log_warn "Dashboard Chart 下载失败, 请手动下载到 ${MANIFESTS_DIR}/"
    fi

    log_info "清单下载完成"
}

# ==================== 5. 拉取并导出镜像 ====================
pull_and_export_images() {
    log_step "拉取并导出容器镜像"

    # 确保 containerd 镜像代理已配置
    if [ ! -f /etc/containerd/config.toml ]; then
        dnf install -y containerd.io
        containerd config default > /etc/containerd/config.toml
    fi
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml 2>/dev/null || true
    sed -i "s|sandbox = 'registry.k8s.io/pause:3.10.1'|sandbox = 'registry.aliyuncs.com/google_containers/pause:3.10.1'|g" /etc/containerd/config.toml 2>/dev/null || true
    local rl=$(grep -n "plugins.'io.containerd.cri.v1.images'.registry" /etc/containerd/config.toml | head -1 | cut -d: -f1)
    if ! grep -q "docker.1panel.live" /etc/containerd/config.toml 2>/dev/null; then
        sed -i "${rl}a\\
    [plugins.'io.containerd.cri.v1.images'.registry.mirrors]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"docker.io\"]\\
        endpoint = [\"${MIRROR_DOCKER}\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"quay.io\"]\\
        endpoint = [\"${MIRROR_QUAY}\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"gcr.io\"]\\
        endpoint = [\"https://gcr.m.daocloud.io\"]" /etc/containerd/config.toml
    fi
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable containerd --now 2>/dev/null || true
    systemctl restart containerd 2>/dev/null || true
    sleep 3

    # crictl 配置
    if [ ! -f /etc/crictl.yaml ]; then
        cat > /etc/crictl.yaml << 'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
debug: false
EOF
    fi

    # 拉取函数 (最多重试 3 次, 间隔 5s)
    try_pull() {
        local img="$1" tries=3 delay=5
        for ((i=1; i<=tries; i++)); do
            if crictl pull "$img" 2>/dev/null; then return 0; fi
            log_warn "  ${img} 拉取失败 (${i}/${tries}), ${delay}s 后重试..."
            sleep $delay
        done
        return 1
    }

    cd "$IMAGES_DIR"

    # 5.1 Kubeadm 组件镜像
    log_info "拉取 kubeadm 镜像..."
    local kubeadm_images=(
        "registry.aliyuncs.com/google_containers/kube-apiserver:${K8S_VERSION}"
        "registry.aliyuncs.com/google_containers/kube-controller-manager:${K8S_VERSION}"
        "registry.aliyuncs.com/google_containers/kube-scheduler:${K8S_VERSION}"
        "registry.aliyuncs.com/google_containers/kube-proxy:${K8S_VERSION}"
        "registry.aliyuncs.com/google_containers/etcd:3.6.6-0"
        "registry.aliyuncs.com/google_containers/coredns:v1.13.1"
        "registry.aliyuncs.com/google_containers/pause:3.10.1"
    )

    for img in "${kubeadm_images[@]}"; do
        local fname=$(echo "$img" | sed 's|[/:]|_|g').tar
        log_info "  ${img}"
        try_pull "$img" || { log_warn "拉取失败: ${img}"; continue; }
        sync; sleep 1
        ctr -n k8s.io images export "$fname" "$img" 2>/dev/null || log_warn "导出失败: ${img}"
    done

    # 5.2 Calico 镜像 (quay.io)
    log_info "拉取 Calico 镜像..."
    local calico_images=(
        "quay.io/calico/cni:${CALICO_VERSION}"
        "quay.io/calico/kube-controllers:${CALICO_VERSION}"
        "quay.io/calico/node:${CALICO_VERSION}"
    )

    for img in "${calico_images[@]}"; do
        local fname=$(echo "$img" | sed 's|[/:]|_|g').tar
        log_info "  ${img}"
        try_pull "$img" || { log_warn "拉取失败: ${img}"; continue; }
        sync; sleep 1
        ctr -n k8s.io images export "$fname" "$img" 2>/dev/null || log_warn "导出失败: ${img}"
    done

    # 5.3 Dashboard 镜像
    log_info "拉取 Dashboard 镜像..."
    local dashboard_images=(
        "docker.io/kubernetesui/dashboard-api:1.10.0"
        "docker.io/kubernetesui/dashboard-auth:1.4.0"
        "docker.io/kubernetesui/dashboard-metrics-scraper:1.2.0"
        "docker.io/kubernetesui/dashboard-web:1.7.0"
    )

    for img in "${dashboard_images[@]}"; do
        local fname=$(echo "$img" | sed 's|[/:]|_|g').tar
        log_info "  ${img}"
        try_pull "$img" || { log_warn "拉取失败: ${img}"; continue; }
        sync; sleep 1
        ctr -n k8s.io images export "$fname" "$img" 2>/dev/null || log_warn "导出失败: ${img}"
    done

    # 5.4 Kong 网关 (Dashboard 依赖)
    log_info "拉取 Kong 网关..."
    local kong_img="docker.io/library/kong:3.9"
    local kong_fname="kong_3.9.tar"
    if try_pull "$kong_img" 2>/dev/null; then
        ctr -n k8s.io images export "$kong_fname" "$kong_img" 2>/dev/null || log_warn "导出失败: ${kong_img}"
        log_info "  kong:3.9  OK"
    else
        log_warn "Kong 拉取失败，跳过"
    fi

    # nginx 离线不需要，跳过

    log_info "镜像导出完成 ($(ls "$IMAGES_DIR"/*.tar 2>/dev/null | wc -l) 个文件)"
}

# ==================== 6. 生成 RPM 仓库元数据 ====================
create_repo_metadata() {
    log_step "生成 RPM 仓库元数据 (createrepo)"
    createrepo_c "$RPMS_DIR" 2>/dev/null || createrepo "$RPMS_DIR" 2>/dev/null || {
        log_warn "createrepo 失败，ISO 将无 repodata"
    }
    log_info "repodata 已生成"
}

# ==================== 7. 生成 ISO ====================
create_iso() {
    log_step "生成 ISO 文件"

    # 生成简洁的导入脚本
    cat > "${IMAGES_DIR}/import-all.sh" << 'EOF'
#!/bin/bash
# 批量导入所有镜像到 containerd
for tar in /mnt/k8s-offline/images/*.tar; do
    [ -s "$tar" ] || continue
    echo "导入: $(basename $tar)"
    ctr -n k8s.io images import "$tar"
done
echo "全部导入完成"
EOF
    chmod +x "${IMAGES_DIR}/import-all.sh"

    cd "$WORK_DIR"
    mkisofs -o "$OUTPUT_ISO" -R -J -V "K8S_OFFLINE" k8s-offline/ 2>/dev/null || {
        log_error "mkisofs 失败，请确认 genisoimage 已安装"
        exit 1
    }

    local iso_size=$(du -h "$OUTPUT_ISO" | cut -f1)
    log_info "ISO 已生成: ${OUTPUT_ISO} (${iso_size})"
}

# ==================== 8. 清理 ====================
cleanup() {
    log_step "清理临时文件"
    rm -rf "$WORK_DIR"
    log_info "清理完成"
}

# ==================== 主流程 ====================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   K8s 离线 ISO 构建脚本                                     ║"
    echo "║   输出: /root/k8s-offline-repo.iso                          ║"
    echo "║   需要: 互联网连接 + ~5GB 磁盘空间                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    prepare_env
    download_rpms
    download_binaries
    download_manifests
    pull_and_export_images
    create_repo_metadata
    create_iso
    cleanup

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ISO 构建完成!                                              ║"
    echo "║  文件: /root/k8s-offline-repo.iso                          ║"
    echo "║  用法: bash deploy-k8s-cluster.sh → 选择离线模式            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

main
