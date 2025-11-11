#!/bin/bash
set -euo pipefail

GAPBS_DIR="/mnt/sda4/gapbs"
GAPBS_GRAPH_DIR="${GAPBS_DIR}/benchmark/graphs"

# GAPBS workloads we support (algorithms come from subdirectories in this repo).
WORKLOAD_BASE_GRAPHS=(twitter web road kron urand)
declare -a REQUIRED_GRAPH_FILES=()
for graph_base in "${WORKLOAD_BASE_GRAPHS[@]}"; do
  REQUIRED_GRAPH_FILES+=("${graph_base}.sg" "${graph_base}.wsg" "${graph_base}U.sg")
done

echo "[1/5] Installing deps (build tools, numactl, vmtouch) ..."
sudo apt-get update -y
sudo apt-get install -y build-essential cmake g++ git numactl vmtouch wget unzip

echo "[2/5] Cloning GAPBS ..."
if [[ ! -d "${GAPBS_DIR}" ]]; then
  sudo mkdir -p "${GAPBS_DIR}"
  sudo chown "$USER":"$(id -gn "$USER")" "${GAPBS_DIR}"
  git clone https://github.com/sbeamer/gapbs.git "${GAPBS_DIR}"
else
  echo "GAPBS already exists at ${GAPBS_DIR}"
fi

echo "[3/5] Building GAPBS ..."
pushd "${GAPBS_DIR}" >/dev/null
make -j"$(nproc)"

echo "[4/5] Preparing graphs for all workloads (bc/bfs/cc/pr/sssp/tc x ${WORKLOAD_BASE_GRAPHS[*]}) ..."
mkdir -p "${GAPBS_GRAPH_DIR}"
make -j"$(nproc)" bench-graphs

missing_graphs=()
for graph_file in "${REQUIRED_GRAPH_FILES[@]}"; do
  if [[ ! -e "${GAPBS_GRAPH_DIR}/${graph_file}" ]]; then
    missing_graphs+=("${graph_file}")
  fi
done

if (( ${#missing_graphs[@]} )); then
  echo "Missing graph inputs: ${missing_graphs[*]}"
  echo "Please re-run the script; GAPBS make logs above show what failed."
  exit 1
fi

popd >/dev/null

echo "[5/5] Environment variables expected by run.sh:"
echo "  export GAPBS_DIR=\"${GAPBS_DIR}\""
echo "  export GAPBS_GRAPH_DIR=\"${GAPBS_GRAPH_DIR}\""
echo "Done. Build artifacts at: ${GAPBS_DIR}"
