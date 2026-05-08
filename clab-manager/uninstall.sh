#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  uninstall.sh — ContainerLab Manager Uninstaller
#
#  Reverses everything install.sh did:
#    - Destroys all running student labs
#    - Stops and removes the systemd service
#    - Removes nginx site config
#    - Deletes /opt/clab-manager/
#
#  Does NOT touch:
#    - Docker, ContainerLab, Python, nginx, pip packages, vrnetlab images
#
#  After this runs, the server is back to the state before install.sh was run.
#  To reinstall: sudo bash install.sh
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/clab-manager"
LAB_DIR="${INSTALL_DIR}/labs"
SERVICE_NAME="clab-manager"
NGINX_ENABLED="/etc/nginx/sites-enabled/clab-manager"
NGINX_AVAILABLE="/etc/nginx/sites-available/clab-manager"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

log()    { echo -e "${CYAN}  →${NC} $1"; }
ok()     { echo -e "${GREEN}  ✓${NC} $1"; }
warn()   { echo -e "${YELLOW}  ⚠${NC} $1"; }
skip()   { echo -e "  ${YELLOW}↷${NC} $1 (not found, skipping)"; }

header() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}  Please run as root: sudo bash uninstall.sh${NC}"
  exit 1
fi

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║  ContainerLab Manager Uninstaller    ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  This will remove:"
echo -e "  ${RED}  •${NC} All running student labs (destroyed + cleaned up)"
echo -e "  ${RED}  •${NC} systemd service: ${SERVICE_NAME}"
echo -e "  ${RED}  •${NC} nginx site config for port 8080"
echo -e "  ${RED}  •${NC} All files in ${INSTALL_DIR}/"
echo ""
echo -e "  ${GREEN}  This will NOT remove:${NC}"
echo -e "  ${GREEN}  •${NC} Docker, ContainerLab, Python, nginx, pip packages"
echo -e "  ${GREEN}  •${NC} vrnetlab Docker images already built"
echo ""
read -rp "  Are you sure? [y/N]: " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && echo -e "${YELLOW}  Aborted.${NC}" && exit 0

# ── Step 1: Destroy all running labs ─────────────────────────────────────────
header "Step 1/5 — Destroying running labs"

NUM_STUDENTS=0
COUNT_FILE="${LAB_DIR}/.lab_count"
[[ -f "$COUNT_FILE" ]] && NUM_STUDENTS=$(cat "$COUNT_FILE")

if (( NUM_STUDENTS > 0 )); then
  log "Destroying ${NUM_STUDENTS} student labs..."
  for i in $(seq 1 "$NUM_STUDENTS"); do
    lab="${LAB_DIR}/student-lab-$(printf '%02d' $i).yml"
    if [[ -f "$lab" ]]; then
      containerlab destroy -t "$lab" --cleanup 2>/dev/null || true
    fi
  done
  ok "Labs destroyed"
else
  log "No lab count found — checking for running student containers..."
  RUNNING=$(docker ps --filter name=clab-student-lab --format '{{.Names}}' 2>/dev/null || true)
  if [[ -n "$RUNNING" ]]; then
    echo "$RUNNING" | xargs -r docker stop 2>/dev/null || true
    echo "$RUNNING" | xargs -r docker rm   2>/dev/null || true
    ok "Containers stopped and removed"
  else
    ok "No running student labs found"
  fi
fi

# ── Step 2: Stop and remove systemd service ───────────────────────────────────
header "Step 2/5 — Removing systemd service"

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
  log "Stopping service..."
  systemctl stop "$SERVICE_NAME"
  ok "Service stopped"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
  log "Disabling service..."
  systemctl disable "$SERVICE_NAME"
  ok "Service disabled"
fi

if [[ -f "$SERVICE_FILE" ]]; then
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  ok "Service file removed"
else
  skip "Service file"
fi

# ── Step 3: Remove nginx site config ─────────────────────────────────────────
header "Step 3/5 — Removing nginx config"

if [[ -L "$NGINX_ENABLED" ]] || [[ -f "$NGINX_ENABLED" ]]; then
  rm -f "$NGINX_ENABLED"
  ok "Removed nginx sites-enabled symlink"
else
  skip "nginx sites-enabled symlink"
fi

if [[ -f "$NGINX_AVAILABLE" ]]; then
  rm -f "$NGINX_AVAILABLE"
  ok "Removed nginx sites-available config"
else
  skip "nginx sites-available config"
fi

# Restore default nginx site if it was removed
if [[ ! -f "/etc/nginx/sites-enabled/default" ]] && [[ -f "/etc/nginx/sites-available/default" ]]; then
  ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  log "Restored nginx default site"
fi

if nginx -t 2>/dev/null; then
  systemctl reload nginx
  ok "nginx reloaded"
else
  warn "nginx config test failed — check manually: sudo nginx -t"
fi

# ── Step 4: Delete install directory ─────────────────────────────────────────
header "Step 4/5 — Removing application files"

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  ok "Removed ${INSTALL_DIR}"
else
  skip "${INSTALL_DIR}"
fi

# ── Step 5: Done ──────────────────────────────────────────────────────────────
header "Step 5/5 — Complete"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ Uninstall complete!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  The server is back to its pre-install state."
echo -e "  Docker, ContainerLab, Python and nginx are still installed."
echo ""
echo -e "  To reinstall:"
echo -e "  ${CYAN}  sudo bash install.sh${NC}"
echo ""
