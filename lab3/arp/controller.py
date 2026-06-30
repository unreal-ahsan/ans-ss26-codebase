import os
import sys

# The `util` symlink doesn't survive a Windows git checkout (it becomes a plain
# text file), so make `from util import ...` work by putting lab3/ on the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from util import controller


class MyController(controller.Client):
    """Reference L2 setup + ARP proxy table.

    The base Client already knows how to build the flood group and the static
    dmac MAC/port bindings from the topology. We just add one more table,
    `arp_resolve`, mapping each connected host's IP to its MAC so the dataplane
    can answer ARP requests on their behalf.
    """

    def setup(self):
        super().setup()          # flood group + dmac (mac -> port)
        self.setup_arp()

    def setup_arp(self):
        print(f"[{self.sw}] setting up ARP proxy entries")
        for host in self.topo.get_hosts_connected_to(self.sw):
            ip = self.topo.get_host_ip(host).split("/")[0]
            mac = self.topo.get_host_mac(host)
            self.table_add("arp_resolve", "arp_reply", [ip], [mac])

    def reset(self):
        super().reset()
        self.table_reset("arp_resolve")


if __name__ == "__main__":
    c = controller.App(MyController())
