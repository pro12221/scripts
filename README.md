# scripts

## deploy-k8s.sh — Kubernetes 快速部署脚本

一键部署 K8s 集群，支持单 Master / 多 Master HA，支持国内/国外网络自动切换。

### 功能特性

- **CNI 选型**：Calico / Flannel / Cilium
- **国内网络自动检测**：通过 ping `google.com` 判断，自动切换阿里云镜像源、Daoocloud Docker mirror、GitHub 加速
- **多 Master HA**：自动部署 HAProxy + Keepalived，提供 VIP
- **K8s 版本选择**：支持 1.24 ~ 1.32+
- **OS 支持**：Ubuntu/Debian、CentOS/RHEL/Rocky
- **containerd 2.x 兼容**：自动适配新版配置格式

### 前置条件

- 目标机器为 Linux x86_64 / aarch64
- 至少 2GB 内存、2 CPU 核心
- 以 root 用户执行
- 各节点间网络互通

### 使用方法

#### 初始化 Master 节点

```bash
# 单 Master
./deploy-k8s.sh init \
  --k8s-version 1.30.2 \
  --network-plugin flannel \
  --node-name master

# 多 Master HA
./deploy-k8s.sh init \
  --k8s-version 1.30.2 \
  --network-plugin calico \
  --node-name master1 \
  --vip 192.168.1.100 \
  --master-ips 192.168.1.10,192.168.1.11,192.168.1.12
```

#### 加入 Worker 节点

Master 初始化完成后会自动输出 join 命令（包含 token 和 hash），直接复制执行：

```bash
./deploy-k8s.sh join-worker \
  --master-ip 10.60.189.99 \
  --node-name node1 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

#### 加入控制平面节点（HA 模式）

```bash
./deploy-k8s.sh join-control-plane \
  --vip 192.168.1.100 \
  --node-name master2 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --certificate-key <key>
```

#### 重置节点

```bash
./deploy-k8s.sh reset
```

### 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--k8s-version` | K8s 版本号，格式 X.Y.Z | 1.28.2 |
| `--network-plugin` | CNI 插件：calico / flannel / cilium | calico |
| `--pod-cidr` | Pod CIDR，不指定则根据 CNI 自动选择 | 自动 |
| `--node-name` | 节点名称，同时设置系统 hostname | 系统 hostname |
| `--vip` | HA 虚拟 IP（多 Master 必填） | 无 |
| `--master-ips` | 所有 Master 节点 IP，逗号分隔（HA 必填） | 无 |
| `--master-ip` | Master 节点 IP（join 命令必填） | 无 |
| `--token` | Bootstrap token（join 命令必填） | 无 |
| `--discovery-token-ca-cert-hash` | CA 证书哈希（join 命令必填） | 无 |
| `--certificate-key` | 证书密钥（join-control-plane 必填） | 无 |

### 完整部署示例

3 节点集群（1 Master + 2 Worker），K8s 1.30.2 + Flannel：

```bash
# 1. 在 Master 节点执行
./deploy-k8s.sh init --k8s-version 1.30.2 --network-plugin flannel --node-name master

# 2. 在 Worker 节点执行（使用 init 输出的 token 和 hash）
./deploy-k8s.sh join-worker --master-ip <master-ip> --node-name node1 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
./deploy-k8s.sh join-worker --master-ip <master-ip> --node-name node2 --token <token> --discovery-token-ca-cert-hash sha256:<hash>

# 3. 在 Master 节点验证
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes
```

### 国内网络说明

脚本自动检测网络环境：

- **国外网络**：使用 `registry.k8s.io`、`packages.cloud.google.com`、GitHub 直连
- **国内网络**：使用 `registry.aliyuncs.com/google_containers` 镜像、`docker.m.daocloud.io` Docker mirror、`ghproxy` GitHub 加速、`pkgs.k8s.io`（如阿里云镜像不可用自动回退）
