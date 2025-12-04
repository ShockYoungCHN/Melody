#!/bin/bash

# Resolve Paths
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SPA_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)

# Load Config
source "$SPA_DIR/config.sh"

# Config
PERF="$SPA_DIR/linux/tools/perf/perf"
GAPBS_DIR="/mnt/sda4/gapbs"
GAPBS_GRAPH_DIR="/mnt/sda4/gapbs/benchmark/graphs"
CMD="${GAPBS_DIR}/bc -f ${GAPBS_GRAPH_DIR}/urand.sg -i4 -n1"
EVENTS="instructions,cycles,CYCLE_ACTIVITY.STALLS_L3_MISS,OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD,OFFCORE_REQUESTS.DEMAND_DATA_RD,OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD,EXE_ACTIVITY.2_PORTS_UTIL"
MODIFY_UNCORE_FREQ="$SPA_DIR/modify-uncore-freq.sh"

# Output dir
mkdir -p results_ts

echo "Preparing System (check_cxl_conf)..."
check_cxl_conf

echo "Preparing Graph..."
VMTOUCH="/usr/bin/vmtouch"
GRAPH_FILE="${GAPBS_GRAPH_DIR}/urand.sg"

# Function to load graph
load_graph() {
    local node=$1
    if [ -x "$VMTOUCH" ] && [ -f "$GRAPH_FILE" ]; then
        echo "Loading graph to Node $node..."
        numactl --membind $node -- $VMTOUCH -f -t $GRAPH_FILE -m 64G
    fi
    sleep 5
}

# 1. Local Run (Node 0 Mem 0)
echo "Running Local..."
sudo sync
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
load_graph 0

# Run with perf
# Note: using -x, for easier CSV parsing
sudo numactl --cpunodebind 0 --membind 0 \
    $PERF stat -I 100 -x, -e $EVENTS -o results_ts/local.csv \
    -- $CMD

# 2. Remote Run (Node 0 Mem 1)
# set uncore frequency to 2GHz for node 0 and 500MHz for node 1, now node0 to node1 latency is 190ns
sudo $MODIFY_UNCORE_FREQ 1200000 2000000 1200000 2000000

echo "Running Remote..."
sudo sync
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
load_graph 1

sudo numactl --cpunodebind 0 --membind 1 \
    $PERF stat -I 100 -x, -e $EVENTS -o results_ts/remote.csv \
    -- $CMD

# restore uncore frequency
sudo $MODIFY_UNCORE_FREQ 1200000 2000000 1200000 2000000

echo "Done."
