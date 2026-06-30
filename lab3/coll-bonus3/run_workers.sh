#!/bin/bash
# Usage: ./run_workers.sh <N> [extra worker.py args...]
#   e.g. ./run_workers.sh 2 --drop-send 0.1 --drop-recv 0.1

N=${1:-2}
shift || true

for ((i=1; i<=N; i++)); do
    setsid mx h$i python3 worker.py $((i-1)) $N "$@" > "log/worker$i.log" 2>&1 < /dev/null &
done

wait
echo "done"
