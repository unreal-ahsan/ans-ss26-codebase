# Bonus 1 — More AllReduce operators (MIN / MAX / AVG)

Extends the base AllReduce (`coll/`) with MIN, MAX and AVG on top of SUM.

## Run
```bash
sudo python3 network.py <N>
sudo python3 controller.py -s
./run_workers.sh <N>                 # add --drop-send/--drop-recv to inject loss
cat log/worker*.log
```
Each worker runs every pattern under all four ops and prints
`AllReduce/{sum,min,max,avg}/<pattern> -- PASS`.

## What changed vs coll/

* **Switch** aggregates by the op carried in the packet. The first contributor of
  a round seeds the slot with its value; later ones apply `sum`/`min`/`max`.
  MIN/MAX comparisons use the `SIGNED()` macro (the bmv2 signed-register bug, same
  one as the calculator task).
* **Worker** maps `min→MIN`, `max→MAX`. **AVG is not done by the switch**: it is
  reduced as SUM, then the worker floor-divides each element by `world`
  (answering the PDF's hint — AVG needs no switch support). Padding the last chunk
  with zeros is still safe: every worker pads the same trailing slots identically
  and those slots are discarded from the output.
