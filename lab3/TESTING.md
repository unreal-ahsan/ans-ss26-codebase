# Lab 3 — Testing Guide

How to run and test every part of the lab, with the exact commands and which
terminal to type them in.

---

## 0. Setup (once per session)

On your **host** machine, in **Git Bash** (from the `ans-vm` folder):

```bash
vm start       # boot the VM (wait ~30s the first time)
vm connect     # SSH into the VM   (password: ans)
```

You will need **2 terminals inside the VM** for most tasks:

- **Terminal A** — runs the network (mininet). It stays busy showing the mininet CLI.
- **Terminal B** — runs the controller and the clients/workers.

To get a second VM terminal, open another Git Bash window and run `vm connect`
again. Both land you in the same VM.

All lab code lives in the VM at:

```bash
cd ~/share/ans-ss26-codebase/lab3
```

### Things to remember

- **Always start `network.py` first**, then the controller, then clients.
- If a `*.sh` script says `bad interpreter: /bin/bash^M`, it has Windows line
  endings. Fix once: `sed -i 's/\r$//' run_workers.sh`.
- For **live** worker output use `python3 -u` (otherwise Python buffers the
  prints to a file and you see nothing until it finishes).
- Re-run the controller with `-s` (setup) before each fresh batch of workers — it
  resets the switch state.

---

## Task 1 — L2 switch (reference, 2 pts)

**Terminal A:**
```bash
cd ~/share/ans-ss26-codebase/lab3/l2
sudo python3 network.py
```
**Terminal B:**
```bash
cd ~/share/ans-ss26-codebase/lab3/l2
sudo python3 util/controller.py -s
```
**Terminal A (mininet CLI):**
```text
mininet> pingall
mininet> iperf h1 h2
```
✅ **Expected:** `pingall` → `0% dropped`; `iperf` reports a bandwidth figure.

Stop the network when done: in Terminal A type `exit` (or press Ctrl-D).

---

## Task 2 — ARP proxy (2 pts)

**Terminal A:**
```bash
cd ~/share/ans-ss26-codebase/lab3/arp
sudo python3 network.py
```
**Terminal B:**
```bash
cd ~/share/ans-ss26-codebase/lab3/arp
sudo python3 controller.py -s
```
**Terminal A (mininet CLI):**
```text
mininet> pingall
```
✅ **Expected:** `0% dropped` — the switch answered the ARP requests on behalf of
the hosts (which have ARP disabled), restoring connectivity.

---

## Task 3 — Calculator (3 pts)

**Terminal A:**
```bash
cd ~/share/ans-ss26-codebase/lab3/calc
sudo python3 network.py
```
**Terminal B** (optional — only needed for forwarding non-calc traffic):
```bash
cd ~/share/ans-ss26-codebase/lab3/calc
sudo python3 controller.py -s
```
**Terminal B** (run the tester on host h1):
```bash
mx h1 python3 client.py
```
✅ **Expected:** 14 tests, ending with `14/14 passed` and a Fibonacci sequence
`[1, 1, 2, 3, 5, 8, 13, 21, 34, 55]`.

---

## Task 4 — AllReduce (15 pts)

**Terminal A** (boot with N workers, e.g. 4):
```bash
cd ~/share/ans-ss26-codebase/lab3/coll
sudo python3 network.py 4
```
**Terminal B:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll
sudo python3 controller.py -s        # reset + provision (run before every batch)
sed -i 's/\r$//' run_workers.sh      # once, if needed
./run_workers.sh 4
cat log/worker*.log
```
✅ **Expected:** every worker prints 8 lines `@rank.N AllReduce/sum/<pattern> -- PASS`.

### Test packet-loss resilience
```bash
sudo python3 controller.py -s
./run_workers.sh 4 --drop-send 0.2 --drop-recv 0.2
cat log/worker*.log
```
✅ Still all `PASS`, just slower (drops trigger retransmits).

### Test a single worker (live output)
```bash
sudo python3 controller.py -s
mx h1 python3 -u worker.py 0 1 --size 8
```
✅ Works with `world = 1` too.

### Useful when debugging
```bash
tail -f log/p4s.s1.log     # the switch's per-packet trace
```

---

## Bonus 1 — MIN / MAX / AVG operators (+2)

**Terminal A:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll-bonus1
sudo python3 network.py 4
```
**Terminal B:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll-bonus1
sudo python3 controller.py -s
sed -i 's/\r$//' run_workers.sh
./run_workers.sh 4
cat log/worker*.log
```
✅ **Expected:** per worker, 32 lines: `AllReduce/{sum,min,max,avg}/<pattern> -- PASS`.
Add `--drop-send 0.2 --drop-recv 0.2` to confirm loss-resilience.

---

## Bonus 3 — ReduceScatter + AllGather (+4)

**Terminal A:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll-bonus3
sudo python3 network.py 4
```
**Terminal B:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll-bonus3
sudo python3 controller.py -s
sed -i 's/\r$//' run_workers.sh
./run_workers.sh 4
cat log/worker*.log
```
✅ **Expected:** per worker, `ReduceScatter/<pattern> -- PASS` (×8) then
`AllGather/<pattern> -- PASS` (×8).

---

## Bonus 2 — Hierarchical AllReduce (+4)

This one uses **3 switches** (2 leaves + 1 spine) and 4 workers — the heaviest run.

**Terminal A:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll-bonus2
sudo python3 network.py          # fixed topology: h1,h2->s1  h3,h4->s2  s1,s2->s3
```
**Terminal B:**
```bash
cd ~/share/ans-ss26-codebase/lab3/coll-bonus2
sudo python3 controller.py -s    # prints the detected roles (LEAF/SPINE)
sed -i 's/\r$//' run_workers.sh
./run_workers.sh 4
cat log/worker*.log
```
✅ **Expected:** controller prints `[s1] LEAF ...`, `[s2] LEAF ...`, `[s3] SPINE ...`;
each worker prints 8 `AllReduce/sum/<pattern> -- PASS`.

### Test loss at every hop (for full marks)
```bash
sudo python3 controller.py -s
./run_workers.sh 4 --drop-send 0.2 --drop-recv 0.2
cat log/worker*.log
```
✅ Still all `PASS`.

### Debugging the hierarchy
```bash
tail -f log/p4s.s1.log     # a leaf: contributions in, partial up
tail -f log/p4s.s3.log     # the spine: partials in, final down
```

---

## Cleanup before zipping

Stop any running network (Terminal A → `exit`), then:
```bash
cd ~/share/ans-ss26-codebase/lab3
find . -type d \( -name log -o -name __pycache__ \) -exec rm -rf {} +
find . -name '*.sh' -exec sed -i 's/\r$//' {} +
```
Then zip the `lab3` folder as `Lab3_GroupX.zip` (X = your group number).
