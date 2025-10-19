#!/bin/bash
set -euo pipefail

GAPBS_DIR="/mnt/sda4/gapbs"
GAPBS_GRAPH_DIR="${GAPBS_DIR}/benchmark/graphs"

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

echo "[4/5] Preparing graphs ..."
mkdir -p "${GAPBS_GRAPH_DIR}"

# we need twitter.sg, road.sg, web.sg, urand.sg, kron.sg
make -j"$(nproc)" \
  benchmark/graphs/web.sg \
  benchmark/graphs/road.sg \
  benchmark/graphs/kron.sg \
  benchmark/graphs/urand.sg \
  benchmark/graphs/twitter.sg

popd >/dev/null

echo "[5/5] Environment variables expected by run.sh:"
echo "  export GAPBS_DIR=\"${GAPBS_DIR}\""
echo "  export GAPBS_GRAPH_DIR=\"${GAPBS_GRAPH_DIR}\""
echo "Done. Build artifacts at: ${GAPBS_DIR}"