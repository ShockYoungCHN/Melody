#!/bin/bash

# Set default concurrency (number of parallel jobs)
# Can be overridden by command line argument: ./gendata.sh [NUM_JOBS]
NUM_JOBS=${1:-$(nproc)}
PBBS_BENCHMARKS_DIR="/mnt/sda4/pbbsbench/benchmarks"

echo "Using concurrency: $NUM_JOBS jobs"

dir_arr=("minSpanningForest/parallelFilterKruskal" "maximalMatching/incrementalMatching" "maximalIndependentSet/incrementalMIS" "spanningForest/ndST" "breadthFirstSearch/backForwardBFS" "integerSort/parallelRadixSort" "comparisonSort/sampleSort" "removeDuplicates/parlayhash" "histogram/parallel" "nearestNeighbors/octTree" "rayCast/kdTree" "convexHull/quickHull" "delaunayTriangulation/incrementalDelaunay" "delaunayRefine/incrementalRefine" "rangeQuery2d/parallelPlaneSweep" "wordCounts/histogram" "invertedIndex/parallel" "suffixArray/parallelRange" "longestRepeatedSubstring/doubling" "comparisonSort/quickSort" "comparisonSort/mergeSort" "comparisonSort/stableSampleSort" "comparisonSort/ips4o" "removeDuplicates/serial_sort" "suffixArray/parallelKS" "spanningForest/incrementalST" "breadthFirstSearch/simpleBFS" "breadthFirstSearch/deterministicBFS" "classify/decisionTree")

# Prepare genData files (serial)
for name in ${dir_arr[@]}; do
  cp $PBBS_BENCHMARKS_DIR/$name/testInputs $PBBS_BENCHMARKS_DIR/$name/genData;
  sed -i 's/runTests.timeAllArgs(bnchmrk, benchmark, checkProgram, dataDir, tests)/runTests.genAllData(tests, dataDir)/' $PBBS_BENCHMARKS_DIR/$name/genData;
done

TOTAL_TASKS=${#dir_arr[@]}
echo "Generating data with $NUM_JOBS parallel jobs ($TOTAL_TASKS total tasks) ..."

# Progress tracking using a temporary file with atomic increments
PROGRESS_FILE=$(mktemp)
LOCK_FILE=$(mktemp)
echo "0" > "$PROGRESS_FILE"

# Function to atomically increment and get progress counter
increment_progress() {
  (
    flock -x 9
    local current=$(cat "$PROGRESS_FILE")
    current=$((current + 1))
    echo "$current" > "$PROGRESS_FILE"
    echo "$current"
  ) 9>"$LOCK_FILE"
}

# Function to run genData in a directory with progress tracking
run_gendata() {
  local dir=$1
  local full_path="$PBBS_BENCHMARKS_DIR/$dir"
  local task_name=$(basename "$dir")
  
  if [ -d "$full_path" ] && [ -f "$full_path/genData" ]; then
    echo "Starting: $task_name" >&2
    cd "$full_path" && ./genData >/dev/null 2>&1
    local ret=$?
    local current=$(increment_progress)
    if [ $ret -eq 0 ]; then
      echo "[$current/$TOTAL_TASKS] ✓ Completed: $task_name" >&2
    else
      echo "[$current/$TOTAL_TASKS] ✗ Failed: $task_name" >&2
    fi
    return $ret
  else
    echo "Warning: $full_path not found or genData missing" >&2
    increment_progress >/dev/null
    return 1
  fi
}

# Export function and variables for parallel execution
export -f run_gendata increment_progress
export PBBS_BENCHMARKS_DIR
export PROGRESS_FILE
export LOCK_FILE
export TOTAL_TASKS

# Use xargs -P for parallel execution with concurrency control (removed -n1 to avoid conflict with -I)
printf '%s\n' "${dir_arr[@]}" | xargs -P${NUM_JOBS} -I{} bash -c 'run_gendata "{}"'

# Wait for all background jobs to complete
wait

# Clean up temporary files
rm -f "$PROGRESS_FILE" "$LOCK_FILE"

echo ""
echo "All data generation tasks completed! ($TOTAL_TASKS/$TOTAL_TASKS)"
