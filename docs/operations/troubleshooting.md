# Node Prerequisites Troubleshooting Guide

This guide provides solutions to common issues encountered when managing Kubernetes node prerequisites.

## Prerequisites

### Required Tools

**On all nodes:**
- yq: `pip install yq` or `sudo dnf install python3-yq`
- jq: `sudo dnf install jq` or `sudo apt-get install jq`

**On control machine (for Ansible):**
- Ansible 2.15+: `pip install ansible`

### Repository Configuration

**IMPORTANT:** Kubernetes repositories must be pre-configured on all nodes before running setup scripts.

**RHEL/Rocky/CentOS:**
```bash
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
EOF
```

**Ubuntu/Debian:**
```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
```

## Common Issues

### Issue: yq Not Found

**Symptom:**
```
[ERROR] yq is required. Install: pip install yq
```

**Solution:**
```bash
# Install yq on all nodes
pip install yq

# Or via package manager (RHEL/Rocky)
sudo dnf install python3-yq
```

### Issue: Package Exclusions (RHEL/Rocky)

**Symptom:**
```
All matches were filtered out by exclude filtering
```

**Cause:**
- excludepkgs settings in dnf/yum configuration

**Solution:**
```bash
# Remove all excludepkgs lines
sudo sed -i '/^excludepkgs=/d; /^exclude =/d' /etc/dnf/dnf.conf
sudo sed -i '/^excludepkgs=/d; /^exclude =/d' /etc/yum.repos.d/*.repo
sudo dnf clean all
```

### Issue: DNF Process Killed (Exit 137)

**Symptom:**
```
Killed: dnf install -y kubelet
```

**Causes:**
- Leftover kubepods cgroup slices with memory limits
- Concurrent dnf processes

**Solutions:**

1. Clean kubepods cgroups:
   ```bash
   sudo systemctl stop kubepods*.slice
   sudo systemctl daemon-reload
   ```

2. Kill stuck dnf processes:
   ```bash
   sudo pkill -9 dnf
   sudo dnf clean all
   ```

3. Run cleanup script (does both):
   ```bash
   sudo automation/scripts/clean-node.sh --yes
   ```

### Issue: Kubelet Still Running After Cleanup

**Symptom:**
```
Verification failed: kubelet still running
```

**Cause:**
- Control plane processes (apiserver, controller-manager, scheduler, etcd) still running

**Solution:**
```bash
# Force kill all K8s processes
sudo pkill -9 -f kubelet
sudo pkill -9 -f kube-apiserver
sudo pkill -9 -f kube-controller-manager
sudo pkill -9 -f kube-scheduler
sudo pkill -9 -f etcd
sudo systemctl daemon-reload
```

The cleanup script now does this automatically.

### Issue: Modules Not Loading

**Symptom:**
```
✗ Module br_netfilter not loaded
```

**Solution:**
```bash
# Load modules
sudo modprobe br_netfilter
sudo modprobe overlay

# Make persistent
echo -e "br_netfilter\noverlay" | sudo tee /etc/modules-load.d/k8s.conf

# Verify
lsmod | grep -E 'br_netfilter|overlay'
   lsmod | grep br_netfilter
   lsmod | grep overlay
   ```

### Issue: Sysctl Parameter Not Set

**Symptom:**
```
✗ net.bridge.bridge-nf-call-iptables = 0 (expected 1)
```

**Causes:**
- Sysctl parameter not configured
- Configuration not persisted

**Solutions:**

1. Set parameter:
   ```bash
   sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
   sudo sysctl -w net.ipv4.ip_forward=1
   ```

2. Persist configuration:
   ```bash
   cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-iptables = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   net.ipv4.ip_forward = 1
   EOF
   
   sudo sysctl --system
   ```

3. Verify:
   ```bash
   sysctl net.bridge.bridge-nf-call-iptables
   sysctl net.ipv4.ip_forward
   ```

### Issue: Platform Driver Not Found

**Symptom:**
```
✗ Driver hfi1 not available
```

**Causes:**
- Cornelis Networks driver not installed
- Wrong driver for platform

**Solutions:**

1. Verify hardware:
   ```bash
   lspci -d 434e:0001
   ```

2. Check driver availability:
   ```bash
   modinfo hfi1  # For CN5000
   ```

3. Install driver (refer to Cornelis Networks documentation)

4. Load driver:
   ```bash
   sudo modprobe hfi1
   ```

### Issue: InfiniBand Subsystem Not Ready

**Symptom:**
```
✗ /dev/infiniband/uverbs0 not found
```

**Causes:**
- InfiniBand core modules not loaded
- Hardware not detected
- Driver not properly initialized

**Solutions:**

1. Load InfiniBand modules:
   ```bash
   sudo modprobe ib_core
   sudo modprobe ib_uverbs
   sudo modprobe ib_ipoib
   sudo modprobe rdma_cm
   ```

2. Verify device files:
   ```bash
   ls -la /dev/infiniband/
   ```

3. Check InfiniBand status:
   ```bash
   ibstat
   ibstatus
   ```

## Cleanup Issues

### Issue: Cleanup Fails with Permission Denied

**Symptom:**
```
rm: cannot remove '/etc/kubernetes': Permission denied
```

**Causes:**
- Not running as root
- SELinux/AppArmor restrictions

**Solutions:**

1. Run as root:
   ```bash
   sudo automation/scripts/clean-node.sh --yes
   ```

2. Check SELinux:
   ```bash
   getenforce  # Should show Permissive or Disabled for K8s
   ```

### Issue: Network Interfaces Remain After Cleanup

**Symptom:**
```
✗ cni0 interface still exists
```

**Causes:**
- Interfaces in use
- Cleanup script didn't complete

**Solutions:**

1. Manually remove interfaces:
   ```bash
   sudo ip link delete cni0
   sudo ip link delete flannel.1
   sudo ip link delete kube-ipvs0
   ```

2. Remove veth interfaces:
   ```bash
   for iface in $(ip link show | grep -o 'veth[^:@]*'); do
   sudo ip link delete "$iface"
   done
   ```

3. Reboot if interfaces persist:
   ```bash
   sudo reboot
   ```

### Issue: Kubelet Process Still Running

**Symptom:**
```
✗ kubelet still running
```

**Causes:**
- Service not stopped properly
- Process stuck

**Solutions:**

1. Stop service:
   ```bash
   sudo systemctl stop kubelet
   ```

2. Kill process if needed:
   ```bash
   sudo pkill -9 kubelet
   ```

3. Verify:
   ```bash
   pgrep kubelet  # Should return nothing
   ```

## Setup Issues

### Issue: Repository GPG Key Error

**Symptom:**
```
GPG error: https://pkgs.k8s.io/core:/stable:/v1.28/deb Release: ...
```

**Causes:**
- GPG key not imported
- Key expired or invalid

**Solutions:**

1. Import GPG key manually:
   ```bash
   # Debian/Ubuntu
   curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
     sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
   
   # RHEL/Rocky
   sudo rpm --import https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
   ```

2. Update package cache:
   ```bash
   sudo apt-get update  # Or sudo dnf makecache
   ```

### Issue: Containerd Configuration Error

**Symptom:**
```
containerd: failed to load config
```

**Causes:**
- Invalid configuration file
- Syntax error in config.toml

**Solutions:**

1. Regenerate configuration:
   ```bash
   sudo mkdir -p /etc/containerd
   containerd config default | sudo tee /etc/containerd/config.toml
   ```

2. Apply Kubernetes-specific settings:
   ```bash
   sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
   ```

3. Restart containerd:
   ```bash
   sudo systemctl restart containerd
   ```

### Issue: Firewall Blocks Kubernetes Ports

**Symptom:**
```
Connection refused on port 6443
```

**Causes:**
- Firewall not configured
- Ports not opened

**Solutions:**

1. Check firewall status:
   ```bash
   # firewalld
   sudo firewall-cmd --list-ports
   
   # ufw
   sudo ufw status
   ```

2. Open required ports:
   ```bash
   # Control plane
   sudo firewall-cmd --permanent --add-port=6443/tcp
   sudo firewall-cmd --permanent --add-port=2379-2380/tcp
   sudo firewall-cmd --permanent --add-port=10250/tcp
   sudo firewall-cmd --permanent --add-port=10259/tcp
   sudo firewall-cmd --permanent --add-port=10257/tcp
   sudo firewall-cmd --reload
   
   # Worker
   sudo firewall-cmd --permanent --add-port=10250/tcp
   sudo firewall-cmd --permanent --add-port=30000-32767/tcp
   sudo firewall-cmd --reload
   ```

3. Or disable firewall (not recommended for production):
   ```bash
   sudo systemctl stop firewalld
   sudo systemctl disable firewalld
   ```

## Ansible Issues

### Issue: SSH Connection Failed

**Symptom:**
```
fatal: [worker1]: UNREACHABLE! => {"changed": false, "msg": "Failed to connect to the host via ssh"}
```

**Causes:**
- SSH key not configured
- Wrong hostname/IP
- Firewall blocking SSH

**Solutions:**

1. Test SSH manually:
   ```bash
   ssh user@node
   ```

2. Setup SSH keys:
   ```bash
   ssh-copy-id user@node
   ```

3. Verify inventory:
   ```bash
   ansible-inventory -i automation/inventory/hosts.yaml --list
   ```

### Issue: Privilege Escalation Failed

**Symptom:**
```
fatal: [worker1]: FAILED! => {"msg": "Missing sudo password"}
```

**Causes:**
- User doesn't have sudo access
- Sudo password required

**Solutions:**

1. Add `--ask-become-pass` flag:
   ```bash
   ansible-playbook ... --ask-become-pass
   ```

2. Configure passwordless sudo:
   ```bash
   echo "user ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/user
   ```

3. Or use root user in inventory:
   ```yaml
   ansible_user: root
   ```

### Issue: Python Not Found

**Symptom:**
```
fatal: [worker1]: FAILED! => {"msg": "/usr/bin/python: not found"}
```

**Causes:**
- Python not installed
- Wrong Python path

**Solutions:**

1. Install Python:
   ```bash
   # Debian/Ubuntu
   sudo apt-get install python3
   
   # RHEL/Rocky
   sudo dnf install python3
   ```

2. Set Python interpreter in inventory:
   ```yaml
   ansible_python_interpreter: /usr/bin/python3
   ```

## Distribution-Specific Issues

### Ubuntu/Debian

**Issue: Package has unmet dependencies**

Solution:
```bash
sudo apt-get update
sudo apt-get install -f
sudo apt-get install kubelet kubeadm kubectl containerd
```

### RHEL/Rocky

**Issue: Package conflicts with existing packages**

Solution:
```bash
sudo dnf remove docker docker-common docker-selinux docker-engine
sudo dnf install containerd.io
```

### SLES

**Issue: Repository not found**

Solution:
```bash
sudo zypper addrepo https://pkgs.k8s.io/core:/stable:/v1.28/rpm/ kubernetes
sudo zypper --gpg-auto-import-keys refresh
sudo zypper install kubelet kubeadm kubectl containerd
```

### Issue: IPoIB Interface Name Does Not Match Inventory

**Symptom:**
```
Flannel pod CrashLoopBackOff with log:
  "Could not find valid interface matching <ipoib_iface>"

Or setup-node.sh / node-precheck.sh reports:
  ✗ IPoIB naming: no ibs* interfaces found
```

**Diagnosis:**
```bash
# List all IB interfaces and their state (name + UP/DOWN)
ip -br link show type ipoib
```

**Common Causes:**

1. **SLES default IPoIB naming** — SLES assigns legacy kernel-assigned names rather
   than the `<ipoib_iface>` value set in `ipoib_interface` in your Ansible inventory.

2. **Multi-HFI node after reboot or driver reload** — On nodes with two HFIs, the kernel may
   assign interface names in a different order after a reboot, causing the active port to appear
   under a different name than what is set in `ipoib_interface` in the Ansible inventory.

**Solution:**

Identify the active IPoIB interface and rename it to match the `ipoib_interface` value in your
inventory (the value you supplied as `ipoib_interface` in your Ansible inventory file):

> **Warning**: The rename sequence below briefly disrupts IPoIB connectivity and will cause
> Flannel to lose its fabric interface until the link is brought back up. Do not run this
> while production workloads depend on the IPoIB link.

```bash
# Find the active port (look for 'Active' in ibstat output)
ibstat

# Check whether <ipoib_iface> already exists — if so, the rename will fail with
# "File exists". Resolve the collision before proceeding (e.g. rename or remove
# the existing interface, or verify it is already the correct interface).
ip -br link show <ipoib_iface> 2>/dev/null && echo "WARNING: <ipoib_iface> already exists"

# Rename the interface — replace <current_name> with the name shown by ibstat,
# and <ipoib_iface> with the value from your ipoib_interface inventory variable.
# The link must be brought down before renaming; modern kernels reject renaming an UP interface.
ip link set <current_name> down
ip link set <current_name> name <ipoib_iface>
ip addr add <data-plane-ip>/24 dev <ipoib_iface>
ip link set <ipoib_iface> up

# Verify the interface is UP and Active before proceeding
ip -br link show <ipoib_iface>
ibstat | grep -A5 'Port 1' | grep -E 'State|Physical'
ping -c 3 <gateway_ip>

# If a Kubernetes cluster is running, verify Flannel recovered
kubectl get pods -n kube-flannel -l app=flannel 2>/dev/null || true
```

**Rollback**: if the rename caused issues, reverse it with:

```bash
ip link set <ipoib_iface> down
ip link set <ipoib_iface> name <current_name>
ip addr add <data-plane-ip>/24 dev <current_name>
ip link set <current_name> up
```

To make the rename persistent across reboots, write a udev rule keyed on the **PCI slot** of the
HFI port you renamed above. The runtime rename used the kernel-assigned name (`<current_name>`)
as the identifier; the udev rule must use the PCI slot + `dev_port` instead, because kernel names
are not stable across reboots. Verify that the PCI slot you use in the rule corresponds to the
same physical port you renamed — on multi-HFI nodes, confirm with `lspci -d 434e:0001 -D` and
cross-reference against `ibstat` port state before writing the rule:

```bash
# Find the PCI slot (e.g. 0000:21:00.0)
lspci -d 434e:0001 -D

# Write udev rules for all IPoIB interfaces on this node.
# dev_port 0 = physical port 1, dev_port 1 = physical port 2.
# On multi-HFI nodes, add one rule per port — all rules must be written
# in a single block (> truncates; a second echo > would overwrite the first rule).
# Replace each <pci_slot_N> with the PCI address from lspci, and each
# <ipoib_iface_N> with the desired interface name for that port.
#
# Example for a single-HFI node (one PCI slot, port 1 only):
cat > /etc/udev/rules.d/70-ipoib-naming.rules << 'EOF'
SUBSYSTEM=="net", ACTION=="add", ENV{ID_NET_DRIVER}=="ib_ipoib", KERNELS=="<pci_slot_0>", ATTR{dev_port}=="0", NAME="<ipoib_iface_0>"
EOF
#
# Example for a dual-HFI node (two PCI slots, one rule per active port):
cat > /etc/udev/rules.d/70-ipoib-naming.rules << 'EOF'
SUBSYSTEM=="net", ACTION=="add", ENV{ID_NET_DRIVER}=="ib_ipoib", KERNELS=="<pci_slot_0>", ATTR{dev_port}=="0", NAME="<ipoib_iface_0>"
SUBSYSTEM=="net", ACTION=="add", ENV{ID_NET_DRIVER}=="ib_ipoib", KERNELS=="<pci_slot_1>", ATTR{dev_port}=="0", NAME="<ipoib_iface_1>"
EOF

udevadm control --reload-rules

# Scope the trigger to the specific IB interface path to avoid re-emitting
# add events for all net interfaces (which can rename or flap the management NIC).
# Replace <current_name> with the current interface name before the rename.
udevadm trigger --action=add /sys/class/net/<current_name>
```

## Getting Help

If you encounter issues not covered in this guide:

1. Check logs:
   ```bash
   journalctl -u kubelet -n 100
   journalctl -u containerd -n 100
   ```

2. Run tests with verbose output:
   ```bash
   sudo tests/functional/test-node-prerequisites.sh --verbose
   ```

3. Check Kubernetes documentation:
   - https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/

4. Check Cornelis Networks documentation for platform-specific issues

5. Review backup logs after cleanup:
   ```bash
   ls -la /var/log/k8s-cleanup-*/
   ```

---

## RDMA CDI Device Plugin Issues

### Issue: Device Plugin Pods in CrashLoopBackOff

**Symptom:**
```bash
kubectl get pods -n kube-system -l app=rdma-shared-device-plugin
# NAME                                  READY   STATUS             RESTARTS
# rdma-shared-device-plugin-xxxxx          0/1     CrashLoopBackOff   5
```

**Diagnosis:**
```bash
kubectl logs -n kube-system -l app=rdma-shared-device-plugin
```

**Common Causes:**

1. **containerd version < 1.7.0**
   ```bash
   # Check version on node:
   containerd --version
   # Should show: containerd.io 1.7.0 or higher
   ```
   
   **Solution:** Upgrade containerd to 1.7.0+
   ```bash
   # RHEL/Rocky:
   sudo dnf upgrade containerd.io
   
   # Ubuntu:
   sudo apt-get update && sudo apt-get install containerd
   ```

2. **CDI not enabled in containerd config**
   ```bash
   # Check config on node:
   grep -A2 "enable_cdi" /etc/containerd/config.toml
   # Should show:
   #   enable_cdi = true
   #   cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
   ```
   
   **Solution:** Re-run node setup with CDI enabled
   ```bash
   cd automation
   ansible-playbook -i inventory/hosts.yaml playbooks/node-management.yaml \
     -e operation=setup \
     -e deploy_cni=rdma-shared-device
   ```

3. **SuperNIC (HFI) devices not present**
   ```bash
    # Check on node:
    ls -l /dev/hfi1_*
    lspci -d 434e:0001
    lsmod | grep hfi
    ```
    
    **Solution:** Load HFI driver
    ```bash
    sudo modprobe hfi1
    ```

### Issue: cornelis.com/hfi Resource Not Advertised

**Symptom:**
```bash
kubectl describe node <node-name> | grep cornelis.com/hfi
# (no output)
```

**Diagnosis:**

1. **Check device plugin is running:**
   ```bash
   kubectl get pods -n kube-system -l app=rdma-shared-device-plugin
   ```

2. **Check device plugin logs:**
   ```bash
   kubectl logs -n kube-system -l app=rdma-shared-device-plugin
   ```

3. **Check (SuperNIC) HFI hardware on node:**
   ```bash
   # On the node:
   lspci -d 434e:0001  # CN5000 (vendor 434e, device 0001, driver hfi1)
   ```

4. **Check HFI driver loaded:**
   ```bash
   lsmod | grep hfi
   # Should show: hfi1
   ```

5. **Check device files exist:**
   ```bash
   ls -l /dev/hfi1_*
   # CN5000: /dev/hfi1_0
   ```

**Solution:**

If driver not loaded:
```bash
sudo modprobe hfi1
```

If device files missing:
```bash
# Check udev rules:
ls -l /etc/udev/rules.d/*hfi*
ls -l /etc/udev/rules.d/*psm*

# Reload udev:
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Issue: Pod Stuck in ContainerCreating

**Symptom:**
```bash
kubectl get pod rdma-test-pod
# NAME            READY   STATUS              RESTARTS   AGE
# rdma-test-pod   0/1     ContainerCreating   0          2m
```

**Diagnosis:**
```bash
kubectl describe pod rdma-test-pod
# Look for events related to device allocation
```

**Common Causes:**

1. **Feature gate not enabled**
   ```bash
   # Check on node:
   grep "DevicePluginCDIDevices" /var/lib/kubelet/kubeadm-flags.env
   # Should show: --feature-gates=DevicePluginCDIDevices=true
   ```
   
   **Solution:** Enable feature gate
   ```bash
   # On all nodes:
   sudo sed -i 's/KUBELET_KUBEADM_ARGS="/KUBELET_KUBEADM_ARGS="--feature-gates=DevicePluginCDIDevices=true /' \
     /var/lib/kubelet/kubeadm-flags.env
   sudo systemctl restart kubelet
   ```

2. **CDI spec file missing**
   ```bash
   # Check on node:
   ls -l /var/run/cdi/
   cat /var/run/cdi/cornelis.com-hfi.yaml
   ```
   
   **Solution:** Restart device plugin to regenerate CDI spec
   ```bash
   kubectl delete pod -n kube-system -l app=rdma-shared-device-plugin
   ```

3. **containerd CDI not enabled**
   ```bash
   # Check on node:
   grep "enable_cdi" /etc/containerd/config.toml
   ```
   
   **Solution:** See "CDI not enabled in containerd config" above

### Issue: RDMA Operations Fail Inside Pod

**Symptom:**
```bash
kubectl exec rdma-test-pod -- ibv_devinfo
# libibverbs: Warning: couldn't open config directory '/etc/libibverbs.d'.
# libibverbs: Warning: no userspace device-specific driver found for /dev/infiniband/uverbs0
```

**Diagnosis:**

1. **Check device files are mounted:**
   ```bash
   kubectl exec rdma-test-pod -- ls -l /dev/hfi1_0 /dev/infiniband/uverbs0
   ```

2. **Check environment variables:**
   ```bash
   kubectl exec rdma-test-pod -- env | grep FI_
   # Should show: FI_PROVIDER=opx
   ```

3. **Check memory lock limits:**
   ```bash
   kubectl exec rdma-test-pod -- ulimit -l
   # Should show: unlimited (or very high value)
   ```

**Common Causes:**

1. **Missing CAP_IPC_LOCK capability**
   
   **Solution:** Add to pod spec:
   ```yaml
   securityContext:
     capabilities:
       add:
       - IPC_LOCK
   ```

2. **memlock ulimit too low**
   
   **Solution:** Ensure `CAP_IPC_LOCK` is set (see above), or set resource limits:
   ```yaml
   resources:
     limits:
       memory: "8Gi"
   ```

3. **/dev/shm too small**
   
   **Solution:** Expand shared memory:
   ```yaml
   volumeMounts:
   - name: dev-shm
     mountPath: /dev/shm
   volumes:
   - name: dev-shm
     emptyDir:
       medium: Memory
       sizeLimit: "1Gi"
   ```

### Issue: CDI Spec Inspection

**View generated CDI spec on a node:**
```bash
cat /var/run/cdi/cornelis.com-hfi.yaml
```

**Expected structure:**
```yaml
cdiVersion: "0.6.0"
kind: "cornelis.com/hfi"
devices:
  - name: "hfi0"
    containerEdits:
      deviceNodes:
        - path: "/dev/hfi1_0"
          permissions: "rw"
        - path: "/dev/infiniband/uverbs0"
          permissions: "rw"
        - path: "/dev/infiniband/rdma_cm"
          permissions: "rw"
containerEdits:
  env:
    - "FI_PROVIDER=opx"
```

**If spec is malformed or missing device nodes:**
1. Check device plugin logs for errors.
2. Verify `/dev/hfi1_*` devices exist on node.
3. Restart device plugin pod.

### Issue: containerd Version Check

**Check containerd version and CDI support:**
```bash
# On node:
containerd --version
# Should show: containerd.io 1.7.0 or higher

containerd config dump | grep -A2 cdi
# Should show:
#   enable_cdi = true
#   cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]
```

**If CDI not enabled:**
```bash
# Regenerate config with CDI:
sudo mkdir -p /etc/containerd
sudo containerd config default | \
  sed 's/enable_cdi = false/enable_cdi = true/' | \
  sudo tee /etc/containerd/config.toml

# Add cdi_spec_dirs if missing:
sudo sed -i '/enable_cdi = true/a\    cdi_spec_dirs = ["/etc/cdi", "/var/run/cdi"]' \
  /etc/containerd/config.toml

sudo systemctl restart containerd
```
