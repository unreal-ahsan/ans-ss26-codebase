# Lab 3 — A Small Book About the Code

A friendly walk through everything in this lab: the ideas, the tools, and how
each piece of code works. Read it top to bottom once and the rest of the lab will
make sense.

---

## Part 1 — The world we're working in

### What is P4?

Normal switches have fixed behaviour baked in. A **P4** switch is *programmable*:
you write a small program that says, for every packet, "parse these headers, then
do this, then send it out here." We run our P4 programs on **BMv2** (`simple_switch`),
a software switch, inside **Mininet** (a virtual network), wired up by **p4utils**.

### The packet's journey through a P4 switch

Every packet flows through the same 6 stages (this is the `v1model` architecture):

```
        ┌─────────┐   ┌────────────────┐   ┌────────┐   ┌─────────┐   ┌──────────────┐   ┌──────────┐
packet ─► PARSER  ├──►│ VERIFY CHECKSUM ├──►│ INGRESS├──►│ EGRESS  ├──►│ COMPUTE CKSUM├──►│ DEPARSER ├──► out
        └─────────┘   └────────────────┘   └────────┘   └─────────┘   └──────────────┘   └──────────┘
         bytes→         (we leave empty)     the brain   (small fixups)  (fix IP cksum)    headers→bytes
         headers
```

- **Parser** — reads raw bytes into named headers (Ethernet, IPv4, …).
- **Ingress** — the main logic: tables, registers, "where does this go?"
- **Egress** — runs *after* the switch decided the output port (and once per copy
  if the packet was multicast).
- **Checksum compute** — recomputes the IP checksum if we changed the header.
- **Deparser** — writes the (possibly modified) headers back into bytes.

You'll see these six controls at the bottom of every `switch.p4`, wired together by:
```p4
V1Switch(parse(), verify(), ingress(), egress(), compute(), deparse()) main;
```

### Three building blocks you can control from outside

A P4 program exposes three kinds of state that the **controller** (a Python script)
configures at runtime:

1. **Tables** — match a packet field against entries, run an *action*. Example:
   `dmac` matches the destination MAC and forwards to a port.
2. **Registers** — small arrays of memory the dataplane can read and write *per
   packet*. This is how a switch "remembers" things (our aggregation sums live here).
3. **Multicast groups** — a named set of ports; setting `mcast_grp = G` sends a
   copy of the packet to every port in group `G`.

### Two rules of BMv2 that shape all our code

- **Actions cannot contain `if`.** Any branching (min/max, op dispatch) must live
  in the control's `apply { }` block, not inside an `action`.
- **The signed-register bug.** When you read a *signed* register and immediately
  use it in a signed comparison/shift, BMv2 treats it as unsigned. The fix is a
  macro that reinterprets the bits as signed:
  ```p4
  #define SIGNED(bits,var) ((int<bits>)(bit<bits>)var)
  ```

### The controller library (`util/controller.py`)

A helper class `Client` wraps the switch's control API with friendly methods:
`table_add`, `register_read/write/reset`, `add_multicast_group`, plus a ready-made
`setup()` that builds the flood group and the MAC→port table from the topology.
We subclass it in each task to add what's specific to that task.

> **Note on imports:** every task dir is supposed to have a `util` symlink. On a
> Windows checkout that symlink is dead, so each `controller.py`/`client.py`/
> `worker.py` starts with a 3-line `sys.path` shim that puts `lab3/` on the path
> so `from util import ...` works. Harmless and portable.

---

## Part 2 — Task 1: the reference L2 switch (`l2/`)

The starting point. `switch.p4` does plain **L2 forwarding**:

- Parse Ethernet only.
- One table `dmac`: match destination MAC → `forward(port)`. On a miss, the
  default action `flood()` sends the packet to a multicast group (all host ports).
- The egress drops the flooded copy that would loop back out the port it came in
  on (so a broadcast doesn't echo to its sender).

The controller's `setup()` fills `dmac` (one entry per host) and builds the flood
group from the topology. **Every later switch is this switch plus extra features.**

---

## Part 3 — Task 2: the ARP proxy (`arp/`)

**Problem:** the hosts are configured to ignore ARP, so nobody answers "who has
10.0.0.2?" and no one can talk. **Job:** make the *switch* answer ARP on everyone's
behalf.

**Idea:** an ARP request and reply have the same shape — to make a reply you just
swap the sender/target fields and fill in the answer. So the switch rewrites the
request *in place* and bounces it back out the port it came in on. No new packet.

How it works:
- Parser branches on EtherType: `0x0806` → parse the ARP header; otherwise it's a
  normal frame.
- A table `arp_resolve` maps a queried **IP → MAC**. The controller fills it from
  the topology (one entry per host).
- The action `arp_reply(mac)`:
  ```
  swap Ethernet src/dst        (reply goes back to the asker)
  opcode = REPLY
  move the asker into the "target" fields
  put `mac` and the queried IP into the "sender" fields
  egress_spec = ingress_port    (send it straight back)
  ```
- Non-ARP traffic falls through to the same `dmac` L2 forwarding as Task 1.

**Quiz-worthy:** the switch tells ARP from non-ARP by EtherType in the parser, then
branches on the ARP opcode; the reply reuses the request packet.

---

## Part 4 — Task 3: the calculator (`calc/`)

**Idea:** the client sends a tiny custom packet `op, a, b`; the switch computes and
sends the answer back in field `a`. It's a made-up L3 protocol (its own EtherType
right after Ethernet).

### The switch
- Parser: EtherType `0x1234` → parse the `calc` header.
- All the math lives in the `apply` block (remember: no `if` in actions). Two groups:
  - **Arithmetic** (ADD, MIN, MAX, NEG, SHL, SHR) → result goes into `a`.
  - **Memory** ops (MSTORE/MLOAD/MADD/…) → use a single signed register `mem`;
    they return the **old** value of `mem` and then store the new one.
- MIN/MAX/SHR read the register and compare, so they use the `SIGNED()` macro.
- After computing, the switch swaps Ethernet src/dst and sends the packet back out
  the ingress port — same "reflect" trick as the ARP reply.

### The client (`client.py`)
Builds the `Calc` packet with Scapy and sends it. The subtle part is **receiving**
the reply reliably:
- It uses an `AsyncSniffer` and only fires the send **after the sniffer is live**
  (`started_callback`), so a fast reply is never missed.
- It does **not** retry. Memory ops are stateful — sending one twice would change
  `mem` twice and return the wrong "old" value. One request → one reply.

> This exact bug bit us during development: retries on a missed reply re-ran
> stateful ops and produced wrong answers. The fix was "don't retry, and make sure
> the receiver is ready before sending."

---

## Part 5 — Task 4: in-network AllReduce (`coll/`) — the big one

### What is AllReduce?

Every worker has a vector. AllReduce replaces each position with the **sum across
all workers**, and gives everyone the same result. (Used everywhere in distributed
ML to average gradients.)

```
rank0: [1,2,3]                         [6, 9, 12]
rank1: [2,3,4]   --AllReduce(sum)-->   [6, 9, 12]   (same on everyone)
rank2: [3,4,5]                         [6, 9, 12]
```

### Why "streaming"?

A switch has tiny memory and can't buffer whole vectors. So we **stream**: split
the vector into small **chunks** (here 8 values/packet). Workers send chunk `i`,
wait for its summed result, copy it to the output, then move on. The switch keeps
only a handful of chunk-sized **slots**, summing into them as packets arrive.

### The protocol (one UDP packet = one chunk)

UDP payload header `sml`:
```
typ  op  rank  world  tag  idx   + 8 int32 values
```
- `typ` — 0 = contribution (worker→switch), 1 = result (switch→worker)
- `rank` / `world` — who I am / how many workers there are
- `idx` — which chunk
- `tag` — which AllReduce *call* (so call #2's chunk 0 ≠ call #1's chunk 0)

Workers send to the subnet **broadcast** address `10.0.0.255:9999`. Why broadcast?
ARP is disabled, and a broadcast frame needs no ARP lookup — it just reaches the
switch. The switch recognises our packets by UDP port 9999.

### The switch's memory, per slot

`SLOTS = 64` slots, each holding:
- `epoch` = `(tag<<32 | idx)` — *what* is currently in this slot,
- `cnt` — how many distinct workers have contributed,
- `seen` — a bitmap of which ranks contributed,
- 8 running sums.

For a packet: `addr = idx % SLOTS`. Then:

1. **Reuse check.** If the slot's stored `epoch` ≠ this packet's epoch, it's a
   **new round** → reset the slot. This single trick handles both reusing a slot
   later in the stream *and* reusing it on the next AllReduce call (thanks to `tag`).
2. **Dedup.** If this rank's bit is already set in `seen`, it's a duplicate
   (a retransmit) — don't add it again. Otherwise set the bit, `cnt++`, add the
   values into the sums.
3. **Complete?** When `cnt == world`, the slot is done: copy the sums into the
   packet, set `typ = RESULT`, and **multicast** it to all workers. A later
   retransmit of an already-counted rank gets a **unicast** copy of the result.

Each register is read once and written once per packet — that's the "respect the
pipeline" rule (a real switch can't read the same memory twice in one pass).

### The martian fix (a crucial detail)

The switch builds the result by *reusing* a worker's packet, whose source IP is
that worker. If a worker receives a packet that claims to come from *its own IP*,
the Linux kernel silently drops it as a "martian." So before sending a result the
switch rewrites the source to a fake switch identity (`10.0.0.254` / `…:fe`) — and
because the IP header changed, it **recomputes the IP checksum**. (UDP checksum is
just set to 0, which means "unused".)

### The worker (`worker.py`)

A **sliding window** of W chunks in flight over one UDP socket:
- Send the first W chunks. As each result arrives, copy it out and send the next
  chunk (the window slides).
- On a socket **timeout**, retransmit the chunks still unacked. This is the whole
  reliability story: a lost contribution or lost result → timeout → resend → the
  switch either aggregates it or re-sends the stored result.

All socket I/O goes through `util.send/recv`, which can randomly *drop* packets to
simulate loss — that's what `--drop-send/--drop-recv` exercise.

Things it handles: any number of workers (even 1), chunk size > 1, window > 1,
inputs of any size (the last chunk is zero-padded; padding 0 doesn't change a sum),
and many AllReduce calls in a row.

### Double buffering, intuitively

Why 64 slots when the window is 8? A completed result must survive until everyone
has it, in case someone needs a retransmit. Because the switch only releases a
chunk's result once **all** workers contributed it, workers stay roughly in lockstep
(at most a window apart). With enough slots (≥ 2×window), by the time a slot is
reused for a far-future chunk, the old result is guaranteed delivered. So no result
is ever overwritten while still needed — that's "double buffering" without extra
bookkeeping.

---

## Part 6 — The bonuses

All three reuse the AllReduce engine. Each lives in its own directory.

### Bonus 1 — MIN / MAX / AVG (`coll-bonus1/`)

The switch now aggregates by the `op` in the packet. The **first** contributor of a
round *seeds* the slot with its value; later ones apply sum / min / max (min/max use
`SIGNED()`). **AVG is not done by the switch** — the worker reduces with SUM and then
floor-divides by `world`. (That answers the PDF's hint: not every operator needs the
switch.)

### Bonus 3 — ReduceScatter + AllGather (`coll-bonus3/`)

Pure Python on top of AllReduce; the switch is unchanged:
- **ReduceScatter** = AllReduce(sum) over the whole vector, then keep only *your*
  slice of the result.
- **AllGather** = scatter your input into your slice of a zero vector, AllReduce(sum):
  each output slot has exactly one nonzero contributor, so the sum is the concatenation.

### Bonus 2 — Hierarchical AllReduce (`coll-bonus2/`)

More workers need more switches. We use 2 **leaf** (ToR) switches + 1 **spine**:

```
   h1 h2            h3 h4
     \ /              \ /
     s1 ----- s3 ----- s2      s1,s2 = leaf (role 0)   s3 = spine (role 1)
```

The beautiful part: **a leaf's partial result is just a "contribution" to the spine.**
So the same aggregation core runs on both, picked by a controller-set `role` register:

- **Leaf**, on a worker contribution: sum locally (threshold = #local workers). When
  done, turn the packet into a **partial** (`rank` = this leaf's id) and send it
  **up** the uplink.
- **Spine**, on a partial: aggregate (threshold = #leaves). When done, send the
  **final** **down** to the leaves.
- **Leaf**, on a final: fan it out to its workers as a result (with the martian fix).

**Loss recovery needs no caching:** a worker that lost its result retransmits → the
leaf re-sends its partial up → the spine (already done) unicasts the final back down
→ the leaf re-fans it to its workers. The "a retransmit re-triggers the level above"
property holds at *every* tier, so the same mechanism that protected the flat design
protects the hierarchy. The controller auto-detects which switches are leaves (they
have hosts) and which is the spine (it doesn't).

---

## Part 7 — Gotchas we hit (and you should know for the quiz)

| Symptom | Cause | Fix |
|---|---|---|
| `No module named 'util'` | dead symlink on Windows checkout | `sys.path` shim at top of entry files |
| `bad interpreter: /bin/bash^M` | Windows CRLF in `*.sh` | `sed -i 's/\r$//' run_workers.sh` |
| memory calc returns wrong "old" value | client retried a stateful op | don't retry; send after sniffer is live |
| workers never receive results | result's source IP = worker's own IP → kernel drops it (martian) | switch rewrites source to `10.0.0.254` + recompute IP checksum |
| single worker hangs but multi works | reset (`-r`) deleted the multicast group | provision with `-s` before running |
| worker logs look empty mid-run | Python buffers stdout to a file | use `python3 -u` for live output |
| min/max compare wrong in P4 | BMv2 signed-register bug | wrap in `SIGNED(32, x)` |
| can't put `if` in a P4 action | BMv2 restriction | do branching in `apply { }` |

---

## One-paragraph summary

There is **one aggregation idea** powering the whole second half of the lab: a slot
keyed by `(tag, idx)` that resets on reuse, counts distinct contributors with a
bitmap (so retransmits are harmless), sums values, and emits a result when everyone
is in — with lost packets recovered by simple retransmission. AllReduce is that idea
once; the operators bonus changes the per-value op; ReduceScatter/AllGather wrap it
in a few lines of Python; and the hierarchy applies it twice, treating a leaf's
partial as a contribution to the spine. Everything else (ARP proxy, calculator) is
the same "parse, decide in `apply`, rewrite-and-reflect the packet" pattern on a
smaller scale.
