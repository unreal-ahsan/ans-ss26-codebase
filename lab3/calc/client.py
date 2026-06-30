import os
import sys

# util/ symlink is broken on the Windows checkout; put lab3/ on the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import time

from scapy.all import (AsyncSniffer, ByteField, Ether, Packet, SignedIntField,
                       bind_layers, get_if_hwaddr, sendp)

from util.calculator import Op, Calculator, CalculatorTester
from util.network import get_iface

ETH_TYPE_CALC = 0x1234
SWITCH_MAC = "00:00:00:00:00:fe"   # dummy dst; switch matches on etherType, not MAC


class Calc(Packet):
    name = "Calc"
    fields_desc = [
        ByteField("op", 0),
        SignedIntField("a", 0),
        SignedIntField("b", 0),
    ]


bind_layers(Ether, Calc, type=ETH_TYPE_CALC)


class MyCalculator(Calculator):
    def __init__(self, timeout=3):
        self.iface = get_iface()
        self.smac = get_if_hwaddr(self.iface)
        self.timeout = timeout

    def exec(self, op: Op, a: int = 0, b: int = 0):
        req = (Ether(src=self.smac, dst=SWITCH_MAC, type=ETH_TYPE_CALC)
               / Calc(op=int(op), a=int(a), b=int(b)))

        # Send the request only AFTER the sniffer is live, otherwise a fast
        # reply is missed. We deliberately do NOT retry: memory ops are stateful,
        # so re-sending a request would mutate `mem` twice and return a stale
        # "old" value. One request -> one reply.
        def fire():
            time.sleep(0.05)            # let the capture loop settle
            sendp(req, iface=self.iface, verbose=0)

        sniffer = AsyncSniffer(
            iface=self.iface,
            lfilter=lambda p: Calc in p and p[Ether].dst == self.smac,
            count=1,
            timeout=self.timeout,
            started_callback=fire,
        )
        sniffer.start()
        sniffer.join()
        if sniffer.results:
            return sniffer.results[0][Calc].a
        raise TimeoutError(f"no response from switch for op={Op(int(op))}")


if __name__ == "__main__":
    c = MyCalculator()
    # quick sanity checks during dev:
    #   print(c.sub(10, c.add(5, 2)))   # -> 3
    CalculatorTester().test(c)


# run with: mx h1 python client.py
