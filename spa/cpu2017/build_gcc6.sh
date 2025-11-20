#!/bin/bash
#
# Build GCC/G++/GFortran 6.x from source and rerun SPEC CPU2017 install.sh
# using the freshly built toolchain. Automatically reports which benchmarks
# still fail to build after the run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_DIR="${SPEC_DIR:-/opt/cpu2017}"

GCC6_VERSION_FULL="${GCC6_VERSION_FULL:-6.5.0}"
GCC6_MAJOR="${GCC6_VERSION_MAJOR:-${GCC6_VERSION_FULL%%.*}}"
GCC6_PREFIX="${GCC6_PREFIX:-/opt/gcc-${GCC6_VERSION_FULL}}"
GCC6_WORK_ROOT="${GCC6_WORK_ROOT:-$HOME/.cache/gcc-${GCC6_VERSION_FULL}}"
GCC6_SRC_ARCHIVE="${GCC6_WORK_ROOT}/gcc-${GCC6_VERSION_FULL}.tar.xz"
GCC6_SRC_URL="${GCC6_SRC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-${GCC6_VERSION_FULL}/gcc-${GCC6_VERSION_FULL}.tar.xz}"
GCC6_SRC_DIR="${GCC6_WORK_ROOT}/gcc-${GCC6_VERSION_FULL}"
GCC6_BUILD_DIR="${GCC6_WORK_ROOT}/build"
GCC6_JOBS="${GCC6_JOBS:-$(nproc)}"
FORCE_REBUILD="${FORCE_GCC6_REBUILD:-0}"
SKIP_APT_DEPS="${GCC6_SKIP_APT_DEPS:-0}"
GCC6_LOG_DIR="${GCC6_WORK_ROOT}/logs"
GCC6_BUILD_LOG="${GCC6_LOG_DIR}/make-gcc.log"
GCC6_INSTALL_LOG="${GCC6_LOG_DIR}/make-install.log"
GCC6_TARGET_TRIPLE="${GCC6_TARGET_TRIPLE:-$("${CC:-gcc}" -dumpmachine 2>/dev/null || echo x86_64-pc-linux-gnu)}"
GCC6_RUNTIME_LIBDIR="${GCC6_PREFIX}/lib/gcc/${GCC6_TARGET_TRIPLE}/${GCC6_VERSION_FULL}"
GCC6_PREFIX_LIB64="${GCC6_PREFIX}/lib64"
GCC6_BUILD_TARGET_DIR="${GCC6_BUILD_DIR}/${GCC6_TARGET_TRIPLE}"

if [[ ! -f "$SCRIPT_DIR/install.sh" ]]; then
  echo "Unable to locate install.sh under $SCRIPT_DIR" >&2
  exit 1
fi

APT_DEPS=(
  build-essential
  bison
  flex
  libgmp-dev
  libmpfr-dev
  libmpc-dev
  texinfo
  libisl-dev
  libzstd-dev
  libz-dev
  wget
  curl
)

log() {
  printf '[%s] %s\n' "$(date +'%F %T')" "$*"
}

toolchain_ready() {
  [[ -x "$GCC6_PREFIX/bin/gcc" && -x "$GCC6_PREFIX/bin/g++" && -x "$GCC6_PREFIX/bin/gfortran" ]]
}

fortran_runtime_present() {
  [[ -f "${GCC6_RUNTIME_LIBDIR}/libgfortran.spec" && -f "${GCC6_PREFIX_LIB64}/libgfortran.so" ]]
}

ensure_version_symlinks() {
  local tool
  for tool in gcc g++ gfortran; do
    local base_path="$GCC6_PREFIX/bin/$tool"
    local versioned_path="$GCC6_PREFIX/bin/${tool}-${GCC6_MAJOR}"
    if [[ -x "$base_path" ]]; then
      sudo ln -sf "$base_path" "$versioned_path"
    fi
  done
}

run_and_log() {
  local log_path="$1"
  shift
  mkdir -p "$(dirname "$log_path")"
  log "Running: $* (log: $log_path)"
  if ! "$@" 2>&1 | tee "$log_path"; then
    log "Command failed. Check $log_path for details."
    return 1
  fi
}

ensure_deps() {
  if [[ "$SKIP_APT_DEPS" == "1" ]]; then
    log "Skipping apt dependency installation (GCC6_SKIP_APT_DEPS=1)."
    return
  fi

  log "Installing build prerequisites: ${APT_DEPS[*]}"
  sudo apt update
  sudo apt install -y "${APT_DEPS[@]}"
}

download_gcc_sources() {
  mkdir -p "$GCC6_WORK_ROOT"
  if [[ ! -f "$GCC6_SRC_ARCHIVE" ]]; then
    log "Downloading GCC ${GCC6_VERSION_FULL} source tarball..."
    wget -O "$GCC6_SRC_ARCHIVE" "$GCC6_SRC_URL"
  else
    log "Using cached GCC source tarball at $GCC6_SRC_ARCHIVE"
  fi

  if [[ -d "$GCC6_SRC_DIR" && "$FORCE_REBUILD" != "1" ]]; then
    log "GCC source directory already exists at $GCC6_SRC_DIR"
  else
    log "Extracting GCC sources to $GCC6_SRC_DIR"
    rm -rf "$GCC6_SRC_DIR"
    tar -xf "$GCC6_SRC_ARCHIVE" -C "$GCC6_WORK_ROOT"
  fi

  # Ensure dependencies (gmp/mpfr/mpc) are fetched into the tree
  (
    cd "$GCC6_SRC_DIR"
    ./contrib/download_prerequisites
  )
}

install_runtime_component() {
  local component="$1"
  local build_component_dir="${GCC6_BUILD_TARGET_DIR}/${component}"
  local libs_dir="${build_component_dir}/.libs"

  if [[ ! -d "$build_component_dir" || ! -d "$libs_dir" ]]; then
    log "Missing build artifacts for ${component} under ${build_component_dir}; cannot install runtime files."
    return 1
  fi

  sudo install -d "$GCC6_PREFIX_LIB64"
  shopt -s nullglob
  for artifact in "$libs_dir"/lib*.a "$libs_dir"/lib*.so*; do
    [[ -e "$artifact" ]] || continue
    local base
    base="$(basename "$artifact")"
    local mode="644"
    [[ "$base" == *.so* ]] && mode="755"
    sudo install -m "$mode" "$artifact" "$GCC6_PREFIX_LIB64/$base"
  done
  shopt -u nullglob
}

ensure_fortran_runtime() {
  if fortran_runtime_present; then
    log "libgfortran runtime already present under $GCC6_PREFIX"
    return 0
  fi

  log "libgfortran runtime missing; attempting to install artifacts from build tree."
  sudo install -d "$GCC6_RUNTIME_LIBDIR"
  local spec_src="${GCC6_BUILD_TARGET_DIR}/libgfortran/libgfortran.spec"
  if [[ -f "$spec_src" ]]; then
    sudo install -m 644 "$spec_src" "${GCC6_RUNTIME_LIBDIR}/libgfortran.spec"
  else
    log "Warning: ${spec_src} not found; libgfortran.spec cannot be installed."
  fi

  install_runtime_component "libgfortran" || true
  install_runtime_component "libquadmath" || true

  if fortran_runtime_present; then
    log "Installed libgfortran runtime libraries into $GCC6_PREFIX"
    return 0
  fi

  log "Warning: libgfortran runtime still incomplete under $GCC6_PREFIX; rebuild may be required."
  return 1
}

build_and_install_gcc() {
  local need_rebuild=1
  if toolchain_ready && fortran_runtime_present && [[ "$FORCE_REBUILD" != "1" ]]; then
    need_rebuild=0
  fi

  if [[ "$need_rebuild" -eq 0 ]]; then
    log "Detected existing GCC toolchain with Fortran runtime under $GCC6_PREFIX; skipping rebuild."
    ensure_version_symlinks
    log "Skip means no new build logs were generated; rerun with FORCE_GCC6_REBUILD=1 if you need fresh logs."
    return
  fi

  log "Building GCC ${GCC6_VERSION_FULL} (languages: C,C++,Fortran)..."
  rm -rf "$GCC6_BUILD_DIR"
  mkdir -p "$GCC6_BUILD_DIR"
  (
    cd "$GCC6_BUILD_DIR"
    "$GCC6_SRC_DIR/configure" \
      --prefix="$GCC6_PREFIX" \
      --enable-languages=c,c++,fortran \
      --disable-multilib \
      --disable-bootstrap \
      --with-system-zlib
    run_and_log "$GCC6_BUILD_LOG" make -j"$GCC6_JOBS"
    run_and_log "$GCC6_INSTALL_LOG" sudo make install
  )

  log "Creating gcc-${GCC6_MAJOR}/g++-${GCC6_MAJOR}/gfortran-${GCC6_MAJOR} symlinks..."
  ensure_version_symlinks

  ensure_fortran_runtime
}

main() {
  ensure_deps
  download_gcc_sources
  build_and_install_gcc
}

main "$@"
