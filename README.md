# Kubeadm v1.35.4 一键部署 Kubernetes 集群

在线 / 离线双模式，Master 一键 SSH 远程部署全部节点。

支持 **1 Master + 1 Worker** 或 **1 Master + 2 Workers** 部署模式。

---

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `deploy-k8s-cluster.sh` | **主脚本**，独立可运行，内置全部默认值 |
| `deploy-k8s-vars.sh` | 变量库（可选），覆盖主脚本默认版本/镜像源/路径 |
| `deploy-k8s.env` | 环境变量（可选），预填主机名/IP/密码跳过交互 |
| `build-offline-iso.sh` | 构建离线 ISO，拉取 RPM/镜像/清单打包 |
| `k8s-offline-repo.iso` | 离线镜像包（由 `build-offline-iso.sh` 生成） |
| `## 📋 Kubeadm v1.md` | 原部署手册（本文档的参考来源） |

---

## 🚀 快速开始

### 一键部署（在线）

```bash
# 一行命令，自动下载脚本并执行
bash <(curl -fsSL https://raw.githubusercontent.com/Townrain/kubeadm-k8s-deploy/main/deploy-k8s-cluster.sh)
```

### 一键拉取脚本到本地

```bash
# 拉取全部脚本到当前目录（不执行）
curl -fsSL https://raw.githubusercontent.com/Townrain/kubeadm-k8s-deploy/main/deploy-k8s-cluster.sh -o deploy-k8s-cluster.sh
curl -fsSL https://raw.githubusercontent.com/Townrain/kubeadm-k8s-deploy/main/deploy-k8s-vars.sh -o deploy-k8s-vars.sh
chmod +x deploy-k8s-cluster.sh
```

### 本地运行（完整步骤）

```bash
# 1. 可选的变量预填 (跳过交互)
vim deploy-k8s.env

# 2. 运行部署
bash deploy-k8s-cluster.sh
```

交互流程：部署模式 → 容器运行时 → 集群规划 → 网络自动检测 → 确认 → 自动部署

### 离线部署

```bash
# 1. 在联网环境构建 ISO（自动下载 RPM + 镜像）
bash build-offline-iso.sh
# → 输出 /root/k8s-offline-repo.iso (约 800M)

# 2. 将 ISO 放到 Master 节点 /root/
scp k8s-offline-repo.iso root@master:/root/

# 3. 运行部署
bash deploy-k8s-cluster.sh
# → 选择 [2] 离线模式
```

---

## ⚙️ 配置

### deploy-k8s.env (跳过交互)

```bash
# 部署模式
DEPLOY_CHOICE="1"              # 1=在线, 2=离线

# 容器运行时（仅 CentOS Stream 10 需要选择）
CONTAINER_RUNTIME="containerd" # containerd 或 docker

# Master
MASTER_HOSTNAME="master"
MASTER_IP="192.168.10.150"

# Worker1（必填）
WORKER1_HOSTNAME="node1"
WORKER1_IP="192.168.10.151"

# Worker2（留空则 1 Master + 1 Worker）
WORKER2_HOSTNAME=""
WORKER2_IP=""

# 网络
POD_CIDR="172.16.10.0/24"
SVC_CIDR="172.16.32.0/24"
```

### deploy-k8s-vars.sh (版本/镜像源)

```bash
K8S_VERSION="v1.35.4"
CRICTL_VERSION="v1.35.0"
CALICO_VERSION="v3.32.0"
HELM_VERSION="v3.19.0"
DASHBOARD_VERSION="7.14.0"
# ...更多详见文件注释
```

---

## 📦 组件版本

| 组件 | 版本 | 说明 |
|------|------|------|
| Kubernetes | v1.35.4 | 集群核心 |
| Containerd | v2.2.3 | 默认运行时，内置 CRI |
| Docker CE | v29.x | 可选运行时（需配合 cri-dockerd） |
| cri-dockerd | v0.3.21 | Docker 运行时的 CRI 适配器 |
| Calico | v3.32.0 | 网络插件 |
| Dashboard | v7.14.0 | Web UI（NodePort 访问） |
| Helm | v3.19.0 | 包管理器 |
| cri-tools | v1.35.0 | CRI 工具 |
| OS | CentOS Stream 9 / 10 | 双版本兼容 |

---

## ⚠️ 系统要求

### 容器运行时选择（仅 CentOS Stream 10）

| 运行时 | 说明 | CRI Socket |
|--------|------|------------|
| **containerd** | 推荐，内置 CRI | `/run/containerd/containerd.sock` |
| **Docker + cri-dockerd** | 可选，Docker 用户 | `/var/run/cri-dockerd.sock` |

### CPU 微架构要求

| CentOS Stream | CPU 要求 | 兼容性 |
|---------------|----------|--------|
| Stream 9 | x86-64-v2 | 大多数 2010 年后 CPU |
| Stream 10 | x86-64-v3 | 需 AVX2/BMI/FMA/SSE4.2 |

### 最低配置

| 节点 | CPU | 内存 | 磁盘 |
|------|-----|------|------|
| Master | 2C | 2G | 20G |
| Worker | 2C | 2G | 20G |

---

## 🌐 网络规划 (默认)

| 类型 | CIDR |
|------|------|
| Pod 网段 | 172.16.10.0/24 |
| Service 网段 | 172.16.32.0/24 |

---

## 🪞 国内镜像源

脚本自动使用以下国内镜像（按优先级）：

| 组件 | 镜像源 |
|------|--------|
| Kubernetes | mirrors.aliyun.com → mirrors.tuna.tsinghua.edu.cn → mirrors.ustc.edu.cn → pkgs.k8s.io |
| Docker CE | mirrors.tuna.tsinghua.edu.cn → mirrors.ustc.edu.cn → mirrors.aliyun.com |
| Containerd 镜像 | docker.1panel.live (docker.io) / quay.m.daocloud.io (quay.io) |

---

## ⚠️ 已知问题

### CentOS Stream 10 兼容性

**kube-proxy 模式变更：** CentOS 10 移除了 iptables 内核模块，默认使用 nftables 模式。脚本已自动处理：
- CentOS 9：`kube-proxy --proxy-mode=ipvs`
- CentOS 10：`kube-proxy --proxy-mode=nftables`

**DNF 5 兼容：** CentOS 10 使用 DNF 5，`dnf config-manager` 语法有变化。脚本已适配。

**kernel-modules-extra：** CentOS 10 可能需要安装 `kernel-modules-extra` 才能加载 `br_netfilter` 模块，脚本已自动处理。

### kubeadm v1.35 super-admin.conf bug

**现象：** `kubeadm init` 报错 `context deadline exceeded`

**原因：** kubeadm v1.35.4 的 `super-admin.conf` 指向 `controlPlaneEndpoint` 而非 `localAPIEndpoint`，导致 API server 未就绪时超时。

**修复：** 脚本已移除 `controlPlaneEndpoint` 配置，使用 `localAPIEndpoint` 避免此问题。

---

## 🔍 部署完成后

```bash
# 集群状态
kubectl get nodes
kubectl get pods -A

# Dashboard 访问
kubectl get svc -n kubernetes-dashboard dashboard-kong-proxy | grep -oP '(\d+):443'
# 浏览器打开 https://<master-ip>:<NodePort>

# 获取登录 Token
kubectl create token dashboard-admin -n kubernetes-dashboard --duration=24h
```

---

## 🛠 常用命令速查

```bash
# 节点/Pod
kubectl get nodes -o wide
kubectl get pods -A
kubectl describe pod <pod> -n <ns>

# 日志
kubectl logs <pod> -n <ns> --tail=100
journalctl -xeu kubelet --no-pager | tail -50

# 容器
crictl ps -a
crictl images
crictl pull <image>

# Dashboard 端口转发
systemctl status dashboard-portforward
systemctl restart dashboard-portforward

# 完全重置
kubeadm reset -f
rm -rf /etc/cni /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube
```
