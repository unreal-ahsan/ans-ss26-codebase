import os
import sys

# util/ symlink is broken on the Windows checkout; put lab3/ on the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from p4utils.utils.helper import load_topo

from util.controller import Client

# Roles are auto-detected from the topology: a switch with hosts attached is a
# leaf (ToR); a switch with only switch neighbours is the spine.

AGG_REGS = ["epoch", "cnt", "seen",
            "val0", "val1", "val2", "val3", "val4", "val5", "val6", "val7"]
DOWN_GID = 1   # downstream multicast group (workers on a leaf; ToRs on the spine)


def _reset_agg(c):
    for r in AGG_REGS:
        c.register_reset(r)


def _cfg(c, role, thr, myid, uplink, dmgid):
    c.register_write("cfg_role", 0, role)
    c.register_write("cfg_thr", 0, thr)
    c.register_write("cfg_myid", 0, myid)
    c.register_write("cfg_uplink", 0, uplink)
    c.register_write("cfg_dmgid", 0, dmgid)


def setup(topo_path="log/topology.json"):
    topo = load_topo(topo_path)
    switches = sorted(topo.get_p4switches())
    leaves = [sw for sw in switches if topo.get_hosts_connected_to(sw)]
    spines = [sw for sw in switches if not topo.get_hosts_connected_to(sw)]
    assert len(spines) == 1, f"expected exactly one spine, got {spines}"
    spine = spines[0]

    # --- leaves ---
    for tid, leaf in enumerate(leaves):
        c = Client(leaf)
        _reset_agg(c)
        hosts = topo.get_hosts_connected_to(leaf)
        ports = [topo.node_to_node_port_num(leaf, h) for h in hosts]
        c.add_multicast_group(DOWN_GID, ports)          # fan results to workers
        uplink = topo.node_to_node_port_num(leaf, spine)
        _cfg(c, role=0, thr=len(hosts), myid=tid, uplink=uplink, dmgid=DOWN_GID)
        print(f"[{leaf}] LEAF id={tid} workers={hosts} ports={ports} uplink={uplink}")

    # --- spine ---
    c = Client(spine)
    _reset_agg(c)
    tor_ports = [topo.node_to_node_port_num(spine, leaf) for leaf in leaves]
    c.add_multicast_group(DOWN_GID, tor_ports)          # fan finals to ToRs
    _cfg(c, role=1, thr=len(leaves), myid=0, uplink=0, dmgid=DOWN_GID)
    print(f"[{spine}] SPINE tors={leaves} ports={tor_ports} thr={len(leaves)}")


if __name__ == "__main__":
    # Accepts (and ignores) the usual -s/-r flags; this controller only ever sets
    # the hierarchy up.  Run before each batch of workers:  sudo python3 controller.py -s
    setup()
