# ContainerLab Manager

> **A self-hosted web platform for deploying, managing, and scaling isolated network lab environments for students — built on top of [ContainerLab](https://containerlab.dev) and [vrnetlab](https://github.com/hellt/vrnetlab).**

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04-orange)
![ContainerLab](https://img.shields.io/badge/ContainerLab-0.74+-green)
![Python](https://img.shields.io/badge/Python-3.10+-yellow)

---

## What is this?

ContainerLab Manager lets you take **one tested network topology** and instantly multiply it into isolated labs for N students — all on a single server, all accessible via SSH on unique ports.

No more managing 20 separate VMs or IP conflicts. Students just SSH in, configure their routers, and learn.

---

## Features

- 🧙 **Web-based setup wizard** — upload your topology, upload your router `.bin`, set student count, done
- 🗂️ **Topology multiplier** — any ContainerLab `.yml` works; the system adjusts mgmt IPs and ports per student automatically
- 📊 **Admin dashboard** — deploy, destroy, restart, or reset individual or all labs with one click
- 🎓 **Student portal** — students enter their number and get their SSH commands instantly
- 📦 **vrnetlab image builder** — upload a Cisco IOL `.bin` and the server builds the Docker image for you
- 🔒 **Token-based auth** — secure admin login, no session issues
- 📈 **Live server stats** — CPU, RAM, disk usage always visible
- 🔄 **Full reset** — clean slate between sessions without reinstalling anything
- 🗑️ **Clean uninstall** — removes everything the installer created, packages untouched

---

## Architecture

```
Browser
  │
  ├── :8080/          → Admin dashboard  (login required)
  ├── :8080/setup     → First-time setup wizard
  └── :8080/student   → Student SSH lookup (public)
         │
       nginx (port 8080)
         │
       Flask API (port 5000)
         │
       ContainerLab + Docker
         │
       Student labs (isolated network namespaces)
```

---

## Requirements

| Component | Version |
|---|---|
| Ubuntu | 22.04 LTS |
| Docker | 20.10+ |
| ContainerLab | 0.74+ |
| Python | 3.10+ |
| nginx | any |
| RAM | 8 GB minimum, 64 GB+ recommended for 20 students |

---

## Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/yourusername/clab-manager.git
cd clab-manager
```

### 2. Run the installer

```bash
sudo bash install.sh
```

This installs Docker, ContainerLab, Python dependencies, nginx, clones vrnetlab, sets up the systemd service, and opens port 8080.

### 3. Open the setup wizard

```
http://YOUR_SERVER_IP:8080
```

Follow the 6-step wizard:

| Step | What you do |
|---|---|
| 1 | System check — confirms all dependencies |
| 2 | Set your admin password |
| 3 | Upload your base topology `.yml` file |
| 4 | Upload your router `.bin` file → build Docker image |
| 5 | Enter server IP + number of student labs |
| 6 | Done — go to dashboard and deploy |

### 4. Students connect

Direct students to:
```
http://YOUR_SERVER_IP:8080/student
```
They enter their student number and get their SSH commands.

---

## How the topology multiplier works

You upload **one working topology file**. The system reads every node's `mgmt-ipv4` and `ports:` mapping and shifts them per student:

```
Port   = 2200 + (student_number × 10) + node_offset
Mgmt   = 192.168.(99+student).0/24
```

Data-plane IPs stay identical across all students — Linux network namespace isolation ensures there are zero conflicts.

**Supported node types:**
- `cisco_iol` — Cisco IOL routers
- `linux` — Generic Linux PCs / hosts
- `cisco_xrv`, `cisco_xrv9k`, `cisco_nxos` — other Cisco platforms

---

## Port scheme

```
Student 1:  rou-1=2211  rou-2=2212  rou-3=2213  pc-1=2214  pc-2=2215
Student 2:  rou-1=2221  rou-2=2222  rou-3=2223  pc-1=2224  pc-2=2225
...
Student N:  ports = 2200 + (N × 10) + offset
```

SSH access:
```bash
# Router (ask instructor for password)
ssh admin@SERVER_IP -p 2211

# PC (password: student)
ssh student@SERVER_IP -p 2214
```

---

## File Structure

```
clab-manager/
├── install.sh              # One-command installer
├── uninstall.sh            # Reverses install.sh completely
├── reset.sh                # Clean slate — destroys labs, clears files
├── deploy_all.sh           # Used internally by the API for bulk operations
├── api/
│   ├── app.py              # Flask API — all endpoints
│   └── topology_parser.py  # Reads and multiplies any topology file
└── web/
    ├── setup.html          # First-time setup wizard
    ├── dashboard.html      # Admin dashboard
    └── student.html        # Student SSH lookup page
```

After install, everything lives at `/opt/clab-manager/` on the server.

---

## Management scripts

### Reset (clean slate, keep install)
Destroys all labs, deletes generated files, resets config. Setup wizard reappears.
```bash
sudo bash /opt/clab-manager/reset.sh
```
Also available as the **⚠ Full Reset** button in the dashboard header.

### Uninstall (remove everything)
Reverses `install.sh` — removes service, nginx config, and `/opt/clab-manager/`. Does not uninstall Docker, ContainerLab, Python or nginx.
```bash
sudo bash /opt/clab-manager/uninstall.sh
```

### Reinstall
```bash
sudo bash install.sh
```

---

## Useful commands

```bash
# Service management
sudo systemctl status clab-manager
sudo systemctl restart clab-manager
sudo journalctl -u clab-manager -f

# Check running labs
sudo containerlab inspect --all
sudo docker ps

# Check a specific container log
sudo docker logs clab-student-lab-01-rou-1

# Monitor RAM during deployment
watch -n 2 free -h
```

---

## Configuration

After setup, settings are stored in `/opt/clab-manager/config.json`:

```json
{
  "admin_password": "yourpassword",
  "auth_token":     "auto-generated",
  "server_ip":      "10.72.96.15",
  "num_students":   20,
  "base_port":      2200,
  "setup_complete": true,
  "router_image":   "vrnetlab/cisco_iol:17.12.01",
  "build_status":   "success"
}
```

To reset the setup wizard without losing built images:
```bash
sudo python3 -c "
import json
f=open('/opt/clab-manager/config.json','r+')
d=json.load(f); d['setup_complete']=False
f.seek(0); json.dump(d,f,indent=2); f.truncate()
"
sudo systemctl restart clab-manager
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Dashboard won't load | `sudo systemctl status clab-manager && sudo systemctl status nginx` |
| Login fails | Check `admin_password` in `/opt/clab-manager/config.json` |
| Labs show stopped after deploy | `sudo containerlab inspect --all --format json` — check state field |
| Can't SSH into PC from outside | Missing return route in exec — check `ip route add 10.X.0.0/16 via MGMT_GW dev eth0` |
| nginx 502 Bad Gateway | `sudo systemctl restart clab-manager` |
| Port not reachable | `sudo ufw allow 2211:2405/tcp && sudo ufw reload` |
| Image build fails | `tail -f /opt/clab-manager/build.log` |

Full troubleshooting guide: see `TROUBLESHOOTING.md` *(or the .docx version)*

---

## RAM guide

| Students | Estimated RAM | Recommended parallel |
|---|---|---|
| 5  | ~20 GB | 5  |
| 10 | ~40 GB | 5  |
| 20 | ~80 GB | 10 |
| 30 | ~120 GB | 10 |

Each student lab = 3 routers + 2 PCs ≈ 4 GB RAM

---

## Roadmap

- [ ] Multi-vendor support (Juniper, Arista)
- [ ] Per-student startup config injection
- [ ] Lab session timer with auto-destroy
- [ ] Student progress tracking
- [ ] HTTPS / TLS support
- [ ] REST API documentation

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Contributing

Pull requests welcome. For major changes please open an issue first.

1. Fork the repo
2. Create your branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request
