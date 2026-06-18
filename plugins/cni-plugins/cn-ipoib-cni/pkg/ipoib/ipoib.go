/*
2022 NVIDIA CORPORATION & AFFILIATES

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Modified by Cornelis Networks, 2026

package ipoib

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/containernetworking/cni/pkg/types/current"
	"github.com/containernetworking/plugins/pkg/ns"
	"github.com/containernetworking/plugins/pkg/utils/sysctl"
	"github.com/vishvananda/netlink"

	"github.com/cornelis/cn-ipoib-cni/pkg/types"
)

const (
	ipV4InterfaceArpProxySysctlTemplate = "net.ipv4.conf.%s.proxy_arp"
	lockDir                             = "/var/run/cni-ipoib"
)

type ipoibManager struct {
	nLink types.NetlinkManager
}

type netLink struct {
}

// LinkByName implements NetlinkManager
func (n *netLink) LinkByName(name string) (netlink.Link, error) {
	return netlink.LinkByName(name)
}

// LinkSetUp using NetlinkManager
func (n *netLink) LinkSetUp(link netlink.Link) error {
	return netlink.LinkSetUp(link)
}

// LinkSetDown using NetlinkManager
func (n *netLink) LinkSetDown(link netlink.Link) error {
	return netlink.LinkSetDown(link)
}

// LinkSetName using NetlinkManager
func (n *netLink) LinkSetName(link netlink.Link, name string) error {
	return netlink.LinkSetName(link, name)
}

// LinkSetNsFd using NetlinkManager
func (n *netLink) LinkSetNsFd(link netlink.Link, fd int) error {
	return netlink.LinkSetNsFd(link, fd)
}

// LinkAdd using NetLinkManager
func (n *netLink) LinkAdd(link netlink.Link) error {
	return netlink.LinkAdd(link)
}

// LinkDel using NetLinkManager
func (n *netLink) LinkDel(link netlink.Link) error {
	return netlink.LinkDel(link)
}

// LinkModify using NetLinkManager
func (n *netLink) LinkModify(link netlink.Link) error {
	// Delete and recreate the link with new attributes
	// This is necessary because netlink doesn't support modifying IPoIB attributes directly
	if err := netlink.LinkDel(link); err != nil {
		return err
	}
	return netlink.LinkAdd(link)
}

// SetSysVal set value for sysctl attribute
func (n *netLink) SetSysVal(attribute, value string) (string, error) {
	return sysctl.Sysctl(attribute, value)
}

// NewIpoibManager returns an instance of IpoibManager
func NewIpoibManager() types.Manager {
	return &ipoibManager{
		nLink: &netLink{},
	}
}

// CreateIpoibLink create a link in pod netns using ip link commands (not netlink)
// This approach matches the working manual test and avoids netlink attribute corruption
func (im *ipoibManager) CreateIpoibLink(conf *types.NetConf, ifName string, netns ns.NetNS, containerID string) (
	*current.Interface, error) {
	iface := &current.Interface{}
	m, err := im.nLink.LinkByName(conf.Master)
	if err != nil {
		return nil, fmt.Errorf("failed to lookup master %q: %v", conf.Master, err)
	}

	if m.Type() != "ipoib" {
		return nil, fmt.Errorf("master device %q is not of type ipoib (type: %s)", conf.Master, m.Type())
	}

	ipoibParent, ok := m.(*netlink.IPoIB)
	if !ok {
		return nil, fmt.Errorf("failed to convert master %q to ipoib netlink interface", conf.Master)
	}

	// Use a unique name based on container ID to avoid conflicts
	tmpName := fmt.Sprintf("ipoib-%s", containerID[:8])

	// Get parent pkey and mode
	parentPkey := ipoibParent.Pkey

	// Debug logging function
	debugLog := func(msg string) {
		f, err := os.OpenFile("/var/log/cni-ipoib-debug.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0666)
		if err == nil {
			defer f.Close()
			f.WriteString(fmt.Sprintf("[%s] %s\n", time.Now().Format("15:04:05"), msg))
		}
		// Also log to stderr
		fmt.Fprintf(os.Stderr, "[CNI-IPOIB-DEBUG] %s\n", msg)
	}

	debugLog(fmt.Sprintf("=== CNI PLUGIN INVOKED === ifName=%s master=%s", ifName, conf.Master))
	debugLog(fmt.Sprintf("Parent interface: %s, pkey=0x%04x, mode=%d (0=datagram, 1=connected)", conf.Master, parentPkey, ipoibParent.Mode))

	// Always inherit mode from parent interface
	mode := "datagram"
	if ipoibParent.Mode == netlink.IPOIB_MODE_CONNECTED {
		mode = "connected"
	}
	debugLog(fmt.Sprintf("Inherited mode from parent: %s", mode))

	// Set MTU from config, or use appropriate default for datagram mode
	// Datagram mode max MTU is 10236, connected mode max MTU is 65520
	// Since we create interfaces in datagram mode (without mode parameter),
	// we must use datagram-compatible MTU
	mtu := conf.MTU
	if mtu == 0 || mtu > 10236 {
		// Use safe default MTU for datagram mode
		mtu = 10236
	}
	debugLog(fmt.Sprintf("MTU: %d (datagram mode max: 10236)", mtu))

	// Acquire per-node lock to serialize IPoIB interface creation
	// This prevents race conditions when multiple CNI instances run concurrently
	lockFile := filepath.Join(lockDir, conf.Master+".lock")
	debugLog(fmt.Sprintf("Acquiring lock: %s", lockFile))

	// Create lock directory if it doesn't exist
	if err := os.MkdirAll(lockDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create lock directory %s: %v", lockDir, err)
	}

	// Open/create lock file
	lock, err := os.OpenFile(lockFile, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open lock file %s: %v", lockFile, err)
	}
	defer lock.Close()

	// Acquire exclusive lock with timeout
	lockTimeout := time.After(30 * time.Second)
	lockTicker := time.NewTicker(100 * time.Millisecond)
	defer lockTicker.Stop()

	locked := false
	for !locked {
		select {
		case <-lockTimeout:
			return nil, fmt.Errorf("timeout acquiring lock %s after 30 seconds", lockFile)
		case <-lockTicker.C:
			err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			if err == nil {
				locked = true
				debugLog(fmt.Sprintf("Lock acquired: %s", lockFile))
			} else if err != syscall.EWOULDBLOCK {
				return nil, fmt.Errorf("failed to acquire lock %s: %v", lockFile, err)
			}
		}
	}
	defer func() {
		syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
		debugLog(fmt.Sprintf("Lock released: %s", lockFile))
	}()

	// Step 1: Create IPoIB child interface in host netns using ip link command
	// NOTE: Do NOT specify pkey or mode parameters - they cause "Device or resource busy" errors
	// when multiple child interfaces are created. The kernel will auto-assign:
	// - pkey: inherited from parent (0x8001)
	// - mode: datagram (default, works for all use cases)
	debugLog(fmt.Sprintf("Creating interface %s (will inherit pkey 0x%04x, use datagram mode)", tmpName, parentPkey))
	cmd := exec.Command("ip", "link", "add", "link", conf.Master, "name", tmpName, "type", "ipoib")
	if output, err := cmd.CombinedOutput(); err != nil {
		debugLog(fmt.Sprintf("Failed to create interface: %v (output: %s)", err, string(output)))
		return nil, fmt.Errorf("failed to create interface %s: %v (output: %s)", tmpName, err, string(output))
	}
	debugLog(fmt.Sprintf("Created interface %s successfully", tmpName))

	// Verify creation
	cmd = exec.Command("ip", "-d", "link", "show", tmpName)
	if output, err := cmd.CombinedOutput(); err == nil {
		debugLog(fmt.Sprintf("After creation: %s", string(output)))
	}

	// Step 2: Set MTU
	debugLog(fmt.Sprintf("Setting MTU to %d for %s", mtu, tmpName))
	cmd = exec.Command("ip", "link", "set", tmpName, "mtu", fmt.Sprintf("%d", mtu))
	if output, err := cmd.CombinedOutput(); err != nil {
		debugLog(fmt.Sprintf("Failed to set MTU: %v (output: %s)", err, string(output)))
		// Cleanup on failure
		_ = exec.Command("ip", "link", "del", tmpName).Run()
		return nil, fmt.Errorf("failed to set MTU for %s: %v (output: %s)", tmpName, err, string(output))
	}
	debugLog(fmt.Sprintf("Set MTU to %d successfully", mtu))

	// Verify MTU setting
	cmd = exec.Command("ip", "-d", "link", "show", tmpName)
	if output, err := cmd.CombinedOutput(); err == nil {
		debugLog(fmt.Sprintf("After MTU set: %s", string(output)))
	}

	// Step 3: Move interface to pod netns using ip link command
	// Use netns path instead of FD because ip command needs the path
	netnsPath := netns.Path()
	netnsFd := netns.Fd()
	debugLog(fmt.Sprintf("DEBUG: netns.Path()='%s', netns.Fd()=%d", netnsPath, netnsFd))
	debugLog(fmt.Sprintf("Moving interface %s to netns path=%s", tmpName, netnsPath))
	cmd = exec.Command("ip", "link", "set", tmpName, "netns", netnsPath)
	if output, err := cmd.CombinedOutput(); err != nil {
		debugLog(fmt.Sprintf("Failed to move to netns: %v (output: %s)", err, string(output)))
		// Cleanup on failure
		_ = exec.Command("ip", "link", "del", tmpName).Run()
		return nil, fmt.Errorf("failed to move interface %s to netns: %v (output: %s)", tmpName, err, string(output))
	}
	debugLog(fmt.Sprintf("Successfully moved interface %s to netns", tmpName))

	// Step 4: Configure interface inside pod netns
	err = netns.Do(func(_ ns.NetNS) error {
		// Check interface in pod netns before rename
		cmd := exec.Command("ip", "-d", "link", "show", tmpName)
		if output, innerErr := cmd.CombinedOutput(); innerErr == nil {
			debugLog(fmt.Sprintf("In pod netns before rename: %s", string(output)))
		}

		// Rename to final name
		debugLog(fmt.Sprintf("Renaming %s to %s in pod netns", tmpName, ifName))
		cmd = exec.Command("ip", "link", "set", tmpName, "name", ifName)
		if output, innerErr := cmd.CombinedOutput(); innerErr != nil {
			debugLog(fmt.Sprintf("Failed to rename: %v (output: %s)", innerErr, string(output)))
			return fmt.Errorf("failed to rename interface %s to %s: %v (output: %s)", tmpName, ifName, innerErr, string(output))
		}
		debugLog(fmt.Sprintf("Renamed %s to %s successfully", tmpName, ifName))

		// Bring up loopback
		cmd = exec.Command("ip", "link", "set", "lo", "up")
		_ = cmd.Run() // Ignore error if already up

		// Bring up the IPoIB interface
		cmd = exec.Command("ip", "link", "set", ifName, "up")
		if output, innerErr := cmd.CombinedOutput(); innerErr != nil {
			return fmt.Errorf("failed to bring up interface %s: %v (output: %s)", ifName, innerErr, string(output))
		}

		// Set proxy_arp
		ipv4SysctlValueName := fmt.Sprintf(ipV4InterfaceArpProxySysctlTemplate, ifName)
		if _, innerErr := im.nLink.SetSysVal(ipv4SysctlValueName, "1"); innerErr != nil {
			return fmt.Errorf("failed to set proxy_arp on %q: %v", ifName, innerErr)
		}

		debugLog(fmt.Sprintf("Interface %s configured, carrier will establish asynchronously", ifName))

		// Get final interface details
		link, innerErr := im.nLink.LinkByName(ifName)
		if innerErr != nil {
			return fmt.Errorf("failed to get interface %q: %v", ifName, innerErr)
		}

		iface.Name = ifName
		iface.Mac = link.Attrs().HardwareAddr.String()
		iface.Sandbox = netns.Path()

		return nil
	})
	if err != nil {
		return nil, err
	}

	return iface, nil
}

func (im *ipoibManager) RemoveIpoibLink(ifName string, netns ns.NetNS) error {
	// There is a netns so try to clean up. Delete can be called multiple times
	// so don't return an error if the device is already removed.
	return netns.Do(func(_ ns.NetNS) error {
		link, err := im.nLink.LinkByName(ifName)
		if err != nil {
			// Link not in the container if cni Add failed
			return nil
		}

		if err := im.nLink.LinkDel(link); err != nil {
			return err
		}
		return nil
	})
}

// CleanupHostNamespace attempts to clean up orphaned IPoIB interfaces in the host namespace
// This handles cases where the pod netns was deleted before CNI cleanup could run
func (im *ipoibManager) CleanupHostNamespace(ifName string, containerID string) error {
	// Try both the final interface name and the temporary name used during creation
	tmpName := fmt.Sprintf("ipoib-%s", containerID[:8])

	for _, name := range []string{ifName, tmpName} {
		link, err := im.nLink.LinkByName(name)
		if err != nil {
			// Interface not found - already cleaned up or never created
			continue
		}

		// Found the interface - delete it
		if err := im.nLink.LinkDel(link); err != nil {
			// Log but don't fail - best effort cleanup
			fmt.Fprintf(os.Stderr, "[CNI-IPOIB] Warning: failed to delete orphaned interface %s: %v\n", name, err)
		}
	}

	// Always return nil - cleanup is best-effort and should not fail pod deletion
	return nil
}
