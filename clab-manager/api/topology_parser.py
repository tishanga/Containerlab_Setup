#!/usr/bin/env python3
"""
topology_parser.py
Reads any ContainerLab topology YAML and multiplies it N times.
Changes per student: mgmt subnet, SSH ports
Keeps unchanged:     data-plane IPs, links, exec commands (namespace isolated)
"""

import yaml
import ipaddress
import copy
import os

SUPPORTED_KINDS = {
    "cisco_iol": "router",
    "cisco_xrv": "router",
    "cisco_xrv9k": "router",
    "cisco_nxos": "router",
    "linux": "pc",
    "generic_vm": "router",
}

BASE_SSH_PORT = 2200
BASE_MGMT_NET = "192.168.100.0/24"
MGMT_STEP     = 256  # one /24 per student


def load_topology(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def detect_nodes(topo: dict) -> dict:
    """Return {node_name: {kind, image, mgmt_ip_last_octet}}"""
    nodes = {}
    for name, cfg in topo.get("topology", {}).get("nodes", {}).items():
        kind  = cfg.get("kind", "linux")
        ntype = SUPPORTED_KINDS.get(kind, "router")
        mgmt  = cfg.get("mgmt-ipv4", "")
        last  = int(mgmt.split(".")[-1]) if mgmt else None
        nodes[name] = {"kind": kind, "type": ntype, "mgmt_last": last}
    return nodes


def mgmt_subnet_for(student: int) -> str:
    base = ipaddress.IPv4Network(BASE_MGMT_NET, strict=False)
    addr = int(base.network_address) + (student - 1) * MGMT_STEP
    return str(ipaddress.IPv4Address(addr)) + "/24"


def mgmt_ip_for(student: int, last_octet: int) -> str:
    subnet = mgmt_subnet_for(student)
    base   = int(ipaddress.IPv4Network(subnet, strict=False).network_address)
    return str(ipaddress.IPv4Address(base + last_octet))


def mgmt_gw_for(student: int) -> str:
    subnet = mgmt_subnet_for(student)
    base   = int(ipaddress.IPv4Network(subnet, strict=False).network_address)
    return str(ipaddress.IPv4Address(base + 1))


def port_for(student: int, base_port: int, offset: int) -> int:
    return BASE_SSH_PORT + (student * 10) + offset


def build_student_topology(base_topo: dict, student: int, server_ip: str) -> dict:
    """Clone base topology and adjust mgmt IPs + ports for a specific student."""
    topo     = copy.deepcopy(base_topo)
    nodes    = detect_nodes(base_topo)
    mgmt_net = mgmt_subnet_for(student)
    mgmt_gw  = mgmt_gw_for(student)

    # Update lab name
    topo["name"] = f"student-lab-{student:02d}"

    # Update mgmt network
    topo["mgmt"] = {
        "network":     f"mgmt-s{student:02d}",
        "ipv4-subnet": mgmt_net,
    }

    # Build sorted node list for port offset assignment
    node_names  = sorted(topo["topology"]["nodes"].keys())
    port_offset = {name: i + 1 for i, name in enumerate(node_names)}

    for node_name, node_cfg in topo["topology"]["nodes"].items():
        info = nodes[node_name]

        # Update mgmt IP
        if info["mgmt_last"]:
            node_cfg["mgmt-ipv4"] = mgmt_ip_for(student, info["mgmt_last"])

        # Update SSH port mapping
        p = port_for(student, BASE_SSH_PORT, port_offset[node_name])
        node_cfg["ports"] = [f"{p}:22"]

        # For Linux PC nodes — patch the return route in exec commands
        if info["kind"] == "linux" and "exec" in node_cfg:
            new_exec = []
            for cmd in node_cfg["exec"]:
                # Replace any existing return route with correct one for this student
                if "ip route add 10." in cmd and "dev eth0" in cmd:
                    new_exec.append(f"ip route add 10.72.0.0/16 via {mgmt_gw} dev eth0")
                else:
                    new_exec.append(cmd)
            node_cfg["exec"] = new_exec

    return topo


def multiply_topology(base_topo: dict, num_students: int,
                      server_ip: str, output_dir: str) -> list:
    """
    Generate N student topology files from a base topology.
    Returns list of generated file paths.
    """
    os.makedirs(output_dir, exist_ok=True)
    generated = []

    for s in range(1, num_students + 1):
        topo  = build_student_topology(base_topo, s, server_ip)
        fname = os.path.join(output_dir, f"student-lab-{s:02d}.yml")
        with open(fname, "w") as f:
            yaml.dump(topo, f, default_flow_style=False,
                      allow_unicode=True, sort_keys=False)
        generated.append(fname)

    # Save student count
    with open(os.path.join(output_dir, ".lab_count"), "w") as f:
        f.write(str(num_students))

    return generated


def get_topology_summary(topo: dict) -> dict:
    """Return a human-readable summary of a topology for the setup wizard preview."""
    nodes = topo.get("topology", {}).get("nodes", {})
    links = topo.get("topology", {}).get("links", [])

    node_list = []
    for name, cfg in nodes.items():
        kind  = cfg.get("kind", "unknown")
        image = cfg.get("image", "unknown")
        mgmt  = cfg.get("mgmt-ipv4", "N/A")
        ntype = SUPPORTED_KINDS.get(kind, "unknown")
        node_list.append({
            "name":  name,
            "kind":  kind,
            "type":  ntype,
            "image": image,
            "mgmt":  mgmt,
        })

    link_list = []
    for link in links:
        eps = link.get("endpoints", [])
        if len(eps) == 2:
            link_list.append({"a": eps[0], "b": eps[1]})

    return {
        "lab_name":   topo.get("name", "unknown"),
        "node_count": len(nodes),
        "link_count": len(links),
        "nodes":      node_list,
        "links":      link_list,
    }
