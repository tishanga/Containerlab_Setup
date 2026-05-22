#!/usr/bin/env python3
"""
ContainerLab Manager — Main API
Handles dashboard, setup wizard, student page, and lab management.
"""

from flask import Flask, jsonify, request, send_from_directory, redirect
from flask_cors import CORS
from functools import wraps
import subprocess, os, json, psutil, threading, time
import yaml

from topology_parser import (
    load_topology, multiply_topology,
    get_topology_summary, mgmt_subnet_for
)

app = Flask(__name__)
CORS(app, supports_credentials=True)

# ── Paths ─────────────────────────────────────────────────────────────────────
BASE_DIR      = "/opt/clab-manager"
WEB_DIR       = f"{BASE_DIR}/web"
LAB_DIR       = f"{BASE_DIR}/labs"
CONFIG_FILE   = f"{BASE_DIR}/config.json"
TOPOLOGY_FILE = f"{BASE_DIR}/topology.yml"
VRNETLAB_DIR  = f"{BASE_DIR}/vrnetlab"
DEPLOY_SCRIPT = f"{BASE_DIR}/deploy_all.sh"

# ── Config helpers ─────────────────────────────────────────────────────────────
def load_config() -> dict:
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except:
        return {}

def save_config(cfg: dict):
    os.makedirs(BASE_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)

def is_setup_complete() -> bool:
    cfg = load_config()
    return cfg.get("setup_complete", False)

def get_auth_token() -> str:
    return load_config().get("auth_token", "")

def get_num_students() -> int:
    try:
        with open(os.path.join(LAB_DIR, ".lab_count")) as f:
            return int(f.read().strip())
    except:
        return load_config().get("num_students", 0)

def get_server_ip() -> str:
    return load_config().get("server_ip", "")

# ── Auth ──────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get("X-Auth-Token")
        if not token or token != get_auth_token():
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

@app.route("/api/login", methods=["POST"])
def login():
    if not is_setup_complete():
        return jsonify({"error": "Setup not complete"}), 400
    data = request.get_json()
    cfg  = load_config()
    if data and data.get("password") == cfg.get("admin_password"):
        return jsonify({"ok": True, "token": cfg["auth_token"]})
    return jsonify({"ok": False, "error": "Invalid password"}), 401

@app.route("/api/check_auth")
def check_auth():
    token = request.headers.get("X-Auth-Token")
    return jsonify({"logged_in": bool(token and token == get_auth_token())})

# ── Page routing ───────────────────────────────────────────────────────────────
@app.route("/")
def index():
    """Student portal — public, no login needed."""
    return send_from_directory(WEB_DIR, "student.html")

@app.route("/admin")
def admin_page():
    """Admin dashboard — login required."""
    if not is_setup_complete():
        return redirect("/setup")
    return send_from_directory(WEB_DIR, "dashboard.html")

@app.route("/setup")
def setup_page():
    """First-time setup wizard."""
    if is_setup_complete():
        return redirect("/admin")
    return send_from_directory(WEB_DIR, "setup.html")

@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(WEB_DIR, filename)

# ── Setup API ──────────────────────────────────────────────────────────────────
@app.route("/api/setup/status")
def setup_status():
    """Check system requirements."""
    checks = {}

    # Docker
    r = subprocess.run("docker info", shell=True, capture_output=True)
    checks["docker"] = r.returncode == 0

    # ContainerLab
    r = subprocess.run("containerlab version", shell=True, capture_output=True)
    checks["containerlab"] = r.returncode == 0

    # RAM
    mem = psutil.virtual_memory()
    checks["ram_gb"]    = round(mem.total / 1024**3, 1)
    checks["ram_avail"] = round(mem.available / 1024**3, 1)

    # vrnetlab
    checks["vrnetlab"] = os.path.isdir(VRNETLAB_DIR)

    # Auto-detect server IP
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        checks["server_ip"] = s.getsockname()[0]
        s.close()
    except:
        checks["server_ip"] = ""

    checks["setup_complete"] = is_setup_complete()
    return jsonify(checks)

@app.route("/api/setup/password", methods=["POST"])
def setup_password():
    data = request.get_json()
    pw   = data.get("password", "").strip()
    if len(pw) < 6:
        return jsonify({"ok": False, "error": "Password must be at least 6 characters"}), 400
    import secrets
    cfg = load_config()
    cfg["admin_password"] = pw
    cfg["auth_token"]     = secrets.token_hex(24)
    save_config(cfg)
    return jsonify({"ok": True})

@app.route("/api/setup/topology", methods=["POST"])
def setup_topology():
    """Upload and parse a topology file."""
    if "file" not in request.files:
        return jsonify({"ok": False, "error": "No file uploaded"}), 400
    f = request.files["file"]
    if not f.filename.endswith(".yml") and not f.filename.endswith(".yaml"):
        return jsonify({"ok": False, "error": "File must be a .yml or .yaml file"}), 400
    os.makedirs(BASE_DIR, exist_ok=True)
    f.save(TOPOLOGY_FILE)
    try:
        topo    = load_topology(TOPOLOGY_FILE)
        summary = get_topology_summary(topo)
        return jsonify({"ok": True, "summary": summary})
    except Exception as e:
        return jsonify({"ok": False, "error": f"Failed to parse topology: {str(e)}"}), 400

@app.route("/api/setup/upload_bin", methods=["POST"])
def upload_bin():
    """Upload a router .bin file."""
    if "file" not in request.files:
        return jsonify({"ok": False, "error": "No file uploaded"}), 400
    f    = request.files["file"]
    name = f.filename
    if not name.endswith(".bin"):
        return jsonify({"ok": False, "error": "File must be a .bin file"}), 400

    # Detect vendor from filename
    vendor = "cisco_iol"
    if "xrv9k" in name.lower():  vendor = "cisco_xrv9k"
    elif "xrv"  in name.lower(): vendor = "cisco_xrv"
    elif "nxos" in name.lower(): vendor = "cisco_nxos"
    elif "iol"  in name.lower(): vendor = "cisco_iol"

    # Save to vrnetlab vendor dir
    vendor_map = {
        "cisco_iol":  "cisco/iol",
        "cisco_xrv":  "cisco/xrv",
        "cisco_xrv9k":"cisco/xrv9k",
        "cisco_nxos": "cisco/nxos",
    }
    subdir  = vendor_map.get(vendor, "cisco/iol")
    dest    = os.path.join(VRNETLAB_DIR, subdir)
    os.makedirs(dest, exist_ok=True)
    f.save(os.path.join(dest, name))

    cfg = load_config()
    cfg["bin_file"]  = name
    cfg["bin_path"]  = os.path.join(dest, name)
    cfg["vendor"]    = vendor
    cfg["build_dir"] = dest
    save_config(cfg)

    return jsonify({"ok": True, "vendor": vendor, "filename": name, "build_dir": dest})

@app.route("/api/setup/build_image", methods=["POST"])
def build_image():
    """Trigger vrnetlab Docker image build in background."""
    cfg      = load_config()
    build_dir = cfg.get("build_dir", "")
    if not build_dir or not os.path.isdir(build_dir):
        return jsonify({"ok": False, "error": "No build directory found. Upload .bin first."}), 400

    def do_build():
        log_file = f"{BASE_DIR}/build.log"
        with open(log_file, "w") as log:
            proc = subprocess.run(
                f"cd {build_dir} && make",
                shell=True, stdout=log, stderr=log
            )
        # Update build status
        cfg2 = load_config()
        cfg2["build_status"] = "success" if proc.returncode == 0 else "failed"
        # Try to detect built image tag
        r = subprocess.run(
            "docker images --format '{{.Repository}}:{{.Tag}}' | grep vrnetlab | head -1",
            shell=True, capture_output=True, text=True
        )
        if r.stdout.strip():
            cfg2["router_image"] = r.stdout.strip()
        save_config(cfg2)

    cfg["build_status"] = "building"
    save_config(cfg)
    threading.Thread(target=do_build, daemon=True).start()
    return jsonify({"ok": True, "message": "Build started in background"})

@app.route("/api/setup/build_status")
def build_status():
    cfg    = load_config()
    status = cfg.get("build_status", "idle")
    log    = ""
    try:
        with open(f"{BASE_DIR}/build.log") as f:
            lines = f.readlines()
            log   = "".join(lines[-30:])  # last 30 lines
    except:
        pass
    return jsonify({
        "status": status,
        "image":  cfg.get("router_image", ""),
        "log":    log
    })

@app.route("/api/setup/configure", methods=["POST"])
def configure():
    """Save server IP, student count, and generate all topology files."""
    data       = request.get_json()
    server_ip  = data.get("server_ip", "").strip()
    num_students = int(data.get("num_students", 20))
    base_port  = int(data.get("base_port", 2200))

    if not server_ip:
        return jsonify({"ok": False, "error": "Server IP is required"}), 400
    if num_students < 1 or num_students > 200:
        return jsonify({"ok": False, "error": "Student count must be 1-200"}), 400

    if not os.path.exists(TOPOLOGY_FILE):
        return jsonify({"ok": False, "error": "No topology file found. Upload topology first."}), 400

    # Load and check router image
    cfg          = load_config()
    router_image = cfg.get("router_image", "")

    # If image detected, patch it into topology
    topo = load_topology(TOPOLOGY_FILE)
    if router_image:
        for node_cfg in topo.get("topology", {}).get("nodes", {}).values():
            kind = node_cfg.get("kind", "")
            if kind in ("cisco_iol","cisco_xrv","cisco_xrv9k","cisco_nxos","generic_vm"):
                node_cfg["image"] = router_image

    # Generate all student labs
    try:
        generated = multiply_topology(topo, num_students, server_ip, LAB_DIR)
    except Exception as e:
        return jsonify({"ok": False, "error": f"Failed to generate labs: {str(e)}"}), 500

    # Save config
    cfg.update({
        "server_ip":    server_ip,
        "num_students": num_students,
        "base_port":    base_port,
        "setup_complete": True,
    })
    save_config(cfg)

    return jsonify({
        "ok":       True,
        "generated":len(generated),
        "message":  f"{len(generated)} lab files generated in {LAB_DIR}/"
    })

@app.route("/api/setup/ram_estimate")
def ram_estimate():
    num = int(request.args.get("students", 20))
    mem = psutil.virtual_memory()
    ram_per_lab = 4  # GB
    needed      = num * ram_per_lab
    available   = round(mem.available / 1024**3, 1)
    total       = round(mem.total    / 1024**3, 1)
    return jsonify({
        "students":  num,
        "needed_gb": needed,
        "avail_gb":  available,
        "total_gb":  total,
        "ok":        needed <= available,
    })

# ── Dashboard API ──────────────────────────────────────────────────────────────
def run_cmd(cmd, background=False):
    if background:
        subprocess.Popen(cmd, shell=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid)
        return "Started in background"
    try:
        result = subprocess.run(cmd, shell=True,
            capture_output=True, text=True, timeout=300)
        return (result.stdout + result.stderr).strip()
    except Exception as e:
        return f"Error: {str(e)}"

def lab_file(student):
    return f"{LAB_DIR}/student-lab-{student:02d}.yml"

def get_running_labs():
    try:
        out  = run_cmd("sudo containerlab inspect --all --format json 2>/dev/null")
        data = json.loads(out)
        running = set()
        for lab_name, containers in data.items():
            if not isinstance(containers, list) or not containers:
                continue
            if all(c.get("state") == "running" for c in containers):
                parts = lab_name.split("-")
                if len(parts) == 3 and parts[2].isdigit():
                    running.add(int(parts[2]))
        return running
    except:
        return set()

@app.route("/api/status")
@login_required
def status():
    n       = get_num_students()
    running = get_running_labs()
    labs    = [{"student": i, "running": i in running} for i in range(1, n + 1)]
    return jsonify({"labs": labs, "total": n})

@app.route("/api/stats")
@login_required
def stats():
    cpu  = psutil.cpu_percent(interval=0.5)
    mem  = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    return jsonify({
        "cpu":        round(cpu, 1),
        "ram_used":   round(mem.used   / 1024**3, 1),
        "ram_total":  round(mem.total  / 1024**3, 1),
        "ram_pct":    round(mem.percent, 1),
        "disk_used":  round(disk.used  / 1024**3, 1),
        "disk_total": round(disk.total / 1024**3, 1),
        "disk_pct":   round(disk.percent, 1),
        "num_students": get_num_students(),
        "server_ip":    get_server_ip(),
    })

@app.route("/api/deploy/<int:student>",  methods=["POST"])
@login_required
def deploy(student):
    f = lab_file(student)
    if not os.path.exists(f):
        return jsonify({"ok": False, "output": f"Lab file not found: {f}"}), 404
    run_cmd(f"sudo containerlab deploy -t {f} --reconfigure", background=True)
    return jsonify({"ok": True, "output": f"Deploying student {student:02d}..."})

@app.route("/api/destroy/<int:student>", methods=["POST"])
@login_required
def destroy(student):
    f = lab_file(student)
    if not os.path.exists(f):
        return jsonify({"ok": False, "output": f"Lab file not found: {f}"}), 404
    run_cmd(f"sudo containerlab destroy -t {f} --cleanup", background=True)
    return jsonify({"ok": True, "output": f"Destroying student {student:02d}..."})

@app.route("/api/restart/<int:student>", methods=["POST"])
@login_required
def restart(student):
    name = f"clab-student-lab-{student:02d}"
    run_cmd(
        f"sudo docker ps --filter name={name} --format '{{{{.Names}}}}' | xargs -r sudo docker restart",
        background=True
    )
    return jsonify({"ok": True, "output": f"Restarting student {student:02d}..."})

@app.route("/api/reset/<int:student>",   methods=["POST"])
@login_required
def reset(student):
    f = lab_file(student)
    if not os.path.exists(f):
        return jsonify({"ok": False, "output": f"Lab file not found: {f}"}), 404
    run_cmd(
        f"sudo containerlab destroy -t {f} --cleanup && "
        f"sudo containerlab deploy  -t {f} --reconfigure",
        background=True
    )
    return jsonify({"ok": True, "output": f"Resetting student {student:02d}..."})

@app.route("/api/deploy/all",  methods=["POST"])
@login_required
def deploy_all():
    n = get_num_students()
    run_cmd(f"bash {DEPLOY_SCRIPT} deploy --students {n} --parallel 10", background=True)
    return jsonify({"ok": True, "output": f"Deploying all {n} labs..."})

@app.route("/api/destroy/all", methods=["POST"])
@login_required
def destroy_all():
    n = get_num_students()
    run_cmd(f"bash {DEPLOY_SCRIPT} destroy --students {n}", background=True)
    return jsonify({"ok": True, "output": f"Destroying all {n} labs..."})

@app.route("/api/restart/all", methods=["POST"])
@login_required
def restart_all():
    run_cmd(
        "sudo docker ps --filter name=clab-student-lab --format '{{.Names}}' | xargs -r sudo docker restart",
        background=True
    )
    return jsonify({"ok": True, "output": "Restarting all containers..."})

@app.route("/api/reset/all",   methods=["POST"])
@login_required
def reset_all():
    n = get_num_students()
    run_cmd(
        f"bash {DEPLOY_SCRIPT} destroy --students {n} && "
        f"bash {DEPLOY_SCRIPT} deploy  --students {n} --parallel 10",
        background=True
    )
    return jsonify({"ok": True, "output": f"Full reset of {n} labs started..."})

# ── Student page API ───────────────────────────────────────────────────────────
@app.route("/api/student/<int:student>")
def student_info(student):
    """Public endpoint — no auth needed. Returns SSH info for one student."""
    n         = get_num_students()
    server_ip = get_server_ip()

    if student < 1 or student > n:
        return jsonify({"error": f"Student {student} not found. Valid range: 1-{n}"}), 404

    topo_file = lab_file(student)
    if not os.path.exists(topo_file):
        return jsonify({"error": "Lab not configured yet"}), 404

    topo  = load_topology(topo_file)
    nodes = topo.get("topology", {}).get("nodes", {})

    entries = []
    for name, cfg in sorted(nodes.items()):
        kind  = cfg.get("kind", "linux")
        ntype = "router" if kind != "linux" else "pc"
        ports = cfg.get("ports", [])
        port  = ports[0].split(":")[0] if ports else "?"
        user  = "student" if ntype == "pc" else "admin"
        entries.append({
            "node":    name,
            "type":    ntype,
            "port":    port,
            "user":    user,
            "command": f"ssh {user}@{server_ip} -p {port}",
            "mgmt_ip": cfg.get("mgmt-ipv4", ""),
        })

    mgmt_subnet = mgmt_subnet_for(student)
    return jsonify({
        "student":     student,
        "server_ip":   server_ip,
        "mgmt_subnet": mgmt_subnet,
        "nodes":       entries,
        "password_pc": "student",
        "password_router": "ask your instructor",
    })

@app.route("/api/student_count")
def student_count():
    return jsonify({"total": get_num_students()})

if __name__ == "__main__":
    os.makedirs(LAB_DIR, exist_ok=True)
    app.run(host="0.0.0.0", port=5000, debug=False)

# ── Full Reset ────────────────────────────────────────────────────────────────
@app.route("/api/reset_all_data", methods=["POST"])
@login_required
def reset_all_data():
    """
    Full clean slate:
    1. Destroy all running student labs
    2. Delete all generated topology files
    3. Delete config.json and uploaded topology
    4. Reset so setup wizard appears on next load
    """
    import threading, glob

    def do_reset():
        n = get_num_students()

        # Step 1 — destroy all labs
        for i in range(1, n + 1):
            f = lab_file(i)
            if os.path.exists(f):
                run_cmd(f"sudo containerlab destroy -t {f} --cleanup 2>/dev/null || true")

        # Fallback — kill any leftover student containers
        run_cmd("sudo docker ps --filter name=clab-student-lab --format '{{.Names}}' | xargs -r sudo docker stop 2>/dev/null || true")
        run_cmd("sudo docker ps -a --filter name=clab-student-lab --format '{{.Names}}' | xargs -r sudo docker rm 2>/dev/null || true")

        # Step 2 — delete generated topology files
        for f in glob.glob(os.path.join(LAB_DIR, "student-lab-*.yml")):
            os.remove(f)
        count_file = os.path.join(LAB_DIR, ".lab_count")
        if os.path.exists(count_file):
            os.remove(count_file)

        # Step 3 — delete config and uploaded topology
        for f in [CONFIG_FILE, TOPOLOGY_FILE, f"{BASE_DIR}/build.log"]:
            if os.path.exists(f):
                os.remove(f)

        print("Full reset complete — setup wizard active")

    threading.Thread(target=do_reset, daemon=True).start()
    return jsonify({"ok": True, "output": "Full reset started. Redirecting to setup wizard..."})
