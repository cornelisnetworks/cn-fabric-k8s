#!/bin/bash
#
# Package Manager Library for Kubernetes Node Prerequisites
# Provides distribution-independent package management and system configuration
#
# Usage: Source this file in other scripts
#   source automation/scripts/lib/package-manager.sh
#
# Supported Distributions:
#   - Ubuntu/Debian (apt)
#   - RHEL/CentOS/Rocky/Fedora (dnf/yum)
#   - SLES/openSUSE (zypper)
#

set -euo pipefail

# Global variables
DISTRO_ID=""
DISTRO_VERSION=""
DISTRO_ID_LIKE=""
DISTRO_NAME=""
PKG_MGR=""
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() {
    if [ "${JSON_OUTPUT:-false}" != "true" ]; then
        echo -e "${BLUE}[INFO]${NC} $*"
    fi
}

log_success() {
    if [ "${JSON_OUTPUT:-false}" != "true" ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $*"
    fi
}

log_warn() {
    if [ "${JSON_OUTPUT:-false}" != "true" ]; then
        echo -e "${YELLOW}[WARN]${NC} $*"
    fi
}

log_fail() {
    if [ "${JSON_OUTPUT:-false}" != "true" ]; then
        echo -e "${RED}[FAIL]${NC} $*"
    fi
}

log_error() {
    if [ "${JSON_OUTPUT:-false}" != "true" ]; then
        echo -e "${RED}[ERROR]${NC} $*" >&2
    else
        echo -e "${RED}[ERROR]${NC} $*" >&2
    fi
}

log_debug() {
    if [ "${VERBOSE}" = "true" ] && [ "${JSON_OUTPUT:-false}" != "true" ]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}



# Distribution Detection Functions

detect_distro() {
    log_debug "Detecting Linux distribution..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID}"
        DISTRO_VERSION="${VERSION_ID:-unknown}"
        DISTRO_ID_LIKE="${ID_LIKE:-}"
        DISTRO_NAME="${NAME}"
        log_info "Detected: ${DISTRO_NAME} (${DISTRO_ID} ${DISTRO_VERSION})"
        return 0
    
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO_ID=$(echo "${DISTRIB_ID}" | tr '[:upper:]' '[:lower:]')
        DISTRO_VERSION="${DISTRIB_RELEASE:-unknown}"
        DISTRO_NAME="${DISTRIB_DESCRIPTION}"
        log_info "Detected via lsb-release: ${DISTRO_NAME}"
        return 0
    
    elif command -v lsb_release >/dev/null 2>&1; then
        DISTRO_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        DISTRO_VERSION=$(lsb_release -sr)
        DISTRO_NAME=$(lsb_release -sd | tr -d '"')
        log_info "Detected via lsb_release command: ${DISTRO_NAME}"
        return 0
    
    elif [ -f /etc/redhat-release ]; then
        DISTRO_ID="rhel"
        DISTRO_NAME=$(cat /etc/redhat-release)
        DISTRO_VERSION="unknown"
        log_info "Detected via redhat-release: ${DISTRO_NAME}"
        return 0
    
    elif [ -f /etc/debian_version ]; then
        DISTRO_ID="debian"
        DISTRO_VERSION=$(cat /etc/debian_version)
        DISTRO_NAME="Debian ${DISTRO_VERSION}"
        log_info "Detected via debian_version: ${DISTRO_NAME}"
        return 0
    
    else
        log_error "Unable to detect Linux distribution"
        return 1
    fi
}

get_package_manager() {
    local distro_id="$1"
    local distro_id_like="$2"
    
    log_debug "Determining package manager for ${distro_id} (like: ${distro_id_like})"
    
    case "${distro_id_like}" in
        *debian*)
            echo "apt"
            return 0
            ;;
        *rhel*|*fedora*)
            if command -v dnf >/dev/null 2>&1; then
                echo "dnf"
            else
                echo "yum"
            fi
            return 0
            ;;
        *suse*)
            echo "zypper"
            return 0
            ;;
    esac
    
    case "${distro_id}" in
        ubuntu|debian|linuxmint|pop)
            echo "apt"
            ;;
        rhel|centos|rocky|almalinux|fedora|ol)
            if command -v dnf >/dev/null 2>&1; then
                echo "dnf"
            else
                echo "yum"
            fi
            ;;
        sles|opensuse*|suse)
            echo "zypper"
            ;;
        *)
            log_error "Unsupported distribution: ${distro_id}"
            echo "unknown"
            return 1
            ;;
    esac
}

get_distro_version() {
    echo "${DISTRO_VERSION}"
}

# Echo the kubeadm `--ignore-preflight-errors` flag string appropriate for this
# host (empty on apt/dnf distros). Only SLES/openSUSE needs SystemVerification
# suppressed: the supported SLES 16 kernel runs the cgroup-v2 unified hierarchy,
# where the v1 controllers (CONFIG_CGROUP_CPUACCT/DEVICE/FREEZER) read as "not
# set" and trip a benign SystemVerification failure. apt/dnf distros keep the
# full preflight checks so this broad suppression is never applied silently
# everywhere. Shared by start-control-plane.sh and start-worker.sh.
# The advisory log is sent to stderr so `$(kubeadm_preflight_ignores)` captures
# only the flag string on stdout.
kubeadm_preflight_ignores() {
    local pkg_mgr=""
    if detect_distro >/dev/null 2>&1; then
        pkg_mgr="$(get_package_manager "${DISTRO_ID:-}" "${DISTRO_ID_LIKE:-}" 2>/dev/null || true)"
    fi
    if [ "${pkg_mgr}" = "zypper" ]; then
        log_warn "SLES/openSUSE detected (${DISTRO_ID:-?} ${DISTRO_VERSION:-?}); suppressing kubeadm SystemVerification preflight (benign cgroup-v2 kernel-config false-positives)" >&2
        echo "--ignore-preflight-errors=SystemVerification"
    fi
}

# Package Manager Abstraction Functions

pkg_update_cache() {
    log_info "Updating package cache..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would update package cache"
        return 0
    fi
    
    case "${PKG_MGR}" in
        apt)
            apt-get update -qq
            ;;
        dnf)
            dnf makecache -q
            ;;
        yum)
            yum makecache -q
            ;;
        zypper)
            zypper --quiet refresh
            ;;
        *)
            log_error "Unknown package manager: ${PKG_MGR}"
            return 1
            ;;
    esac
}

wait_for_dnf_lock() {
    local max_wait=300
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if ! pgrep -f 'dnf|yum' >/dev/null 2>&1; then
            return 0
        fi
        log_info "Waiting for other dnf/yum processes to finish..."
        sleep 5
        waited=$((waited + 5))
    done
    
    log_error "Package manager lock held for over 300s. Refusing to force-kill (would corrupt RPM database)."
    log_error "Resolve manually:"
    log_error "  1. Identify the holder: lsof /var/lib/rpm/.rpm.lock 2>/dev/null || fuser /var/run/dnf.pid 2>/dev/null"
    log_error "  2. Wait for it to finish, OR if stale: pkill -TERM dnf && rm -f /var/run/dnf.pid"
    log_error "  3. Verify RPM DB intact: rpm --rebuilddb --quiet"
    log_error "  4. Re-run this script"
    exit 1
}

pkg_install() {
    local packages=("$@")
    log_info "Installing packages: ${packages[*]}"
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would install: ${packages[*]}"
        return 0
    fi
    
    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
            ;;
        dnf|yum)
            # Wait for any existing dnf/yum processes
            wait_for_dnf_lock
            
            sed -i '/^excludepkgs=/d; /^exclude =/d' /etc/dnf/dnf.conf 2>/dev/null || true
            sed -i '/^excludepkgs=/d; /^exclude =/d' /etc/yum.conf 2>/dev/null || true
            for repo_file in /etc/yum.repos.d/*.repo; do
                sed -i '/^excludepkgs=/d; /^exclude =/d' "$repo_file" 2>/dev/null || true
            done
            
            if [ -f /etc/dnf/plugins/versionlock.list ]; then
                sed -i '/kubelet/d; /kubeadm/d; /kubectl/d; /containerd/d' /etc/dnf/plugins/versionlock.list 2>/dev/null || true
            fi
            
            if [ "${PKG_MGR}" = "dnf" ]; then
                dnf clean all -q 2>/dev/null || true
                
                # Install packages one at a time to avoid resource issues
                for pkg in "${packages[@]}"; do
                    log_info "Installing ${pkg}..."
                    dnf install -y --setopt='*.excludepkgs=' --setopt='*.exclude=' "${pkg}" || return 1
                    sleep 1
                done
            else
                yum clean all -q 2>/dev/null || true
                
                # Install packages one at a time to avoid resource issues
                for pkg in "${packages[@]}"; do
                    log_info "Installing ${pkg}..."
                    yum install -y --setopt='*.excludepkgs=' --setopt='*.exclude=' "${pkg}" || return 1
                    sleep 1
                done
            fi
            ;;
        zypper)
            zypper --quiet --non-interactive install "${packages[@]}"
            ;;
        *)
            log_error "Unknown package manager: ${PKG_MGR}"
            return 1
            ;;
    esac
}

pkg_remove() {
    local packages=("$@")
    log_info "Removing packages: ${packages[*]}"
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would remove: ${packages[*]}"
        return 0
    fi
    
    case "${PKG_MGR}" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "${packages[@]}"
            ;;
        dnf|yum)
            # Wait for any existing dnf/yum processes
            wait_for_dnf_lock
            
            if [ "${PKG_MGR}" = "dnf" ]; then
                dnf remove -y -q "${packages[@]}"
            else
                yum remove -y -q "${packages[@]}"
            fi
            ;;
        zypper)
            zypper --quiet --non-interactive remove "${packages[@]}"
            ;;
        *)
            log_error "Unknown package manager: ${PKG_MGR}"
            return 1
            ;;
    esac
}

pkg_is_installed() {
    local package="$1"
    
    case "${PKG_MGR}" in
        apt)
            dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q "install ok installed"
            ;;
        dnf|yum)
            if [ "$package" = "containerd" ]; then
                rpm -q containerd >/dev/null 2>&1 || rpm -q containerd.io >/dev/null 2>&1
            else
                rpm -q "${package}" >/dev/null 2>&1
            fi
            ;;
        zypper)
            if [ "$package" = "containerd" ]; then
                rpm -q containerd >/dev/null 2>&1 || rpm -q containerd.io >/dev/null 2>&1
            else
                rpm -q "${package}" >/dev/null 2>&1
            fi
            ;;
        *)
            log_error "Unknown package manager: ${PKG_MGR}"
            return 1
            ;;
    esac
}

pkg_get_version() {
    local package="$1"
    
    case "${PKG_MGR}" in
        apt)
            dpkg-query -W -f='${Version}' "${package}" 2>/dev/null
            ;;
        dnf|yum)
            if [ "$package" = "containerd" ]; then
                if rpm -q containerd >/dev/null 2>&1; then
                    rpm -q --queryformat '%{VERSION}-%{RELEASE}' containerd 2>/dev/null
                elif rpm -q containerd.io >/dev/null 2>&1; then
                    rpm -q --queryformat '%{VERSION}-%{RELEASE}' containerd.io 2>/dev/null
                fi
            else
                rpm -q --queryformat '%{VERSION}-%{RELEASE}' "${package}" 2>/dev/null
            fi
            ;;
        zypper)
            if [ "$package" = "containerd" ]; then
                if rpm -q containerd >/dev/null 2>&1; then
                    rpm -q --queryformat '%{VERSION}-%{RELEASE}' containerd 2>/dev/null
                elif rpm -q containerd.io >/dev/null 2>&1; then
                    rpm -q --queryformat '%{VERSION}-%{RELEASE}' containerd.io 2>/dev/null
                fi
            else
                rpm -q --queryformat '%{VERSION}-%{RELEASE}' "${package}" 2>/dev/null
            fi
            ;;
        *)
            log_error "Unknown package manager: ${PKG_MGR}"
            return 1
            ;;
    esac
}

pkg_ensure_installed() {
    local package="$1"
    
    if pkg_is_installed "${package}"; then
        local version=$(pkg_get_version "${package}")
        log_success "${package} (${version})"
        return 0
    else
        log_warn "${package} not installed"
        pkg_install "${package}"
    fi
}

version_compare() {
    local v1="$1"
    local op="$2"
    local v2="$3"
    
    printf '%s\n%s\n' "$v1" "$v2" | sort -V -C
    local result=$?
    
    case "$op" in
        ">=")
            [ $result -eq 0 ]
            ;;
        "<=")
            printf '%s\n%s\n' "$v2" "$v1" | sort -V -C
            ;;
        "==")
            [ "$v1" = "$v2" ]
            ;;
        ">")
            [ "$v1" != "$v2" ] && printf '%s\n%s\n' "$v1" "$v2" | sort -V -C
            ;;
        "<")
            [ "$v1" != "$v2" ] && printf '%s\n%s\n' "$v2" "$v1" | sort -V -C
            ;;
        *)
            log_error "Unknown comparison operator: $op"
            return 1
            ;;
    esac
}

pkg_check_version() {
    local package="$1"
    local min_version="$2"
    
    if ! pkg_is_installed "${package}"; then
        log_fail "${package} not installed"
        return 1
    fi
    
    local current_version=$(pkg_get_version "${package}")
    current_version=$(echo "${current_version}" | sed 's/^[0-9]*://; s/-.*$//')
    
    if version_compare "${current_version}" ">=" "${min_version}"; then
        log_success "${package} ${current_version} (>= ${min_version})"
        return 0
    else
        log_fail "${package} ${current_version} (< ${min_version})"
        return 1
    fi
}

# Repository Management Functions
# NOTE: Repository setup removed - assumes OS has repos pre-configured

# System Configuration Functions

disable_swap() {
    local permanent="${1:-true}"
    
    log_info "Disabling swap..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would disable swap (permanent: ${permanent})"
        return 0
    fi
    
    swapoff -a
    
    if [ "${permanent}" = "true" ]; then
        log_info "Disabling swap permanently in /etc/fstab..."
        sed -i.bak '/\sswap\s/d' /etc/fstab
    fi
    
    log_success "Swap disabled"
}

load_kernel_module() {
    local module="$1"
    local persist="${2:-true}"
    
    log_debug "Loading kernel module: ${module}"
    
    if lsmod | grep -q "^${module}"; then
        log_debug "Module ${module} already loaded"
        return 0
    fi
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would load module ${module}"
        return 0
    fi
    
    modprobe "${module}"
    
    if [ "${persist}" = "true" ]; then
        if ! grep -q "^${module}$" /etc/modules-load.d/k8s.conf 2>/dev/null; then
            echo "${module}" >> /etc/modules-load.d/k8s.conf
        fi
    fi
    
    log_success "Module ${module} loaded"
}

configure_sysctl() {
    local param="$1"
    local value="$2"
    local persist="${3:-true}"
    
    log_debug "Setting sysctl ${param}=${value}"
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would set ${param}=${value}"
        return 0
    fi
    
    sysctl -w "${param}=${value}" >/dev/null
    
    if [ "${persist}" = "true" ]; then
        mkdir -p /etc/sysctl.d
        if ! grep -q "^${param}" /etc/sysctl.d/k8s.conf 2>/dev/null; then
            echo "${param} = ${value}" >> /etc/sysctl.d/k8s.conf
        fi
    fi
    
    log_success "Sysctl ${param} set to ${value}"
}

configure_firewall() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    log_info "Configuring firewall for port ${port}/${protocol}..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would open port ${port}/${protocol}"
        return 0
    fi
    
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1; then
        ufw allow "${port}/${protocol}" >/dev/null 2>&1 || true
    else
        log_warn "No supported firewall detected (firewalld/ufw)"
    fi
    
    log_success "Firewall configured for port ${port}/${protocol}"
}

# Platform Detection Functions

detect_cornelis_hardware() {
    log_debug "Detecting Cornelis Networks hardware..."
    
    if ! command -v lspci >/dev/null 2>&1; then
        log_warn "lspci not available, cannot detect hardware"
        return 1
    fi
    
    local cornelis_devices=$(lspci -d 434e: 2>/dev/null)
    
    if [ -z "$cornelis_devices" ]; then
        log_debug "No Cornelis Networks hardware detected"
        return 1
    fi
    
    log_success "Cornelis Networks hardware detected"
    echo "$cornelis_devices"
    return 0
}

check_driver_available() {
    local driver="$1"
    
    log_debug "Checking if driver ${driver} is available..."
    
    if modinfo "${driver}" >/dev/null 2>&1; then
        local version=$(modinfo -F version "${driver}" 2>/dev/null || echo "unknown")
        log_success "Driver ${driver} available (version: ${version})"
        return 0
    else
        log_fail "Driver ${driver} not available"
        return 1
    fi
}

check_driver_loaded() {
    local driver="$1"
    
    log_debug "Checking if driver ${driver} is loaded..."
    
    if lsmod | grep -q "^${driver}"; then
        log_success "Driver ${driver} loaded"
        return 0
    else
        log_fail "Driver ${driver} not loaded"
        return 1
    fi
}

get_platform_type() {
    log_debug "Detecting platform type..."
    
    if ! command -v lspci >/dev/null 2>&1; then
        log_warn "lspci not available"
        echo "unknown"
        return 1
    fi
    
    if lspci -d 434e:0001 2>/dev/null | grep -q .; then
        echo "cn5000"
        return 0
    else
        echo "unknown"
        return 1
    fi
}

check_ib_subsystem() {
    log_debug "Checking InfiniBand subsystem..."
    
    local status=0
    
    if [ -e /dev/infiniband/uverbs0 ]; then
        log_success "/dev/infiniband/uverbs0 exists"
    else
        log_fail "/dev/infiniband/uverbs0 not found"
        status=1
    fi
    
    if [ -e /dev/infiniband/rdma_cm ]; then
        log_success "/dev/infiniband/rdma_cm exists"
    else
        log_fail "/dev/infiniband/rdma_cm not found"
        status=1
    fi
    
    if command -v ibstat >/dev/null 2>&1; then
        if ibstat 2>/dev/null | grep -q "State: Active"; then
            log_success "InfiniBand port active"
        else
            log_warn "InfiniBand port not active"
        fi
    fi
    
    return $status
}

check_hfi_devices() {
    log_debug "Checking HFI character devices..."
    
    local status=0
    local found_device=false
    
    # Check for HFI devices (CN5000: hfi1_0)
    for dev in /dev/hfi1_*; do
        if [ -e "$dev" ]; then
            log_success "$dev exists"
            found_device=true
        fi
    done
    
    if [ "$found_device" = false ]; then
        log_fail "No HFI character devices found (/dev/hfi1_*)"
        status=1
    fi
    
    return $status
}

check_cdi_runtime() {
    log_debug "Checking CDI runtime configuration..."
    
    local status=0
    
    # Check containerd version (>= 1.7.0 for CDI)
    if command -v containerd >/dev/null 2>&1; then
        local version
        version=$(containerd --version 2>/dev/null | awk '{print $3}' | sed 's/^v//')
        if [ -n "$version" ]; then
            if printf '%s\n' "1.7.0" "$version" | sort -V | head -n1 | grep -q "^1.7.0$"; then
                log_success "containerd version $version (>= 1.7.0)"
            else
                log_fail "containerd version $version (< 1.7.0, CDI requires >= 1.7.0)"
                status=1
            fi
        fi
    else
        log_fail "containerd not found"
        status=1
    fi
    
    # Check containerd CDI configuration
    if [ -f /etc/containerd/config.toml ]; then
        if grep -q "enable_cdi.*=.*true" /etc/containerd/config.toml; then
            log_success "containerd CDI enabled (enable_cdi = true)"
        else
            log_fail "containerd CDI not enabled in /etc/containerd/config.toml"
            status=1
        fi
    else
        log_fail "/etc/containerd/config.toml not found"
        status=1
    fi
    
    # Check CDI spec directory
    if [ -d /var/run/cdi ]; then
        log_success "/var/run/cdi directory exists"
    else
        log_warn "/var/run/cdi directory not found (will be created by device plugin)"
    fi
    
    # Check kubelet feature gate (DevicePluginCDIDevices)
    if [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
        if grep -q "DevicePluginCDIDevices=true" /var/lib/kubelet/kubeadm-flags.env; then
            log_success "kubelet feature gate DevicePluginCDIDevices=true"
        else
            log_fail "kubelet feature gate DevicePluginCDIDevices not enabled"
            status=1
        fi
    else
        log_warn "/var/lib/kubelet/kubeadm-flags.env not found (kubelet may not be initialized)"
    fi
    
    return $status
}

# Kubernetes-Specific Functions

configure_containerd() {
    log_info "Configuring containerd..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would configure containerd"
        return 0
    fi
    
    mkdir -p /etc/containerd
    
    # CDI must be enabled for the rdma-shared-device workflow, but only the
    # containerd 1.7.x line (e.g. SLES 16) needs it forced on: it leaves CDI off
    # unless explicitly set, silently dropping the device-plugin's container
    # edits. containerd >=2.0 enables CDI by default, so we leave its config
    # untouched there rather than change behavior for every distro implicitly.
    # An explicit ENABLE_CDI=true/false always wins; with no override we default
    # to true for containerd <2.0 (and when the version can't be parsed, to stay
    # safe on the 1.7.x target) and to false (containerd's own default) for >=2.0.
    local enable_cdi
    if [ -n "${ENABLE_CDI:-}" ]; then
        enable_cdi="${ENABLE_CDI}"
    else
        local containerd_ver
        # Reuse the version idiom from check_cdi_runtime(); tolerate a missing
        # containerd binary (|| true) so set -euo pipefail does not abort here.
        containerd_ver="$(containerd --version 2>/dev/null | awk '{print $3}' | sed 's/^v//')" || true
        if [ -n "${containerd_ver}" ] && \
           [ "$(printf '%s\n' "2.0.0" "${containerd_ver}" | sort -V | head -n1)" = "2.0.0" ]; then
            # containerd >=2.0 already enables CDI by default.
            enable_cdi="false"
        else
            # containerd <2.0 or an unparseable version: force CDI on for 1.7.x.
            enable_cdi="true"
        fi
    fi
    
    cat > /etc/containerd/config.toml <<EOF
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
$(if [ "${enable_cdi}" = "true" ]; then
    echo "  enable_cdi = true"
    echo "  cdi_spec_dirs = [\"/etc/cdi\", \"/var/run/cdi\"]"
fi)

  [plugins."io.containerd.grpc.v1.cri".cni]
    bin_dir = "/opt/cni/bin"
    conf_dir = "/etc/cni/net.d"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true
EOF
    
    systemctl enable containerd
    systemctl restart containerd
    log_success "Containerd configured"
}

configure_kubelet() {
    log_info "Configuring kubelet..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would configure kubelet"
        return 0
    fi
    
    mkdir -p /var/lib/kubelet
    
    cat > /var/lib/kubelet/config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
    
    log_success "Kubelet configured"
}

start_k8s_services() {
    log_info "Starting Kubernetes services..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would start kubelet and containerd"
        return 0
    fi
    
    systemctl enable --now containerd
    systemctl enable --now kubelet
    
    log_success "Services started"
}

verify_k8s_installation() {
    log_info "Verifying Kubernetes installation..."
    
    local status=0
    
    if pkg_is_installed kubelet; then
        local version=$(pkg_get_version kubelet)
        log_success "kubelet ${version} installed"
    else
        log_fail "kubelet not installed"
        status=1
    fi
    
    if pkg_is_installed kubeadm; then
        local version=$(pkg_get_version kubeadm)
        log_success "kubeadm ${version} installed"
    else
        log_fail "kubeadm not installed"
        status=1
    fi
    
    if pkg_is_installed containerd; then
        local version=$(pkg_get_version containerd)
        log_success "containerd ${version} installed"
    else
        log_fail "containerd not installed"
        status=1
    fi
    
    for service in kubelet containerd; do
        if ! systemctl is-enabled "$service" >/dev/null 2>&1; then
            log_fail "${service}: not enabled"
            status=1
            continue
        fi
        local svc_state
        # || true: systemctl is-active exits non-zero (e.g. 3) for inactive/unknown
        # services; suppress so set -e does not kill the script before we can log it.
        svc_state="$(systemctl is-active "$service" 2>&1)" || true
        if [ "${svc_state}" = "active" ]; then
            log_success "${service}: enabled and active"
        elif [ "${service}" = "kubelet" ] && [ "${svc_state}" = "activating" ]; then
            # kubelet enters 'activating' before kubeadm init/join completes; this
            # is the expected pre-cluster state and is not a setup failure.
            log_success "${service}: enabled and activating (waiting for kubeadm init/join)"
        else
            log_fail "${service}: enabled but NOT active (state: ${svc_state})"
            status=1
        fi
    done
    
    return $status
}

# Cleanup Functions

backup_k8s_state() {
    local backup_dir="${1:-/var/log/k8s-cleanup-$(date +%Y%m%d-%H%M%S)}"
    
    log_info "Creating backup in ${backup_dir}..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would create backup in ${backup_dir}"
        return 0
    fi
    
    mkdir -p "${backup_dir}"
    
    journalctl -u kubelet --no-pager > "${backup_dir}/kubelet.log" 2>&1 || true
    journalctl -u containerd --no-pager > "${backup_dir}/containerd.log" 2>&1 || true
    ip addr > "${backup_dir}/ip-addr.txt" 2>&1 || true
    ip route > "${backup_dir}/ip-route.txt" 2>&1 || true
    iptables-save > "${backup_dir}/iptables.txt" 2>&1 || true
    ps aux > "${backup_dir}/processes.txt" 2>&1 || true
    
    if command -v ibstat >/dev/null 2>&1; then
        ibstat > "${backup_dir}/ibstat.txt" 2>&1 || true
    fi
    
    log_success "Backup created in ${backup_dir}"
    echo "${backup_dir}"
}

cleanup_k8s_configs() {
    log_info "Cleaning Kubernetes configurations..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would remove K8s config directories"
        return 0
    fi
    
    rm -rf /etc/kubernetes
    rm -rf /var/lib/kubelet
    rm -rf /var/lib/etcd
    rm -rf /etc/systemd/system/kubelet.service.d
    
    log_success "Kubernetes configurations removed"
}

cleanup_network() {
    # Scoping policy: only destroy CNI-created network state.
    # - iptables: flush/delete only KUBE-*, FLANNEL-*, CNI-* chains; never -F on default chains.
    # - nft: delete only tables whose names match kube|flannel|cni; never flush entire ruleset.
    # - veth: delete only veths with CNI-characteristic names (cali*, veth[hex]{7}, cni-*).
    # - cni0/flannel.1/kube-ipvs0 are unambiguous CNI artifacts and are always removed.
    log_info "Cleaning network configuration..."

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would clean CNI-scoped iptables chains and network interfaces"
        return 0
    fi

    for table in nat filter mangle; do
        for c in $(iptables -t "${table}" -L -n 2>/dev/null | grep -oP '^Chain \K(KUBE-[A-Z0-9-]+|FLANNEL-[A-Z0-9-]+|CNI-[A-Z0-9-]+)' | sort -u); do
            iptables -t "${table}" -F "$c" 2>/dev/null || true
            iptables -t "${table}" -X "$c" 2>/dev/null || true
        done
    done

    for table in nat filter mangle; do
        for c in $(ip6tables -t "${table}" -L -n 2>/dev/null | grep -oP '^Chain \K(KUBE-[A-Z0-9-]+|FLANNEL-[A-Z0-9-]+|CNI-[A-Z0-9-]+)' | sort -u); do
            ip6tables -t "${table}" -F "$c" 2>/dev/null || true
            ip6tables -t "${table}" -X "$c" 2>/dev/null || true
        done
    done

    if command -v nft >/dev/null 2>&1; then
        while IFS= read -r tbl; do
            nft delete table "${tbl}" 2>/dev/null || true
        done < <(nft list tables 2>/dev/null | grep -Ei 'kube|flannel|cni' | awk '{print $2}')
    fi

    if command -v ipvsadm >/dev/null 2>&1; then
        ipvsadm --clear 2>/dev/null || true
    fi

    ip link delete cni0 2>/dev/null || true
    ip link delete flannel.1 2>/dev/null || true
    ip link delete kube-ipvs0 2>/dev/null || true

    for v in $(ip -o link show type veth 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(cali|veth[a-f0-9]{7}|cni-)'); do
        ip link delete "$v" 2>/dev/null || true
    done

    log_success "Network cleaned"
}

cleanup_cni() {
    log_info "Cleaning CNI configuration..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would remove CNI configs"
        return 0
    fi
    
    rm -rf /etc/cni/net.d/*
    rm -rf /var/lib/cni/*
    
    if [ -d /hostroot/opt/cni/bin ]; then
        log_info "Removing Multus chroot CNI binaries..."
        rm -rf /hostroot/opt/cni/bin/*
    fi
    
    log_success "CNI configuration removed"
}

verify_cleanup() {
    log_info "Verifying cleanup..."
    
    local status=0
    
    if [ -d /etc/kubernetes ]; then
        log_fail "/etc/kubernetes still exists"
        status=1
    else
        log_success "/etc/kubernetes removed"
    fi
    
    if [ -d /var/lib/kubelet ]; then
        log_fail "/var/lib/kubelet still exists"
        status=1
    else
        log_success "/var/lib/kubelet removed"
    fi
    
    if pgrep -f kubelet >/dev/null; then
        log_fail "kubelet still running"
        status=1
    else
        log_success "kubelet not running"
    fi
    
    if ip link show cni0 >/dev/null 2>&1; then
        log_fail "cni0 interface still exists"
        status=1
    else
        log_success "cni0 interface removed"
    fi
    
    return $status
}

# Validation Functions

check_system_requirements() {
    log_info "Checking system requirements..."
    
    local status=0
    
    local cpu_count=$(nproc)
    if [ "$cpu_count" -ge 2 ]; then
        log_success "CPU cores: ${cpu_count} (>= 2)"
    else
        log_fail "CPU cores: ${cpu_count} (< 2)"
        status=1
    fi
    
    local mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
    if [ "$mem_mb" -ge 2048 ]; then
        log_success "Memory: ${mem_mb} MB (>= 2048 MB)"
    else
        log_fail "Memory: ${mem_mb} MB (< 2048 MB)"
        status=1
    fi
    
    local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$disk_gb" -ge 20 ]; then
        log_success "Disk space: ${disk_gb} GB (>= 20 GB)"
    else
        log_fail "Disk space: ${disk_gb} GB (< 20 GB)"
        status=1
    fi
    
    return $status
}

check_network_connectivity() {
    log_info "Checking network connectivity..."
    
    local status=0
    
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log_success "Internet connectivity available"
    else
        log_warn "No internet connectivity"
        status=1
    fi
    
    if host google.com >/dev/null 2>&1 || nslookup google.com >/dev/null 2>&1; then
        log_success "DNS resolution working"
    else
        log_warn "DNS resolution not working"
        status=1
    fi
    
    return $status
}

check_time_sync() {
    log_info "Checking time synchronization..."
    
    if systemctl is-active chronyd >/dev/null 2>&1; then
        log_success "chronyd active"
        return 0
    elif systemctl is-active systemd-timesyncd >/dev/null 2>&1; then
        log_success "systemd-timesyncd active"
        return 0
    elif systemctl is-active ntpd >/dev/null 2>&1; then
        log_success "ntpd active"
        return 0
    else
        log_warn "No time sync service active"
        return 1
    fi
}

check_firewall_rules() {
    local port="$1"
    local protocol="${2:-tcp}"
    
    log_debug "Checking firewall for port ${port}/${protocol}..."
    
    if command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/${protocol}"; then
            log_success "Port ${port}/${protocol} open (firewalld)"
            return 0
        fi
    elif command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "${port}/${protocol}"; then
            log_success "Port ${port}/${protocol} open (ufw)"
            return 0
        fi
    fi
    
    log_warn "Cannot verify port ${port}/${protocol} (no supported firewall or port not explicitly open)"
    return 1
}

# Reporting Functions

report_check_results() {
    local total="$1"
    local passed="$2"
    local failed="$3"
    local warnings="$4"
    
    echo ""
    echo "=== Summary ==="
    
    if [ "$failed" -eq 0 ]; then
        log_success "Status: PASS"
    else
        log_fail "Status: FAIL"
    fi
    
    echo "Checks: ${passed} passed, ${failed} failed, ${warnings} warnings"
    echo ""
    
    if [ "$failed" -eq 0 ]; then
        echo "Node is ready for Kubernetes cluster"
        return 0
    else
        echo "Node is NOT ready for Kubernetes cluster"
        return 1
    fi
}

report_cleanup_results() {
    local backup_dir="$1"
    
    echo ""
    echo "=== Cleanup Complete ==="
    log_success "Backup saved to: ${backup_dir}"
    echo ""
    echo "Next steps:"
    echo "  1. Review logs in ${backup_dir}"
    echo "  2. Reboot node (recommended): sudo reboot"
    echo "  3. Run setup script to prepare for new cluster"
}

report_install_results() {
    local k8s_version="$1"
    
    echo ""
    echo "=== Setup Complete ==="
    log_success "Node is cluster-ready with Kubernetes ${k8s_version}"
    echo ""
    echo "Next steps:"
    echo "  1. Initialize cluster (control plane):"
    echo "     kubeadm init --pod-network-cidr=10.244.0.0/16"
    echo ""
    echo "  2. Join cluster (worker):"
    echo "     kubeadm join <control-plane>:6443 --token <token> \\"
    echo "       --discovery-token-ca-cert-hash sha256:<hash>"
}

generate_json_report() {
    local status="$1"
    local checks="$2"
    
    cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "status": "${status}",
  "distribution": "${DISTRO_NAME}",
  "checks": ${checks}
}
EOF
}

# Error Handling and Logging

handle_error() {
    local exit_code=$?
    local line_number=$1
    
    log_error "Error occurred in script at line ${line_number} (exit code: ${exit_code})"
    
    if [ "${DRY_RUN}" != "true" ]; then
        log_error "Operation failed. Check logs for details."
    fi
    
    return $exit_code
}

trap 'handle_error ${LINENO}' ERR

# Go Toolchain Installation Functions

install_go() {
    local go_version="${1:-1.21.5}"
    local go_arch="amd64"
    
    if [ "$(uname -m)" = "ppc64le" ]; then
        go_arch="ppc64le"
    elif [ "$(uname -m)" = "aarch64" ]; then
        go_arch="arm64"
    fi
    
    log_info "Installing Go toolchain (version ${go_version})..."
    
    if command -v go >/dev/null 2>&1; then
        local installed_version=$(go version | awk '{print $3}' | sed 's/go//')
        log_info "Go already installed: ${installed_version}"
        
        if verify_go_version; then
            log_success "Go version is compatible"
            return 0
        else
            log_warn "Installed Go version is too old, upgrading..."
        fi
    fi
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would install Go ${go_version}"
        return 0
    fi
    
    log_info "Attempting to install Go via package manager..."
    case "${PKG_MGR}" in
        apt)
            if pkg_install golang-go 2>/dev/null || pkg_install golang 2>/dev/null; then
                if verify_go_version; then
                    log_success "Go installed via apt"
                    return 0
                else
                    log_warn "Package manager Go version too old, using official tarball"
                fi
            else
                log_warn "Go package not available via apt, using official tarball"
            fi
            ;;
        dnf|yum)
            if pkg_install golang 2>/dev/null; then
                if verify_go_version; then
                    log_success "Go installed via ${PKG_MGR}"
                    return 0
                else
                    log_warn "Package manager Go version too old, using official tarball"
                fi
            else
                log_warn "Go package not available via ${PKG_MGR}, using official tarball"
            fi
            ;;
        zypper)
            if pkg_install go 2>/dev/null; then
                if verify_go_version; then
                    log_success "Go installed via zypper"
                    return 0
                else
                    log_warn "Package manager Go version too old, using official tarball"
                fi
            else
                log_warn "Go package not available via zypper, using official tarball"
            fi
            ;;
    esac
    
    log_info "Installing Go from official tarball..."
    local go_tarball="go${go_version}.linux-${go_arch}.tar.gz"
    local go_url="https://go.dev/dl/${go_tarball}"

    declare -A GO_SHA256_BY_ARCH=(
        ["amd64-1.21.5"]="e2bc0b3e4b64111ec117295c088bde5f00eeed1567999ff77bc859d7df70078e"
        ["arm64-1.21.5"]="841cced7ecda9b2014f139f5bab5ae31785f35399f236b8b3e75dff2a2978d96"
    )
    local arch_normalized
    arch_normalized=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local expected_sha="${GO_SHA256_BY_ARCH[${arch_normalized}-${go_version}]:-}"
    if [ -z "${expected_sha}" ] || [[ "${expected_sha}" == UNRESOLVED_* ]]; then
        log_error "No SHA256 pinned for Go ${go_version}/${arch_normalized}. Refusing to install."
        rm -f "/tmp/${go_tarball}"
        exit 1
    fi

    log_info "Downloading ${go_url}..."
    if ! wget -q --show-progress "${go_url}" -O "/tmp/${go_tarball}"; then
        log_error "Failed to download Go tarball"
        return 1
    fi

    local actual_sha
    actual_sha=$(sha256sum "/tmp/${go_tarball}" | awk '{print $1}')
    [ "${actual_sha}" = "${expected_sha}" ] || { log_error "Go checksum mismatch"; rm -f "/tmp/${go_tarball}"; exit 1; }
    log_success "Go SHA256 verified"

    log_info "Removing existing Go installation..."
    rm -rf /usr/local/go
    
    log_info "Extracting Go to /usr/local/go..."
    tar -C /usr/local -xzf "/tmp/${go_tarball}"
    
    rm -f "/tmp/${go_tarball}"
    
    configure_go_path
    
    if verify_go_version; then
        log_success "Go ${go_version} installed successfully"
        return 0
    else
        log_error "Go installation verification failed"
        return 1
    fi
}

configure_go_path() {
    log_info "Configuring Go PATH..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would configure Go PATH"
        return 0
    fi
    
    export PATH=$PATH:/usr/local/go/bin
    
    if ! grep -q '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
        # GOPATH derived from $HOME so non-root users get a writable workspace;
        # root keeps /root/go via $HOME expansion at login.
        cat > /etc/profile.d/go.sh <<'EOF'
export PATH=$PATH:/usr/local/go/bin
export GOPATH=${HOME:-/root}/go
export PATH=$PATH:$GOPATH/bin
EOF
        chmod +x /etc/profile.d/go.sh
        log_success "Go PATH configured in /etc/profile.d/go.sh"
    fi
}

verify_go_version() {
    local min_version="1.19"
    
    if ! command -v go >/dev/null 2>&1; then
        log_debug "Go not found in PATH"
        return 1
    fi
    
    local installed_version=$(go version | awk '{print $3}' | sed 's/go//')
    log_debug "Checking Go version: ${installed_version} (minimum: ${min_version})"
    
    local installed_major=$(echo "${installed_version}" | cut -d. -f1)
    local installed_minor=$(echo "${installed_version}" | cut -d. -f2)
    local min_major=$(echo "${min_version}" | cut -d. -f1)
    local min_minor=$(echo "${min_version}" | cut -d. -f2)
    
    if [ "${installed_major}" -gt "${min_major}" ]; then
        return 0
    elif [ "${installed_major}" -eq "${min_major}" ] && [ "${installed_minor}" -ge "${min_minor}" ]; then
        return 0
    else
        log_debug "Go version ${installed_version} is older than minimum ${min_version}"
        return 1
    fi
}

# cn-ipoib-cni Build and Installation Functions

prepare_cni_ipoib_source() {
    local repo_root="${1:-/root/cn-fabric-k8s}"
    local build_dir="/tmp/cn-ipoib-cni-build"
    # Logs go to stderr so the caller's $(...) only captures the build_dir path.
    log_info "Preparing cn-ipoib-cni source for build..." >&2

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would copy cn-ipoib-cni source to ${build_dir}" >&2
        echo "${build_dir}"
        return 0
    fi

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    if [ -d "${repo_root}/plugins/cni-plugins/cn-ipoib-cni" ]; then
        log_info "Copying cn-ipoib-cni source from ${repo_root}..." >&2
        cp -r "${repo_root}/plugins/cni-plugins/cn-ipoib-cni"/* "${build_dir}/"
        log_success "Source copied to ${build_dir}" >&2
    else
        log_error "cn-ipoib-cni source not found at ${repo_root}/plugins/cni-plugins/cn-ipoib-cni"
        return 1
    fi

    echo "${build_dir}"
}

build_cni_ipoib() {
    local build_dir="$1"
    
    log_info "Building cn-ipoib-cni from source..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would build cn-ipoib-cni in ${build_dir}"
        return 0
    fi
    
    if [ ! -d "${build_dir}" ]; then
        log_error "Build directory not found: ${build_dir}"
        return 1
    fi
    
    cd "${build_dir}"
    
    log_info "Running 'make build' in ${build_dir}..."
    if make build 2>&1 | tee /tmp/cn-ipoib-cni-build.log; then
        if [ -f "${build_dir}/build/ipoib" ]; then
            log_success "cn-ipoib-cni built successfully"
            return 0
        else
            log_error "Build succeeded but binary not found at ${build_dir}/build/ipoib"
            log_error "Build log saved to /tmp/cn-ipoib-cni-build.log"
            return 1
        fi
    else
        log_error "cn-ipoib-cni build failed"
        log_error "Build log saved to /tmp/cn-ipoib-cni-build.log"
        log_error "Last 20 lines of build output:"
        tail -20 /tmp/cn-ipoib-cni-build.log
        return 1
    fi
}

install_cni_ipoib_binary() {
    local build_dir="$1"
    local binary_path="${build_dir}/build/ipoib"
    local install_path="/opt/cni/bin/ipoib"
    
    log_info "Installing cn-ipoib-cni binary..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would install ${binary_path} to ${install_path}"
        return 0
    fi
    
    if [ ! -f "${binary_path}" ]; then
        log_error "Binary not found: ${binary_path}"
        return 1
    fi
    
    mkdir -p /opt/cni/bin
    
    cp "${binary_path}" "${install_path}"
    chmod 0755 "${install_path}"
    
    if [ -x "${install_path}" ]; then
        log_success "cn-ipoib-cni binary installed to ${install_path}"
        return 0
    else
        log_error "Failed to install cn-ipoib-cni binary"
        return 1
    fi
}

verify_cni_ipoib_binary() {
    local install_path="/opt/cni/bin/ipoib"
    
    if [ ! -f "${install_path}" ]; then
        log_fail "cn-ipoib-cni binary not found at ${install_path}"
        return 1
    fi
    
    if [ ! -x "${install_path}" ]; then
        log_fail "cn-ipoib-cni binary is not executable"
        return 1
    fi
    
    log_success "cn-ipoib-cni binary verified at ${install_path}"
    return 0
}

# cn-rdma-shared-dev-plugin Build and Image Functions
#
# The cn-rdma-shared-dev-plugin runs as a DaemonSet Pod (not a CNI binary
# at /opt/cni/bin/*), so setup must produce BOTH the Go binary AND a
# container image loaded into containerd's k8s.io namespace. The image
# tag must match manifests/device-plugins/rdma-cdi-device-plugin.yaml.

install_buildah_if_missing() {
    if command -v buildah >/dev/null 2>&1; then
        log_debug "buildah already installed: $(buildah --version | head -n1)"
        return 0
    fi

    log_info "buildah not found; installing..."

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would install buildah"
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y buildah || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y buildah || return 1
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y buildah || return 1
    elif command -v zypper >/dev/null 2>&1; then
        zypper -n install buildah || return 1
    else
        log_error "No supported package manager found to install buildah"
        return 1
    fi

    if command -v buildah >/dev/null 2>&1; then
        log_success "buildah installed: $(buildah --version | head -n1)"
        return 0
    fi
    log_error "buildah install reported success but binary is still missing"
    return 1
}

prepare_cn_rdma_shared_dp_source() {
    local repo_root="${1:-/tmp}"
    local build_dir="/tmp/cn-rdma-shared-dp-build"
    # Logs go to stderr so the caller's $(...) only captures the build_dir path.
    log_info "Preparing cn-rdma-shared-dev-plugin source for build..." >&2

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would copy cn-rdma-shared-dev-plugin source to ${build_dir}" >&2
        echo "${build_dir}"
        return 0
    fi

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    local src_dir="${repo_root}/plugins/device-plugins/cn-rdma-shared-dev-plugin"
    if [ -d "${src_dir}" ]; then
        log_info "Copying cn-rdma-shared-dev-plugin source from ${src_dir}..." >&2
        cp -r "${src_dir}"/* "${build_dir}/"
        log_success "Source copied to ${build_dir}" >&2
    else
        log_error "cn-rdma-shared-dev-plugin source not found at ${src_dir}"
        return 1
    fi

    echo "${build_dir}"
}

build_cn_rdma_shared_dp_image() {
    # Cornelis fork of k8s-rdma-shared-dev-plugin ships a self-contained
    # multi-stage Dockerfile.cornelis that compiles the Go binary inside a
    # builder image. The plugin runs as a DaemonSet (not a CNI binary on
    # disk), so the host never needs the binary itself — only the container
    # image loaded into containerd's k8s.io namespace.
    #
    # Pipeline: prepare source -> buildah bud -> push OCI archive with
    # ref-name annotation -> ctr import. The OCI ref name MUST match the
    # manifest's image:; without it, ctr import puts blobs in containerd
    # but does NOT rebind the :latest tag.
    local repo_root="${1:-/tmp}"
    local image_tag="localhost/cn-rdma-shared-dev-plugin:latest"
    local build_dir="/tmp/cn-rdma-shared-dp-build"
    local oci_archive="/tmp/cn-rdma-shared-dev-plugin-image.tar"

    if ! prepare_cn_rdma_shared_dp_source "${repo_root}" >/dev/null; then
        log_error "Failed to stage cn-rdma-shared-dev-plugin source"
        return 1
    fi

    if [ ! -f "${build_dir}/Dockerfile.cornelis" ]; then
        log_error "Dockerfile.cornelis not found in ${build_dir}"
        return 1
    fi

    log_info "Building container image ${image_tag} from Dockerfile.cornelis..."

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would build, push to OCI archive, and import to containerd"
        return 0
    fi

    cd "${build_dir}" || return 1

    # buildah 1.37.2 (RHEL 9.5) does not accept --progress=plain (BuildKit flag). Stream directly.
    if ! buildah bud -t "${image_tag}" -f Dockerfile.cornelis . 2>&1 | tee /tmp/cn-rdma-shared-dp-image.log; then
        log_error "buildah bud failed; tail of log:"
        tail -20 /tmp/cn-rdma-shared-dp-image.log
        return 1
    fi

    log_info "Pushing image to OCI archive ${oci_archive} with ref-name annotation..."
    rm -f "${oci_archive}"
    if ! buildah push "${image_tag}" "oci-archive:${oci_archive}:${image_tag}"; then
        log_error "buildah push to oci-archive failed"
        return 1
    fi

    if ! ctr -n k8s.io images import "${oci_archive}"; then
        log_error "ctr image import failed"
        return 1
    fi
    if ! ctr -n k8s.io images list -q | grep -Fxq "${image_tag}"; then
        log_error "Imported image but tag ${image_tag} not visible in k8s.io namespace"
        return 1
    fi
    log_success "Image ${image_tag} imported and verified"
}

# Multus CNI Binary Installation Functions

# MULTUS_VERSION must be exported by the caller (resolved from package-requirements.yaml
# via lib/load-versions.sh). No literal fallback here: a fallback would shadow the YAML
# lookup in callers and silently install the wrong version.
if [ -z "${MULTUS_VERSION:-}" ]; then
    echo "[ERROR] MULTUS_VERSION must be exported before sourcing package-manager.sh." >&2
    return 1 2>/dev/null || exit 1
fi
MULTUS_CHECKSUM_URL="https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${MULTUS_VERSION}/multus-cni_${MULTUS_VERSION}_checksums.txt"

download_multus_cni() {
    local version="${1:-${MULTUS_VERSION}}"
    local arch="amd64"
    
    if [ "$(uname -m)" = "ppc64le" ]; then
        arch="ppc64le"
    elif [ "$(uname -m)" = "aarch64" ]; then
        arch="arm64"
    fi
    
    local version_no_v="${version#v}"
    local tarball="multus-cni_${version_no_v}_linux_${arch}.tar.gz"
    local url="https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${version}/${tarball}"
    local download_path="/tmp/${tarball}"
    
    if [ "${DRY_RUN}" = "true" ]; then
        return 0
    fi
    
    if ! wget -q "${url}" -O "${download_path}"; then
        return 1
    fi
    
    echo "${download_path}"
}

verify_multus_checksum() {
    local tarball_path="$1"
    local version="${2:-${MULTUS_VERSION}}"
    
    log_info "Verifying Multus CNI checksum..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would verify checksum for ${tarball_path}"
        return 0
    fi
    
    local version_no_v="${version#v}"
    local checksum_file="/tmp/multus-checksums.txt"
    local checksum_url="https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${version}/multus-cni_${version_no_v}_checksums.txt"

    # Fail-closed: a missing checksum file means we cannot verify integrity.
    # Refusing to install is the only safe behaviour for unverified binaries.
    if ! wget -q "${checksum_url}" -O "${checksum_file}"; then
        log_error "Could not download Multus checksum file from ${checksum_url}; refusing to install unverified binary"
        return 1
    fi

    local tarball_name=$(basename "${tarball_path}")
    local expected_checksum=$(grep "${tarball_name}" "${checksum_file}" | awk '{print $1}')

    if [ -z "${expected_checksum}" ]; then
        log_error "Multus checksum for ${tarball_name} not found in checksum file; refusing to install"
        rm -f "${checksum_file}"
        return 1
    fi
    
    local actual_checksum=$(sha256sum "${tarball_path}" | awk '{print $1}')
    
    if [ "${actual_checksum}" = "${expected_checksum}" ]; then
        log_success "Checksum verification passed"
        rm -f "${checksum_file}"
        return 0
    else
        log_error "Checksum verification failed!"
        log_error "Expected: ${expected_checksum}"
        log_error "Actual:   ${actual_checksum}"
        rm -f "${checksum_file}"
        return 1
    fi
}

install_multus_binary() {
    local tarball_path="$1"
    local install_path="/opt/cni/bin/multus"
    
    log_info "Installing Multus CNI binary..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would extract and install Multus binary to ${install_path}"
        return 0
    fi
    
    mkdir -p /opt/cni/bin
    
    local extract_dir="/tmp/multus-extract"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"
    
    if ! tar -xzf "${tarball_path}" -C "${extract_dir}"; then
        log_error "Failed to extract Multus tarball"
        return 1
    fi
    
    local arch_normalized
    arch_normalized=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local multus_version_stripped="${MULTUS_VERSION#v}"
    local multus_extracted_dir="${extract_dir}/multus-cni_${multus_version_stripped}_linux_${arch_normalized}"
    if [ -f "${multus_extracted_dir}/multus" ]; then
        cp "${multus_extracted_dir}/multus" /opt/cni/bin/multus
        chmod 0755 /opt/cni/bin/multus
        log_success "Installed multus binary"
    elif [ -f "${extract_dir}/multus" ]; then
        cp "${extract_dir}/multus" /opt/cni/bin/multus
        chmod 0755 /opt/cni/bin/multus
        log_success "Installed multus binary (root-extracted)"
    else
        log_error "multus binary not found in extracted tarball at ${multus_extracted_dir}/multus"
        return 1
    fi

    rm -rf "${extract_dir}"
    rm -f "${tarball_path}"

    if [ -x "${install_path}" ]; then
        log_success "Multus CNI binary installed to ${install_path}"
        return 0
    else
        log_error "Failed to install Multus CNI binary"
        return 1
    fi
}

verify_multus_binary() {
    local install_path="/opt/cni/bin/multus"
    
    if [ ! -f "${install_path}" ]; then
        log_fail "Multus CNI binary not found at ${install_path}"
        return 1
    fi
    
    if [ ! -x "${install_path}" ]; then
        log_fail "Multus CNI binary is not executable"
        return 1
    fi
    
    log_success "Multus CNI binary verified at ${install_path}"
    return 0
}

# Flannel CNI Binary Installation Functions

# FLANNEL_VERSION must be exported by the caller (resolved from package-requirements.yaml
# via lib/load-versions.sh). No literal fallback here: a fallback would shadow the YAML
# lookup in callers and silently install the wrong version.
if [ -z "${FLANNEL_VERSION:-}" ]; then
    echo "[ERROR] FLANNEL_VERSION must be exported before sourcing package-manager.sh." >&2
    return 1 2>/dev/null || exit 1
fi

download_flannel_cni() {
    local version="${1:-${FLANNEL_VERSION}}"
    local arch="amd64"
    
    if [ "$(uname -m)" = "ppc64le" ]; then
        arch="ppc64le"
    elif [ "$(uname -m)" = "aarch64" ]; then
        arch="arm64"
    fi
    
    local version_no_prefix="${version#v}"
    local version_no_suffix="${version_no_prefix%-flannel*}"
    local tarball="cni-plugin-flannel-linux-${arch}-v${version_no_suffix}.tgz"
    local url="https://github.com/flannel-io/cni-plugin/releases/download/${version}/${tarball}"
    local download_path="/tmp/${tarball}"
    
    if [ "${DRY_RUN}" = "true" ]; then
        return 0
    fi
    
    if ! wget -q "${url}" -O "${download_path}"; then
        return 1
    fi
    
    echo "${download_path}"
}

verify_flannel_checksum() {
    local tarball_path="$1"
    local version="${2:-${FLANNEL_VERSION}}"
    
    log_info "Verifying Flannel CNI checksum..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would verify checksum for ${tarball_path}"
        return 0
    fi
    
    local arch="amd64"
    if [ "$(uname -m)" = "ppc64le" ]; then
        arch="ppc64le"
    elif [ "$(uname -m)" = "aarch64" ]; then
        arch="arm64"
    fi
    
    # The published asset is the per-tarball .sha256 sidecar
    # (e.g. cni-plugin-flannel-linux-amd64-v1.9.0.tgz.sha256), NOT a separate
    # flannel-${arch}.tgz.sha256sum file (which never existed upstream for this tag).
    local version_no_prefix="${version#v}"
    local version_no_suffix="${version_no_prefix%-flannel*}"
    local tarball_name="cni-plugin-flannel-linux-${arch}-v${version_no_suffix}.tgz"
    local checksum_file="/tmp/flannel-checksums.txt"
    local checksum_url="https://github.com/flannel-io/cni-plugin/releases/download/${version}/${tarball_name}.sha256"

    # Fail-closed: without an authoritative checksum we refuse to install.
    if ! wget -q "${checksum_url}" -O "${checksum_file}"; then
        log_error "Could not download Flannel checksum file from ${checksum_url}; refusing to install unverified binary"
        return 1
    fi

    local expected_checksum=$(cat "${checksum_file}" | awk '{print $1}')

    if [ -z "${expected_checksum}" ]; then
        log_error "Flannel checksum file is empty; refusing to install unverified binary"
        rm -f "${checksum_file}"
        return 1
    fi
    
    local actual_checksum=$(sha256sum "${tarball_path}" | awk '{print $1}')
    
    if [ "${actual_checksum}" = "${expected_checksum}" ]; then
        log_success "Checksum verification passed"
        rm -f "${checksum_file}"
        return 0
    else
        log_error "Checksum verification failed!"
        log_error "Expected: ${expected_checksum}"
        log_error "Actual:   ${actual_checksum}"
        rm -f "${checksum_file}"
        return 1
    fi
}

install_flannel_binaries() {
    local tarball_path="$1"
    
    log_info "Installing Flannel CNI binaries..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would extract and install Flannel binaries to /opt/cni/bin/"
        return 0
    fi
    
    mkdir -p /opt/cni/bin
    
    local extract_dir="/tmp/flannel-extract"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}"
    
    if ! tar -xzf "${tarball_path}" -C "${extract_dir}"; then
        log_error "Failed to extract Flannel tarball"
        return 1
    fi
    
    local arch="amd64"
    if [ "$(uname -m)" = "ppc64le" ]; then
        arch="ppc64le"
    elif [ "$(uname -m)" = "aarch64" ]; then
        arch="arm64"
    fi
    
    if [ -f "${extract_dir}/flannel-${arch}" ]; then
        cp "${extract_dir}/flannel-${arch}" /opt/cni/bin/flannel
        chmod 0755 /opt/cni/bin/flannel
        log_success "Installed flannel binary"
    elif [ -f "${extract_dir}/flannel" ]; then
        cp "${extract_dir}/flannel" /opt/cni/bin/flannel
        chmod 0755 /opt/cni/bin/flannel
        log_success "Installed flannel binary"
    else
        log_error "flannel binary not found in tarball"
        return 1
    fi
    
    if [ -f "${extract_dir}/bridge" ] && [ ! -f /opt/cni/bin/bridge ]; then
        cp "${extract_dir}/bridge" /opt/cni/bin/bridge
        chmod 0755 /opt/cni/bin/bridge
        log_success "Installed bridge binary"
    elif [ -f /opt/cni/bin/bridge ]; then
        log_info "bridge binary already exists, skipping"
    fi
    
    if [ -f "${extract_dir}/host-local" ] && [ ! -f /opt/cni/bin/host-local ]; then
        cp "${extract_dir}/host-local" /opt/cni/bin/host-local
        chmod 0755 /opt/cni/bin/host-local
        log_success "Installed host-local binary"
    elif [ -f /opt/cni/bin/host-local ]; then
        log_info "host-local binary already exists, skipping"
    fi
    
    rm -rf "${extract_dir}"
    rm -f "${tarball_path}"
    
    log_info "Installing additional required CNI plugins..."
    install_standard_cni_plugins
    
    return 0
}

verify_flannel_binaries() {
    local all_ok=true
    
    if [ ! -f /opt/cni/bin/flannel ] || [ ! -x /opt/cni/bin/flannel ]; then
        log_fail "flannel binary not found or not executable at /opt/cni/bin/flannel"
        all_ok=false
    else
        log_success "flannel binary verified"
    fi
    
    if [ ! -f /opt/cni/bin/host-local ] || [ ! -x /opt/cni/bin/host-local ]; then
        log_fail "host-local binary not found or not executable at /opt/cni/bin/host-local"
        all_ok=false
    else
        log_success "host-local binary verified"
    fi
    
    if [ "${all_ok}" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# CNI Binary Directory Preparation Functions

prepare_cni_bin_directory() {
    log_info "Preparing CNI binary directory..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would create /opt/cni/bin with permissions 0755"
        return 0
    fi
    
    if [ ! -d /opt/cni/bin ]; then
        mkdir -p /opt/cni/bin
        log_success "Created /opt/cni/bin directory"
    else
        log_info "/opt/cni/bin directory already exists"
    fi
    
    chmod 0755 /opt/cni/bin
    chown root:root /opt/cni/bin
    
    log_success "CNI binary directory prepared"
    return 0
}

install_standard_cni_plugins() {
    # Allow caller to override; default still pins to a known-good release.
    # Authoritative value lives in package-requirements.yaml under
    # cni_artifacts.cni_plugins.version (read by setup-node.sh callers).
    local cni_plugins_version="${CNI_PLUGINS_VERSION:-v1.1.1}"
    local arch_normalized
    arch_normalized=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    case "${arch_normalized}" in
        amd64|arm64) ;;
        *) log_error "Unsupported arch for CNI plugins: $(uname -m)"; exit 1 ;;
    esac
    local tarball_url="https://github.com/containernetworking/plugins/releases/download/${cni_plugins_version}/cni-plugins-linux-${arch_normalized}-${cni_plugins_version}.tgz"
    local tarball_path="/tmp/cni-plugins-linux-${arch_normalized}-${cni_plugins_version}.tgz"

    log_info "Downloading standard CNI plugins ${cni_plugins_version}..."

    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would download and install standard CNI plugins"
        return 0
    fi

    if ! curl -L -o "${tarball_path}" "${tarball_url}"; then
        log_error "Failed to download CNI plugins from ${tarball_url}"
        return 1
    fi

    declare -A CNI_PLUGINS_SHA256=(
        ["amd64-v1.1.1"]="b275772da4026d2161bf8a8b41ed4786754c8a93ebfb6564006d5da7f23831e5"
        ["arm64-v1.1.1"]="16484966a46b4692028ba32d16afd994e079dc2cc63fbc2191d7bfaf5e11f3dd"
    )
    local expected_sha="${CNI_PLUGINS_SHA256[${arch_normalized}-${cni_plugins_version}]:-}"
    if [ -z "${expected_sha}" ]; then
        log_error "No SHA256 entry for CNI plugins ${arch_normalized}-${cni_plugins_version} (extend CNI_PLUGINS_SHA256 map and retry)"
        exit 1
    fi
    [[ "${expected_sha}" =~ ^UNRESOLVED ]] && { log_error "Unresolved SHA256 placeholder for CNI plugins ${cni_plugins_version}/${arch_normalized}"; exit 1; }
    local actual_sha
    actual_sha=$(sha256sum "${tarball_path}" | awk '{print $1}')
    [ "${actual_sha}" = "${expected_sha}" ] || { log_error "CNI plugins checksum mismatch"; exit 1; }
    log_success "CNI plugins SHA256 verified"

    log_success "Downloaded CNI plugins to ${tarball_path}"
    
    local required_plugins=("loopback" "bridge" "portmap" "bandwidth" "host-local")
    
    for plugin in "${required_plugins[@]}"; do
        if [ -f "/opt/cni/bin/${plugin}" ]; then
            log_info "${plugin} already exists, skipping"
            continue
        fi
        
        if tar -xzf "${tarball_path}" -C /opt/cni/bin "./${plugin}" 2>/dev/null; then
            chmod 0755 "/opt/cni/bin/${plugin}"
            log_success "Installed ${plugin} plugin"
        else
            log_warn "Failed to extract ${plugin} from tarball (may not be present)"
        fi
    done
    
    rm -f "${tarball_path}"
    log_success "Standard CNI plugins installation complete"
    
    return 0
}

# CNI Binary Verification Functions

verify_all_cni_binaries() {
    log_info "Verifying all CNI binaries..."
    
    local all_ok=true
    local binaries=("ipoib" "multus" "flannel" "host-local" "loopback" "bridge" "portmap" "bandwidth")
    
    for binary in "${binaries[@]}"; do
        if [ ! -f "/opt/cni/bin/${binary}" ]; then
            log_fail "${binary} binary not found at /opt/cni/bin/${binary}"
            all_ok=false
        elif [ ! -x "/opt/cni/bin/${binary}" ]; then
            log_fail "${binary} binary is not executable"
            all_ok=false
        else
            log_success "${binary} binary verified"
        fi
    done
    
    if [ "${all_ok}" = "true" ]; then
        log_success "All CNI binaries verified successfully"
        return 0
    else
        log_fail "Some CNI binaries are missing or not executable"
        return 1
    fi
}

query_cni_binary_versions() {
    log_info "Querying CNI binary versions..."
    
    if [ -x /opt/cni/bin/ipoib ]; then
        log_info "cn-ipoib-cni: $(ls -lh /opt/cni/bin/ipoib | awk '{print $5}')"
    fi
    
    if [ -x /opt/cni/bin/multus ]; then
        if /opt/cni/bin/multus --version 2>/dev/null | head -1; then
            :
        else
            log_info "multus: $(ls -lh /opt/cni/bin/multus | awk '{print $5}')"
        fi
    fi
    
    if [ -x /opt/cni/bin/flannel ]; then
        log_info "flannel: $(ls -lh /opt/cni/bin/flannel | awk '{print $5}')"
    fi
    
    if [ -x /opt/cni/bin/host-local ]; then
        log_info "host-local: $(ls -lh /opt/cni/bin/host-local | awk '{print $5}')"
    fi
}

generate_cni_verification_report() {
    echo ""
    echo "=== CNI Binary Installation Report ==="
    echo ""
    
    verify_all_cni_binaries
    local verify_result=$?
    
    echo ""
    query_cni_binary_versions
    echo ""
    
    if [ $verify_result -eq 0 ]; then
        log_success "All CNI binaries installed and verified"
        return 0
    else
        log_fail "CNI binary installation incomplete"
        return 1
    fi
}

# Build Artifact Cleanup Functions

CLEANUP_BUILD_DEPS="${CLEANUP_BUILD_DEPS:-false}"

cleanup_go_toolchain() {
    log_info "Removing Go toolchain..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would remove Go toolchain"
        return 0
    fi
    
    if [ -d /usr/local/go ]; then
        rm -rf /usr/local/go
        log_success "Removed /usr/local/go"
    fi
    
    case "${PKG_MGR}" in
        apt)
            if dpkg -l | grep -q golang; then
                pkg_remove golang-go golang 2>/dev/null || true
                log_success "Removed Go packages via apt"
            fi
            ;;
        dnf|yum)
            if rpm -qa | grep -q golang; then
                pkg_remove golang 2>/dev/null || true
                log_success "Removed Go packages via ${PKG_MGR}"
            fi
            ;;
        zypper)
            if rpm -qa | grep -q "^go-"; then
                pkg_remove go 2>/dev/null || true
                log_success "Removed Go packages via zypper"
            fi
            ;;
    esac
    
    if [ -f /etc/profile.d/go.sh ]; then
        rm -f /etc/profile.d/go.sh
        log_success "Removed Go PATH configuration"
    fi
    
    log_success "Go toolchain cleanup complete"
}

cleanup_cni_ipoib_build() {
    log_info "Cleaning up cn-ipoib-cni build artifacts..."
    
    if [ "${DRY_RUN}" = "true" ]; then
        log_info "[DRY-RUN] Would remove build artifacts"
        return 0
    fi
    
    if [ -d /tmp/cn-ipoib-cni-build ]; then
        rm -rf /tmp/cn-ipoib-cni-build
        log_success "Removed build directory"
    fi
    
    if [ -f /tmp/cn-ipoib-cni-build.log ]; then
        rm -f /tmp/cn-ipoib-cni-build.log
        log_success "Removed build log"
    fi
    
    log_success "Build artifact cleanup complete"
}

cleanup_build_dependencies() {
    if [ "${CLEANUP_BUILD_DEPS}" != "true" ]; then
        log_info "Skipping build dependency cleanup (use --cleanup-build-deps to enable)"
        return 0
    fi
    
    log_info "Cleaning up build dependencies..."
    
    if [ ! -x /opt/cni/bin/ipoib ]; then
        log_warn "cn-ipoib-cni binary not found, skipping cleanup to preserve build capability"
        return 0
    fi
    
    cleanup_cni_ipoib_build
    cleanup_go_toolchain
    
    log_success "Build dependency cleanup complete"
    log_info "CNI binaries preserved at /opt/cni/bin/"
}

# Suppress library loading message - scripts will control output
# log_info "Package manager library loaded"
