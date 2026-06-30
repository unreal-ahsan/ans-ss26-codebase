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

OP_CODES = {"sum": 0, "min": 1, "max": 2, "avg": 3}

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
        opc = OP_CODES.get(op, 0)
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

    # ---- bonus collectives, built on top of AllReduce ----

    def ReduceScatter(self, input, output):
        """Sum every slot across all ranks (an AllReduce), then keep only this
        rank's contiguous slice of the result."""
        assert len(input), "input cannot be empty"
        assert len(input) == len(output) * self.world, "input size must be N * output size"
        full = [0] * len(input)
        self.AllReduce(input, full, "sum")
        chunk = len(output)
        base = self.rank * chunk
        output[:] = full[base:base + chunk]

    def AllGather(self, input, output):
        """Concatenate every rank's input in rank order. Implemented by scattering
        this rank's input into its slice of a zero vector and AllReduce-summing:
        each output slot has exactly one nonzero contributor (its owner)."""
        assert len(input), "input cannot be empty"
        assert len(output) == len(input) * self.world, "output size must be N * input size"
        insize = len(input)
        scattered = [0] * len(output)
        base = self.rank * insize
        scattered[base:base + insize] = input
        self.AllReduce(scattered, output, "sum")


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

    # ReduceScatter needs input size divisible by world; round down for it.
    rs_size = max(args.world, (args.size // args.world) * args.world)

    print(f"--- ReduceScatter (input size {rs_size}) ---")
    Test.test_reducescatter(coll, args.rank, args.world, rs_size)
    print(f"--- AllGather (input size {args.size}) ---")
    Test.test_allgather(coll, args.rank, args.world, args.size)
