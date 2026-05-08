#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  deploy_all.sh — ContainerLab Manager lab deployer
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

LAB_DIR="/opt/clab-manager/labs"
RAM_PER_LAB=4

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

available_ram_gb() { awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo; }
total_ram_gb()     { awk '/MemTotal/     {printf "%d", $2/1024/1024}' /proc/meminfo; }

deploy_all() {
  local students=$1 parallel=$2
  echo -e "${GREEN}🚀 Deploying ${students} labs (${parallel} at a time)...${NC}"
  local pids=()
  for i in $(seq 1 "$students"); do
    lab="${LAB_DIR}/student-lab-$(printf '%02d' $i).yml"
    [[ ! -f "$lab" ]] && echo -e "${YELLOW}  Missing: $lab${NC}" && continue
    echo -e "  ${CYAN}▶ Student ${i}${NC}"
    sudo containerlab deploy -t "$lab" --reconfigure &
    pids+=($!)
    if (( ${#pids[@]} >= parallel )); then
      wait "${pids[0]}"; pids=("${pids[@]:1}")
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  echo "$students" > "${LAB_DIR}/.lab_count"
  echo -e "${GREEN}✅ Done.${NC}"
}

destroy_all() {
  local students=$1
  echo -e "${RED}🗑️  Destroying ${students} labs...${NC}"
  for i in $(seq 1 "$students"); do
    lab="${LAB_DIR}/student-lab-$(printf '%02d' $i).yml"
    [[ -f "$lab" ]] && sudo containerlab destroy -t "$lab" --cleanup || true
  done
  echo -e "${GREEN}✅ Done.${NC}"
}

ACTION="${1:-deploy}"
STUDENTS=""
PARALLEL=""

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --students) STUDENTS="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Read from .lab_count if students not specified
if [[ -z "$STUDENTS" ]]; then
  COUNT_FILE="${LAB_DIR}/.lab_count"
  STUDENTS=$(cat "$COUNT_FILE" 2>/dev/null || echo "20")
fi

if [[ -z "$PARALLEL" ]]; then
  AVAIL=$(available_ram_gb)
  PARALLEL=$(( AVAIL / RAM_PER_LAB ))
  PARALLEL=$(( PARALLEL < 1 ? 1 : PARALLEL > 10 ? 10 : PARALLEL ))
fi

case "$ACTION" in
  deploy)  deploy_all  "$STUDENTS" "$PARALLEL" ;;
  destroy) destroy_all "$STUDENTS" ;;
  *) echo "Usage: $0 [deploy|destroy] [--students N] [--parallel N]" ;;
esac
