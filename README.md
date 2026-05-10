# Kubeadm v1.35.4 一键部署 Kubernetes 集群

在线 / 离线双模式，Master 一键 SSH 远程部署全部节点。

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

### 一键部署

```bash
# 在线模式 (全部交互式)
bash <(curl -fsSL https://raw.githubusercontent.com/Townrain/kubeadm-k8s-deploy/main/deploy-k8s-cluster.sh)
```

### 在线部署 (完整步骤)

```bash
# 1. 可选的变量预填 (跳过交互)
vim deploy-k8s.env

# 2. 一键部署 (自动检测网络/SSH 远程配置)
bash deploy-k8s-cluster.sh
```

交互流程：部署模式 → 主机名/IP → 网络自动检测 → 确认 → 自动部署

### 离线部署

```bash
# 1. 在联网环境构建 ISO
bash build-offline-iso.sh
# → 输出 /root/k8s-offline-repo.iso

# 2. 将 ISO 放到所有节点 /root/
scp k8s-offline-repo.iso root@master:/root/
scp k8s-offline-repo.iso root@node1:/root/
scp k8s-offline-repo.iso root@node2:/root/

# 3. 运行部署 (选离线模式)
bash deploy-k8s-cluster.sh
# → 选择 [2] 离线模式
```

---

## ⚙️ 配置

### deploy-k8s.env (跳过交互)

```bash
DEPLOY_CHOICE="2"              # 1=在线, 2=离线

MASTER_HOSTNAME="master"
MASTER_IP="192.168.10.150"
MASTER_IFACE="ens33"

WORKER1_HOSTNAME="node1"
WORKER1_IP="192.168.10.151"
WORKER1_USER="root"
WORKER1_PASS="your-password"   # 需安装 sshpass

WORKER2_HOSTNAME="node2"
WORKER2_IP="192.168.10.152"
WORKER2_USER="root"
WORKER2_PASS="your-password"

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

| 组件 | 版本 |
|------|------|
| Kubernetes | v1.35.4 |
| Containerd | v2.2.3 |
| Calico | v3.32.0 |
| Dashboard | v7.14.0 |
| Helm | v3.19.0 |
| cri-tools | v1.35.0 |
| OS | CentOS Stream 9 |

---

## 🌐 网络规划 (默认)

| 类型 | CIDR |
|------|------|
| Pod 网段 | 172.16.10.0/24 |
| Service 网段 | 172.16.32.0/24 |

---

## 🔍 部署完成后

```bash
# 集群状态
kubectl get nodes
kubectl get pods -A

# Dashboard 登录
https://<master-ip>:8443          # Token 在部署完成输出末尾

# 重新获取 Token
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
