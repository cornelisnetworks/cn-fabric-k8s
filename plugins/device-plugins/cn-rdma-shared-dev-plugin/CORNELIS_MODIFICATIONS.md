# Cornelis Modifications to k8s-rdma-shared-dev-plugin

This document details all modifications made to the upstream Mellanox `k8s-rdma-shared-dev-plugin` v1.5.3 to support Cornelis HFI devices with CDI.

## Summary of Changes

| Area | Files Modified | Purpose |
|------|---------------|---------|
| CDI Kind | `pkg/resources/server.go` | Change from `nvidia.com/net-rdma` to `cornelis.com/hfi` |
| HFI Device Discovery | `pkg/utils/utils.go` | Add `GetHfiDevices()` to discover `/dev/hfi1_*` via sysfs |
| Device Tracking | `pkg/resources/pci_net_device.go` | Add `hfiSpec` field to track HFI char devices |
| Device Spec Generation | `pkg/resources/server.go` | Include HFI devices in `getDevicesSpec()` |
| CDI Spec Generation | `pkg/cdi/cdi.go` | Add HFI device nodes and environment variables to CDI specs |
| Config Schema | `pkg/types/types.go` | Add `HfiDeviceConfig` struct for custom env vars |
| Interface Extension | `pkg/types/types.go` | Add `GetHfiSpec()` to `PciNetDevice` interface |
| Module Path | All Go files | Update import paths to Cornelis namespace |

## Detailed Modifications

### 1. CDI Kind Change

**File:** `pkg/resources/server.go`

**Before:**
```go
const (
	cdiResourcePrefix = "nvidia.com"
	cdiResourceKind   = "net-rdma"
)
```

**After:**
```go
const (
	cdiResourcePrefix = "cornelis.com"
	cdiResourceKind   = "hfi"
)
```

**Rationale:** Cornelis-specific CDI kind for proper resource identification and isolation.

---

### 2. HFI Device Discovery

**File:** `pkg/utils/utils.go`

**Added Function:**
```go
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
```

**Rationale:** Discovers HFI-specific character devices (`/dev/hfi1_*`) that are required for native OPX/PSM2 data path, in addition to standard RDMA devices.

---

### 3. Device Tracking Extension

**File:** `pkg/resources/pci_net_device.go`

**Modified Struct:**
```go
type pciNetDevice struct {
	pciAddress string
	ifName     string
	vendor     string
	deviceID   string
	driver     string
	linkType   string
	rdmaSpec   []*pluginapi.DeviceSpec
	hfiSpec    []*pluginapi.DeviceSpec  // ADDED
}
```

**Modified Constructor:**
```go
func NewPciNetDevice(dev *ghw.PCIDevice, rds types.RdmaDeviceSpec,
	nLink types.NetlinkManager) (types.PciNetDevice, error) {
	// ... existing code ...
	
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
		// ... existing fields ...
		hfiSpec:    hfiSpec,  // ADDED
	}, nil
}
```

**Added Getter:**
```go
func (nd *pciNetDevice) GetHfiSpec() []*pluginapi.DeviceSpec {
	return nd.hfiSpec
}
```

**Rationale:** Tracks HFI device specs separately from RDMA device specs for proper device mounting.

---

### 4. Device Spec Generation

**File:** `pkg/resources/server.go`

**Modified Function:**
```go
func getDevicesSpec(devices []types.PciNetDevice) []*pluginapi.DeviceSpec {
	devicesSpec := make([]*pluginapi.DeviceSpec, 0)
	for _, device := range devices {
		// Add RDMA device specs (/dev/infiniband/*)
		rdmaDeviceSpec := device.GetRdmaSpec()
		if len(rdmaDeviceSpec) == 0 {
			log.Printf("Warning: non-Rdma Device %s\n", device.GetPciAddr())
		}
		devicesSpec = append(devicesSpec, rdmaDeviceSpec...)
		
		// Add HFI device specs (/dev/hfi1_*)  // ADDED
		hfiDeviceSpec := device.GetHfiSpec()
		devicesSpec = append(devicesSpec, hfiDeviceSpec...)
	}

	return devicesSpec
}
```

**Rationale:** Ensures both RDMA and HFI device files are included in legacy mode allocations.

---

### 5. CDI Spec Generation

**File:** `pkg/cdi/cdi.go`

**Modified Interface:**
```go
type CDI interface {
	CreateCDISpec(resourcePrefix, resourceName, poolName string, devices []types.PciNetDevice, envVars []string) error  // ADDED envVars parameter
	CreateContainerAnnotations(
		devices []types.PciNetDevice, resourcePrefix, resourceKind string) (map[string]string, error)
}
```

**Modified Function:**
```go
func (c *impl) CreateCDISpec(
	resourcePrefix, resourceName, poolName string, devices []types.PciNetDevice, envVars []string) error {
	log.Printf("creating CDI spec for \"%s\" resource", resourceName)

	cdiDevices := make([]cdiSpecs.Device, 0)
	
	// Global container edits applied to all devices  // ADDED
	globalEdits := cdiSpecs.ContainerEdits{}
	if len(envVars) > 0 {
		globalEdits.Env = envVars
	}
	
	cdiSpec := cdiSpecs.Spec{
		Version:        cdiSpecs.CurrentVersion,
		Kind:           resourcePrefix + "/" + resourceName,
		Devices:        cdiDevices,
		ContainerEdits: globalEdits,  // ADDED
	}

	for _, dev := range devices {
		containerEdit := cdiSpecs.ContainerEdits{
			DeviceNodes: make([]*cdiSpecs.DeviceNode, 0),
		}

		// Add RDMA device nodes (/dev/infiniband/*)
		rdmaSpec := dev.GetRdmaSpec()
		for _, spec := range rdmaSpec {
			deviceNode := cdiSpecs.DeviceNode{
				Path:        spec.ContainerPath,
				HostPath:    spec.HostPath,
				Permissions: "rw",
			}
			containerEdit.DeviceNodes = append(containerEdit.DeviceNodes, &deviceNode)
		}
		
		// Add HFI device nodes (/dev/hfi1_*)  // ADDED
		hfiSpec := dev.GetHfiSpec()
		for _, spec := range hfiSpec {
			deviceNode := cdiSpecs.DeviceNode{
				Path:        spec.ContainerPath,
				HostPath:    spec.HostPath,
				Permissions: "rw",
			}
			containerEdit.DeviceNodes = append(containerEdit.DeviceNodes, &deviceNode)
		}

		device := cdiSpecs.Device{
			Name:           dev.GetPciAddr(),
			ContainerEdits: containerEdit,
		}
		cdiSpec.Devices = append(cdiSpec.Devices, device)
	}
	
	// ... rest of function unchanged ...
}
```

**Rationale:** Adds HFI device nodes and global environment variables to CDI specs for proper container configuration.

---

### 6. Config Schema Extension

**File:** `pkg/types/types.go`

**Added Struct:**
```go
// HfiDeviceConfig contains HFI-specific device configuration
type HfiDeviceConfig struct {
	DevicePattern string   `json:"devicePattern,omitempty"` // e.g., "/dev/hfi1_%d"
	EnvVars       []string `json:"envVars,omitempty"`       // e.g., ["FI_PROVIDER=opx"]
}
```

**Modified Struct:**
```go
type UserConfig struct {
	ResourceName   string           `json:"resourceName"`
	ResourcePrefix string           `json:"resourcePrefix"`
	RdmaHcaMax     int              `json:"rdmaHcaMax"`
	Devices        []string         `json:"devices"`
	Selectors      Selectors        `json:"selectors"`
	HfiDevices     *HfiDeviceConfig `json:"hfiDevices,omitempty"`  // ADDED
}
```

**Rationale:** Allows ConfigMap to specify custom environment variables for HFI devices.

---

### 7. Interface Extension

**File:** `pkg/types/types.go`

**Modified Interface:**
```go
type PciNetDevice interface {
	GetPciAddr() string
	GetIfName() string
	GetVendor() string
	GetDeviceID() string
	GetDriver() string
	GetLinkType() string
	GetRdmaSpec() []*pluginapi.DeviceSpec
	GetHfiSpec() []*pluginapi.DeviceSpec  // ADDED
}
```

**Rationale:** Extends interface to support HFI device spec retrieval.

---

### 8. Resource Server Modifications

**File:** `pkg/resources/server.go`

**Modified Struct:**
```go
type resourceServer struct {
	// ... existing fields ...
	envVars         []string  // ADDED
}
```

**Modified Constructor:**
```go
func newResourceServer(config *types.UserConfig, devices []types.PciNetDevice, watcherMode bool,
	socketSuffix string, useCdi bool) (types.ResourceServer, error) {
	// ... existing code ...
	
	// Extract environment variables from config  // ADDED
	envVars := []string{"FI_PROVIDER=opx"}
	if config.HfiDevices != nil && len(config.HfiDevices.EnvVars) > 0 {
		envVars = config.HfiDevices.EnvVars
	}

	return &resourceServer{
		// ... existing fields ...
		envVars:         envVars,  // ADDED
	}, nil
}
```

**Modified Function:**
```go
func (rs *resourceServer) updateCDISpec() error {
	if !rs.useCdi {
		return nil
	}
	err := rs.cdi.CreateCDISpec(cdiResourcePrefix, cdiResourceKind, rs.cdiResourceName, rs.pciDevices, rs.envVars)  // ADDED envVars parameter
	if err != nil {
		log.Printf("updateCDISpec(): error creating CDI spec: %v", err)
		return err
	}
	return nil
}
```

**Rationale:** Passes environment variables from config to CDI spec generation.

---

### 9. Module Path Updates

**All Go Files**

**Before:**
```go
import "github.com/Mellanox/k8s-rdma-shared-dev-plugin/pkg/..."
```

**After:**
```go
import "github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin/pkg/..."
```

**Rationale:** Aligns with Cornelis repository structure.

---

## Testing Status

| Component | Status | Notes |
|-----------|--------|-------|
| Go compilation | ✅ Verified | Binary builds successfully (21MB) |
| HFI device discovery | ⏸️ Pending | Requires CN5000 hardware with `/dev/hfi1_0` |
| CDI spec generation | ⏸️ Pending | Requires integration test with containerd 1.7+ |
| Environment variable injection | ⏸️ Pending | Requires pod deployment test |
| Multi-platform support | ⏸️ Pending | Requires additional Cornelis hardware generations |

---

## Known Limitations

1. **rdmamap compatibility:** The upstream `rdmamap.GetRdmaCharDevices()` function has not been tested with Cornelis vendor ID `1fc1`. A sysfs fallback may be needed if rdmamap does not recognize Cornelis devices.

2. **Unit tests:** No unit tests have been added yet for the new HFI device discovery and CDI spec generation logic. Mock sysfs entries are needed for comprehensive testing.

3. **Hardware validation:** All modifications are based on sysfs structure analysis and kernel driver documentation. Hardware validation on CN5000 is required.

---

## Next Steps

1. **Hardware Testing:**
   - Deploy on CN5000 node with HFI driver loaded
   - Verify `/dev/hfi1_0` discovery
   - Test rdmamap compatibility with vendor `1fc1`

2. **Unit Tests:**
   - Add mock sysfs entries for CN5000
   - Test `GetHfiDevices()` with various sysfs layouts
   - Test CDI spec generation with env vars

3. **Integration Testing:**
   - Deploy DaemonSet on test cluster
   - Verify CDI spec file creation in `/var/run/cdi/`
   - Deploy test pod requesting `cornelis.com/hfi: 1`
   - Verify device mounts and env vars inside pod
   - Run `ibv_devinfo` to validate RDMA access

4. **Documentation:**
   - Update README with build instructions
   - Add troubleshooting guide for common issues
   - Document ConfigMap customization options

---

## Compatibility Matrix

| Upstream Version | Cornelis Fork Version | Status |
|-----------------|----------------------|--------|
| v1.5.3 | v1.0.0-alpha | Active development |

---

## License

All modifications maintain the original Apache 2.0 license from the upstream project. See `LICENSE` file for details.
