package resources

import (
	"fmt"
	"log"

	"github.com/jaypipes/ghw"
	pluginapi "k8s.io/kubelet/pkg/apis/deviceplugin/v1beta1"

	"github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin/pkg/types"
	"github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin/pkg/utils"
)

// pciNetDevice implements PciNetDevice interface to get generic device specific information
type pciNetDevice struct {
	pciAddress string
	ifName     string
	vendor     string
	deviceID   string
	driver     string
	linkType   string
	rdmaSpec   []*pluginapi.DeviceSpec
	hfiSpec    []*pluginapi.DeviceSpec
}

// NewPciNetDevice returns an instance of PciNetDevice interface
func NewPciNetDevice(dev *ghw.PCIDevice, rds types.RdmaDeviceSpec,
	nLink types.NetlinkManager) (types.PciNetDevice, error) {
	var ifName string

	pciAddr := dev.Address
	netDevs, _ := utils.GetNetNames(pciAddr)
	if len(netDevs) == 0 {
		ifName = ""
	} else {
		ifName = netDevs[0]
		if len(netDevs) > 1 {
			log.Printf("Warning: found several names for device %s %v, using first name %s", pciAddr, netDevs,
				ifName)
		}
	}

	driver, err := utils.GetPCIDevDriver(pciAddr)
	if err != nil {
		return nil, err
	}

	linkType := ""
	if ifName != "" {
		link, err := nLink.LinkByName(ifName)
		if err != nil {
			return nil, err
		}
		linkType = link.Attrs().EncapType
	}

	rdmaSpec := rds.Get(pciAddr)
	if err := rds.VerifyRdmaSpec(rdmaSpec); err != nil {
		return nil, fmt.Errorf("missing RDMA device spec for device %s, %v", pciAddr, err)
	}

	// Get HFI-specific device files (/dev/hfi1_*)
	hfiDevices, err := utils.GetHfiDevices(pciAddr)
	if err != nil {
		log.Printf("Warning: failed to get HFI devices for %s: %v", pciAddr, err)
		hfiDevices = []string{}
	}

	hfiSpec := make([]*pluginapi.DeviceSpec, 0, len(hfiDevices))
	for _, device := range hfiDevices {
		hfiSpec = append(hfiSpec, &pluginapi.DeviceSpec{
			HostPath:      device,
			ContainerPath: device,
			Permissions:   "rwm",
		})
	}

	return &pciNetDevice{
		pciAddress: pciAddr,
		vendor:     dev.Vendor.ID,
		deviceID:   dev.Product.ID,
		driver:     driver,
		ifName:     ifName,
		linkType:   linkType,
		rdmaSpec:   rdmaSpec,
		hfiSpec:    hfiSpec,
	}, nil
}

func (nd *pciNetDevice) GetVendor() string {
	return nd.vendor
}

func (nd *pciNetDevice) GetDeviceID() string {
	return nd.deviceID
}

func (nd *pciNetDevice) GetDriver() string {
	return nd.driver
}

func (nd *pciNetDevice) GetLinkType() string {
	return nd.linkType
}

func (nd *pciNetDevice) GetIfName() string {
	return nd.ifName
}

func (nd *pciNetDevice) GetPciAddr() string {
	return nd.pciAddress
}

func (nd *pciNetDevice) GetRdmaSpec() []*pluginapi.DeviceSpec {
	return nd.rdmaSpec
}

func (nd *pciNetDevice) GetHfiSpec() []*pluginapi.DeviceSpec {
	return nd.hfiSpec
}
