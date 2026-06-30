# Task 4 — In-Network AllReduce (streaming aggregation)

## How to run

```bash
sudo python3 network.py <N>        # boot mininet with N workers (hosts h1..hN)
sudo python3 controller.py -s      # reset + provision the switch (do this first!)
./run_workers.sh <N>               # launch N workers; logs under log/worker*.log

# inject packet loss to exercise the reliability path:
./run_workers.sh <N> --drop-send 0.2 --drop-recv 0.2
```

`controller.py -s` (or `-r`) must be run before each batch of workers to reset the
aggregation registers. Workers may call `AllReduce` many times in a row without a
reset in between (the per-call `tag` keeps slots distinct).

> If `run_workers.sh` reports `bad interpreter`, it has Windows line endings:
> `sed -i 's/\r$//' run_workers.sh`.

## Protocol

L5 over UDP. Workers send chunk-sized packets to the subnet broadcast
`10.0.0.255:9999`; the switch aggregates and returns results. The UDP payload is:

```
typ(1) op(1) rank(2) world(2) tag(4) idx(4)  val0..val7 (8 x int32)
```

* `typ`   — 0 contribution (worker→switch), 1 result (switch→worker)
* `tag`   — per-AllReduce counter (distinguishes call N's chunk i from call N+1's)
* `idx`   — chunk index within the vector
* `world` — number of workers (lets the switch detect completion generically)

## Switch (dataplane)

`SLOTS=64` aggregation slots, each holding `epoch` (= `tag<<32 | idx`),
contributor `cnt`, a `seen` rank-bitmap, and `CHUNK=8` running sums.

* `addr = idx % SLOTS`. If the slot's stored epoch differs, it's a new round →
  reset the slot. This handles both slot reuse along the stream and reuse across
  successive AllReduce calls.
* `seen` makes a retransmitted contribution idempotent (never double-counted).
* On the `world`-th distinct contribution the slot is complete: the sums are
  written into the packet, `typ` is set to RESULT, the source is rewritten to the
  switch's identity (10.0.0.254 / ...:fe — otherwise a worker drops a packet that
  appears to come from its own IP as a martian), the IP checksum is recomputed,
  and the result is **multicast** to all workers.
* A later retransmit of an already-counted rank gets a **unicast** result back
  out its ingress port (loss recovery — the completed slot is retained until the
  slot is reused, i.e. double buffering across `2*WINDOW <= SLOTS`).

Each register is read once and written once per packet, respecting the pipeline.
Non-SML traffic is L2-forwarded (dmac table + flood) as normal.

## Worker

A sliding window of `WINDOW=8` chunks in flight over a single UDP socket. Slide
forward as results arrive; on a socket timeout, retransmit the unacked chunks.
All socket I/O goes through `util.send/recv`, so injected loss is handled. Inputs
of any size work (the last chunk is zero-padded for SUM); `world=1` works too.
