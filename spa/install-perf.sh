#!/bin/bash
set -euo pipefail

LOGF=log
ROOT_DIR="$PWD"
SRC_DIR="linux"

sudo apt-get update -y
sudo apt-get install -y build-essential flex bison pkg-config \
  libelf-dev libdw-dev libnuma-dev zlib1g-dev libunwind-dev

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Sparse cloning Linux sources (perf only) ..."
  git clone --depth=1 --filter=blob:none --sparse https://github.com/torvalds/linux.git "${SRC_DIR}"
  git -C "${SRC_DIR}" sparse-checkout init --cone
  git -C "${SRC_DIR}" sparse-checkout set \
    scripts \
    include \
    tools/perf \
    tools/lib \
    tools/arch \
    tools/include \
    tools/scripts \
    tools/build \
    arch/x86/include \
    arch/x86/tools \
    arch/arm64/include \
    arch/arm64/tools
else
  # Ensure required sparse paths are present even on existing clones
  git -C "${SRC_DIR}" sparse-checkout add \
    scripts include \
    tools/perf tools/lib tools/arch tools/include tools/scripts tools/build \
    arch/x86/include arch/x86/tools arch/arm64/include arch/arm64/tools
fi

echo "Compiling perf ..."
cd "${SRC_DIR}/tools/perf"
KARCH="$(uname -m)"
if [[ "${KARCH}" == "x86_64" ]]; then KARCH="x86"; fi
make -j"$(nproc)" ARCH="${KARCH}" NO_LIBTRACEEVENT=1 NO_JEVENTS=1 NO_SLANG=1 NO_LIBPYTHON=1 > "$LOGF" 2>&1 || { echo "Build failed; showing log:"; tail -n +1 "$LOGF"; exit 1; }
rm -f "$LOGF"
echo "Checking perf ..."
[[ -x perf ]] || exit 1
./perf --version || true
echo "Finished checking"
cd "${ROOT_DIR}"
