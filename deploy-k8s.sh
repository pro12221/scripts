#!/usr/bin/env bash
#
# deploy-k8s.sh - Kubernetes Cluster Quick Deployment Script
#
# Features:
#   - Single / Multi-master (HA) deployment
#   - Network plugin selection (Calico / Flannel / Cilium)
#   - Auto-detect China / International network (ping google.com)
#   - K8s version selection
#   - Support Ubuntu/Debian and CentOS/RHEL/Rocky
#
# ═══════════════════════════════════════════════════════════
#  Usage Examples
# ═══════════════════════════════════════════════════════════
#
#   # Single master
#   ./deploy-k8s.sh init --k8s-version 1.28.2 --network-plugin calico
#
#   # Multi-master HA
#   ./deploy-k8s.sh init --k8s-version 1.28.2 --network-plugin calico \
#       --vip 192.168.1.100 \
#       --master-ips 192.168.1.10,192.168.1.11,192.168.1.12
#
#   # Join additional control-plane node
#   ./deploy-k8s.sh join-control-plane \
#       --vip 192.168.1.100 \
#       --token abcdef.0123456789abcdef \
#       --discovery-token-ca-cert-hash sha256:xxx \
#       --certificate-key yyy
#
#   # Join worker node
#   ./deploy-k8s.sh join-worker \
#       --vip 192.168.1.100 \
#       --token abcdef.0123456789abcdef \
#       --discovery-token-ca-cert-hash sha256:xxx
#
#   # Reset node
#   ./deploy-k8s.sh reset
#

set -euo pipefail

# ======================== Constants ========================
readonly SCRIPT_VERSION="1.0.0"
readonly K8S_API_PORT=6443
readonly HAPROXY_PORT=16443
readonly KEEPALIVED_VRID=51
readonly SERVICE_CIDR="10.96.0.0/12"

# CNI default Pod CIDRs
readonly CALICO_POD_CIDR="192.168.0.0/16"
readonly FLANNEL_POD_CIDR="10.244.0.0/16"
readonly CILIUM_POD_CIDR="10.0.0.0/8"

# CNI manifest URLs (version-pinned)
readonly CALICO_VERSION="v3.27.2"
readonly FLANNEL_VERSION="v0.24.2"
readonly CILIUM_VERSION="v1.15.3"

readonly CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
readonly FLANNEL_URL="https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml"
readonly CILIUM_URL="https://raw.githubusercontent.com/cilium/cilium/${CILIUM_VERSION}/install/kubernetes/quick-install.yaml"

# GitHub mirror for China
readonly GH_MIRRORS=("https://ghp.ci" "https://gh-proxy.com" "https://ghproxy.net")

# Image registries
readonly REGISTRY_INTL="registry.k8s.io"
readonly REGISTRY_CN="registry.aliyuncs.com/google_containers"

# Docker Hub mirrors for China
readonly DOCKER_MIRROR_CN="https://docker.m.daocloud.io"

# K8s package repos
readonly K8S_APT_INTL="https://packages.cloud.google.com/apt"
readonly K8S_APT_CN="https://mirrors.aliyun.com/kubernetes/apt"
readonly K8S_YUM_INTL="https://packages.cloud.google.com/yum"
readonly K8S_YUM_CN="https://mirrors.aliyun.com/kubernetes/yum"

get_pause_version() {
    local minor
    minor=$(get_k8s_minor_version)
    case "${minor}" in
        1.24) echo "3.7" ;;
        1.25) echo "3.8" ;;
        *)    echo "3.9" ;;
    esac
}

# ======================== Colors ========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()    { echo -e "\n${BLUE}${BOLD}[STEP]${NC}  ${BOLD}$*${NC}"; }
log_detail()  { echo -e "${CYAN}  ↳${NC} $*"; }

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║        Kubernetes Quick Deploy v${SCRIPT_VERSION}          ║"
    echo "╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ======================== Global Variables ========================
COMMAND=""
K8S_VERSION="1.28.2"
NETWORK_PLUGIN="calico"
POD_CIDR=""
VIP=""
MASTER_IPS=""
MASTER_IP=""
TOKEN=""
CERT_KEY=""
CA_CERT_HASH=""
NODE_NAME=""
IS_CHINA=false
OS_ID=""
OS_VERSION=""
HOST_IP=""
DEFAULT_IFACE=""
IMAGE_REGISTRY=""
PAUSE_IMG_VER=""

# ======================== Usage ========================
usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  init                Initialize first master node
  join-control-plane  Join additional master (control-plane) node
  join-worker         Join worker node
  reset               Reset this node (kubeadm reset)

Options:
  --k8s-version <version>              K8s version (default: 1.28.2)
  --network-plugin <calico|flannel|cilium>  CNI plugin (default: calico)
  --pod-cidr <cidr>                    Pod CIDR (default: auto based on CNI)
  --vip <ip>                           Virtual IP for HA (required for multi-master)
  --master-ips <ip1,ip2,ip3>           All master node IPs for HA haproxy config
  --token <token>                      Bootstrap token (for join commands)
  --certificate-key <key>              Certificate key (for join-control-plane)
  --discovery-token-ca-cert-hash <h>   CA certificate hash (for join commands)
  --master-ip <ip>                     Master node IP (for join commands, required for single-master)
  --node-name <name>                   Node name (default: system hostname)
  -h, --help                           Show this help

EOF
    exit 0
}

# ======================== Argument Parsing ========================
parse_args() {
    [[ $# -lt 1 ]] && usage

    COMMAND="$1"
    shift

    case "${COMMAND}" in
        init|join-control-plane|join-worker|reset) ;;
        -h|--help) usage ;;
        *) log_error "Unknown command: ${COMMAND}"; usage ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --k8s-version)           K8S_VERSION="$2";           shift 2 ;;
            --network-plugin)        NETWORK_PLUGIN="$2";        shift 2 ;;
            --pod-cidr)             POD_CIDR="$2";              shift 2 ;;
            --vip)                  VIP="$2";                   shift 2 ;;
            --master-ips)           MASTER_IPS="$2";            shift 2 ;;
            --master-ip)            MASTER_IP="$2";             shift 2 ;;
            --token)                TOKEN="$2";                 shift 2 ;;
            --certificate-key)      CERT_KEY="$2";              shift 2 ;;
            --discovery-token-ca-cert-hash) CA_CERT_HASH="$2";  shift 2 ;;
            --node-name)            NODE_NAME="$2";             shift 2 ;;
            -h|--help)              usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done

    # Set default Pod CIDR based on CNI
    if [[ -z "${POD_CIDR}" ]]; then
        case "${NETWORK_PLUGIN}" in
            calico) POD_CIDR="${CALICO_POD_CIDR}" ;;
            flannel) POD_CIDR="${FLANNEL_POD_CIDR}" ;;
            cilium)  POD_CIDR="${CILIUM_POD_CIDR}" ;;
            *)       POD_CIDR="${CALICO_POD_CIDR}" ;;
        esac
    fi

    # Validate network plugin
    case "${NETWORK_PLUGIN}" in
        calico|flannel|cilium) ;;
        *) log_error "Unsupported network plugin: ${NETWORK_PLUGIN}. Use calico, flannel, or cilium."; exit 1 ;;
    esac

    # Validate K8s version format
    if ! [[ "${K8S_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid K8s version format: ${K8S_VERSION}. Expected format: X.Y.Z (e.g., 1.28.2)"
        exit 1
    fi

    # HA validation
    if [[ "${COMMAND}" == "init" && -n "${VIP}" && -z "${MASTER_IPS}" ]]; then
        log_error "--vip requires --master-ips for HA setup"
        exit 1
    fi

    if [[ "${COMMAND}" == "init" && -n "${MASTER_IPS}" && -z "${VIP}" ]]; then
        log_error "--master-ips requires --vip for HA setup"
        exit 1
    fi

    # Join commands require token and hash
    if [[ "${COMMAND}" == "join-control-plane" || "${COMMAND}" == "join-worker" ]]; then
        if [[ -z "${TOKEN}" || -z "${CA_CERT_HASH}" ]]; then
            log_error "Join commands require --token and --discovery-token-ca-cert-hash"
            exit 1
        fi
    fi

    if [[ "${COMMAND}" == "join-control-plane" && -z "${CERT_KEY}" ]]; then
        log_error "join-control-plane requires --certificate-key"
        exit 1
    fi
}

# ======================== Utility Functions ========================
command_exists() {
    command -v "$1" &>/dev/null
}

is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

get_k8s_minor_version() {
    echo "${K8S_VERSION}" | cut -d. -f1,2
}

get_pause_version() {
    local minor
    minor=$(get_k8s_minor_version)
    case "${minor}" in
        1.24) echo "3.7" ;;
        1.25) echo "3.8" ;;
        *)    echo "3.9" ;;
    esac
}

# ======================== OS Detection ========================
detect_os() {
    log_step "Detecting operating system"

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
        OS_VERSION=$(rpm -q --qf '%{VERSION}' centos-release 2>/dev/null || echo "7")
    else
        log_error "Unsupported OS. This script supports Ubuntu/Debian and CentOS/RHEL/Rocky."
        exit 1
    fi

    log_detail "OS: ${OS_ID} ${OS_VERSION}"

    case "${OS_ID}" in
        ubuntu|debian)   OS_FAMILY="debian" ;;
        centos|rhel|rocky|almalinux|anolis) OS_FAMILY="redhat" ;;
        *) log_error "Unsupported OS: ${OS_ID}"; exit 1 ;;
    esac

    log_detail "OS family: ${OS_FAMILY}"
}

# ======================== Network Detection ========================
detect_network() {
    log_step "Detecting network environment (China / International)"

    if ping -c 1 -W 3 google.com &>/dev/null; then
        IS_CHINA=false
        IMAGE_REGISTRY="${REGISTRY_INTL}"
        log_info "International network detected → using ${IMAGE_REGISTRY}"
    else
        IS_CHINA=true
        IMAGE_REGISTRY="${REGISTRY_CN}"
        log_info "China network detected → using ${IMAGE_REGISTRY}"
    fi

    PAUSE_IMG_VER=$(get_pause_version)
}

# ======================== Host IP Detection ========================
detect_host_ip() {
    log_step "Detecting host IP address"

    DEFAULT_IFACE=$(ip route | awk '/default/ {print $5}' | head -1)
    if [[ -z "${DEFAULT_IFACE}" ]]; then
        log_error "Cannot detect default network interface"
        exit 1
    fi

    HOST_IP=$(ip -4 addr show "${DEFAULT_IFACE}" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [[ -z "${HOST_IP}" ]]; then
        log_error "Cannot detect host IP on interface ${DEFAULT_IFACE}"
        exit 1
    fi

    log_detail "Interface: ${DEFAULT_IFACE}, IP: ${HOST_IP}"
}

# ======================== Prerequisite Checks ========================
check_prerequisites() {
    log_step "Checking prerequisites"

    # Root check
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    log_detail "Running as root ✓"

    # Architecture check
    local arch
    arch=$(uname -m)
    if [[ "${arch}" != "x86_64" && "${arch}" != "aarch64" ]]; then
        log_error "Unsupported architecture: ${arch}. Only x86_64 and aarch64 are supported."
        exit 1
    fi
    log_detail "Architecture: ${arch} ✓"

    # Memory check (at least 2GB)
    local mem_mb
    mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    if [[ "${mem_mb}" -lt 1700 ]]; then
        log_error "Insufficient memory: ${mem_mb}MB. At least 2GB required."
        exit 1
    fi
    log_detail "Memory: ${mem_mb}MB ✓"

    # CPU check (at least 2 cores)
    local cpu_cores
    cpu_cores=$(nproc)
    if [[ "${cpu_cores}" -lt 2 ]]; then
        log_warn "Low CPU cores: ${cpu_cores}. At least 2 recommended."
    else
        log_detail "CPU cores: ${cpu_cores} ✓"
    fi
}

# ======================== System Preparation ========================
configure_system() {
    log_step "Configuring system (swap, sysctl, kernel modules)"

    # Set hostname if --node-name is specified
    if [[ -n "${NODE_NAME}" ]]; then
        hostnamectl set-hostname "${NODE_NAME}" 2>/dev/null || hostname "${NODE_NAME}" 2>/dev/null || true
        log_detail "Hostname set to: ${NODE_NAME} ✓"
    fi

    # Disable swap
    swapoff -a
    sed -i '/swap/s/^/#/' /etc/fstab
    log_detail "Swap disabled ✓"

    # Load kernel modules
    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
    modprobe overlay
    modprobe br_netfilter
    log_detail "Kernel modules loaded ✓"

    # Sysctl parameters
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system &>/dev/null
    log_detail "Sysctl parameters set ✓"

    # Disable firewalld (RedHat)
    if [[ "${OS_FAMILY}" == "redhat" ]]; then
        if systemctl is-active firewalld &>/dev/null; then
            systemctl disable --now firewalld
            log_detail "Firewalld disabled ✓"
        fi
    fi

    # Disable ufw (Debian)
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        if command_exists ufw; then
            ufw disable &>/dev/null || true
            log_detail "UFW disabled ✓"
        fi
    fi

    # Set SELinux to permissive (RedHat)
    if [[ "${OS_FAMILY}" == "redhat" ]]; then
        if command_exists setenforce; then
            setenforce 0 || true
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
            log_detail "SELinux set to permissive ✓"
        fi
    fi

    # Time sync
    if ! systemctl is-active chronyd &>/dev/null && ! systemctl is-active systemd-timesyncd &>/dev/null; then
        if [[ "${OS_FAMILY}" == "redhat" ]]; then
            yum install -y chrony &>/dev/null
            systemctl enable --now chronyd
        else
            apt-get install -y chrony &>/dev/null || true
            systemctl enable --now chrony 2>/dev/null || true
        fi
        log_detail "Time sync configured ✓"
    fi
}

# ======================== Containerd Installation ========================
install_containerd() {
    log_step "Installing containerd"

    if command_exists containerd && containerd --version &>/dev/null; then
        log_info "containerd already installed: $(containerd --version)"
        configure_containerd
        return
    fi

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        install_containerd_debian
    else
        install_containerd_redhat
    fi

    configure_containerd
    systemctl enable --now containerd
    log_info "containerd installed and started ✓"
}

install_containerd_debian() {
    # Install dependencies
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    # Add Docker official GPG key (containerd comes from docker repo)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    mkdir -p /etc/apt/sources.list.d
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
        $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y containerd.io
}

install_containerd_redhat() {
    # Install dependencies
    yum install -y yum-utils ca-certificates curl

    # Add Docker repository
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    yum install -y containerd.io
}

configure_containerd() {
    log_step "Configuring containerd"

    # Always regenerate config to ensure correct format for current version
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml

    # Detect containerd major version for config format differences
    local ctd_ver
    ctd_ver=$(containerd --version | grep -oP '\d+\.\d+' | head -1)
    local ctd_major
    ctd_major=$(echo "${ctd_ver}" | cut -d. -f1)

    # Enable SystemdCgroup
    sed -i 's/SystemdCgroup\s*=\s*false/SystemdCgroup = true/' /etc/containerd/config.toml
    log_detail "SystemdCgroup enabled ✓"

    # Set sandbox image based on registry
    local sandbox_img="${IMAGE_REGISTRY}/pause:${PAUSE_IMG_VER}"
    if [[ "${ctd_major}" -ge 2 ]]; then
        # containerd 2.x: pinned_images.sandbox = '...'
        sed -i "s|sandbox\s*=\s*'.*'|sandbox = '${sandbox_img}'|" /etc/containerd/config.toml
    else
        # containerd 1.x: sandbox_image = "..."
        sed -i "s|sandbox_image.*=.*|sandbox_image = \"${sandbox_img}\"|" /etc/containerd/config.toml
    fi
    log_detail "Sandbox image: ${sandbox_img} ✓"

    # Configure registry mirrors for China
    if [[ "${IS_CHINA}" == true ]]; then
        configure_containerd_china_mirrors
    fi

    systemctl restart containerd
}

configure_containerd_china_mirrors() {
    log_detail "Configuring China registry mirrors"

    # For containerd 1.x with config.toml
    # Check if registry.mirrors section exists, if not append
    local config_file="/etc/containerd/config.toml"

    # Create a registry config directory for containerd 1.4+ style
    mkdir -p /etc/containerd/certs.d/docker.io
    cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://registry-1.docker.io"
[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
EOF

    mkdir -p /etc/containerd/certs.d/registry.k8s.io
    cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<EOF
server = "https://registry.k8s.io"
[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
EOF

    mkdir -p /etc/containerd/certs.d/k8s.gcr.io
    cat > /etc/containerd/certs.d/k8s.gcr.io/hosts.toml <<EOF
server = "https://k8s.gcr.io"
[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
EOF

    mkdir -p /etc/containerd/certs.d/quay.io
    cat > /etc/containerd/certs.d/quay.io/hosts.toml <<EOF
server = "https://quay.io"
[host."https://quay.m.daocloud.io"]
  capabilities = ["pull", "resolve"]
  skip_verify = false
EOF

    log_detail "Registry mirrors configured ✓"
}

# ======================== K8s Packages Installation ========================
install_k8s_packages() {
    log_step "Installing kubeadm, kubelet, kubectl (v${K8S_VERSION})"

    if command_exists kubeadm; then
        local installed_ver
        installed_ver=$(kubeadm version -o short 2>/dev/null || echo "unknown")
        if [[ "${installed_ver}" == "v${K8S_VERSION}" ]]; then
            log_info "kubeadm ${installed_ver} already installed ✓"
            systemctl enable kubelet
            return
        fi
        log_warn "Installed kubeadm ${installed_ver} doesn't match requested ${K8S_VERSION}, will reinstall"
    fi

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        install_k8s_debian
    else
        install_k8s_redhat
    fi

    systemctl enable kubelet
    log_info "kubeadm $(kubeadm version -o short) installed ✓"
}

install_k8s_debian() {
    local minor_ver
    minor_ver=$(get_k8s_minor_version)
    local major minor
    major=$(echo "${minor_ver}" | cut -d. -f1)
    minor=$(echo "${minor_ver}" | cut -d. -f2)

    apt-get install -y apt-transport-https ca-certificates curl gpg

    # K8s 1.24+ uses pkgs.k8s.io (new community-owned repository)
    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor_ver}/deb/Release.key" | \
        gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    local k8s_apt_url="https://pkgs.k8s.io/core:/stable:/v${minor_ver}/deb/"
    if [[ "${IS_CHINA}" == true ]]; then
        if curl -fsSL --connect-timeout 5 -o /dev/null "https://mirrors.aliyun.com/kubernetes-new/core:/stable:/v${minor_ver}/deb/Release.key" 2>/dev/null; then
            k8s_apt_url="https://mirrors.aliyun.com/kubernetes-new/core:/stable:/v${minor_ver}/deb/"
        else
            log_warn "Aliyun K8s mirror unavailable for v${minor_ver}, falling back to pkgs.k8s.io"
        fi
    fi

    mkdir -p /etc/apt/sources.list.d
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${k8s_apt_url} /" | \
        tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

    apt-get update -y
    apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    apt-get install -y kubelet="${K8S_VERSION}-*" kubeadm="${K8S_VERSION}-*" kubectl="${K8S_VERSION}-*"
    apt-mark hold kubelet kubeadm kubectl
}

install_k8s_redhat() {
    local yum_repo="${K8S_YUM_INTL}"
    if [[ "${IS_CHINA}" == true ]]; then
        yum_repo="${K8S_YUM_CN}"
    fi

    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=${yum_repo}/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF

    yum install -y kubelet-"${K8S_VERSION}" kubeadm-"${K8S_VERSION}" kubectl-"${K8S_VERSION}" --disableexcludes=kubernetes
    yum versionlock add kubelet kubeadm kubectl 2>/dev/null || true
}

# ======================== Pull K8s Images ========================
pull_k8s_images() {
    log_step "Pulling Kubernetes images"

    log_info "Using image registry: ${IMAGE_REGISTRY}"

    if [[ "${IS_CHINA}" == true ]]; then
        # Pull images from China mirror
        kubeadm config images pull \
            --kubernetes-version "${K8S_VERSION}" \
            --image-repository "${IMAGE_REGISTRY}"
    else
        kubeadm config images pull \
            --kubernetes-version "${K8S_VERSION}" \
            --image-repository "${IMAGE_REGISTRY}"
    fi

    log_info "K8s images pulled ✓"
}

# ======================== HA Setup (HAProxy + Keepalived) ========================
setup_haproxy_keepalived() {
    if [[ -z "${VIP}" ]]; then
        return
    fi

    log_step "Setting up HAProxy + Keepalived for HA"

    local master_ip_array
    IFS=',' read -ra master_ip_array <<< "${MASTER_IPS}"

    # Install HAProxy and Keepalived
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        apt-get install -y haproxy keepalived
    else
        yum install -y haproxy keepalived
    fi

    # ---------- Configure HAProxy ----------
    local haproxy_backend=""
    local i=1
    for mip in "${master_ip_array[@]}"; do
        haproxy_backend+="    server master${i} ${mip}:${K8S_API_PORT} check inter 2000 fall 2 rise 2 weight 100\n"
        ((i++))
    done

    cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log         127.0.0.1 local2
    maxconn     4000
    daemon

defaults
    mode                    tcp
    log                     global
    retries                 3
    timeout connect         5s
    timeout client          30s
    timeout server          30s

frontend k8s-api-fe
    bind *:${HAPROXY_PORT}
    default_backend k8s-api-be

backend k8s-api-be
    balance roundrobin
$(echo -e "${haproxy_backend}")
EOF

    log_detail "HAProxy configured ✓"

    # ---------- Configure Keepalived ----------
    # Determine this node's priority (first master = highest)
    local priority=100
    local state="MASTER"
    i=1
    for mip in "${master_ip_array[@]}"; do
        if [[ "${mip}" == "${HOST_IP}" ]]; then
            priority=$((100 - (i - 1) * 10))
            if [[ ${i} -gt 1 ]]; then
                state="BACKUP"
            fi
            break
        fi
        ((i++))
    done

    # Keepalived health check script
    cat > /etc/keepalived/check_haproxy.sh <<'EOF'
#!/bin/bash
if ! killall -0 haproxy 2>/dev/null; then
    systemctl restart haproxy
    sleep 2
    if ! killall -0 haproxy 2>/dev/null; then
        exit 1
    fi
fi
exit 0
EOF
    chmod +x /etc/keepalived/check_haproxy.sh

    cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id LVS_K8S
}

vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 3
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_K8S {
    state ${state}
    interface ${DEFAULT_IFACE}
    virtual_router_id ${KEEPALIVED_VRID}
    priority ${priority}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass k8s_ha
    }

    virtual_ipaddress {
        ${VIP}/32
    }

    track_script {
        check_haproxy
    }
}
EOF

    log_detail "Keepalived configured (state=${state}, priority=${priority}) ✓"

    # Start services
    systemctl enable --now haproxy
    systemctl enable --now keepalived

    # Wait for VIP
    log_info "Waiting for VIP ${VIP} to be available..."
    local retry=0
    while [[ ${retry} -lt 30 ]]; do
        if ip addr show | grep -q "${VIP}"; then
            log_info "VIP ${VIP} is active ✓"
            return
        fi
        sleep 1
        ((retry++))
    done
    log_warn "VIP ${VIP} not yet visible on this node (may appear on another master)"
}

# ======================== Master Initialization ========================
init_master() {
    log_step "Initializing Kubernetes master (v${K8S_VERSION})"

    # Generate kubeadm config
    local kubeadm_config="/etc/kubernetes/kubeadm-init.yaml"
    local control_plane_endpoint=""

    mkdir -p /etc/kubernetes

    if [[ -n "${VIP}" ]]; then
        control_plane_endpoint="${VIP}:${HAPROXY_PORT}"
    fi

    cat > "${kubeadm_config}" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    cgroup-driver: systemd
EOF

    if [[ -n "${NODE_NAME}" ]]; then
        sed -i "/nodeRegistration:/a\\  name: ${NODE_NAME}" "${kubeadm_config}"
    fi

    cat >> "${kubeadm_config}" <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
imageRepository: ${IMAGE_REGISTRY}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
EOF

    if [[ -n "${control_plane_endpoint}" ]]; then
        echo "controlPlaneEndpoint: ${control_plane_endpoint}" >> "${kubeadm_config}"
    fi

    # For multi-master, upload certs
    local upload_certs_flag=""
    if [[ -n "${VIP}" ]]; then
        upload_certs_flag="--upload-certs"
        cat >> "${kubeadm_config}" <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: UploadCertsConfiguration
ttl: 24h0m0s
EOF
    fi

    log_info "Running kubeadm init..."
    if [[ -n "${VIP}" ]]; then
        kubeadm init --config "${kubeadm_config}" --upload-certs -v 1
    else
        kubeadm init --config "${kubeadm_config}" -v 1
    fi

    # Configure kubectl for root
    export KUBECONFIG=/etc/kubernetes/admin.conf
    mkdir -p "${HOME}/.kube"
    cp -i /etc/kubernetes/admin.conf "${HOME}/.kube/config"
    chown "$(id -u):$(id -g)" "${HOME}/.kube/config" 2>/dev/null || true

    log_info "Master initialized ✓"
}

# ======================== CNI Installation ========================
install_cni() {
    log_step "Installing network plugin: ${NETWORK_PLUGIN}"

    local cni_url=""
    case "${NETWORK_PLUGIN}" in
        calico) cni_url="${CALICO_URL}" ;;
        flannel) cni_url="${FLANNEL_URL}" ;;
        cilium)  cni_url="${CILIUM_URL}" ;;
    esac

    local yaml_file="/tmp/${NETWORK_PLUGIN}.yaml"
    local downloaded=false

    # Try direct download first
    log_info "Downloading ${NETWORK_PLUGIN} manifest..."
    if curl -fsSL --connect-timeout 10 -o "${yaml_file}" "${cni_url}"; then
        downloaded=true
        log_detail "Downloaded from GitHub directly ✓"
    fi

    # If direct download failed and in China, try mirrors
    if [[ "${downloaded}" == false ]]; then
        log_warn "Direct download failed, trying GitHub mirrors..."
        for mirror in "${GH_MIRRORS[@]}"; do
            local mirror_url="${mirror}/${cni_url}"
            if curl -fsSL --connect-timeout 10 -o "${yaml_file}" "${mirror_url}"; then
                downloaded=true
                log_detail "Downloaded from mirror: ${mirror} ✓"
                break
            fi
        done
    fi

    if [[ "${downloaded}" == false ]]; then
        log_error "Failed to download ${NETWORK_PLUGIN} manifest. Please download manually:"
        log_error "  curl -o ${yaml_file} ${cni_url}"
        log_error "Then apply: kubectl apply -f ${yaml_file}"
        return 1
    fi

    # Patch Pod CIDR for Flannel
    if [[ "${NETWORK_PLUGIN}" == "flannel" ]]; then
        sed -i "s|\"Network\": \"[^\"]*\"|\"Network\": \"${POD_CIDR}\"|" "${yaml_file}"
    fi

    # Patch Pod CIDR for Calico
    if [[ "${NETWORK_PLUGIN}" == "calico" ]]; then
        sed -i "s|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|" "${yaml_file}"
        sed -i "s|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|" "${yaml_file}"
    fi

    # Apply CNI manifest
    kubectl apply -f "${yaml_file}"
    log_info "${NETWORK_PLUGIN} network plugin applied ✓"

    # Wait for CNI pods to be ready
    log_info "Waiting for CNI pods to be ready..."
    kubectl wait --for=condition=Ready pods -n kube-system -l "k8s-app in (calico-node,flannel,cilium)" --timeout=120s 2>/dev/null || {
        log_warn "CNI pods not all ready within 120s, check with: kubectl get pods -n kube-system"
    }
}

# ======================== Generate Join Commands ========================
generate_join_commands() {
    log_step "Generating join commands"

    echo -e "\n${GREEN}${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Cluster initialized successfully!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════${NC}"

    # Get join token
    local join_token cert_key_hash certificate_key
    join_token=$(kubeadm token create --print-join-command 2>/dev/null | grep -oP 'token \K\S+' || kubeadm token generate)
    if ! kubeadm token list | grep -q "${join_token}"; then
        kubeadm token create "${join_token}" --ttl 24h &>/dev/null
    fi

    # Get CA cert hash
    cert_key_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
        openssl rsa -pubin -outform DER 2>/dev/null | \
        sha256sum | awk '{print $1}')
    cert_key_hash="sha256:${cert_key_hash}"

    # Get certificate key (for control-plane join)
    if [[ -n "${VIP}" ]]; then
        certificate_key=$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
    fi

    local endpoint="${HOST_IP}:${K8S_API_PORT}"
    if [[ -n "${VIP}" ]]; then
        endpoint="${VIP}:${HAPROXY_PORT}"
    fi

    echo ""
    echo -e "${CYAN}▸ Worker join command:${NC}"
    if [[ -n "${VIP}" ]]; then
        echo -e "${YELLOW}  ./deploy-k8s.sh join-worker \\"
        echo -e "    --vip ${VIP} \\"
        echo -e "    --node-name <NODE_NAME> \\"
        echo -e "    --token ${join_token} \\"
        echo -e "    --discovery-token-ca-cert-hash ${cert_key_hash}${NC}"
    else
        echo -e "${YELLOW}  ./deploy-k8s.sh join-worker \\"
        echo -e "    --master-ip ${HOST_IP} \\"
        echo -e "    --node-name <NODE_NAME> \\"
        echo -e "    --token ${join_token} \\"
        echo -e "    --discovery-token-ca-cert-hash ${cert_key_hash}${NC}"
    fi

    if [[ -n "${VIP}" && -n "${certificate_key}" ]]; then
        echo ""
        echo -e "${CYAN}▸ Control-plane join command:${NC}"
        echo -e "${YELLOW}  ./deploy-k8s.sh join-control-plane \\"
        echo -e "    --vip ${VIP} \\"
        echo -e "    --token ${join_token} \\"
        echo -e "    --discovery-token-ca-cert-hash ${cert_key_hash} \\"
        echo -e "    --certificate-key ${certificate_key}${NC}"
    fi

    echo ""
    echo -e "${CYAN}▸ Verify cluster:${NC}"
    echo -e "${YELLOW}  kubectl get nodes${NC}"
    echo ""
    echo -e "${CYAN}▸ Install kubectl on your local machine:${NC}"
    echo -e "${YELLOW}  scp root@${HOST_IP}:/etc/kubernetes/admin.conf ~/.kube/config${NC}"
    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════${NC}"
}

# ======================== Join Control Plane ========================
join_control_plane() {
    log_step "Joining control-plane node to cluster"

    local endpoint
    if [[ -n "${VIP}" ]]; then
        endpoint="${VIP}:${HAPROXY_PORT}"
    elif [[ -n "${MASTER_IP}" ]]; then
        endpoint="${MASTER_IP}:${K8S_API_PORT}"
    else
        log_error "join-control-plane requires --master-ip (or --vip for HA)"
        exit 1
    fi

    local node_name_flag=()
    if [[ -n "${NODE_NAME}" ]]; then
        node_name_flag=(--node-name "${NODE_NAME}")
    fi

    kubeadm join "${endpoint}" \
        --token "${TOKEN}" \
        --discovery-token-ca-cert-hash "${CA_CERT_HASH}" \
        --certificate-key "${CERT_KEY}" \
        --control-plane \
        --cri-socket unix:///run/containerd/containerd.sock \
        "${node_name_flag[@]}"

    # Configure kubectl
    export KUBECONFIG=/etc/kubernetes/admin.conf
    mkdir -p "${HOME}/.kube"
    cp -i /etc/kubernetes/admin.conf "${HOME}/.kube/config"
    chown "$(id -u):$(id -g)" "${HOME}/.kube/config" 2>/dev/null || true

    log_info "Control-plane node joined ✓"
    log_detail "Verify with: kubectl get nodes"
}

# ======================== Join Worker ========================
join_worker() {
    log_step "Joining worker node to cluster"

    local endpoint
    if [[ -n "${VIP}" ]]; then
        endpoint="${VIP}:${HAPROXY_PORT}"
    elif [[ -n "${MASTER_IP}" ]]; then
        endpoint="${MASTER_IP}:${K8S_API_PORT}"
    else
        log_error "Join worker requires --master-ip (or --vip for HA). Example: --master-ip 192.168.1.10"
        exit 1
    fi

    local node_name_flag=()
    if [[ -n "${NODE_NAME}" ]]; then
        node_name_flag=(--node-name "${NODE_NAME}")
    fi

    kubeadm join "${endpoint}" \
        --token "${TOKEN}" \
        --discovery-token-ca-cert-hash "${CA_CERT_HASH}" \
        --cri-socket unix:///run/containerd/containerd.sock \
        "${node_name_flag[@]}"

    log_info "Worker node joined ✓"
    log_detail "Verify on master with: kubectl get nodes"
}

# ======================== Reset Node ========================
reset_node() {
    log_step "Resetting this node"

    kubeadm reset -f

    # Clean up
    rm -rf /etc/kubernetes /etc/cni/net.d /var/lib/etcd /var/lib/kubelet
    rm -f "${HOME}/.kube/config"
    iptables -F &>/dev/null
    iptables -t nat -F &>/dev/null
    iptables -t mangle -F &>/dev/null
    ipvsadm --clear &>/dev/null || true

    # Stop HA services if installed
    systemctl disable --now haproxy 2>/dev/null || true
    systemctl disable --now keepalived 2>/dev/null || true

    log_info "Node reset complete ✓"
}

# ======================== Print Summary ========================
print_summary() {
    echo -e "\n${CYAN}${BOLD}── Deployment Summary ──${NC}"
    echo -e "  K8s Version:      ${BOLD}${K8S_VERSION}${NC}"
    echo -e "  Network Plugin:   ${BOLD}${NETWORK_PLUGIN}${NC}"
    echo -e "  Pod CIDR:         ${BOLD}${POD_CIDR}${NC}"
    echo -e "  Service CIDR:     ${BOLD}${SERVICE_CIDR}${NC}"
    echo -e "  Image Registry:   ${BOLD}${IMAGE_REGISTRY}${NC}"
    echo -e "  China Mode:       ${BOLD}${IS_CHINA}${NC}"
    if [[ -n "${VIP}" ]]; then
        echo -e "  HA Mode:          ${BOLD}enabled${NC}"
        echo -e "  VIP:              ${BOLD}${VIP}${NC}"
        echo -e "  Master IPs:       ${BOLD}${MASTER_IPS}${NC}"
    else
        echo -e "  HA Mode:          ${BOLD}disabled (single master)${NC}"
    fi
    echo -e "  Host IP:          ${BOLD}${HOST_IP}${NC}"
    echo -e "  OS:               ${BOLD}${OS_ID} ${OS_VERSION}${NC}"
    echo ""
}

# ======================== Main ========================
main() {
    banner
    parse_args "$@"

    case "${COMMAND}" in
        reset)
            reset_node
            exit 0
            ;;
    esac

    # Common setup for init and join commands
    detect_os
    detect_network
    detect_host_ip
    check_prerequisites
    configure_system
    install_containerd
    install_k8s_packages
    pull_k8s_images

    case "${COMMAND}" in
        init)
            setup_haproxy_keepalived
            init_master
            install_cni
            print_summary
            generate_join_commands
            ;;
        join-control-plane)
            setup_haproxy_keepalived
            join_control_plane
            print_summary
            ;;
        join-worker)
            join_worker
            print_summary
            ;;
    esac
}

main "$@"
