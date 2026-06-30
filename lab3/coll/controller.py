import os
import sys

# util/ symlink is broken on the Windows checkout; put lab3/ on the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from util import controller


class CollController(controller.Client):
    """L2 setup (flood group + dmac) plus a clean wipe of the aggregation state.

    Multicast group 1 (all host ports), which the base sets up for flooding,
    doubles as the "all workers" group the dataplane uses to broadcast results.

    Reset the switch before a run:  sudo python3 controller.py -s
    """

    AGG_REGS = ["epoch", "cnt", "seen",
                "val0", "val1", "val2", "val3", "val4", "val5", "val6", "val7"]

    def setup(self):
        super().setup()          # reset + flood group 1 + dmac (mac -> port)
        self.reset_agg()

    def reset(self):
        super().reset()
        self.reset_agg()

    def reset_agg(self):
        print(f"[{self.sw}] clearing aggregation registers")
        for r in self.AGG_REGS:
            self.register_reset(r)


if __name__ == "__main__":
    c = controller.App(CollController())
