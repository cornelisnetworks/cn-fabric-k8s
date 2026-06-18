#!/bin/bash
#
# Node Prerequisites Checker
# Config-driven automation tool for validating node state
#
# Usage: ./node-precheck.sh --config <config-file> [--json]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

JSON_OUTPUT=true
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --json) JSON_OUTPUT=true; shift ;;
        --human) JSON_OUTPUT=false; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: --config <file> is required"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi

export JSON_OUTPUT

source "${REPO_ROOT}/automation/scripts/lib/load-versions.sh"
if [ -f "${REPO_ROOT}/automation/scripts/lib/package-manager.sh" ]; then
    source "${REPO_ROOT}/automation/scripts/lib/package-manager.sh" 2>/dev/null
else
    echo "ERROR: package-manager.sh not found" >&2
    exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
    log_error "yq is required. Install: pip install yq"
    exit 1
fi

if [ "${JSON_OUTPUT}" != "true" ]; then
    echo "=== Node Prerequisites Check ==="
    echo "Config: ${CONFIG_FILE}"
    echo "Hostname: $(hostname)"
fi

detect_distro >/dev/null 2>&1
PKG_MGR=$(get_package_manager "${DISTRO_ID}" "${DISTRO_ID_LIKE}")

if [ "${JSON_OUTPUT}" != "true" ]; then
    echo "Distribution: ${DISTRO_NAME}"
    echo ""
fi

TOTAL=0
PASSED=0
FAILED=0

declare -A PKG_RESULTS
declare -A MOD_RESULTS
declare -A SYSCTL_RESULTS
declare -A SVC_RESULTS

if [ "${JSON_OUTPUT}" != "true" ]; then
    echo "[Packages]"
fi

while IFS='|' read -r name required; do
    if [ -n "$name" ]; then
        TOTAL=$((TOTAL + 1))
        if pkg_is_installed "$name"; then
            version=$(pkg_get_version "$name")
            PKG_RESULTS["$name"]="$version|pass"
            PASSED=$((PASSED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_success "${name}: ${version}"
        else
            PKG_RESULTS["$name"]="not installed|fail"
            FAILED=$((FAILED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_fail "${name}: not installed"
        fi
    fi
done < <(yq -r '.packages[]? | "\(.name)|\(.required // true)"' "$CONFIG_FILE")

if [ "${JSON_OUTPUT}" != "true" ]; then
    echo ""
    echo "[System Configuration]"
fi

TOTAL=$((TOTAL + 1))
if swapon --show | grep -q .; then
    FAILED=$((FAILED + 1))
    [ "${JSON_OUTPUT}" != "true" ] && log_fail "Swap: enabled"
else
    PASSED=$((PASSED + 1))
    [ "${JSON_OUTPUT}" != "true" ] && log_success "Swap: disabled"
fi

while IFS= read -r module; do
    if [ -n "$module" ]; then
        TOTAL=$((TOTAL + 1))
        if lsmod | awk '{print $1}' | grep -q "^${module}$"; then
            MOD_RESULTS["$module"]="loaded|pass"
            PASSED=$((PASSED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_success "Module ${module}: loaded"
        else
            MOD_RESULTS["$module"]="not loaded|fail"
            FAILED=$((FAILED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_fail "Module ${module}: not loaded"
        fi
    fi
done < <(yq -r '.system.kernel_modules[]?.name' "$CONFIG_FILE")

while IFS='|' read -r param expected; do
    if [ -n "$param" ]; then
        TOTAL=$((TOTAL + 1))
        actual=$(sysctl -n "$param" 2>/dev/null || echo "0")
        if [ "$actual" = "$expected" ]; then
            SYSCTL_RESULTS["$param"]="$actual|pass"
            PASSED=$((PASSED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_success "${param}: ${actual}"
        else
            SYSCTL_RESULTS["$param"]="$actual|fail"
            FAILED=$((FAILED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_fail "${param}: ${actual} (expected: ${expected})"
        fi
    fi
done < <(yq -r '.system.sysctl[]? | "\(.parameter)|\(.value)"' "$CONFIG_FILE")

if [ "${JSON_OUTPUT}" != "true" ]; then
    echo ""
    echo "[Services]"
fi

while IFS='|' read -r service expected_enabled expected_running; do
    if [ -n "$service" ]; then
        TOTAL=$((TOTAL + 1))
        enabled=$(systemctl is-enabled "$service" 2>/dev/null | head -1 | tr -d '\n' || echo "disabled")
        running=$(systemctl is-active "$service" 2>/dev/null | head -1 | tr -d '\n' || echo "inactive")
        
        enabled_match=false
        running_match=false
        
        # Check enabled state
        if [ "$expected_enabled" = "true" ] && [ "$enabled" = "enabled" ]; then
            enabled_match=true
        elif [ "$expected_enabled" = "false" ] && [ "$enabled" != "enabled" ]; then
            enabled_match=true
        fi
        
        # Check running state
        if [ "$expected_running" = "true" ] && [ "$running" = "active" ]; then
            running_match=true
        elif [ "$expected_running" = "false" ] && [ "$running" != "active" ]; then
            running_match=true
        fi
        
        # Both must match for pass
        if [ "$enabled_match" = "true" ] && [ "$running_match" = "true" ]; then
            SVC_RESULTS["$service"]="$enabled|$running|pass"
            PASSED=$((PASSED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_success "${service}: enabled=${enabled}, running=${running}"
        else
            SVC_RESULTS["$service"]="$enabled|$running|fail"
            FAILED=$((FAILED + 1))
            [ "${JSON_OUTPUT}" != "true" ] && log_fail "${service}: enabled=${enabled}, running=${running} (expected: enabled=${expected_enabled}, running=${expected_running})"
        fi
    fi
done < <(yq -r '.services[]? | "\(.name)|\(.enabled // true)|\(.running // false)"' "$CONFIG_FILE")

if [ "${JSON_OUTPUT}" = "true" ]; then
    echo "{"
    echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"hostname\": \"$(hostname)\","
    echo "  \"status\": \"$([ $FAILED -eq 0 ] && echo 'pass' || echo 'fail')\","
    echo "  \"distribution\": {"
    echo "    \"name\": \"${DISTRO_NAME}\","
    echo "    \"id\": \"${DISTRO_ID}\","
    echo "    \"version\": \"${DISTRO_VERSION}\""
    echo "  },"
    echo "  \"platform\": {"
    echo "    \"detected\": \"auto\""
    echo "  },"
    echo "  \"checks\": {"
    echo "    \"packages\": {"
    first=true
    for pkg in "${!PKG_RESULTS[@]}"; do
        IFS='|' read -r version status <<< "${PKG_RESULTS[$pkg]}"
        [ "$first" = false ] && echo ","
        echo -n "      \"$pkg\": {\"actual\": \"$version\", \"status\": \"$status\", \"expected\": \"any\", \"installed\": $([ "$status" = "pass" ] && echo true || echo false)}"
        first=false
    done
    echo ""
    echo "    },"
    echo "    \"system\": {"
    echo "      \"swap\": {\"actual\": \"disabled\", \"expected\": \"disabled\", \"status\": \"pass\"},"
    echo "      \"modules\": {"
    first=true
    for mod in "${!MOD_RESULTS[@]}"; do
        IFS='|' read -r actual status <<< "${MOD_RESULTS[$mod]}"
        [ "$first" = false ] && echo ","
        echo -n "        \"$mod\": {\"actual\": \"$actual\", \"expected\": \"loaded\", \"status\": \"$status\"}"
        first=false
    done
    echo ""
    echo "      },"
    echo "      \"sysctl\": {"
    first=true
    for param in "${!SYSCTL_RESULTS[@]}"; do
        IFS='|' read -r actual status <<< "${SYSCTL_RESULTS[$param]}"
        [ "$first" = false ] && echo ","
        echo -n "        \"$param\": {\"actual\": $actual, \"expected\": 1, \"status\": \"$status\"}"
        first=false
    done
    echo ""
    echo "      }"
    echo "    },"
    echo "    \"services\": {"
    first=true
    for svc in "${!SVC_RESULTS[@]}"; do
        svc_data="${SVC_RESULTS[$svc]}"
        IFS='|' read -r svc_enabled svc_running svc_status <<< "$svc_data"
        [ "$first" = false ] && echo ","
        echo "      \"$svc\": {"
        echo "        \"enabled\": $([ "$svc_enabled" = "enabled" ] && echo "true" || echo "false"),"
        echo "        \"running\": $([ "$svc_running" = "active" ] && echo "true" || echo "false"),"
        echo "        \"status\": \"${svc_status}\""
        echo -n "      }"
        first=false
    done
    echo ""
    echo "    }"
    echo "  },"
    echo "  \"summary\": {"
    echo "    \"total\": $TOTAL,"
    echo "    \"passed\": $PASSED,"
    echo "    \"failed\": $FAILED,"
    echo "    \"warnings\": 0"
    echo "  }"
    echo "}"
else
    echo ""
    echo "=== Summary ==="
    if [ $FAILED -eq 0 ]; then
        log_success "Status: PASS"
        echo "Checks: ${PASSED} passed, ${FAILED} failed"
        echo ""
        echo "Node is ready for Kubernetes cluster"
    else
        log_fail "Status: FAIL"
        echo "Checks: ${PASSED} passed, ${FAILED} failed"
        echo ""
        echo "Node is NOT ready for Kubernetes cluster"
    fi
fi

exit $([ $FAILED -eq 0 ] && echo 0 || echo 1)
