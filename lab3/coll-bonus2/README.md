# Bonus 2 — Hierarchical AllReduce (2 levels)

```
   h1 h2            h3 h4
     \ /              \ /
     s1 ----- s3 ----- s2       s1,s2 = leaf/ToR (role 0)   s3 = spine (role 1)
```

## Run
```bash
sudo python3 network.py            # 3 switches, 4 workers (2 per leaf)
sudo python3 controller.py -s      # auto-detects roles, configs all switches
sed -i 's/\r$//' run_workers.sh
./run_workers.sh 4                 # add --drop-send/--drop-recv to inject loss
cat log/worker*.log
```
Each worker prints `AllReduce/sum/<pattern> -- PASS` (the workers are identical to
the base task — they don't know the network is hierarchical).

## How it works

One `switch.p4`, two roles chosen by a controller-set `cfg_role` register. The
aggregation core (epoch / count / seen-bitmap / running sums) is identical for
both roles; only the completion action differs.

* **Leaf**, on a worker **contribution** (`typ=0`): aggregate locally (threshold =
  number of local workers). When locally complete, rewrite the packet into a
  **partial** (`typ=2`, `rank` = this ToR's id) and unicast it up the uplink.
* **Spine**, on a **partial** (`typ=2`): aggregate it as if it were a contribution
  whose "rank" is the ToR id (threshold = number of ToRs). When complete, send the
  **final** (`typ=3`) down to all ToRs (multicast; unicast back on a retransmit).
* **Leaf**, on a **final** (`typ=3`): fan it out to local workers as a **result**
  (`typ=1`), rewriting the source to the switch identity (martian fix) so the
  worker's kernel accepts it.

**Loss recovery needs no caching.** A worker that lost its result retransmits its
contribution → the leaf (still locally complete) re-pushes its partial up → the
spine (already globally complete) unicasts the final back down → the leaf re-fans
it to its workers. The "a retransmit re-triggers the level above" property holds at
every tier, so the same mechanism that protects the flat design protects this one.

The controller auto-detects roles from the topology (a switch with hosts is a
leaf; the switch with only switch neighbours is the spine), so it is not hardcoded
to these specific switch names or worker counts.
