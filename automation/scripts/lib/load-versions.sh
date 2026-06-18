#!/bin/bash
#
# Shared version loader for Cornelis node-management scripts.
#
# Resolves authoritative versions from automation/config/package-requirements.yaml
# and exports them so lib/package-manager.sh's required-var guards see real values
# instead of falling back to stale literal defaults.
#
# Usage: source "$SCRIPT_DIR/lib/load-versions.sh"  BEFORE  sourcing package-manager.sh
#
# Required env (with sensible fallbacks):
#   REPO_ROOT   - absolute path to repo root. Falls back to two-up from this file.
#
# Exports on success: K8S_VERSION, GO_VERSION, MULTUS_VERSION, FLANNEL_VERSION,
#                     CNI_PLUGINS_VERSION, WHEREABOUTS_VERSION
#
# Fails fast (exit 1) if: yq missing, YAML missing/unreadable, any value null/empty.
# Callers' own env-var values (if pre-set and non-empty) take precedence; this
# preserves the ad-hoc-override escape hatch.

# Resolve REPO_ROOT from the script's own location if caller didn't set it.
_LV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT="$(cd "${_LV_LIB_DIR}/../../.." && pwd)"
fi

# shellcheck source=automation/scripts/lib/distro-detect.sh
. "${_LV_LIB_DIR}/distro-detect.sh"
unset _LV_LIB_DIR

_LV_PKG_REQ_YAML="${REPO_ROOT}/automation/config/package-requirements.yaml"

if [ ! -f "${_LV_PKG_REQ_YAML}" ]; then
    echo "[ERROR] load-versions.sh: package-requirements.yaml not found at ${_LV_PKG_REQ_YAML}" >&2
    return 1 2>/dev/null || exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "[ERROR] load-versions.sh: yq is required. Install: pip install yq==3.2.3" >&2
    return 1 2>/dev/null || exit 1
fi

# Authoritative YAML lookups; caller env overrides take precedence (legitimate
# ad-hoc-test escape hatch; e.g. `MULTUS_VERSION=vX.Y bash ./stop-node.sh`).
_LV_K8S_CALLER_PRESET="${K8S_VERSION:-}"
K8S_VERSION="${K8S_VERSION:-$(yq -r '.kubernetes.versions.default' "${_LV_PKG_REQ_YAML}")}"

# Per-distribution kubelet override (SLES 16 kubelet 1.28.5 has an unsatisfiable
# `Requires: conntrack`; 1.28.14+ needs conntrack-tools). get_distro_override_key
# comes from distro-detect.sh, which is dependency-free and sourceable here even
# though package-manager.sh has not been sourced yet.
if [ -z "${_LV_K8S_CALLER_PRESET}" ]; then
    _LV_OVERRIDE_KEY="$(get_distro_override_key)"
    if [ -n "${_LV_OVERRIDE_KEY}" ]; then
        _LV_OVERRIDE_VER="$(yq -r ".kubernetes.versions.overrides.${_LV_OVERRIDE_KEY} // \"\"" "${_LV_PKG_REQ_YAML}")"
        if [ -n "${_LV_OVERRIDE_VER}" ] && [ "${_LV_OVERRIDE_VER}" != "null" ] && [ "${_LV_OVERRIDE_VER}" != "${K8S_VERSION}" ]; then
            echo "[INFO] load-versions.sh: K8S_VERSION overridden ${K8S_VERSION} -> ${_LV_OVERRIDE_VER} for ${_LV_OVERRIDE_KEY} (kubelet conntrack-tools dependency on SLES 16)" >&2
            K8S_VERSION="${_LV_OVERRIDE_VER}"
        fi
    fi
    unset _LV_OVERRIDE_KEY _LV_OVERRIDE_VER
fi
unset _LV_K8S_CALLER_PRESET
GO_VERSION="${GO_VERSION:-$(yq -r '.cni_artifacts.go.version' "${_LV_PKG_REQ_YAML}")}"
MULTUS_VERSION="${MULTUS_VERSION:-$(yq -r '.cni_artifacts.multus.version' "${_LV_PKG_REQ_YAML}")}"
FLANNEL_VERSION="${FLANNEL_VERSION:-$(yq -r '.cni_artifacts.flannel.version' "${_LV_PKG_REQ_YAML}")}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-$(yq -r '.cni_artifacts.cni_plugins.version' "${_LV_PKG_REQ_YAML}")}"
WHEREABOUTS_VERSION="${WHEREABOUTS_VERSION:-$(yq -r '.cni_artifacts.whereabouts.version' "${_LV_PKG_REQ_YAML}")}"

for _lv_name in K8S_VERSION GO_VERSION MULTUS_VERSION FLANNEL_VERSION CNI_PLUGINS_VERSION WHEREABOUTS_VERSION; do
    _lv_val="${!_lv_name}"
    if [ -z "${_lv_val}" ] || [ "${_lv_val}" = "null" ]; then
        echo "[ERROR] load-versions.sh: ${_lv_name} could not be resolved from ${_LV_PKG_REQ_YAML}" >&2
        unset _lv_name _lv_val _LV_PKG_REQ_YAML
        return 1 2>/dev/null || exit 1
    fi
done
unset _lv_name _lv_val _LV_PKG_REQ_YAML

# Export BEFORE the caller sources lib/package-manager.sh so its required-var
# guards see real values.
export K8S_VERSION GO_VERSION MULTUS_VERSION FLANNEL_VERSION CNI_PLUGINS_VERSION WHEREABOUTS_VERSION
