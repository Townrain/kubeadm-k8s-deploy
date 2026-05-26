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
CRI_DOCKERD_VERSION="${CRI_DOCKERD_VERSION:-0.3.21}"

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

    # 配置 Docker CE 仓库并安装 containerd + docker (镜像拉取需要)
    if ! command -v containerd &>/dev/null || ! command -v docker &>/dev/null; then
        cat > /etc/yum.repos.d/docker-ce-tmp.repo << EOF
[docker-ce-stable]
name=Docker CE
baseurl=https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=0
timeout=30
EOF
        dnf makecache --repo=docker-ce-stable 2>/dev/null || true
        dnf install -y containerd.io 2>/dev/null || log_warn "containerd 安装失败"
        # Docker 用于拉取镜像 (有镜像加速)
        if ! command -v docker &>/dev/null; then
            log_info "安装 Docker (用于镜像拉取)..."
            dnf install -y docker-ce docker-ce-cli 2>/dev/null || log_warn "Docker 安装失败，将使用 containerd"
        fi
        rm -f /etc/yum.repos.d/docker-ce-tmp.repo 2>/dev/null || true
    fi

    # 配置 Docker daemon 镜像加速
    if command -v docker &>/dev/null && [ ! -f /etc/docker/daemon.json ]; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << EOF
{
    "exec-opts": ["native.cgroupdriver=systemd"],
    "registry-mirrors": [
        "${MIRROR_DOCKER}",
        "https://docker.m.daocloud.io",
        "https://hub-mirror.c.163.com",
        "https://dockerhub.icu",
        "https://dockerproxy.com"
    ]
}
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable docker --now 2>/dev/null || true
        systemctl restart docker 2>/dev/null || true
        sleep 2
    fi

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

    # Docker CE 仓库
    cat > /etc/yum.repos.d/docker-ce-build.repo << EOF
[docker-ce-stable]
name=Docker CE
baseurl=https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=0
timeout=30
EOF

    # Kubernetes 仓库 (无 GPG 检查，避免交互) - 国内镜像优先
    local k8s_repo_ok=0
    for baseurl in \
        "https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.35/rpm/" \
        "https://mirrors.tuna.tsinghua.edu.cn/kubernetes/core:/stable:/v1.35/rpm/" \
        "https://mirrors.ustc.edu.cn/kubernetes/core:/stable:/v1.35/rpm/" \
        "https://pkgs.k8s.io/core:/stable:/v1.35/rpm/"; do
        cat > /etc/yum.repos.d/kubernetes-build.repo << EOF
[kubernetes-build]
name=Kubernetes
baseurl=${baseurl}
enabled=1
gpgcheck=0
timeout=30
EOF
        if dnf makecache --repo=kubernetes-build 2>/dev/null; then
            log_info "Kubernetes 仓库 OK: ${baseurl}"
            k8s_repo_ok=1
            break
        fi
    done
    [ "$k8s_repo_ok" -eq 0 ] && { log_error "所有 Kubernetes 镜像源失败"; exit 1; }

    # 检测当前系统版本并构建目标版本列表
    local current_ver
    current_ver=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d'"' -f2 | cut -d'.' -f1 || echo "9")
    local target_versions=("$current_ver")
    # 自动添加另一个版本
    if [ "$current_ver" -eq 9 ]; then
        target_versions+=("10")
    elif [ "$current_ver" -eq 10 ]; then
        target_versions+=("9")
    fi

    local pkg_list=(
        "containerd.io"
        "docker-ce"
        "docker-ce-cli"
        "container-selinux"
        "kubeadm"
        "kubelet"
        "kubectl"
    )

    for ver in "${target_versions[@]}"; do
        log_info "下载 CentOS Stream ${ver} RPM 包..."
        local ver_failed=0
        for pkg in "${pkg_list[@]}"; do
            # OS 绑定包: 使用 --releasever 指定版本
            if [ "$pkg" = "containerd.io" ] || [ "$pkg" = "docker-ce" ] || [ "$pkg" = "docker-ce-cli" ] || [ "$pkg" = "container-selinux" ]; then
                if ! (dnf download --destdir="$RPMS_DIR" --releasever="$ver" "${pkg}.$(uname -m)" 2>/dev/null || \
                      dnf download --destdir="$RPMS_DIR" --releasever="$ver" "$pkg" 2>/dev/null); then
                    log_error "  ${pkg} (el${ver}) 下载失败"
                    ver_failed=1
                fi
            else
                # Kubernetes 包: distro-agnostic，只下载一次
                if [ "$ver" = "$current_ver" ]; then
                    if ! (dnf download --destdir="$RPMS_DIR" "${pkg}.$(uname -m)" 2>/dev/null || \
                          dnf download --destdir="$RPMS_DIR" "$pkg" 2>/dev/null); then
                        log_error "  ${pkg} 下载失败"
                        ver_failed=1
                    fi
                fi
            fi
        done
        # 验证关键 RPM 是否下载成功
        if [ "$ver_failed" -eq 1 ]; then
            log_error "CentOS Stream ${ver} 部分 RPM 下载失败，ISO 可能不完整"
            log_error "请检查网络连接和镜像源后重试"
            exit 1
        fi
    done

    # 清理临时仓库
    rm -f /etc/yum.repos.d/kubernetes-build.repo /etc/yum.repos.d/docker-ce-build.repo
    dnf makecache 2>/dev/null || true

    log_info "RPM 下载完成 ($(ls "$RPMS_DIR"/*.rpm 2>/dev/null | wc -l || echo 0) 个文件)"
}

# ==================== 3. 下载二进制 ====================
download_binaries() {
    log_step "下载二进制文件"

    cd "$BINARIES_DIR"

    # crictl
    log_info "下载 crictl ${CRICTL_VERSION}..."
    if github_dl "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"; then
        tar -zxf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
        cp crictl /usr/local/bin/crictl    # 当前系统用
        rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    else
        log_warn "crictl 下载失败"
    fi

    # helm (国内镜像优先)
    log_info "下载 helm ${HELM_VERSION}..."
    local helm_downloaded=0
    for helm_url in \
        "https://mirrors.aliyun.com/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
        "https://mirror.tuna.tsinghua.edu.cn/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"; do
        if wget -q --timeout=30 -O "helm-${HELM_VERSION}-linux-amd64.tar.gz" "$helm_url" 2>/dev/null; then
            helm_downloaded=1
            break
        fi
    done
    if [ "$helm_downloaded" -eq 1 ]; then
        tar -zxf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
        cp linux-amd64/helm /usr/local/bin/helm
        mv linux-amd64/helm .
        rm -rf linux-amd64 "helm-${HELM_VERSION}-linux-amd64.tar.gz"
    else
        log_warn "helm 下载失败"
    fi

    # cri-dockerd (可选，仅 Docker 运行时需要)
    CRI_DOCKERD_VERSION="${CRI_DOCKERD_VERSION:-0.3.21}"
    log_info "下载 cri-dockerd ${CRI_DOCKERD_VERSION} (可选，Docker 运行时)..."
    local cri_dockerd_url="https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"
    if github_dl "$cri_dockerd_url" "cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"; then
        tar -xzf "cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"
        # 正确处理解压结果：可能是单文件或多个文件
        if [ ! -d "cri-dockerd" ]; then
            # 解压出单个文件
            chmod +x cri-dockerd 2>/dev/null || true
        else
            # 解压出目录，提取二进制后删除目录
            local found_bin
            found_bin=$(find cri-dockerd -name "cri-dockerd" -type f 2>/dev/null | head -1) || true
            if [ -n "$found_bin" ]; then
                mv "$found_bin" cri-dockerd.bin 2>/dev/null
                rm -rf cri-dockerd
                mv cri-dockerd.bin cri-dockerd 2>/dev/null
                chmod +x cri-dockerd 2>/dev/null || true
            fi
        fi
        rm -f "cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz"
        log_info "cri-dockerd ${CRI_DOCKERD_VERSION} 下载完成"
    else
        log_warn "cri-dockerd 下载失败 (Docker 运行时需要，containerd 不需要)"
    fi
    log_info "二进制下载完成 ($(ls "$BINARIES_DIR"/* 2>/dev/null | wc -l || echo 0) 个文件)"
}

# ==================== 4. 下载清单 ====================
download_manifests() {
    log_step "下载 YAML 清单和 Chart"

    cd "$MANIFESTS_DIR"

    # Calico
    log_info "下载 Calico ${CALICO_VERSION}..."
    github_dl "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" || {
        log_warn "Calico 下载失败，请手动放到 ${MANIFESTS_DIR}/calico.yaml"
    }

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
        # 确保 Docker CE 仓库存在
        if ! dnf repolist --enabled 2>/dev/null | grep -q docker; then
            cat > /etc/yum.repos.d/docker-ce-tmp.repo << EOF
[docker-ce-stable]
name=Docker CE
baseurl=https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=0
timeout=30
EOF
            dnf makecache --repo=docker-ce-stable 2>/dev/null || true
        fi
        dnf install -y containerd.io 2>/dev/null || log_warn "containerd 安装失败"
        rm -f /etc/yum.repos.d/docker-ce-tmp.repo 2>/dev/null || true
        containerd config default > /etc/containerd/config.toml
    fi
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml 2>/dev/null || true
    sed -i "s|sandbox = 'registry.k8s.io/pause:3.10.1'|sandbox = 'registry.aliyuncs.com/google_containers/pause:3.10.1'|g" /etc/containerd/config.toml 2>/dev/null || true
    local rl
    rl=$(grep -n "plugins.'io.containerd.cri.v1.images'.registry" /etc/containerd/config.toml | head -1 | cut -d: -f1 || echo "")
    if [ -n "$rl" ] && ! grep -q "docker.1panel.live" /etc/containerd/config.toml 2>/dev/null; then
        sed -i "${rl}a\\
    [plugins.'io.containerd.cri.v1.images'.registry.mirrors]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"docker.io\"]\\
        endpoint = [\"${MIRROR_DOCKER}\", \"https://docker.m.daocloud.io\", \"https://hub-mirror.c.163.com\", \"https://dockerhub.icu\", \"https://dockerproxy.com\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"quay.io\"]\\
        endpoint = [\"${MIRROR_QUAY}\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"gcr.io\"]\\
        endpoint = [\"https://gcr.m.daocloud.io\"]" /etc/containerd/config.toml
    fi
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable containerd --now 2>/dev/null || true
    systemctl restart containerd 2>/dev/null || true
    sleep 3

    # crictl 配置 (强制指向 containerd)
    cat > /etc/crictl.yaml << 'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
debug: false
EOF

    # 拉取函数 (最多重试 3 次, 间隔 5s)
    try_pull() {
        local img="$1" tries=3 delay=5
        # 优先用 docker (有镜像加速)，回退 crictl
        if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null 2>&1; then
            for ((i=1; i<=tries; i++)); do
                if timeout 180 docker pull "$img" 2>/dev/null; then return 0; fi
                log_warn "  ${img} docker 拉取失败 (${i}/${tries}), ${delay}s 后重试..."
                sleep $delay
            done
        fi
        # 回退 containerd/crictl
        for ((i=1; i<=tries; i++)); do
            if timeout 180 crictl pull "$img" 2>/dev/null; then return 0; fi
            log_warn "  ${img} crictl 拉取失败 (${i}/${tries}), ${delay}s 后重试..."
            sleep $delay
        done
        return 1
    }

    cd "$IMAGES_DIR"

    # 导出函数: 自动适配 docker save / ctr export
    export_img() {
        local img="$1" fname="$2"
        # docker 优先
        if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null 2>&1; then
            if docker image inspect "$img" &>/dev/null 2>&1; then
                docker save "$img" -o "$fname" 2>/dev/null && return 0
            fi
        fi
        # 回退 containerd
        ctr -n k8s.io images export "$fname" "$img" 2>/dev/null && return 0
        return 1
    }

    # 5.1 Kubeadm 组件镜像: 优先用 kubeadm，回退多个镜像源
    log_info "拉取 kubeadm 镜像..."

    # 确保 Docker 可用 (优先使用 Docker，有镜像加速)
    local use_docker=0
    if command -v docker &>/dev/null; then
        systemctl start docker 2>/dev/null || true
        sleep 2
        if docker info &>/dev/null 2>&1; then
            use_docker=1
            log_info "使用 Docker 拉取镜像"
        fi
    fi
    if [ $use_docker -eq 0 ]; then
        log_info "使用 crictl/containerd 拉取镜像"
    fi

    # 用 kubeadm 拉取 kubeadm 镜像 (Docker 运行时可用时更可靠)
    local pull_ok=0
    if [ $use_docker -eq 1 ] && command -v kubeadm &>/dev/null; then
        local tmp_conf="/tmp/kubeadm-build-config.yaml"
        cat > "$tmp_conf" << EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
imageRepository: registry.aliyuncs.com/google_containers
EOF
        if timeout 120 kubeadm config images pull --config "$tmp_conf" --cri-socket unix:///var/run/docker.sock 2>/dev/null; then
            pull_ok=1
            log_info "kubeadm 镜像拉取成功"
        else
            log_warn "kubeadm 拉取超时或失败"
        fi
        rm -f "$tmp_conf" 2>/dev/null || true
    fi

    # 检测可用镜像源
    local try_mirrors=(
        "registry.aliyuncs.com/google_containers"
        "registry.cn-hangzhou.aliyuncs.com/google_containers"
    )
    local mirror_ok=""
    if [ $use_docker -eq 1 ]; then
        for mirror in "${try_mirrors[@]}"; do
            if timeout 60 docker pull "${mirror}/pause:3.10.1" 2>/dev/null | grep -qE "(Downloaded|up to date)"; then
                mirror_ok="$mirror"
                log_info "镜像源可用: ${mirror}"
                break
            fi
        done
    fi
    [ -z "$mirror_ok" ] && mirror_ok="registry.aliyuncs.com/google_containers"

    log_info "使用镜像源: ${mirror_ok}"

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
        local fname mirror_img
        fname=$(echo "$img" | sed 's|[/:]|_|g').tar || true
        # 替换镜像前缀为可用源
        mirror_img=$(echo "$img" | sed "s|registry.aliyuncs.com/google_containers|${mirror_ok}|")
        if [ $pull_ok -eq 0 ]; then
            log_info "  ${mirror_img}"
            try_pull "$mirror_img" || { log_warn "拉取失败: ${mirror_img}"; continue; }
        fi
        # 如果镜像源不同，tag 为部署时用的名字
        if [ "$mirror_ok" != "registry.aliyuncs.com/google_containers" ]; then
            docker tag "$mirror_img" "$img" 2>/dev/null || ctr -n k8s.io images tag "$mirror_img" "$img" 2>/dev/null || true
        fi
        sync; sleep 1
        export_img "$img" "$fname" || log_warn "导出失败: ${img}"
    done

    # 5.2 Calico 镜像 (quay.io)
    log_info "拉取 Calico 镜像..."
    local calico_images=(
        "quay.io/calico/cni:${CALICO_VERSION}"
        "quay.io/calico/kube-controllers:${CALICO_VERSION}"
        "quay.io/calico/node:${CALICO_VERSION}"
    )

    for img in "${calico_images[@]}"; do
        local fname
        fname=$(echo "$img" | sed 's|[/:]|_|g').tar || true
        log_info "  ${img}"
        try_pull "$img" || { log_warn "拉取失败: ${img}"; continue; }
        sync; sleep 1
        export_img "$img" "$fname" || log_warn "导出失败: ${img}"
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
        local fname
        fname=$(echo "$img" | sed 's|[/:]|_|g').tar || true
        log_info "  ${img}"
        try_pull "$img" || { log_warn "拉取失败: ${img}"; continue; }
        sync; sleep 1
        export_img "$img" "$fname" || log_warn "导出失败: ${img}"
    done

    # 5.4 Kong 网关 (Dashboard 依赖)
    log_info "拉取 Kong 网关..."
    local kong_img="docker.io/library/kong:3.9"
    local kong_fname="kong_3.9.tar"
    if try_pull "$kong_img" 2>/dev/null; then
        export_img "$kong_img" "$kong_fname" || log_warn "导出失败: ${kong_img}"
        log_info "  kong:3.9  OK"
    else
        log_warn "Kong 拉取失败，跳过"
    fi

    # nginx 离线不需要，跳过

    log_info "镜像导出完成 ($(ls "$IMAGES_DIR"/*.tar 2>/dev/null | wc -l || echo 0) 个文件)"
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
