import os
import sys

# util/ symlink is broken on the Windows checkout; put lab3/ on the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from util import controller

# The calculator path is handled entirely in the dataplane and needs no
# controller. This only sets up L2 forwarding (flood group + dmac) so that
# non-calc traffic between hosts is forwarded normally. The reference switch's
# dmac/flood layout matches ours, so the base Client works as-is.
#   sudo python3 controller.py -s

if __name__ == "__main__":
    c = controller.App(controller.Client())
