# Bonus 3 — More collectives (ReduceScatter + AllGather)

Both are built on top of the base AllReduce (`coll/`); the switch is unchanged.

## Run
```bash
sudo python3 network.py <N>
sudo python3 controller.py -s
./run_workers.sh <N>                 # add --drop-send/--drop-recv to inject loss
cat log/worker*.log
```
Each worker prints `ReduceScatter/<pattern> -- PASS` then
`AllGather/<pattern> -- PASS`.

## How they reduce to AllReduce

* **ReduceScatter** — run AllReduce(sum) over the full vector, then each rank
  keeps only its contiguous slice of the result.
* **AllGather** — scatter this rank's input into its slice of an otherwise-zero
  vector, then AllReduce(sum): every output slot has exactly one nonzero
  contributor (its owner), so the sum is the concatenation.

Because both reuse the loss-resilient AllReduce, packet loss is handled for free.
