#!/usr/bin/env python3
# Two-level fat-tree-ish topology for hierarchical AllReduce:
#
#     h1 h2          h3 h4
#       \ /            \ /
#       s1 ---- s3 ---- s2      (s1,s2 = leaf/ToR ; s3 = spine)
#
# Minimal setting from the PDF: 2 leaves, 2 workers each, 1 spine.

import os

from p4utils.mininetlib.network_API import NetworkAPI

log = os.path.join(os.path.abspath(os.path.dirname(__file__)), "log")
net = NetworkAPI()

# --- switches (all run the same role-parameterized program) ---
for sw in ("s1", "s2", "s3"):
    net.addP4Switch(sw)
    net.setP4Source(sw, "switch.p4")

# --- workers: h1,h2 -> s1 ; h3,h4 -> s2 ---
leaf_of = {"h1": "s1", "h2": "s1", "h3": "s2", "h4": "s2"}
for i, (h, sw) in enumerate(leaf_of.items(), start=1):
    net.addHost(h)
    net.addLink(h, sw)
    net.setIntfMac(h, sw, f"00:00:00:00:00:{i:02x}")
    net.setIntfIp(h, sw, f"10.0.0.{i}/24")

# --- uplinks: each leaf to the spine ---
net.addLink("s1", "s3")
net.addLink("s2", "s3")

net.setLogLevel("info")
net.disableArpTables()
net.setCompiler(outdir=log)
net.enableLogAll(log_dir=log)
net.setTopologyFile(f"{log}/topology.json")
net.enablePcapDumpAll(pcap_dir=f"{log}/pcap")
net.startNetwork()
net.enableCli()
