# Kubernetes HA 集群 Ansible 自动化部署

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35-blue)](https://kubernetes.io/)
[![Ansible](https://img.shields.io/badge/Ansible-2.12+-red)](https://www.ansible.com/)
[![Platform](https://img.shields.io/badge/Platform-CentOS%20Stream%209-lightgrey)](https://centos.org/)

基于 Ansible 一键部署生产级 Kubernetes 高可用集群。支持 **3 控制节点 + N 工作节点**架构，使用 **HAProxy + Keepalived** 实现控制平面高可用，**Calico** 作为 CNI，全程走**阿里云镜像**，无需科学上网。

> ✅ 已在 VMware vSphere 虚拟化环境实测，针对 VMware ARP 过滤问题做了专项处理。

---

## 目录

- [集群架构](#集群架构)
- [节点规划](#节点规划)
- [前置要求](#前置要求)
- [快速开始](#快速开始)
- [详细配置说明](#详细配置说明)
- [部署流程详解](#部署流程详解)
- [部署后验证](#部署后验证)
- [日常运维](#日常运维)
- [常见问题 FAQ](#常见问题-faq)
- [重置集群](#重置集群)
- [目录结构](#目录结构)
- [技术细节](#技术细节)

---

## 集群架构

```
                    ┌─────────────────────────────────────────┐
                    │         VIP: 192.168.88.200:6443         │
                    │         Keepalived VRRP 漂移              │
                    └──────────────────┬──────────────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                        │
    ┌─────────▼────────┐   ┌──────────▼───────┐   ┌───────────▼──────┐
    │     master1      │   │     master2      │   │     master3      │
    │  192.168.88.119  │   │  192.168.88.120  │   │  192.168.88.124  │
    │  HAProxy+KA      │   │  HAProxy+KA      │   │  HAProxy+KA      │
    │  kube-apiserver  │   │  kube-apiserver  │   │  kube-apiserver  │
    │  etcd            │◄──┤  etcd            ├──►│  etcd            │
    └──────────────────┘   └──────────────────┘   └──────────────────┘

              ┌────────────────────────────────────────────────┐
              │                  Worker 节点                    │
    ┌─────────▼────────┐   ┌──────────▼───────┐   ┌───────────▼──────┐
    │     worker1      │   │     worker2      │   │     worker3      │
    │  192.168.88.121  │   │  192.168.88.122  │   │  192.168.88.123  │
    └──────────────────┘   └──────────────────┘   └──────────────────┘
```

**etcd quorum = 2（3节点）**：任意一个控制节点宕机，集群写入不受影响。

```

**HA 工作原理：**
- Keepalived 通过 VRRP 在两个 master 间漂移 VIP，master1 故障时 VIP 秒级切换到 master2
- HAProxy 监听 VIP:6443，将请求轮询到两个 kube-apiserver
- etcd 双节点互为备份，保证控制平面数据不丢失

---

## 节点规划

| 角色 | 主机名 | IP | 说明 |
|------|--------|----|------|
| 控制机（Ansible） | ollama | 192.168.88.118 | 不加入集群 |
| 控制节点 | master1 | 192.168.88.119 | 初始主节点 |
| 控制节点 | master2 | 192.168.88.120 | |
| 控制节点 | master3 | 192.168.88.124 | |
| 工作节点 | worker1 | 192.168.88.121 | |
| 工作节点 | worker2 | 192.168.88.122 | |
| 工作节点 | worker3 | 192.168.88.123 | |
| VIP | — | 192.168.88.200 | 同网段空闲 IP |

---

## 软件版本

| 组件 | 版本 |
|------|------|
| OS | CentOS Stream 9 |
| Kubernetes | v1.35.5 |
| containerd | v2.2.x |
| Calico | v3.31.5 |
| HAProxy | 系统包 |
| Keepalived | 系统包 |


### Ansible 控制机

```bash
# Python 3.8+
python3 --version

# 安装 Ansible（2.12+）
pip3 install ansible

# 验证
ansible --version
```

### 网络要求

| 要求 | 说明 |
|------|------|
| 节点互通 | 所有 K8s 节点之间网络互通 |
| 控制机 SSH | Ansible 控制机到所有节点 SSH 免密 root 登录 |
| VIP 空闲 | VIP 在同一局域网且未被占用 |
| 外网访问 | 节点能访问互联网（下载 RPM 包和容器镜像） |

> **VMware 用户注意：** VMware 虚拟交换机默认过滤 Gratuitous ARP，导致 worker 节点无法直接访问 VIP。本项目已通过 iptables DNAT + 持久化 systemd 服务自动解决，**无需修改 VMware 配置**。

---

## 快速开始

### 第一步：配置 SSH 免密登录

```bash
# 在 Ansible 控制机上执行
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# 分发公钥（按实际 IP 修改）
for ip in 192.168.88.119 192.168.88.120 192.168.88.121 192.168.88.122 192.168.88.123; do
    ssh-copy-id root@$ip
done

# 验证
ansible -i inventory.ini all -m ping
```

### 第二步：直接下载k8s-final9.tar.gz文件，使用Winscap上传至ansible主机并解压，在文件目录执行即可

```bash
[root@ollama ~]# tar -zxvf k8s-final9.tar.gz
k8s-final9/
k8s-final9/site.yml
k8s-final9/{group_vars,roles/
k8s-final9/{group_vars,roles/{common/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/{tasks,handlers,templates},containerd/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/{tasks,handlers,templates},containerd/{tasks,handlers,templates},kubernetes/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/{tasks,handlers,templates},containerd/{tasks,handlers,templates},kubernetes/tasks,master_init/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/{tasks,handlers,templates},containerd/{tasks,handlers,templates},kubernetes/tasks,master_init/tasks,master_join/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/{tasks,handlers,templates},containerd/{tasks,handlers,templates},kubernetes/tasks,master_init/tasks,master_join/tasks,worker_join/
k8s-final9/{group_vars,roles/{common/{tasks,handlers},haproxy_keepalived/{tasks,handlers,templates},containerd/{tasks,handlers,templates},kubernetes/tasks,master_init/tasks,master_join/tasks,worker_join/tasks}}/
k8s-final9/group_vars/
k8s-final9/group_vars/all.yml
k8s-final9/inventory.ini
k8s-final9/reset.yml
k8s-final9/roles/
k8s-final9/roles/containerd/
k8s-final9/roles/containerd/tasks/
k8s-final9/roles/containerd/tasks/main.yml
k8s-final9/roles/containerd/handlers/
k8s-final9/roles/containerd/handlers/main.yml
k8s-final9/roles/containerd/templates/
k8s-final9/roles/containerd/templates/config.toml.j2
k8s-final9/roles/worker_join/
k8s-final9/roles/worker_join/tasks/
k8s-final9/roles/worker_join/tasks/main.yml
k8s-final9/roles/keepalived_only/
k8s-final9/roles/keepalived_only/tasks/
k8s-final9/roles/keepalived_only/tasks/main.yml
k8s-final9/roles/keepalived_only/handlers/
k8s-final9/roles/keepalived_only/handlers/main.yml
k8s-final9/roles/keepalived_only/templates/
k8s-final9/roles/keepalived_only/templates/keepalived.conf.j2
k8s-final9/roles/keepalived_only/{tasks,handlers,templates}/
k8s-final9/roles/common/
k8s-final9/roles/common/tasks/
k8s-final9/roles/common/tasks/main.yml
k8s-final9/roles/kubernetes/
k8s-final9/roles/kubernetes/tasks/
k8s-final9/roles/kubernetes/tasks/main.yml
k8s-final9/roles/haproxy_keepalived/
k8s-final9/roles/haproxy_keepalived/tasks/
k8s-final9/roles/haproxy_keepalived/tasks/main.yml
k8s-final9/roles/haproxy_keepalived/handlers/
k8s-final9/roles/haproxy_keepalived/handlers/main.yml
k8s-final9/roles/haproxy_keepalived/templates/
k8s-final9/roles/haproxy_keepalived/templates/haproxy.cfg.j2
k8s-final9/roles/haproxy_keepalived/templates/keepalived.conf.j2
k8s-final9/roles/haproxy_only/
k8s-final9/roles/haproxy_only/tasks/
k8s-final9/roles/haproxy_only/tasks/main.yml
k8s-final9/roles/haproxy_only/handlers/
k8s-final9/roles/haproxy_only/handlers/main.yml
k8s-final9/roles/haproxy_only/templates/
k8s-final9/roles/haproxy_only/templates/haproxy.cfg.j2
k8s-final9/roles/haproxy_only/{tasks,handlers,templates}/
k8s-final9/roles/master_init/
k8s-final9/roles/master_init/tasks/
k8s-final9/roles/master_init/tasks/main.yml
k8s-final9/roles/master_join/
k8s-final9/roles/master_join/tasks/
k8s-final9/roles/master_join/tasks/main.yml
[root@ollama ~]# cd k8s-final9
[root@ollama k8s-final9]# ls
group_vars  {group_vars,roles  inventory.ini  reset.yml  roles  site.yml

```

### 第三步：修改配置

**① 修改 `inventory.ini`（改为你的实际 IP）：**

```ini
[masters]
master1 ansible_host=192.168.88.119 ansible_user=root
master2 ansible_host=192.168.88.120 ansible_user=root

[workers]
worker1 ansible_host=192.168.88.121 ansible_user=root
worker2 ansible_host=192.168.88.122 ansible_user=root
worker3 ansible_host=192.168.88.123 ansible_user=root

[k8s_cluster:children]
masters
workers

[first_master]
master1 ansible_host=192.168.88.119 ansible_user=root
```

**② 修改 `group_vars/all.yml`（至少修改 VIP 地址）：**

```yaml
vip_address: "192.168.88.200"   # ← 改为你网段内空闲 IP
vip_port: 6443
pod_network_cidr: "10.244.0.0/16"
service_cidr: "10.96.0.0/12"
k8s_repo_version: "v1.32"       # K8s yum 仓库大版本
k8s_version: ""                 # 留空=最新，填"1.35.4"=指定版本
calico_version: "v3.29.0"
```

### 第四步：一键部署

```bash
ansible-playbook -i inventory.ini site.yml
```

部署约需 **15～25 分钟**，完成后输出集群状态报告。

---

## 详细配置说明

### `inventory.ini` 参数说明

```ini
[masters]
# 格式：主机名  ansible_host=IP  ansible_user=登录用户
master1 ansible_host=192.168.88.119 ansible_user=root

[workers]
# 工作节点可任意增减数量
worker1 ansible_host=192.168.88.121 ansible_user=root

[k8s_cluster:children]   # 全集群组，勿修改
masters
workers

[first_master]           # 第一控制节点（初始化节点），勿修改
master1 ansible_host=192.168.88.119 ansible_user=root
```

### `group_vars/all.yml` 参数说明

| 参数 | 默认值 | 说明 |
|------|-------|------|
| `vip_address` | `192.168.88.200` | 虚拟 IP，必须改为实际空闲 IP |
| `vip_port` | `6443` | API Server 端口，通常无需修改 |
| `pod_network_cidr` | `10.244.0.0/16` | Pod 网段，不能与宿主机网段冲突 |
| `service_cidr` | `10.96.0.0/12` | Service 网段，不能与宿主机网段冲突 |
| `dns_domain` | `cluster.local` | 集群 DNS 域名 |
| `k8s_repo_version` | `v1.32` | yum 仓库版本（影响可安装的版本范围）|
| `k8s_version` | `""` | 留空安装最新版，填 `"1.35.4"` 指定版本 |
| `calico_version` | `v3.29.0` | Calico CNI 版本 |
| `aliyun_k8s_registry` | `registry.aliyuncs.com/google_containers` | 阿里云镜像仓库 |
| `timezone` | `Asia/Shanghai` | 系统时区 |

---

## 部署流程详解

`site.yml` 按以下顺序执行：

```
Step 1  所有节点 - 系统初始化
        ├─ 配置主机名 & /etc/hosts
        ├─ 关闭 swap / SELinux / firewalld
        ├─ 加载内核模块（br_netfilter / overlay / ip_vs）
        ├─ 配置 sysctl（ip_forward / bridge-nf-call-iptables）
        └─ 安装基础工具（ipvsadm / iproute-tc / wget 等）

Step 2  所有节点 - 安装 containerd
        ├─ 配置阿里云 containerd 仓库
        ├─ 安装 containerd 2.x（SystemdCgroup = true）
        └─ 配置镜像加速（docker.io / registry.k8s.io 等）

Step 3  所有节点 - 安装 K8s 组件
        ├─ 配置阿里云 K8s yum 仓库（自动回退旧版仓库）
        ├─ 所有节点安装 kubelet + kubeadm
        └─ 控制节点额外安装 kubectl

Step 4  控制节点 - 启动 Keepalived
        ├─ master1：MASTER 角色，priority=100，持有 VIP
        └─ master2：BACKUP 角色，priority=99，备用

Step 5  master1 - 启动 HAProxy（仅 master1）
        └─ 监听 VIP:6443，此时 master2 不启动 HAProxy
           （避免 master2 本地截获 VIP 流量）

Step 6  master1 - kubeadm init
        ├─ 通过 kubeadm patches 设置 kube-apiserver bind-address=节点IP
        │  （patches 不写入 ClusterConfiguration，不影响 master2）
        ├─ controlPlaneEndpoint = VIP:6443
        ├─ 使用阿里云镜像仓库拉取镜像
        ├─ 部署 Calico CNI
        └─ 生成 master/worker join 命令保存到控制机

Step 7  master2 - 加入控制平面
        ├─ 添加 iptables DNAT（VIP:6443 → master1:6443）
        ├─ 使用 JoinConfiguration 指定 apiServerEndpoint=master1 IP
        ├─ 通过 patches 设置 master2 自己的 bind-address
        ├─ join 成功后部署 k8s-dnat.service（DNAT 持久化）
        └─ 验证 master2 进入 Ready 状态

Step 8  master2 - 启动 HAProxy
        └─ master2 join 成功后，才启动 master2 的 HAProxy

Step 9  worker1/2/3 - 加入集群
        ├─ 添加 iptables DNAT（VIP:6443 → master1:6443）
        ├─ join 命令替换 VIP 为 master1 直接 IP
        ├─ join 成功后部署 k8s-dnat.service（DNAT 持久化）
        └─ 添加 worker 角色标签

Step 10 等待全部节点 Ready（超时 6 分钟）

Step 11 输出集群最终状态报告
```

### 预计耗时

| 阶段 | 时间 |
|------|------|
| Step 1-3 基础环境 | 5～8 分钟 |
| Step 4-5 HA 组件 | 1～2 分钟 |
| Step 6 kubeadm init + Calico | 4～6 分钟 |
| Step 7-8 master2 join | 3～5 分钟 |
| Step 9 worker join | 2～4 分钟 |
| Step 10-11 验证 | 2～3 分钟 |
| **合计** | **约 17～28 分钟** |

---

## 部署后验证

在 master1 上执行：

```bash
# 1. 查看所有节点（应全为 Ready）
kubectl get nodes -o wide

# 期望输出：
# NAME      STATUS   ROLES           AGE   VERSION   INTERNAL-IP
# master1   Ready    control-plane   10m   v1.35.4   192.168.88.119
# master2   Ready    control-plane   8m    v1.35.4   192.168.88.120
# worker1   Ready    worker          5m    v1.35.4   192.168.88.121
# worker2   Ready    worker          5m    v1.35.4   192.168.88.122
# worker3   Ready    worker          5m    v1.35.4   192.168.88.123

# 2. 查看系统 Pod（应全为 Running）
kubectl get pods -n kube-system -o wide

# 3. 验证 VIP 绑定在 master1
ip a | grep 192.168.88.200

# 4. 验证通过 VIP 访问 API Server
curl -sk https://192.168.88.200:6443/healthz
# 期望输出：ok

# 5. 验证 HA 服务状态
systemctl is-active haproxy keepalived

# 6. 验证 etcd 集群健康
kubectl exec -n kube-system etcd-master1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
```

### HA 故障切换测试

```bash
# 模拟 master1 故障（在 master1 上）
systemctl stop keepalived

# 在 master2 上查看 VIP 是否飘过来（约 3 秒）
ip a | grep 192.168.88.200

# VIP 应出现在 master2，集群仍可访问
curl -sk https://192.168.88.200:6443/healthz

# 恢复 master1
systemctl start keepalived
```

---

## 日常运维

### 扩容工作节点

1. 在 `inventory.ini` 的 `[workers]` 组添加新节点
2. 配置 SSH 免密登录
3. 生成新的 join token（旧 token 24 小时过期）：

```bash
# 在 master1 上执行，生成新 token
kubeadm token create --print-join-command
```

4. 只对新节点执行部署：

```bash
ansible-playbook -i inventory.ini site.yml --limit worker4
```

### 查看集群状态

```bash
# 节点状态
kubectl get nodes -o wide

# 系统 Pod
kubectl get pods -n kube-system

# etcd 成员
kubectl exec -n kube-system etcd-master1 -- \
  etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list
```

### 重新生成 join token

```bash
# worker join 命令（24 小时过期后需重新生成）
kubeadm token create --print-join-command

# master join 命令（还需上传证书）
kubeadm init phase upload-certs --upload-certs
# 组合: kubeadm token create --print-join-command 的输出 + --control-plane --certificate-key <上面的key>
```

### 节点维护

```bash
# 驱逐节点上的 Pod（维护前）
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data

# 节点维护完成后恢复调度
kubectl uncordon worker1
```

---

## 常见问题 FAQ

### Q1：部署失败如何排查？

每个关键步骤失败时 Ansible 会自动打印完整日志。也可直接查看节点日志：

```bash
# kubeadm init 日志
ssh root@192.168.88.119 "cat /root/kubeadm-init.log | tail -50"

# master2 join 日志
ssh root@192.168.88.120 "cat /root/master-join.log | tail -50"

# worker join 日志
ssh root@192.168.88.121 "cat /root/worker-join.log | tail -50"

# kubelet 日志
ssh root@192.168.88.121 "journalctl -u kubelet --no-pager | tail -30"
```

### Q2：worker 节点重启后变为 NotReady？

原因是 DNAT 规则丢失，kubelet 无法连接 API Server。本项目已通过 `k8s-dnat.service` 自动持久化，正常不会发生。

如果仍然出现，手动检查并修复：

```bash
# 在 worker 节点上检查
iptables -t nat -L OUTPUT -n | grep 192.168.88.200

# 如果规则不存在，手动恢复
/usr/local/bin/k8s-dnat-setup.sh

# 验证服务是否启用
systemctl status k8s-dnat
systemctl enable k8s-dnat
```

### Q3：kube-controller-manager / kube-scheduler 一直重启？

检查 manifest 是否有两个 `--bind-address` 参数（一个 `127.0.0.1`，一个节点 IP）：

```bash
grep bind-address /etc/kubernetes/manifests/kube-controller-manager.yaml
grep bind-address /etc/kubernetes/manifests/kube-scheduler.yaml
```

如果有两个，删除节点 IP 那一条（只保留 `127.0.0.1`）：

```bash
# 在 master1 上
sed -i '/--bind-address=192.168.88.119/d' /etc/kubernetes/manifests/kube-controller-manager.yaml
sed -i '/--bind-address=192.168.88.119/d' /etc/kubernetes/manifests/kube-scheduler.yaml

# 在 master2 上
sed -i '/--bind-address=192.168.88.120/d' /etc/kubernetes/manifests/kube-controller-manager.yaml
sed -i '/--bind-address=192.168.88.120/d' /etc/kubernetes/manifests/kube-scheduler.yaml
```

kubelet 检测到 manifest 变化后会自动重建 Pod，约 30 秒恢复。

### Q4：Calico install-cni 容器一直 BackOff？

通常是因为 `ClusterIP (10.96.0.1:443)` 不可达，根源是 DNAT 丢失导致 kube-proxy 未建立 IPVS 规则。参考 Q2 修复 DNAT，然后删除异常 Pod 让其重建：

```bash
# 找到异常 Pod
kubectl get pods -n kube-system -o wide | grep calico-node

# 删除重建（会自动调度）
kubectl delete pod -n kube-system <calico-node-xxxxx>
```

### Q5：VIP 不可达？

```bash
# 检查 Keepalived
systemctl status keepalived

# 检查 VIP 是否绑定在某个节点
ip a | grep 192.168.88.200          # master1
ssh root@192.168.88.120 "ip a | grep 192.168.88.200"  # master2

# 检查 HAProxy
systemctl status haproxy
curl -sk --max-time 5 https://192.168.88.200:6443/healthz
```

### Q6：如何只重跑某些节点？

```bash
# 只重跑 worker 节点
ansible-playbook -i inventory.ini site.yml --limit workers

# 从指定任务开始执行
ansible-playbook -i inventory.ini site.yml \
  --start-at-task="worker_join : 检查是否已加入集群"

# 跳过某些步骤（需要 role 定义了 tag）
ansible-playbook -i inventory.ini site.yml --skip-tags "containerd"
```

### Q7：如何更新 Kubernetes 版本？

修改 `group_vars/all.yml`：

```yaml
k8s_repo_version: "v1.32"   # 改为目标大版本
k8s_version: "1.35.4"       # 指定精确版本
```

然后重置集群重新部署（生产环境建议先在测试环境验证）。

---

## 重置集群

> ⚠️ **警告：** 以下操作将**删除所有集群数据**，不可恢复！

```bash
# 重置所有节点
ansible-playbook -i inventory.ini reset.yml

# 清理控制机临时 join 文件
rm -f /tmp/k8s_worker_join.sh /tmp/k8s_master_join.sh

# 重新部署
ansible-playbook -i inventory.ini site.yml
```

---

## 目录结构

```
k8s-ansible-ha/
├── inventory.ini              # 主机清单 ← 需要修改
├── group_vars/
│   └── all.yml                # 全局变量 ← 需要修改
├── site.yml                   # 主部署 Playbook
├── reset.yml                  # 集群重置 Playbook
├── README.md                  # 本文档
└── roles/
    ├── common/                # Step 1: 系统初始化
    │   ├── tasks/main.yml
    │   └── handlers/main.yml
    ├── containerd/            # Step 2: containerd 运行时
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/config.toml.j2
    ├── kubernetes/            # Step 3: kubelet/kubeadm/kubectl
    │   └── tasks/main.yml
    ├── keepalived_only/       # Step 4: Keepalived VIP
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/keepalived.conf.j2
    ├── haproxy_only/          # Step 5/8: HAProxy 负载均衡
    │   ├── tasks/main.yml
    │   ├── handlers/main.yml
    │   └── templates/haproxy.cfg.j2
    ├── master_init/           # Step 6: 初始化第一控制节点
    │   └── tasks/main.yml
    ├── master_join/           # Step 7: 第二控制节点加入
    │   └── tasks/main.yml
    └── worker_join/           # Step 9: 工作节点加入
        └── tasks/main.yml
```

---

## 技术细节

### 解决的核心技术难题

#### 1. HAProxy 与 kube-apiserver 端口冲突

**问题：** kube-apiserver 默认绑定 `0.0.0.0:6443`，HAProxy 同时绑定 `VIP:6443`（VIP 已绑定到本机网卡），产生 `EADDRINUSE` 冲突。

**方案：** 使用 kubeadm `patches` 机制，通过 JSON Patch 为每节点的 kube-apiserver 追加 `--bind-address=本节点IP`：

```json
[{"op": "add", "path": "/spec/containers/0/command/-", "value": "--bind-address=192.168.88.119"}]
```

- 使用 `+json.json`（JSON Patch 追加），不能用 `+strategic.yaml`（会替换整个 command 数组导致崩溃）
- patches 只影响本节点 Pod manifest，**不写入 ClusterConfiguration**，master2 join 时不受影响
- controller-manager 和 scheduler **不需要**修改 bind-address，它们默认绑定 `127.0.0.1`，不与 HAProxy 冲突

#### 2. VMware 环境 VIP 不可达

**问题：** VMware 虚拟交换机过滤 Gratuitous ARP，master2 和 worker 节点的 ARP 缓存无法学到 VIP 对应的 MAC，发往 VIP 的包无法到达 master1。

**方案：** 在 master2 和 worker 节点添加 iptables DNAT 规则：

```bash
iptables -t nat -I OUTPUT 1 \
  -d 192.168.88.200 -p tcp --dport 6443 \
  -j DNAT --to-destination 192.168.88.119:6443
```

持久化方案（`/etc/systemd/system/k8s-dnat.service`）：

```ini
[Unit]
After=network.target
Before=kubelet.service   # 关键：在 kubelet 启动前恢复规则

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k8s-dnat-setup.sh
```

#### 3. master2 join 时 kubelet TLS Bootstrap 失败

**问题：** kubeadm join 过程分多个阶段：
- discovery 阶段：可以通过命令行指定 master1 IP
- fetch kubeadm-config 阶段：固定使用 `controlPlaneEndpoint`（VIP）
- kubelet TLS bootstrap：使用 `bootstrap-kubelet.conf` 中记录的 server 地址

后两个阶段无法通过命令行参数改变，都会连接 VIP，必须配合 DNAT 才能工作。

**方案：** DNAT + JoinConfiguration 双重保障：

```yaml
# JoinConfiguration 文件
discovery:
  bootstrapToken:
    apiServerEndpoint: "192.168.88.119:6443"  # discovery 直连 master1
```

DNAT 处理 fetch kubeadm-config 和 kubelet bootstrap 阶段，JoinConfiguration 处理 discovery 阶段。

#### 4. HAProxy 启动顺序

**问题：** 若 master2 在 join 前启动 HAProxy，由于 `ip_nonlocal_bind=1`，HAProxy 绑定了 VIP:6443，master2 发出的到 VIP 的包被本地 HAProxy 截获（不路由出去），导致永久超时。

**方案：** 严格控制启动顺序：

```
Step 5: 仅 master1 启动 HAProxy
Step 7: master2 join（通过 DNAT 绕过 VIP）
Step 8: master2 join 成功后，才启动 master2 的 HAProxy
```

### 组件版本

| 组件 | 版本 | 用途 |
|------|------|------|
| Kubernetes | 1.35.x | 容器编排 |
| containerd | 2.2.x | 容器运行时（SystemdCgroup=true）|
| Calico | v3.29.0 | CNI 网络插件（IPIP 模式）|
| HAProxy | 2.8.x | API Server 负载均衡 |
| Keepalived | 2.x | VIP 浮动（VRRP 协议）|
| 镜像源 | 阿里云 | `registry.aliyuncs.com/google_containers` |

### HAProxy 关键配置

```haproxy
frontend k8s-apiserver
    bind 192.168.88.200:6443   # 只绑 VIP，不绑 0.0.0.0（避免与 kube-apiserver 冲突）
    mode tcp
    default_backend k8s-apiserver

backend k8s-apiserver
    mode tcp
    balance roundrobin
    option tcp-check
    server master1 192.168.88.119:6443 check
    server master2 192.168.88.120:6443 check
```

---

## License

[MIT License](LICENSE)

## Contributing

欢迎提交 Issue 和 Pull Request！

如果这个项目对你有帮助，请点个 ⭐ Star！
