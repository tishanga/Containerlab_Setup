#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  ContainerLab Manager — Installer
#  Usage: curl -fsSL https://yoursite.com/install.sh | bash
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/clab-manager"
SERVICE_NAME="clab-manager"
NGINX_CONF="/etc/nginx/sites-available/clab-manager"
PORT=8080

log()  { echo -e "${CYAN}  →${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $1"; }
err()  { echo -e "${RED}  ✗${NC} $1"; exit 1; }
header() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Please run as root: sudo bash install.sh"
fi

# ── Detect server IP ──────────────────────────────────────────────────────────
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║   ContainerLab Manager Installer     ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  Server IP detected: ${CYAN}${SERVER_IP}${NC}"
echo -e "  Install directory : ${CYAN}${INSTALL_DIR}${NC}"
echo -e "  Dashboard port    : ${CYAN}${PORT}${NC}"
echo ""
read -rp "  Continue? [Y/n]: " confirm
[[ "$confirm" =~ ^[Nn]$ ]] && exit 0

# ── Step 1: System packages ───────────────────────────────────────────────────
header "Step 1/6 — Installing system packages"

log "Updating package list..."
apt-get update -qq

log "Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "${SUDO_USER:-$USER}" 2>/dev/null || true
  ok "Docker installed"
else
  ok "Docker already installed"
fi

log "Starting Docker..."
systemctl enable docker --now
ok "Docker running"

log "Installing ContainerLab..."
if ! command -v containerlab &>/dev/null; then
  bash -c "$(curl -sL https://get.containerlab.dev)"
  ok "ContainerLab installed"
else
  ok "ContainerLab already installed"
fi

log "Installing Python3 + pip..."
apt-get install -y -qq python3 python3-pip nginx git curl
ok "System packages installed"

log "Installing Python dependencies..."
pip3 install flask flask-cors psutil pyyaml --break-system-packages -q
ok "Python dependencies installed"

# ── Step 2: Install vrnetlab ──────────────────────────────────────────────────
header "Step 2/6 — Installing vrnetlab"

VRNETLAB_DIR="${INSTALL_DIR}/vrnetlab"
if [[ ! -d "$VRNETLAB_DIR" ]]; then
  log "Cloning vrnetlab..."
  git clone https://github.com/hellt/vrnetlab.git "$VRNETLAB_DIR"
  ok "vrnetlab cloned to ${VRNETLAB_DIR}"
else
  ok "vrnetlab already present"
fi

# ── Step 3: Create install directory ─────────────────────────────────────────
header "Step 3/6 — Setting up application"

mkdir -p "${INSTALL_DIR}/api"
mkdir -p "${INSTALL_DIR}/web"
mkdir -p "${INSTALL_DIR}/labs"

# Copy application files (assumes they're in the same directory as this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Copying application files..."
cp "${SCRIPT_DIR}/api/app.py"              "${INSTALL_DIR}/api/"
cp "${SCRIPT_DIR}/api/topology_parser.py"  "${INSTALL_DIR}/api/"
cp "${SCRIPT_DIR}/web/setup.html"          "${INSTALL_DIR}/web/"
cp "${SCRIPT_DIR}/web/dashboard.html"      "${INSTALL_DIR}/web/"
cp "${SCRIPT_DIR}/web/student.html"        "${INSTALL_DIR}/web/"
cp "${SCRIPT_DIR}/deploy_all.sh"           "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/reset.sh"               "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/uninstall.sh"           "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/deploy_all.sh"
chmod +x "${INSTALL_DIR}/reset.sh"
chmod +x "${INSTALL_DIR}/uninstall.sh"
ok "Application files copied"

# ── Step 4: nginx ─────────────────────────────────────────────────────────────
header "Step 4/6 — Configuring nginx"

cat > "$NGINX_CONF" << NGINX
server {
    listen ${PORT};

    client_max_body_size 2G;

    location /api/ {
        proxy_pass              http://127.0.0.1:5000;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_read_timeout      3600;
        proxy_send_timeout      3600;
    }

    location / {
        proxy_pass              http://127.0.0.1:5000;
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
    }
}
NGINX

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/clab-manager 2>/dev/null || true
# Remove default nginx site to avoid port conflict
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
ok "nginx configured on port ${PORT}"

# ── Step 5: systemd service ───────────────────────────────────────────────────
header "Step 5/6 — Creating system service"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE
[Unit]
Description=ContainerLab Manager API
After=network.target docker.service

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/api
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/api/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable  "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
sleep 2

if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "Service running"
else
  warn "Service may have failed — check: journalctl -u ${SERVICE_NAME} -n 20"
fi

# ── Step 6: Firewall ──────────────────────────────────────────────────────────
header "Step 6/6 — Firewall"

if command -v ufw &>/dev/null; then
  ufw allow "${PORT}/tcp" 2>/dev/null && ok "Port ${PORT} opened in ufw"
else
  warn "ufw not found — make sure port ${PORT} is open in your firewall/security group"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ Installation complete!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Open your browser and go to:"
echo -e "  ${CYAN}${BOLD}http://${SERVER_IP}:${PORT}${NC}"
echo ""
echo -e "  The setup wizard will guide you through:"
echo -e "   1. Setting your admin password"
echo -e "   2. Uploading your topology file"
echo -e "   3. Uploading your router .bin file"
echo -e "   4. Configuring and generating student labs"
echo ""
echo -e "  Student access page:"
echo -e "  ${CYAN}http://${SERVER_IP}:${PORT}/student${NC}"
echo ""
echo -e "  Useful commands:"
echo -e "  ${YELLOW}sudo systemctl status ${SERVICE_NAME}${NC}   — check service"
echo -e "  ${YELLOW}sudo journalctl -u ${SERVICE_NAME} -f${NC}  — view logs"
echo -e "  ${YELLOW}sudo bash ${INSTALL_DIR}/reset.sh${NC}       — full reset (keep install)"
echo -e "  ${YELLOW}sudo bash ${INSTALL_DIR}/uninstall.sh${NC}   — remove everything"
echo ""
