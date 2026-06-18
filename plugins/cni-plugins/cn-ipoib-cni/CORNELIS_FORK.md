# Cornelis Fork of ipoib-cni

This is a fork of [Mellanox ipoib-cni](https://github.com/Mellanox/ipoib-cni) v1.2.2 with Cornelis-specific fixes for reliable IPoIB child-interface creation on Cornelis fabric nodes.

## Fork Rationale

The upstream CNI plugin creates IPoIB child interfaces over a parent IPoIB device. On Cornelis fabric nodes the fork uses strict netlink type validation for parent pkey/mode extraction and adds explicit mode control, so child-interface creation is deterministic when multiple pods are created concurrently.

## Key Modifications

### 1. Restore Strict IPoIB Type Validation
- **Location**: `pkg/ipoib/ipoib.go`
- **Change**: Use Mellanox's strict netlink type checking (`m.Type() == "ipoib"` and a checked `*netlink.IPoIB` type assertion) for pkey/mode extraction.
- **Reason**: The strict type assertion acts as a synchronization barrier so that concurrent CNI instances do not race to create child interfaces with the same name (`net1`), which would otherwise collide on kernel debugfs entries (`net1_mcg`, `net1_path`).

### 2. Explicit Mode Override
- **Location**: `pkg/ipoib/ipoib.go`
- **Change**: Add support for an explicit IPoIB mode override sourced from the CNI configuration, rather than relying solely on inherited parent state.
- **Note**: The `mode` configuration field is consumed by `pkg/ipoib/ipoib.go`; the upstream `pkg/config/config.go` and `pkg/types/types.go` are unchanged apart from the mechanical Go module-path rename and retain their original upstream copyright headers.

## License

This fork preserves the original Apache 2.0 license from Mellanox. See the LICENSE file.

## Upstream Compatibility

This fork tracks upstream Mellanox/ipoib-cni v1.2.2. Periodic rebases may be performed to incorporate upstream bug fixes and features.
