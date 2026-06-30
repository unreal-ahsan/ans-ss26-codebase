import argparse
import os
import socket
import struct
import sys

# util/ symlink is broken on the Windows checkout; put lab3/ on the path.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from util.collectives import Collectives, Test
from util.network import get_ip, set_drop_prob, recv, send

# ---- protocol constants (must match switch.p4) ----
SML_PORT = 9999
CHUNK = 8                 # values per packet
TYPE_CONTRIB = 0
TYPE_RESULT = 1

# The switch only reduces SUM/MIN/MAX. AVG is done as SUM here, then divided by
# world on the worker (the switch need not know about AVG).
OP_CODES = {"sum": 0, "min": 1, "max": 2}

# sml header: typ, op, rank, world, tag, idx  then CHUNK signed int32 values
_HDR = struct.Struct("!BBHHII")
_VALS = struct.Struct("!%di" % CHUNK)

# Worker tunables
WINDOW = 8                # max chunks in flight (2*WINDOW must be <= SLOTS)
TIMEOUT = 0.3             # socket timeout -> drives retransmission


def _pack(typ, op, rank, world, tag, idx, vals):
    padded = list(vals) + [0] * (CHUNK - len(vals))
    return _HDR.pack(typ, op, rank, world, tag, idx) + _VALS.pack(*padded)


def _unpack(data):
    typ, op, rank, world, tag, idx = _HDR.unpack(data[:_HDR.size])
    vals = list(_VALS.unpack(data[_HDR.size:_HDR.size + _VALS.size]))
    return typ, op, rank, world, tag, idx, vals


class MyCollectives(Collectives):
    def __init__(self, rank, world):
        self.rank = rank
        self.world = world
        self.tag = 0          # increments per AllReduce so slots reset across calls

        # broadcast address of this host's /24 (avoids needing ARP)
        self.bcast = ".".join(get_ip().split(".")[:3] + ["255"])

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.bind(("", SML_PORT))
        self.sock.settimeout(TIMEOUT)

    def AllReduce(self, input, output, op="sum"):
        assert len(input), "input cannot be empty"
        assert len(input) == len(output), "input and output must have the same size"

        self.tag += 1
        wire = "sum" if op == "avg" else op    # AVG reduces as SUM, divide after
        opc = OP_CODES[wire]
        n = len(input)
        nchunks = (n + CHUNK - 1) // CHUNK
        w = max(1, min(WINDOW, nchunks))

        def send_chunk(i):
            off = i * CHUNK
            vals = input[off:off + CHUNK]
            pkt = _pack(TYPE_CONTRIB, opc, self.rank, self.world, self.tag, i, vals)
            send(self.sock, pkt, (self.bcast, SML_PORT))

        done = [False] * nchunks
        base = 0          # first chunk not yet completed
        nxt = 0           # next chunk to send

        def fill():
            nonlocal nxt
            while nxt < min(base + w, nchunks):
                send_chunk(nxt)
                nxt += 1

        fill()
        while base < nchunks:
            try:
                data, _ = recv(self.sock, 2048)
            except socket.timeout:
                # nothing (or a dropped result) within the window -> retransmit
                for i in range(base, nxt):
                    if not done[i]:
                        send_chunk(i)
                continue

            typ, _op, _r, _wd, tag, idx, vals = _unpack(data)
            if typ != TYPE_RESULT or tag != self.tag:
                continue                      # own broadcast echo / stale result
            if 0 <= idx < nchunks and not done[idx]:
                off = idx * CHUNK
                count = min(CHUNK, len(output) - off)
                output[off:off + count] = vals[:count]
                done[idx] = True
                while base < nchunks and done[base]:
                    base += 1
                fill()

        # AVG: the switch summed; floor-divide by the worker count locally.
        if op == "avg":
            for i in range(len(output)):
                output[i] = output[i] // self.world


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("rank", type=int)
    p.add_argument("world", type=int)
    p.add_argument("--size", type=int, default=66, help="input vector size")
    p.add_argument("--drop-send", type=float, default=0.0)
    p.add_argument("--drop-recv", type=float, default=0.0)
    args = p.parse_args()

    if args.drop_send or args.drop_recv:
        set_drop_prob(send=args.drop_send, recv=args.drop_recv)

    coll = MyCollectives(args.rank, args.world)

    # Runs every input pattern across ALL ops (sum/min/max/avg). Prints PASS/FAIL
    # per (op, pattern) for this rank.
    Test.test_allreduce_all(coll, args.rank, args.world, args.size)
