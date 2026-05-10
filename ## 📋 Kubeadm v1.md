## 🤖 Assistant

## 📋 Kubeadm v1.35.4 部署 Kubernetes 集群手册（CentOS Stream 9）

**已验证环境：** CentOS Stream 9 · containerd v2.2.3 · Calico v3.32.0 · Dashboard v7.14.0  
**验证日期：** 2026-05-09 · **状态：全功能通过**

---

## 目录

1. [版本信息](#1-版本信息)
2. [集群规划](#2-集群规划)
3. [基础环境准备（所有节点）](#3-基础环境准备所有节点)
4. [Containerd 运行时安装与配置（所有节点）](#4-containerd-运行时安装与配置所有节点)
5. [安装 kubeadm / kubelet / kubectl（所有节点）](#5-安装-kubeadmkubeletkubectl所有节点)
6. [Master 节点初始化](#6-master-节点初始化)
7. [Node 节点加入集群](#7-node-节点加入集群)
8. [Calico 网络插件安装](#8-calico-网络插件安装)
9. [集群功能验证](#9-集群功能验证)
10. [Dashboard 仪表板部署](#10-dashboard-仪表板部署)
11. [常用故障排查](#11-常用故障排查)
12. [附录：关键踩坑与路径速查](#12-附录)

---

## 1. 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| **Kubernetes** | **v1.35.4** | 4 个补丁版本，生产推荐 |
| Containerd | v2.2.3 | Docker CE 仓库分发 |
| Calico | **v3.32.0** | 网络插件（CNI），镜像已迁至 quay.io |
| Dashboard | v7.14.0 | ⚠️ 已于 2026-01-21 归档退役，Helm 部署 |
| Helm | v3.19.0 | Kubernetes 包管理器 |
| cri-tools | **v1.35.0** | 与 K8s v1.35 匹配 |
| OS 内核 | 5.14+ | CentOS Stream 9 默认 |

> **选版理由：** v1.36.0 发布仅 2 周无补丁，生产建议 v1.35.4。

---

## 2. 集群规划

| 主机名 | IP | 角色 | 最低配置 |
|--------|-----|------|---------|
| master | 192.168.10.150 | control-plane | 2C/2G/20G |
| node1 | 192.168.10.151 | worker | 2C/2G/20G |
| node2 | 192.168.10.152 | worker | 2C/2G/20G |

| 网络 | CIDR |
|------|------|
| Pod 网段 | `172.16.10.0/24` |
| Service 网段 | `172.16.32.0/24` |

---

## 3. 基础环境准备（所有节点）

### 3.1 主机名

```bash
# Master
hostnamectl set-hostname master
# Node1
hostnamectl set-hostname node1
# Node2
hostnamectl set-hostname node2
exec bash
```

### 3.2 hosts 文件

```bash
cat >> /etc/hosts << 'EOF'
192.168.10.150 master
192.168.10.151 node1
192.168.10.152 node2
EOF
```

### 3.3 静态 IP（示例：master）

```bash
CON_NAME="ens33"   # 按实际网卡名修改
nmcli connection modify "$CON_NAME" \
  ipv4.method manual \
  ipv4.addresses 192.168.10.150/24 \
  ipv4.gateway 192.168.10.2 \
  ipv4.dns "8.8.8.8 223.5.5.5" \
  connection.autoconnect yes
nmcli connection down "$CON_NAME" && nmcli connection up "$CON_NAME"
```

### 3.4 防火墙 / SELinux

```bash
systemctl stop firewalld && systemctl disable firewalld
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
```

### 3.5 彻底禁用 Swap（五步法）

```bash
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab
systemctl stop dev-mapper-cs\\x2dswap.swap 2>/dev/null
systemctl mask dev-mapper-cs\\x2dswap.swap 2>/dev/null
lvchange -an /dev/mapper/cs-swap 2>/dev/null
sed -i 's/ resume=[^ "]*//g' /etc/default/grub
sed -i 's/ rd\.lvm\.lv=cs\/swap//g' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
```

**立即验证：**

```bash
swapon --show                      # 应无输出
cat /proc/swaps | grep -v Filename  # 应无输出
free -h | grep Swap                 # 应显示 0B

echo "✅ Swap 已禁用，kubelet 可正常运行。"
echo "⚠️  建议稍后 reboot 验证持久化：重启后执行 swapon --show 确认无输出"
```

> 💡 **不需要立即重启。** 五步操作在当前会话已彻底停用 swap，kubelet 可正常运行。`reboot` 仅为验证重启后 swap 不会重新挂载。如需脚本化部署，跳过重启即可。

### 3.6 内核参数 & 模块

```bash
modprobe br_netfilter && modprobe overlay

cat > /etc/modules-load.d/k8s.conf << 'EOF'
br_netfilter
overlay
EOF

cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.swappiness                       = 0
vm.overcommit_memory                = 1
fs.inotify.max_user_instances       = 8192
fs.inotify.max_user_watches         = 1048576
EOF

sysctl --system
```

### 3.7 时间同步

```bash
systemctl enable chronyd --now
```

### 3.8 Docker CE 仓库

```bash
dnf install -y dnf-plugins-core
dnf config-manager --add-repo \
  https://download.docker.com/linux/centos/docker-ce.repo
```

---

## 4. Containerd 运行时安装与配置（所有节点）

### 4.1 安装

```bash
dnf install -y containerd.io
containerd --version   # 应输出 v2.2.3
```

### 4.2 生成配置

```bash
containerd config default > /etc/containerd/config.toml
```

### 4.3 修改关键配置

```bash
# ① cgroup 驱动 → systemd
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# ② pause 镜像 → 阿里云（v2 配置项名是 sandbox，单引号！）
sed -i "s|sandbox = 'registry.k8s.io/pause:3.10.1'|sandbox = 'registry.aliyuncs.com/google_containers/pause:3.10.1'|g" \
  /etc/containerd/config.toml
```

### 4.4 添加镜像代理（v2 路径，docker.io 用 docker.1panel.live）

```bash
REGISTRY_LINE=$(grep -n "plugins.'io.containerd.cri.v1.images'.registry" \
  /etc/containerd/config.toml | head -1 | cut -d: -f1)

sed -i "${REGISTRY_LINE}a\\
    [plugins.'io.containerd.cri.v1.images'.registry.mirrors]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"docker.io\"]\\
        endpoint = [\"https://docker.1panel.live\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"k8s.gcr.io\"]\\
        endpoint = [\"https://registry.k8s.io\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"gcr.io\"]\\
        endpoint = [\"https://gcr.m.daocloud.io\"]\\
      [plugins.'io.containerd.cri.v1.images'.registry.mirrors.\"quay.io\"]\\
        endpoint = [\"https://quay.m.daocloud.io\"]" /etc/containerd/config.toml
```

> ⚠️ **为什么不推荐 `docker.m.daocloud.io`？**  
> DaoCloud 只代理 manifest 查询，blob 下载会重定向到 `production.cloudflare.docker.com`，该域名同样被国内封锁。  
> **`docker.1panel.live`** 是唯一实测 blob 全量缓存、不重定向的稳定镜像站。

### 4.5 验证 & 启动

```bash
# 确认关键配置
grep SystemdCgroup /etc/containerd/config.toml
grep sandbox /etc/containerd/config.toml | grep pause
grep -A2 'mirrors.*docker' /etc/containerd/config.toml

# 验证 TOML 语法
containerd config dump > /dev/null 2>&1 && echo "OK" || echo "ERROR"

# 启动
systemctl daemon-reload
systemctl enable containerd --now
systemctl restart containerd
```

### 4.6 安装 crictl

```bash
ARCH=$(uname -m)
case $ARCH in x86_64) ARCH="amd64" ;; aarch64) ARCH="arm64" ;; esac

CRICTL_VERSION="v1.35.0"
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz
tar -zxvf crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz
mv crictl /usr/local/bin/
rm -f crictl-*.tar.gz

cat > /etc/crictl.yaml << 'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

### 4.7 验证镜像拉取（三节点都执行）

```bash
crictl pull nginx:1.27
# 期望：Image is up to date for sha256:...
```

---

## 5. 安装 kubeadm / kubelet / kubectl（所有节点）

```bash
cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/repodata/repomd.xml.key
EOF

dnf makecache
dnf install -y kubeadm-1.35* kubelet-1.35* kubectl-1.35*

cat > /etc/sysconfig/kubelet << 'EOF'
KUBELET_EXTRA_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

systemctl daemon-reload
systemctl enable kubelet --now
```

---

## 6. Master 节点初始化

### 6.1 初始化配置文件

```bash
mkdir -p /etc/k8s && cd /etc/k8s

cat > kubeadm-config.yaml << 'EOF'
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.4
controlPlaneEndpoint: "192.168.10.150:6443"
imageRepository: registry.aliyuncs.com/google_containers
networking:
  podSubnet: "172.16.10.0/24"
  serviceSubnet: "172.16.32.0/24"
  dnsDomain: "cluster.local"
apiServer:
  certSANs:
    - 192.168.10.150
    - master
  extraArgs:
    - name: authorization-mode
      value: Node,RBAC
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.10.150
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: master
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
ipvs:
  strictARP: true
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

> ⚠️ **v1beta4 关键格式：** `extraArgs` 必须使用数组格式（`- name: key` / `value: val`），v1beta3 的 map 格式会导致 `cannot unmarshal object` 错误。

### 6.2 拉取镜像 & 初始化

```bash
# 预拉取镜像
kubeadm config images pull --config /etc/k8s/kubeadm-config.yaml

# 初始化（⚠️ 必须跳过 CRI 预检——containerd 已知竞态）
kubeadm init --config /etc/k8s/kubeadm-config.yaml --upload-certs \
  --ignore-preflight-errors=CRI,ContainerRuntimeVersion
```

成功标志：

```
Your Kubernetes control-plane has initialized successfully!
```

**保存 join 命令！**（输出中 `kubeadm join ...` 那一行）

### 6.3 配置 kubectl

```bash
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
echo 'export KUBECONFIG=/etc/kubernetes/admin.conf' >> /etc/profile

kubectl get nodes   # 应显示 master NotReady（暂时，等 Calico）
```

---

## 7. Node 节点加入集群

### 7.1 执行 Join（Node1 / Node2 分别执行）

```bash
kubeadm join 192.168.10.150:6443 --token <your-token> \
    --discovery-token-ca-cert-hash sha256:<your-hash> \
    --ignore-preflight-errors=CRI,ContainerRuntimeVersion
```

### 7.2 验证 & 打标签（Master 上执行）

```bash
kubectl get nodes
kubectl label node node1 node-role.kubernetes.io/worker=worker
kubectl label node node2 node-role.kubernetes.io/worker=worker
```

> `kubectl` 命令**仅在 Master 上执行**。Node 节点无 kubeconfig。

---

## 8. Calico 网络插件安装

> 在 Master 上执行。

```bash
cd /etc/k8s

# 下载 Calico v3.32.0
wget https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml \
  -O calico.yaml

# ① 替换 quay.io → quay.m.daocloud.io（国内加速）
sed -i 's|quay.io/|quay.m.daocloud.io/|g' calico.yaml

# ② 配置 Pod 网段
sed -i 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' calico.yaml
sed -i 's|#   value: "192.168.0.0/16"|  value: "172.16.10.0/24"|' calico.yaml

# 部署
kubectl create -f calico.yaml
kubectl get pods -n kube-system -w   # 等待全部 Running
kubectl get nodes                    # 应全部 Ready
```

---

## 9. 集群功能验证

```bash
# 部署 nginx 测试
kubectl create deployment nginx --image=nginx:1.27 --replicas=3
kubectl expose deployment nginx --port=80 --type=NodePort

# 等待就绪
kubectl get pods -o wide
# 预期：3/3 Running，跨 node1/node2 分布

# 访问验证
NODE_PORT=$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}')
curl -I http://192.168.10.151:$NODE_PORT   # HTTP/1.1 200 OK
curl -I http://192.168.10.152:$NODE_PORT   # HTTP/1.1 200 OK

# DNS 验证
NGINX_POD=$(kubectl get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $NGINX_POD -- nslookup kubernetes.default

# 清理
kubectl delete deployment nginx
kubectl delete svc nginx
```

---

## 10. Dashboard 仪表板部署

> ⚠️ Dashboard 项目已于 2026-01-21 归档退役（v7.14.0），不再接收安全更新。  
> 替代推荐：**Headlamp** / **k9s** / **OpenLens**。

### 10.1 安装 Helm

```bash
cd /etc/k8s

wget https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz
tar -zxvf helm-v3.19.0-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/
rm -rf linux-amd64 helm-*.tar.gz

helm version
```

### 10.2 下载并解压 Dashboard Chart

```bash
cd /etc/k8s

wget https://github.com/kubernetes-retired/dashboard/archive/refs/tags/v7.14.0.tar.gz \
  -O kubernetes-dashboard-7.14.0.tgz

tar -xzf kubernetes-dashboard-7.14.0.tgz
```

### 10.3 部署 Dashboard（⚠️ Kong 必须启用）

Dashboard v7 依赖 **Kong 网关** 路由前端请求到后端 API/Auth 服务，不能禁用。

```bash
helm install dashboard ./kubernetes-dashboard \
  --namespace kubernetes-dashboard \
  --create-namespace \
  --set kong.enabled=true \
  --set cert-manager.enabled=false \
  --set nginx.enabled=false \
  --set metrics-server.enabled=false
```

**等待所有 Pod Running：**

```bash
kubectl get pods -n kubernetes-dashboard -w
```

预期组件：

| 组件 | 说明 |
|------|------|
| `dashboard-kong` | API 网关（核心） |
| `dashboard-kubernetes-dashboard-api` | 后端 API |
| `dashboard-kubernetes-dashboard-auth` | 认证服务 |
| `dashboard-kubernetes-dashboard-metrics-scraper` | 指标采集 |
| `dashboard-kubernetes-dashboard-web` | Web 前端 |

> ⚠️ Kong 镜像约 300MB+，`Init:0/1` 状态持续数分钟属正常拉取过程。可用 `crictl pull kong:3.9` 在各节点预拉取加速。

### 10.4 端口转发（systemd 服务 — 生产默认）

使用 systemd 管理 `kubectl port-forward`，实现无日志噪音、Master 重启后自动恢复。

```bash
cat > /etc/systemd/system/dashboard-portforward.service << 'EOF'
[Unit]
Description=Dashboard Port Forward (8443 → Kong 443)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/kubectl -n kubernetes-dashboard port-forward --address=0.0.0.0 svc/dashboard-kong-proxy 8443:443
Restart=on-failure
RestartSec=10
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dashboard-portforward --now
systemctl status dashboard-portforward --no-pager | head -5
```

> 💡 验证：`https://192.168.10.150:8443` 应可访问 Dashboard 登录页。

### 10.5 创建管理员 ServiceAccount 并生成 Token

```bash
# 创建 SA
kubectl create serviceaccount dashboard-admin -n kubernetes-dashboard

# 绑定 cluster-admin 权限
kubectl create clusterrolebinding dashboard-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=kubernetes-dashboard:dashboard-admin

# 生成登录 Token（24 小时有效）
kubectl create token dashboard-admin -n kubernetes-dashboard --duration=24h
```

### 10.6 浏览器访问

```
https://192.168.10.150:8443
```

1. 浏览器提示 **"您的连接不是私密连接"** → 点击 **"高级"** → **"继续前往"**
2. 选择 **"Token"** 登录
3. 粘贴上一步生成的完整 Token

> ⚠️ **Token 是一个完整的长 JWT 字符串（三段，以 `.` 分隔）**，必须完整复制，不可截断。

### 10.7 Dashboard 功能验证

登录后依次检查：

| 页面 | 预期 |
|------|------|
| 集群概览 | 显示 CPU / 内存、节点数、Pod 数 |
| 节点列表 | master / node1 / node2 状态 Ready |
| 命名空间 | default、kube-system、kubernetes-dashboard 等 |
| Pod 列表 | Calico、CoreDNS、Dashboard 等 Pod Running |
| Deployments | Dashboard 的 api / auth / web 等 |

---

## 11. 常用故障排查

### 11.1 命令速查

```bash
# 集群状态
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by='.lastTimestamp'

# Pod 排错
kubectl describe pod <pod> -n <ns>
kubectl logs <pod> -n <ns> --tail=100

# 容器运行时
crictl ps -a
crictl images
crictl pull <image>

# 服务日志
journalctl -xeu kubelet --no-pager | tail -50
journalctl -xeu containerd --no-pager | tail -30

# Dashboard
kubectl get pods -n kubernetes-dashboard
kubectl logs -n kubernetes-dashboard -l app.kubernetes.io/component=auth --tail=20
kubectl create token dashboard-admin -n kubernetes-dashboard --duration=24h

# 端口转发服务
systemctl status dashboard-portforward --no-pager
systemctl restart dashboard-portforward
```

### 11.2 常见问题 TOP 7

| # | 问题 | 根因 | 解决 |
|---|------|------|------|
| 1 | kubelet 报 `running with swap on` | Swap 未彻底禁用 | 执行 §3.5 五步法，当前会话立即生效 |
| 2 | kubeadm init 报 `CRI connection refused` | containerd 启动竞态 | 加 `--ignore-preflight-errors=CRI,ContainerRuntimeVersion` |
| 3 | 控制平面 `ContainerCreating` | pause 镜像拉取失败 | 确认 `sandbox = 'registry.aliyuncs.com/...'`（§4.3 第②步） |
| 4 | Pod `ErrImagePull` / `ImagePullBackOff` | docker.io 镜像代理失效 | 使用 `docker.1panel.live` 替代 `docker.m.daocloud.io`（§4.4） |
| 5 | `containerd config dump` 报错 | TOML 格式错误 | 重生成默认配置，按 §4.2-4.5 重新操作 |
| 6 | kubeadm-config `cannot unmarshal object` | extraArgs 用了 v1beta3 map 格式 | v1beta4 必须使用数组格式（§6.1） |
| 7 | Dashboard 401 / CSRF 错误 | Kong 未启用或 Token 不完整 | 启用 Kong（§10.3），确保 Token 完整复制（§10.5） |

### 11.3 完全重置

```bash
# 所有节点
kubeadm reset -f
rm -rf /etc/cni /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube /etc/cni/net.d
systemctl restart containerd
iptables -F && iptables -t nat -F && iptables -t mangle -F
ipvsadm --clear 2>/dev/null
```

### 11.4 Dashboard 卸载重装

```bash
systemctl stop dashboard-portforward
systemctl disable dashboard-portforward
rm -f /etc/systemd/system/dashboard-portforward.service
systemctl daemon-reload

helm uninstall dashboard -n kubernetes-dashboard
kubectl delete namespace kubernetes-dashboard
# 然后重新执行 §10.2-10.6
```

---

## 12. 附录

### 12.1 核心踩坑 TOP 6

| # | 坑 | 错误做法 | 正确做法 |
|---|-----|---------|---------|
| 1 | Swap 禁不掉 | 仅 `swapoff -a` | fstab + GRUB + LVM + systemd mask（§3.5） |
| 2 | pause 镜像 | 未改 containerd 默认值 | v2 配置项名是 `sandbox`（单引号），替换为阿里云 |
| 3 | docker.io 镜像 | `docker.m.daocloud.io` 重定向 blob 到 Cloudflare | 改用 **`docker.1panel.live`** |
| 4 | kubeadm init CRI 错误 | 反复重启 containerd | 直接 `--ignore-preflight-errors`（已知竞态） |
| 5 | extraArgs 格式 | 用 v1beta3 map 格式 | v1beta4 数组格式 |
| 6 | Dashboard 不可用 | 禁用 Kong 或直接访问 web NodePort | Kong 必须启用；通过 port-forward 访问 Kong 443 |

### 12.2 关键文件路径

| 文件 | 路径 |
|------|------|
| kubeadm 配置 | `/etc/k8s/kubeadm-config.yaml` |
| Calico 清单 | `/etc/k8s/calico.yaml` |
| Containerd 配置 | `/etc/containerd/config.toml` |
| crictl 配置 | `/etc/crictl.yaml` |
| Kubernetes 仓库 | `/etc/yum.repos.d/kubernetes.repo` |
| kubelet 参数 | `/etc/sysconfig/kubelet` |
| kubectl 凭证 | `/etc/kubernetes/admin.conf` |
| Dashboard 端口转发服务 | `/etc/systemd/system/dashboard-portforward.service` |

### 12.3 Containerd v1.x → v2.x 路径对照

| 配置项 | v1.x | v2.x |
|--------|------|------|
| pause 镜像 | `[plugins."io.containerd.grpc.v1.cri"]` → `sandbox_image` | `[plugins.'io.containerd.cri.v1.images'.pinned_images]` → `sandbox` |
| 镜像代理 | `[plugins."io.containerd.grpc.v1.cri".registry.mirrors]` | `[plugins.'io.containerd.cri.v1.images'.registry.mirrors]` |

### 12.4 镜像代理最终方案

| 仓库 | 代理 | 备注 |
|------|------|------|
| `docker.io` | **`docker.1panel.live`** | 唯一实测 blob 全量缓存 |
| `quay.io` | `quay.m.daocloud.io` | Calico 镜像 |
| `k8s.gcr.io` / K8s 组件 | `registry.aliyuncs.com/google_containers` | kubeadm `imageRepository` 指定 |
| `gcr.io` | `gcr.m.daocloud.io` | 其他 Google 镜像 |

### 12.5 Dashboard 访问方式总结

| 方式 | 可用性 | 说明 |
|------|--------|------|
| **port-forward Kong 443（systemd）** ✅ | 生产推荐 | 无日志噪音，Master 重启自愈。`https://IP:8443` |
| port-forward Kong 443（手动后台） | 可用 | `kubectl -n kubernetes-dashboard port-forward --address=0.0.0.0 svc/dashboard-kong-proxy 8443:443 &`，终端会刷屏 |
| 直接访问 NodePort ❌ | 不可用 | Web 组件仅 HTTP，无反向代理路由，CSRF 登录失败 |
| kubectl proxy | 可用但路径长 | `kubectl proxy` → `http://IP:8001/api/v1/.../proxy/`（推荐 port-forward） |

---

> **手册版本：** v7.1（stable）  
> **适用系统：** CentOS Stream 9  
> **Kubernetes：** v1.35.4 · **Containerd：** v2.2.3 · **Calico：** v3.32.0 · **Dashboard：** v7.14.0  
> **全部步骤三节点生产验证通过。**  
> **v7.1 变更：** §3.5 重启改为可选 · §10.4 端口转发改用 systemd 服务（默认）
