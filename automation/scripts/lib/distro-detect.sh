# shellcheck shell=bash
#
# distro-detect.sh - os-release -> distro-key mapping, with ZERO dependencies
# beyond /etc/os-release so it is safe to source before lib/package-manager.sh
# (load-versions.sh needs the mapping before detect_distro/get_package_manager
# exist). Single source of truth for the override-key buckets.

if [ -n "${_CN_DISTRO_DETECT_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
_CN_DISTRO_DETECT_SOURCED=1

# Echoes the kubernetes.versions.overrides.<key> bucket for the running distro,
# or empty string when none applies. Buckets mirror get_package_manager().
get_distro_override_key() {
    local _dd_tags=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        _dd_tags="$(. /etc/os-release 2>/dev/null && echo "${ID:-} ${ID_LIKE:-}")"
    fi

    case "${_dd_tags}" in
        *suse*|*sles*)            echo "suse" ;;
        *rhel*|*centos*|*fedora*) echo "rhel" ;;
        *debian*|*ubuntu*)        echo "debian" ;;
        *)                        echo "" ;;
    esac
}
