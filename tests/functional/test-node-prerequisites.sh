#!/bin/bash
#
# Test Case: Node Prerequisites Validation
# Validates that node meets expected state defined in configuration
#
# Usage: ./test-node-prerequisites.sh [CONFIG_FILE]
#
# Arguments:
#   CONFIG_FILE    Path to test configuration file (default: configs/node-prerequisites-minimal.yaml)
#
# Examples:
#   ./test-node-prerequisites.sh
#   ./test-node-prerequisites.sh configs/node-prerequisites-cn5000.yaml
#   ./test-node-prerequisites.sh configs/node-prerequisites-control-plane.yaml
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"

# Default config
CONFIG_FILE="${1:-${SCRIPT_DIR}/configs/node-prerequisites-minimal.yaml}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}ERROR:${NC} jq is required for this test. Install: sudo apt-get install jq"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}ERROR:${NC} Config file not found: ${CONFIG_FILE}"
    exit 1
fi

echo "=== Node Prerequisites Test ==="
echo "Config: ${CONFIG_FILE}"
echo "Hostname: $(hostname)"
echo ""

# Call automation tool
echo "Running node precheck..."

# Find node-precheck.sh (either in repo or copied to same directory)
if [ -f "${REPO_ROOT}/automation/scripts/node-precheck.sh" ]; then
    PRECHECK_SCRIPT="${REPO_ROOT}/automation/scripts/node-precheck.sh"
elif [ -f "${REPO_ROOT}/node-precheck.sh" ]; then
    PRECHECK_SCRIPT="${REPO_ROOT}/node-precheck.sh"
elif [ -f "${SCRIPT_DIR}/../node-precheck.sh" ]; then
    PRECHECK_SCRIPT="${SCRIPT_DIR}/../node-precheck.sh"
else
    echo -e "${RED}ERROR:${NC} node-precheck.sh not found"
    exit 127
fi

RESULT=$("${PRECHECK_SCRIPT}" --config "${CONFIG_FILE}" --json 2>&1)

# Check if result is valid JSON
if ! echo "$RESULT" | jq empty 2>/dev/null; then
    echo -e "${RED}ERROR:${NC} node-precheck.sh did not return valid JSON"
    echo "Output:"
    echo "$RESULT"
    exit 1
fi

# Parse overall status
STATUS=$(echo "$RESULT" | jq -r '.status')
TOTAL=$(echo "$RESULT" | jq -r '.summary.total')
PASSED=$(echo "$RESULT" | jq -r '.summary.passed')
FAILED=$(echo "$RESULT" | jq -r '.summary.failed')
WARNINGS=$(echo "$RESULT" | jq -r '.summary.warnings')

echo "Validating results..."
echo ""

# Detailed field-by-field assertions
ASSERTION_FAILURES=0

# Assert packages
echo -e "${BLUE}[Packages]${NC}"
PACKAGE_COUNT=$(echo "$RESULT" | jq '.checks.packages | length')

if [ "$PACKAGE_COUNT" -gt 0 ]; then
    for pkg in $(echo "$RESULT" | jq -r '.checks.packages | keys[]'); do
        PKG_STATUS=$(echo "$RESULT" | jq -r ".checks.packages.\"${pkg}\".status")
        EXPECTED=$(echo "$RESULT" | jq -r ".checks.packages.\"${pkg}\".expected // \"any\"")
        ACTUAL=$(echo "$RESULT" | jq -r ".checks.packages.\"${pkg}\".actual // \"not installed\"")
        INSTALLED=$(echo "$RESULT" | jq -r ".checks.packages.\"${pkg}\".installed")
        
        if [ "$PKG_STATUS" = "pass" ]; then
            echo -e "  ${GREEN}✓${NC} ${pkg}: ${ACTUAL} (expected: ${EXPECTED})"
        else
            echo -e "  ${RED}✗${NC} ${pkg}: ${ACTUAL} (expected: ${EXPECTED})"
            ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
        fi
    done
else
    echo "  No package checks defined"
fi
echo ""

# Assert system configuration
echo -e "${BLUE}[System Configuration]${NC}"

# Swap
SWAP_STATUS=$(echo "$RESULT" | jq -r '.checks.system.swap.status // "unknown"')
if [ "$SWAP_STATUS" != "unknown" ]; then
    SWAP_EXPECTED=$(echo "$RESULT" | jq -r '.checks.system.swap.expected')
    SWAP_ACTUAL=$(echo "$RESULT" | jq -r '.checks.system.swap.actual')
    
    if [ "$SWAP_STATUS" = "pass" ]; then
        echo -e "  ${GREEN}✓${NC} Swap: ${SWAP_ACTUAL} (expected: ${SWAP_EXPECTED})"
    else
        echo -e "  ${RED}✗${NC} Swap: ${SWAP_ACTUAL} (expected: ${SWAP_EXPECTED})"
        ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
    fi
fi

# Modules
MODULE_COUNT=$(echo "$RESULT" | jq '.checks.system.modules | length // 0')
if [ "$MODULE_COUNT" -gt 0 ]; then
    for module in $(echo "$RESULT" | jq -r '.checks.system.modules | keys[]'); do
        MOD_STATUS=$(echo "$RESULT" | jq -r ".checks.system.modules.\"${module}\".status")
        MOD_EXPECTED=$(echo "$RESULT" | jq -r ".checks.system.modules.\"${module}\".expected")
        MOD_ACTUAL=$(echo "$RESULT" | jq -r ".checks.system.modules.\"${module}\".actual")
        
        if [ "$MOD_STATUS" = "pass" ]; then
            echo -e "  ${GREEN}✓${NC} Module ${module}: ${MOD_ACTUAL} (expected: ${MOD_EXPECTED})"
        else
            echo -e "  ${RED}✗${NC} Module ${module}: ${MOD_ACTUAL} (expected: ${MOD_EXPECTED})"
            ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
        fi
    done
fi

# Sysctl
SYSCTL_COUNT=$(echo "$RESULT" | jq '.checks.system.sysctl | length // 0')
if [ "$SYSCTL_COUNT" -gt 0 ]; then
    for param in $(echo "$RESULT" | jq -r '.checks.system.sysctl | keys[]'); do
        SYSCTL_STATUS=$(echo "$RESULT" | jq -r ".checks.system.sysctl.\"${param}\".status")
        SYSCTL_EXPECTED=$(echo "$RESULT" | jq -r ".checks.system.sysctl.\"${param}\".expected")
        SYSCTL_ACTUAL=$(echo "$RESULT" | jq -r ".checks.system.sysctl.\"${param}\".actual")
        
        if [ "$SYSCTL_STATUS" = "pass" ]; then
            echo -e "  ${GREEN}✓${NC} ${param}: ${SYSCTL_ACTUAL} (expected: ${SYSCTL_EXPECTED})"
        else
            echo -e "  ${RED}✗${NC} ${param}: ${SYSCTL_ACTUAL} (expected: ${SYSCTL_EXPECTED})"
            ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
        fi
    done
fi
echo ""

# Assert platform
PLATFORM_DETECTED=$(echo "$RESULT" | jq -r '.platform.detected // "unknown"')
if [ "$PLATFORM_DETECTED" != "unknown" ] && [ "$PLATFORM_DETECTED" != "null" ]; then
    echo -e "${BLUE}[Platform: ${PLATFORM_DETECTED}]${NC}"
    
    # Hardware
    HW_STATUS=$(echo "$RESULT" | jq -r '.checks.platform.hardware.status // "unknown"')
    if [ "$HW_STATUS" != "unknown" ]; then
        HW_EXPECTED=$(echo "$RESULT" | jq -r '.checks.platform.hardware.expected')
        HW_ACTUAL=$(echo "$RESULT" | jq -r '.checks.platform.hardware.actual')
        
        if [ "$HW_STATUS" = "pass" ]; then
            echo -e "  ${GREEN}✓${NC} Hardware: ${HW_ACTUAL} (expected: ${HW_EXPECTED})"
        else
            echo -e "  ${RED}✗${NC} Hardware: ${HW_ACTUAL} (expected: ${HW_EXPECTED})"
            ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
        fi
    fi
    
    # Drivers
    DRIVER_COUNT=$(echo "$RESULT" | jq '.checks.platform.drivers | length // 0')
    if [ "$DRIVER_COUNT" -gt 0 ]; then
        for driver in $(echo "$RESULT" | jq -r '.checks.platform.drivers | keys[]'); do
            DRV_STATUS=$(echo "$RESULT" | jq -r ".checks.platform.drivers.\"${driver}\".status")
            DRV_EXPECTED=$(echo "$RESULT" | jq -r ".checks.platform.drivers.\"${driver}\".expected")
            DRV_LOADED=$(echo "$RESULT" | jq -r ".checks.platform.drivers.\"${driver}\".loaded")
            DRV_AVAILABLE=$(echo "$RESULT" | jq -r ".checks.platform.drivers.\"${driver}\".available")
            
            if [ "$DRV_STATUS" = "pass" ]; then
                echo -e "  ${GREEN}✓${NC} Driver ${driver}: loaded=${DRV_LOADED}, available=${DRV_AVAILABLE}"
            else
                echo -e "  ${RED}✗${NC} Driver ${driver}: loaded=${DRV_LOADED}, available=${DRV_AVAILABLE} (expected: ${DRV_EXPECTED})"
                ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
            fi
        done
    fi
    echo ""
fi

# Assert services
echo -e "${BLUE}[Services]${NC}"
SERVICE_COUNT=$(echo "$RESULT" | jq '.checks.services | length // 0')

if [ "$SERVICE_COUNT" -gt 0 ]; then
    for service in $(echo "$RESULT" | jq -r '.checks.services | keys[]'); do
        SVC_STATUS=$(echo "$RESULT" | jq -r ".checks.services.\"${service}\".status")
        SVC_ENABLED=$(echo "$RESULT" | jq -r ".checks.services.\"${service}\".enabled")
        SVC_RUNNING=$(echo "$RESULT" | jq -r ".checks.services.\"${service}\".running")
        
        if [ "$SVC_STATUS" = "pass" ]; then
            echo -e "  ${GREEN}✓${NC} ${service}: enabled=${SVC_ENABLED}, running=${SVC_RUNNING}"
        else
            echo -e "  ${RED}✗${NC} ${service}: enabled=${SVC_ENABLED}, running=${SVC_RUNNING}"
            ASSERTION_FAILURES=$((ASSERTION_FAILURES + 1))
        fi
    done
else
    echo "  No service checks defined"
fi
echo ""

# Final assertion
echo "=== Test Results ==="
echo "Total checks: ${TOTAL}"
echo "Passed: ${PASSED}"
echo "Failed: ${FAILED}"
echo "Warnings: ${WARNINGS}"
echo "Assertion failures: ${ASSERTION_FAILURES}"
echo ""

if [ "$STATUS" = "pass" ] && [ "$FAILED" -eq 0 ] && [ "$ASSERTION_FAILURES" -eq 0 ]; then
    echo -e "${GREEN}✓ TEST PASSED${NC}: Node meets all prerequisites"
    echo ""
    echo "Node is ready for Kubernetes cluster"
    exit 0
else
    echo -e "${RED}✗ TEST FAILED${NC}: Node does not meet prerequisites"
    echo ""
    
    if [ "$FAILED" -gt 0 ]; then
        echo "Failed checks: ${FAILED}"
        echo "Review the output above for details"
    fi
    
    if [ "$ASSERTION_FAILURES" -gt 0 ]; then
        echo "Assertion failures: ${ASSERTION_FAILURES}"
        echo "Some checks did not match expected values"
    fi
    
    exit 1
fi
