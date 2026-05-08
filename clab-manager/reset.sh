#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  reset.sh — ContainerLab Manager Full Reset
#  Destroys all running labs, deletes generated files, resets config.
#  Does NOT uninstall Docker, ContainerLab, Python, nginx or vrnetlab.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/clab-manager"
LAB_DIR="${INSTALL_DIR}/labs"

header() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log()  { echo -e "${CYAN}  →${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Please run as root: sudo bash reset.sh${NC}"
  exit 1
fi

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║   ContainerLab Manager — Full Reset  ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  This will:"
echo -e "  ${RED}  •${NC} Destroy all running student labs"
echo -e "  ${RED}  •${NC} Delete all generated lab topology files"
echo -e "  ${RED}  •${NC} Delete the uploaded topology and config"
echo -e "  ${RED}  •${NC} Reset the setup wizard"
echo ""
echo -e "  ${YELLOW}This will NOT:${NC}"
echo -e "  ${GREEN}  •${NC} Uninstall Docker, ContainerLab, Python, nginx"
echo -e "  ${GREEN}  •${NC} Remove vrnetlab or built Docker images"
echo -e "  ${GREEN}  •${NC} Stop the dashboard service"
echo ""
read -rp "  Are you sure you want to continue? [y/N]: " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && echo -e "${YELLOW}  Aborted.${NC}" && exit 0

# ── Step 1: Destroy all running labs ─────────────────────────────────────────
header "Step 1/4 — Destroying running labs"

# Read student count
COUNT_FILE="${LAB_DIR}/.lab_count"
NUM_STUDENTS=0
if [[ -f "$COUNT_FILE" ]]; then
  NUM_STUDENTS=$(cat "$COUNT_FILE")
  log "Found ${NUM_STUDENTS} student labs to destroy..."
fi

if (( NUM_STUDENTS > 0 )); then
  for i in $(seq 1 "$NUM_STUDENTS"); do
    lab="${LAB_DIR}/student-lab-$(printf '%02d' $i).yml"
    if [[ -f "$lab" ]]; then
      log "Destroying student ${i}..."
      containerlab destroy -t "$lab" --cleanup 2>/dev/null || true
    fi
  done
  ok "All labs destroyed"
else
  # Fallback: destroy any clab-student-lab containers still running
  log "No lab count found — checking for any running student containers..."
  RUNNING=$(docker ps --filter name=clab-student-lab --format '{{.Names}}' 2>/dev/null || true)
  if [[ -n "$RUNNING" ]]; then
    echo "$RUNNING" | xargs -r docker stop 2>/dev/null || true
    echo "$RUNNING" | xargs -r docker rm   2>/dev/null || true
    ok "Stopped and removed running containers"
  else
    ok "No running student labs found"
  fi
fi

# ── Step 2: Delete generated lab files ───────────────────────────────────────
header "Step 2/4 — Deleting generated lab files"

if [[ -d "$LAB_DIR" ]]; then
  COUNT=$(find "$LAB_DIR" -name "student-lab-*.yml" | wc -l)
  if (( COUNT > 0 )); then
    rm -f "${LAB_DIR}"/student-lab-*.yml
    ok "Deleted ${COUNT} topology files"
  else
    ok "No topology files found"
  fi
  rm -f "${LAB_DIR}/.lab_count"
  ok "Cleared lab count"
else
  ok "Labs directory already empty"
fi

# ── Step 3: Delete config and uploaded topology ───────────────────────────────
header "Step 3/4 — Resetting configuration"

if [[ -f "${INSTALL_DIR}/config.json" ]]; then
  rm -f "${INSTALL_DIR}/config.json"
  ok "Deleted config.json"
fi

if [[ -f "${INSTALL_DIR}/topology.yml" ]]; then
  rm -f "${INSTALL_DIR}/topology.yml"
  ok "Deleted uploaded topology.yml"
fi

if [[ -f "${INSTALL_DIR}/build.log" ]]; then
  rm -f "${INSTALL_DIR}/build.log"
  ok "Cleared build.log"
fi

# ── Step 4: Restart API so setup wizard appears ───────────────────────────────
header "Step 4/4 — Restarting dashboard"

systemctl restart clab-manager 2>/dev/null || true
sleep 2

if systemctl is-active --quiet clab-manager; then
  ok "Dashboard restarted"
else
  warn "Dashboard may not have restarted — run: sudo systemctl restart clab-manager"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ Reset complete!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  The setup wizard is now active at:"

# Detect server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "  ${CYAN}http://${SERVER_IP}:8080${NC}"
echo ""
