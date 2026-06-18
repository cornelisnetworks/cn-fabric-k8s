package utils

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/Mellanox/rdmamap"

	"github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin/pkg/types"
)

var (
	sysNetDevices      = "/sys/class/net"
	SysBusPci          = "/sys/bus/pci/devices"
	sysClassInfiniband = "/sys/class/infiniband"
)

// GetPciAddress return the pci address for given interface name
func GetPciAddress(ifName string) (string, error) {
	var pciAddress string
	ifaceDir := path.Join(sysNetDevices, ifName, "device")
	dirInfo, err := os.Lstat(ifaceDir)
	if err != nil {
		return pciAddress, fmt.Errorf("can't get the symbolic link of the device %q: %v", ifName, err)
	}

	if (dirInfo.Mode() & os.ModeSymlink) == 0 {
		return pciAddress, fmt.Errorf("no symbolic link for the device %q", ifName)
	}

	pciInfo, err := os.Readlink(ifaceDir)
	if err != nil {
		return pciAddress, fmt.Errorf("can't read the symbolic link of the device %q: %v", ifName, err)
	}

	pciAddress = pciInfo[9:]
	return pciAddress, nil
}

// GetRdmaDevices return rdma devices for given device pci address
func GetRdmaDevices(pciAddress string) []string {
	rdmaResources := rdmamap.GetRdmaDevicesForPcidev(pciAddress)
	rdmaDevices := make([]string, 0, len(rdmaResources))
	for _, resource := range rdmaResources {
		rdmaResourceDevices := rdmamap.GetRdmaCharDevices(resource)
		rdmaDevices = append(rdmaDevices, rdmaResourceDevices...)
	}

	return rdmaDevices
}

// IsEmptySelector returns if the selector is empty
func IsEmptySelector(selector *types.Selectors) bool {
	values := reflect.ValueOf(*selector)

	for i := 0; i < values.NumField(); i++ {
		value := values.Field(i)
		if !value.IsNil() && value.Len() > 0 {
			return false
		}
	}
	return true
}

// GetNetNames returns host net interface names as string for a PCI device from its pci address
func GetNetNames(pciAddr string) ([]string, error) {
	netDir := filepath.Join(SysBusPci, pciAddr, "net")
	if _, err := os.Lstat(netDir); err != nil {
		return nil, fmt.Errorf("no net directory under pci device %s: %q", pciAddr, err)
	}

	fInfos, err := os.ReadDir(netDir)
	if err != nil {
		return nil, fmt.Errorf("failed to read net directory %s: %q", netDir, err)
	}

	names := make([]string, 0)
	for _, f := range fInfos {
		names = append(names, f.Name())
	}

	return names, nil
}

// GetPCIDevDriver returns current driver attached to a pci device from its pci address
func GetPCIDevDriver(pciAddr string) (string, error) {
	driverLink := filepath.Join(SysBusPci, pciAddr, "driver")
	driverInfo, err := os.Readlink(driverLink)
	if err != nil {
		return "", fmt.Errorf("error getting driver info for device %s %v", pciAddr, err)
	}
	return filepath.Base(driverInfo), nil
}

// GetHfiDevices returns HFI character device paths for a given PCI address
// by discovering the InfiniBand device name via sysfs and mapping to /dev/hfi1_*
func GetHfiDevices(pciAddr string) ([]string, error) {
	hfiDevices := make([]string, 0)

	// Find InfiniBand device name via sysfs
	// /sys/bus/pci/devices/<pciAddr>/infiniband/ contains symlinks to IB devices
	ibDir := filepath.Join(SysBusPci, pciAddr, "infiniband")
	if _, err := os.Stat(ibDir); err != nil {
		// No InfiniBand device for this PCI address
		return hfiDevices, nil
	}

	fInfos, err := os.ReadDir(ibDir)
	if err != nil {
		return nil, fmt.Errorf("failed to read infiniband directory %s: %v", ibDir, err)
	}

	// For each IB device (e.g., hfi1_0), construct the corresponding /dev/hfi1_* path
	for _, f := range fInfos {
		ibDevName := f.Name()

		// Extract unit number from IB device name (e.g., "hfi1_0" -> "0")
		// HFI devices follow the pattern: hfi1_<unit>
		if strings.HasPrefix(ibDevName, "hfi") {
			// Construct device path: /dev/hfi1_<unit>
			// Note: the device file uses the "hfi1" prefix and lives at /dev/hfi1_*
			devPath := filepath.Join("/dev", ibDevName)

			// Verify device file exists before adding
			if _, err := os.Stat(devPath); err == nil {
				hfiDevices = append(hfiDevices, devPath)
			}
		}
	}

	return hfiDevices, nil
}
