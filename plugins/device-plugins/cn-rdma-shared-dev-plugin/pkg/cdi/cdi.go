/*----------------------------------------------------

  2023 NVIDIA CORPORATION & AFFILIATES

  Licensed under the Apache License, Version 2.0 (the License);
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an AS IS BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

----------------------------------------------------*/

package cdi

import (
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/container-orchestrated-devices/container-device-interface/pkg/cdi"
	cdiSpecs "github.com/container-orchestrated-devices/container-device-interface/specs-go"

	"github.com/cornelisnetworks/cn-fabric-k8s/plugins/device-plugins/cn-rdma-shared-dev-plugin/pkg/types"
)

// HFISelectEnvKey names libfabric's per-context OPX HFI selection knob. Injecting
// it as a node-global edit pins every pod to one HFI unit and breaks dual-HFI
// nodes where that unit is not ACTIVE; when it is absent OPX performs
// its own ACTIVE/NUMA-aware selection. It is stripped defensively so a stale
// ConfigMap can never reintroduce the global pin.
const HFISelectEnvKey = "FI_OPX_HFI_SELECT"

// FilterGlobalEnv returns envVars with any FI_OPX_HFI_SELECT entry removed. It is
// shared by every node-global injection surface (CDI container edits and the
// legacy device-spec Allocate path) so the defensive rule has a single source of
// truth.
func FilterGlobalEnv(envVars []string) []string {
	filtered := make([]string, 0, len(envVars))
	for _, env := range envVars {

		key := env
		if i := strings.IndexByte(env, '='); i >= 0 {
			key = env[:i]
		}
		if key == HFISelectEnvKey {
			log.Printf("dropping %q from device-plugin env injection; "+
				"FI_OPX_HFI_SELECT must not be set node-globally (OPX auto-selects the "+
				"ACTIVE HFI). Remove it from the device-plugin ConfigMap.", env)
			continue
		}
		filtered = append(filtered, env)
	}
	return filtered
}

// CDI represents CDI API required by Device plugin
type CDI interface {
	CreateCDISpec(resourcePrefix, resourceName, poolName string, devices []types.PciNetDevice, envVars []string) error
	CreateContainerAnnotations(
		devices []types.PciNetDevice, resourcePrefix, resourceKind string) (map[string]string, error)
}

// impl implements CDI interface
type impl struct {
}

// CreateCDISpec creates CDI spec file with specified devices
func (c *impl) CreateCDISpec(
	resourcePrefix, resourceName, poolName string, devices []types.PciNetDevice, envVars []string) error {
	log.Printf("creating CDI spec for \"%s\" resource", resourceName)

	cdiDevices := make([]cdiSpecs.Device, 0)

	// Global container edits; FilterGlobalEnv strips FI_OPX_HFI_SELECT (see HFISelectEnvKey).
	globalEdits := cdiSpecs.ContainerEdits{}
	if globalEnv := FilterGlobalEnv(envVars); len(globalEnv) > 0 {
		globalEdits.Env = globalEnv
	}

	// OPX follows /sys/class/infiniband/hfi1_* symlinks into /sys/devices/...,
	// so the full /sys is required (a narrower bind leaves the targets
	// dangling). rbind preserves nested submounts; ro keeps it read-only.
	globalEdits.Mounts = append(globalEdits.Mounts, &cdiSpecs.Mount{
		HostPath:      "/sys",
		ContainerPath: "/sys",
		Type:          "bind",
		Options:       []string{"rbind", "ro"},
	})

	cdiSpec := cdiSpecs.Spec{
		Version:        cdiSpecs.CurrentVersion,
		Kind:           resourcePrefix + "/" + resourceName,
		Devices:        cdiDevices,
		ContainerEdits: globalEdits,
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

		// Add HFI device nodes (/dev/hfi1_*)
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

	err := cdi.GetRegistry().SpecDB().WriteSpec(&cdiSpec, resourcePrefix+"_"+poolName)
	if err != nil {
		log.Printf("createCDISpec(): can not create CDI json: %q", err)
		return err
	}

	log.Printf("createCDISpec(): listing cache")
	for _, vendor := range cdi.GetRegistry().SpecDB().ListVendors() {
		for _, spec := range cdi.GetRegistry().SpecDB().GetVendorSpecs(vendor) {
			for _, dev := range spec.Devices {
				log.Printf("createCDISpec(): device: %s, %s, %s", vendor, spec.Kind, dev.Name)
			}
		}
	}

	return nil
}

// CreateContainerAnnotations creates container annotations based on CDI spec for a container runtime
func (c *impl) CreateContainerAnnotations(
	devices []types.PciNetDevice, resourceNamePrefix, resourceKind string) (map[string]string, error) {
	if len(devices) == 0 {
		return nil, errors.New("devices list is empty")
	}
	annotations := make(map[string]string, 0)
	annoKey, err := cdi.AnnotationKey(resourceNamePrefix, resourceKind)
	if err != nil {
		log.Printf("can not create container annotation: %q", err)
		return nil, err
	}
	deviceNames := make([]string, len(devices))
	for i, dev := range devices {
		deviceNames[i] = cdi.QualifiedName(resourceNamePrefix, resourceKind, dev.GetPciAddr())
	}
	annoValue, err := cdi.AnnotationValue(deviceNames)
	if err != nil {
		log.Printf("can not create container annotation: %q", err)
		return nil, err
	}
	annotations[annoKey] = annoValue

	log.Printf("created CDI annotations: %v", annotations)

	return annotations, nil
}

// CleanupSpecs removes previously-created CDI specs
func CleanupSpecs(specFilePrefix string) error {
	for _, dir := range cdi.GetRegistry().GetSpecDirectories() {
		specs, err := filepath.Glob(filepath.Join(dir, specFilePrefix+"*"))
		if err != nil {
			return err
		}
		for _, spec := range specs {
			log.Printf("Cleaning up CDI spec file: %s", spec)
			if err := os.Remove(spec); err != nil {
				return err
			}
		}
	}

	return nil
}

func New() CDI {
	return &impl{}
}
