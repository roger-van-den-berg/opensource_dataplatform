#!/bin/bash
# =============================================================================
# Lakehouse Platform Health Check Script
# =============================================================================
# Usage: bash health_check.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo ""
echo "======================================"
echo " LAKEHOUSE PLATFORM HEALTH CHECK"
echo "======================================"
echo ""

PASS=0
FAIL=0
WARN=0

check_http() {
    local name=$1
    local url=$2
    local timeout=${3:-5}

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout "$timeout" "$url" 2>/dev/null || echo "000")

    if echo "$http_code" | grep -qE "^(200|301|302|303|307|308)$"; then
        echo -e "  ${GREEN}OK${NC}  $name ($url)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}DOWN${NC}  $name ($url) [HTTP $http_code]"
        FAIL=$((FAIL + 1))
    fi
}

check_container() {
    local name=$1
    local container=$2
    local check_cmd=$3

    if nerdctl inspect "$container" &>/dev/null; then
        if eval "$check_cmd" &>/dev/null; then
            echo -e "  ${GREEN}OK${NC}  $name ($container)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}WARN${NC}  $name ($container) - container exists but check failed"
            WARN=$((WARN + 1))
        fi
    else
        echo -e "  ${RED}DOWN${NC}  $name ($container) - container not found"
        FAIL=$((FAIL + 1))
    fi
}

# --- Storage Layer ---
echo "Storage Layer:"
check_http "SeaweedFS Master" "http://localhost:9333"
check_http "SeaweedFS S3 API" "http://localhost:8333"
check_http "SeaweedFS Filer" "http://localhost:8888"
echo ""

# --- Query Engines ---
echo "Query Engines:"
check_http "Databend UI" "http://localhost:28080"
check_http "Trino" "http://localhost:8085"
echo ""

# --- Processing ---
echo "Processing & Catalog:"
check_http "Spark Master UI" "http://localhost:8081"
check_http "Spark History" "http://localhost:18080"
check_http "Nessie Catalog" "http://localhost:19120/api/v1/trees"
echo ""

# --- Data Science ---
echo "Data Science:"
check_http "JupyterLab" "http://localhost:8889"
echo ""

# --- Orchestration & BI ---
echo "Orchestration & BI:"
check_http "Airflow" "http://localhost:8086"
check_http "Superset" "http://localhost:8088"
echo ""

# --- Portal ---
echo "Portal:"
check_http "Homer Dashboard" "http://localhost:8090"
echo ""

# --- Shared Services (non-HTTP) ---
echo "Shared Services:"
check_container "PostgreSQL" "lakehouse-postgres" \
    "nerdctl exec lakehouse-postgres pg_isready -U lakehouse"
check_container "Redis" "lakehouse-redis" \
    "nerdctl exec lakehouse-redis redis-cli ping | grep -q PONG"
echo ""

# --- Summary ---
echo "======================================"
echo -e " Results: ${GREEN}${PASS} OK${NC} | ${RED}${FAIL} DOWN${NC} | ${YELLOW}${WARN} WARN${NC}"
echo "======================================"
echo ""

# --- Memory Info ---
echo "System Resources:"
free -h | head -2
echo ""
echo "Container Resource Usage:"
nerdctl stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | head -20 || echo "  (nerdctl stats not available)"
echo ""

echo "Visit http://localhost:8090 for the Homer Dashboard."
echo ""

# Exit with error if any services are down
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
