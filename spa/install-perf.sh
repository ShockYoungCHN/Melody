#!/bin/bash
set -euo pipefail

LOGF=log
ROOT_DIR="$PWD"
SRC_DIR="linux"

sudo apt-get update -y
sudo apt-get install -y build-essential flex bison pkg-config \
  libelf-dev libdw-dev libnuma-dev zlib1g-dev libunwind-dev \

sudo apt install -y libtraceevent-dev libdebuginfod-dev libslang2-dev \
  clang libbabeltrace-dev libcapstone-dev libssl-dev

git clone --depth 1 https://github.com/torvalds/linux.git

# compile perf
cd "${SRC_DIR}/tools/perf"
make -j"$(nproc)"
cd "${ROOT_DIR}"
