#!/bin/bash

# Script to install CPU SPEC 2017 from ISO and/or build all required benchmarks
# Usage: ./install.sh [path_to_cpu2017_iso]
# Based on official install-guide-unix.txt

set -e

CPU2017_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPA_DIR="$(dirname "$CPU2017_DIR")"

# Compiler/config knobs (override via SPEC_* environment variables if desired)
GCC_VERSION="${SPEC_GCC_VERSION:-6}"
GCC_VERSION_FULL="${SPEC_GCC_VERSION_FULL:-6.5.0}"
GCC_PREFIX="${SPEC_GCC_PREFIX:-/opt/gcc-6.5.0}" 
GCC_PREFIX="${GCC_PREFIX%/}"
GCC_BINDIR="${GCC_PREFIX}/bin"
GCC_CC_BIN="${GCC_BINDIR}/gcc-${GCC_VERSION}"
GCC_CXX_BIN="${GCC_BINDIR}/g++-${GCC_VERSION}"
GCC_FC_BIN="${GCC_BINDIR}/gfortran-${GCC_VERSION}"
GCC_CACHE_ROOT="${SPEC_GCC_CACHE_DIR:-$HOME/.cache/gcc-${GCC_VERSION_FULL}}"

CONFIG_NAME="${SPEC_CONFIG_NAME:-admin-try1}"
CONFIG_LABEL="${SPEC_CONFIG_LABEL:-mytest}"
CONFIG_BITS="${SPEC_CONFIG_BITS:-64}"
CONFIG_FILE_SUFFIX="${CONFIG_LABEL}-m${CONFIG_BITS}"

for compiler in "$GCC_CC_BIN" "$GCC_CXX_BIN" "$GCC_FC_BIN"; do
  if [[ ! -x "$compiler" ]]; then
    echo "Error: expected compiler $compiler not found after installation."
    exit 1
  fi
done

GCC_TARGET_TRIPLE="$("$GCC_CC_BIN" -dumpmachine 2>/dev/null || echo x86_64-pc-linux-gnu)"
GCC_SPEC_DIR="${SPEC_GCC_SPEC_DIR:-$GCC_PREFIX/lib/gcc/$GCC_TARGET_TRIPLE/$GCC_VERSION_FULL}"
GCC_LIB64_DIR="${SPEC_GCC_LIB64_DIR:-$GCC_PREFIX/lib64}"
GCC_FMODULE_DIR="${SPEC_GCC_FMODULE_DIR:-$GCC_PREFIX/lib/gcc/$GCC_TARGET_TRIPLE/$GCC_VERSION_FULL/finclude}"

INSTALL_DIR="/opt/cpu2017"
MOUNT_POINT="/tmp/cpu2017_iso_mount"

usage() {
  cat <<USAGE
Usage: $0 [path_to_cpu2017_iso]
  - When an ISO path is provided the script will mount, install, then unmount.
  - Without an ISO path it assumes CPU2017 already exists at ${INSTALL_DIR}.
USAGE
}

fortran_runtime_present() {
  local spec_file="${GCC_SPEC_DIR:-}/libgfortran.spec"
  if [[ -z "$GCC_SPEC_DIR" || ! -f "$spec_file" ]]; then
    return 1
  fi

  if compgen -G "${GCC_LIB64_DIR:-}/libgfortran.so*" >/dev/null 2>&1; then
    return 0
  fi

  if compgen -G "${GCC_LIB64_DIR:-}/libgfortran.a" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

copy_runtime_libs() {
  local libs_dir="$1"
  if [[ -z "$libs_dir" || ! -d "$libs_dir" ]]; then
    return 1
  fi

  local copied=0
  sudo install -d "$GCC_LIB64_DIR"
  shopt -s nullglob
  for artifact in "$libs_dir"/lib*.a "$libs_dir"/lib*.so*; do
    [[ -e "$artifact" ]] || continue
    local mode="644"
    [[ "$artifact" == *.so* ]] && mode="755"
    sudo install -m "$mode" "$artifact" "$GCC_LIB64_DIR/$(basename "$artifact")"
    copied=1
  done
  shopt -u nullglob

  if [[ "$copied" -eq 1 ]]; then
    return 0
  fi
  return 1
}

copy_header_artifacts() {
  local source_dir="$1"
  shift
  local patterns=("$@")

  if [[ -z "$source_dir" || ! -d "$source_dir" || "${#patterns[@]}" -eq 0 ]]; then
    return 1
  fi

  sudo install -d "$GCC_PREFIX/include"
  sudo install -d "$GCC_FMODULE_DIR"

  local copied=0
  shopt -s nullglob
  for pattern in "${patterns[@]}"; do
    for artifact in "$source_dir"/$pattern; do
      [[ -e "$artifact" ]] || continue
      local dest="$GCC_PREFIX/include"
      case "$artifact" in
        *.mod|*.MOD)
          dest="$GCC_FMODULE_DIR"
          ;;
      esac
      sudo install -m 644 "$artifact" "$dest/$(basename "$artifact")"
      copied=1
    done
  done
  shopt -u nullglob

  if [[ "$copied" -eq 1 ]]; then
    return 0
  fi
  return 1
}

restore_fortran_runtime_from_cache() {
  local build_target_dir="$GCC_CACHE_ROOT/build/$GCC_TARGET_TRIPLE"
  local spec_src="$build_target_dir/libgfortran/libgfortran.spec"
  local libs_dir="$build_target_dir/libgfortran/.libs"
  local quadmath_dir="$build_target_dir/libquadmath/.libs"
  local restored=0

  if [[ -f "$spec_src" ]]; then
    sudo install -d "$GCC_SPEC_DIR"
    sudo install -m 644 "$spec_src" "$GCC_SPEC_DIR/libgfortran.spec"
    restored=1
  fi

  if copy_runtime_libs "$libs_dir"; then
    restored=1
  fi

  if copy_runtime_libs "$quadmath_dir"; then
    restored=1
  fi

  if [[ "$restored" -eq 1 ]] && fortran_runtime_present; then
    echo "Restored libgfortran runtime from $build_target_dir"
    return 0
  fi

  return 1
}

ensure_fortran_runtime() {
  if fortran_runtime_present; then
    return 0
  fi

  if restore_fortran_runtime_from_cache; then
    return 0
  fi

  cat <<EOF
Error: libgfortran runtime files are missing under $GCC_PREFIX.

Please build or reinstall the GCC ${GCC_VERSION_FULL} toolchain with Fortran
support before continuing. The helper script $CPU2017_DIR/build_gcc6.sh can
rebuild the toolchain and populate the runtime libraries.
EOF
  exit 1
}

gomp_runtime_present() {
  local spec_file="$GCC_SPEC_DIR/libgomp.spec"
  local omp_header="$GCC_PREFIX/include/omp.h"
  local omp_module="$GCC_FMODULE_DIR/omp_lib.mod"

  if [[ ! -f "$spec_file" ]]; then
    return 1
  fi

  if [[ ! -f "$omp_header" ]]; then
    return 1
  fi

  if [[ ! -f "$omp_module" ]]; then
    return 1
  fi

  if compgen -G "$GCC_LIB64_DIR/libgomp.so*" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -f "$GCC_LIB64_DIR/libgomp.a" ]]; then
    return 0
  fi

  return 1
}

restore_gomp_runtime_from_cache() {
  local build_target_dir="$GCC_CACHE_ROOT/build/$GCC_TARGET_TRIPLE"
  local component_dir="$build_target_dir/libgomp"
  local spec_src="$component_dir/libgomp.spec"
  local libs_dir="$component_dir/.libs"
  local headers_dir="$component_dir"
  local restored=0

  if [[ -f "$spec_src" ]]; then
    sudo install -d "$GCC_SPEC_DIR"
    sudo install -m 644 "$spec_src" "$GCC_SPEC_DIR/libgomp.spec"
    restored=1
  fi

  if copy_runtime_libs "$libs_dir"; then
    restored=1
  fi

  if copy_header_artifacts "$headers_dir" \
      "omp.h" "omp_*.h" "omp_*.mod" "omp_lib.h" "omp_lib*.mod" \
      "libgomp_f.h" "openacc*.h" "openacc*.mod"; then
    restored=1
  fi

  if [[ "$restored" -eq 1 ]] && gomp_runtime_present; then
    echo "Restored libgomp runtime from $component_dir"
    return 0
  fi

  return 1
}

ensure_gomp_runtime() {
  if gomp_runtime_present; then
    return 0
  fi

  if restore_gomp_runtime_from_cache; then
    return 0
  fi

  cat <<EOF
Error: libgomp runtime files are missing under $GCC_PREFIX.

Please build or reinstall the GCC ${GCC_VERSION_FULL} toolchain with OpenMP
support before continuing. The helper script $CPU2017_DIR/build_gcc6.sh can
rebuild the toolchain and populate the runtime libraries.
EOF
  exit 1
}

blender_portability_has_gnu_source() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 1
  awk '
    /^526\.blender_r:/ {
      if (getline) {
        if ($0 ~ /PORTABILITY/ && $0 ~ /-D_GNU_SOURCE/) {
          found=1
        }
      }
      exit
    }
    END { exit found ? 0 : 1 }
  ' "$config_file" >/dev/null 2>&1
}

ensure_config_patchups() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 0

  if ! blender_portability_has_gnu_source "$config_file"; then
    perl -0pi -e 's/(526\.blender_r:[^\n]*\n\s*PORTABILITY\s*=\s*[^\n]*)/$1 -D_GNU_SOURCE/' "$config_file"
    echo "Updated 526.blender_r portability flags with -D_GNU_SOURCE"
  fi
}

ensure_fortran_runtime
ensure_gomp_runtime

ensure_mount_point() {
  if [[ ! -d "$MOUNT_POINT" ]]; then
    mkdir -p "$MOUNT_POINT"
  fi
}

mount_iso() {
  local iso="$1"
  ensure_mount_point
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "ISO already mounted at $MOUNT_POINT"
    return 0
  fi
  echo "Mounting ISO $iso..."
  sudo mount -o loop "$iso" "$MOUNT_POINT" || {
    echo "Error: Failed to mount ISO with sudo, retrying without..."
    mount -o loop "$iso" "$MOUNT_POINT"
  }
}

unmount_iso() {
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Unmounting ISO from $MOUNT_POINT..."
    sudo umount "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null || true
  fi
}

install_from_iso() {
  local iso="$1"
  if [[ ! -f "$iso" ]]; then
    echo "Error: ISO file '$iso' does not exist!"
    exit 1
  fi

  mount_iso "$iso"

  if [[ -d "$INSTALL_DIR" ]]; then
    echo "Removing existing installation at $INSTALL_DIR..."
    sudo rm -rf "$INSTALL_DIR"
  fi

  if [[ -f "$MOUNT_POINT/install.sh" ]]; then
    echo "Running SPEC installer to $INSTALL_DIR (this may take a while)..."
    (cd "$MOUNT_POINT" && bash install.sh -d "$INSTALL_DIR")
  else
    echo "Error: install.sh not found in mounted ISO at $MOUNT_POINT"
    unmount_iso
    exit 1
  fi

  unmount_iso
}

maybe_install_from_iso() {
  local iso="$1"
  if [[ -z "$iso" ]]; then
    echo "No ISO path supplied; assuming CPU2017 already installed at $INSTALL_DIR"
    return 0
  fi

  install_from_iso "$iso"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ISO_PATH="${1:-}"

echo "=========================================="
echo "CPU SPEC 2017 Build Script"
echo "=========================================="
echo "ISO path: ${ISO_PATH:-<skipped>}"
echo "Install directory: $INSTALL_DIR"
echo "=========================================="

maybe_install_from_iso "$ISO_PATH"

# Source CPU2017 environment
if [[ -f "$INSTALL_DIR/shrc" ]]; then
  # Save CPU2017_DIR before sourcing shrc (it may be modified)
  SAVED_CPU2017_DIR="$CPU2017_DIR"
  # Change to install directory before sourcing shrc (it checks current directory)
  cd "$INSTALL_DIR"
  source "$INSTALL_DIR/shrc"
  # Restore CPU2017_DIR after sourcing
  CPU2017_DIR="$SAVED_CPU2017_DIR"
  # Ensure we're still in the install directory after sourcing shrc
  cd "$INSTALL_DIR"
  # Set SPEC environment variable if not set
  export SPEC="$INSTALL_DIR"
else
  echo "Error: CPU SPEC 2017 shrc not found!"
  exit 1
fi

# Extract benchmark names from w.txt
BENCHMARKS=()
while IFS= read -r line; do
  if [[ -n "$line" ]]; then
    BENCHMARK=$(echo "$line" | awk '{print $1}')
    BENCHMARKS+=("$BENCHMARK")
  fi
done < "$CPU2017_DIR/w.txt"

echo "=========================================="
echo "Found ${#BENCHMARKS[@]} benchmarks to build"
echo "=========================================="

# Create config file if it doesn't exist
CONFIG_FILE="$INSTALL_DIR/config/${CONFIG_NAME}.cfg"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Creating config file: $CONFIG_FILE (based on Example-gcc-linux-x86.cfg)"
  BASE_CONFIG="$INSTALL_DIR/config/Example-gcc-linux-x86.cfg"
  if [[ ! -f "$BASE_CONFIG" ]]; then
    echo "Error: reference config $BASE_CONFIG not found!"
    exit 1
  fi

  cp "$BASE_CONFIG" "$CONFIG_FILE"
  perl -0pi -e 's|%define label .*|%define label '"$CONFIG_LABEL"'|' "$CONFIG_FILE"
  perl -0pi -e 's|%   define  gcc_dir\s+.*|%   define  gcc_dir        '"$GCC_PREFIX"'|' "$CONFIG_FILE"
  perl -0pi -e 's|SPECLANG\s*=.*|   SPECLANG                = '"$GCC_PREFIX"'/bin/|' "$CONFIG_FILE"
  perl -0pi -e 's|\$\(SPECLANG\)gcc\s+-std|\$(SPECLANG)gcc-'"$GCC_VERSION"'     -std|' "$CONFIG_FILE"
  perl -0pi -e 's|\$\(SPECLANG\)g\+\+|\$(SPECLANG)g++-'"$GCC_VERSION"'|' "$CONFIG_FILE"
  perl -0pi -e 's|\$\(SPECLANG\)gfortran|\$(SPECLANG)gfortran-'"$GCC_VERSION"'|' "$CONFIG_FILE"
  perl -0pi -e 's|-fno-tree-loop-vectorize|#-fno-tree-loop-vectorize|' "$CONFIG_FILE"
  echo "Config $CONFIG_FILE customized for gcc-${GCC_VERSION} under ${GCC_PREFIX}/bin"
else
  echo "Config file already exists: $CONFIG_FILE (skipping creation)"
fi

ensure_config_patchups "$CONFIG_FILE"

# Build all benchmarks
echo "=========================================="
echo "Building benchmarks..."
echo "=========================================="

cd "$INSTALL_DIR"

# Build rate benchmarks
RATE_BENCHMARKS=()
SPEED_BENCHMARKS=()

for bench in "${BENCHMARKS[@]}"; do
  if [[ "$bench" =~ _r$ ]]; then
    RATE_BENCHMARKS+=("$bench")
  elif [[ "$bench" =~ _s$ ]]; then
    SPEED_BENCHMARKS+=("$bench")
  fi
done

# Build rate benchmarks
if [[ ${#RATE_BENCHMARKS[@]} -gt 0 ]]; then
  echo "Building rate benchmarks: ${RATE_BENCHMARKS[*]}"
  runcpu --config="$CONFIG_NAME" --action=build --tune=base --size=ref \
    "${RATE_BENCHMARKS[@]}" || {
    echo "Warning: Some rate benchmarks failed to build"
  }
fi

# Build speed benchmarks
if [[ ${#SPEED_BENCHMARKS[@]} -gt 0 ]]; then
  echo "Building speed benchmarks: ${SPEED_BENCHMARKS[*]}"
  runcpu --config="$CONFIG_NAME" --action=build --tune=base --size=ref \
    "${SPEED_BENCHMARKS[@]}" || {
    echo "Warning: Some speed benchmarks failed to build"
  }
fi

# Copy built executables to workload directories
echo "=========================================="
echo "Copying executables to workload directories..."
echo "=========================================="

copy_tree_contents() {
  local source_dir="$1"
  local dest_dir="$2"

  if [[ ! -d "$source_dir" ]]; then
    return 1
  fi

  mkdir -p "$dest_dir"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$source_dir"/ "$dest_dir"/ >/dev/null 2>&1 || return 1
  else
    cp -a "$source_dir"/. "$dest_dir"/ >/dev/null 2>&1 || return 1
  fi

  return 0
}

resolve_benchspec_dir() {
  local bench="$1"
  local direct="$INSTALL_DIR/benchspec/CPU/$bench"

  if [[ -d "$direct" ]]; then
    echo "$direct"
    return 0
  fi

  local bench_without_prefix="${bench#*.}"
  local alt="$INSTALL_DIR/benchspec/CPU/$bench_without_prefix"

  if [[ -d "$alt" ]]; then
    echo "$alt"
    return 0
  fi

  find "$INSTALL_DIR/benchspec/CPU" -maxdepth 1 -type d -name "*.${bench_without_prefix}" -print -quit 2>/dev/null
}

find_executable_path() {
  local spec_dir="$1"
  local suffix="_base.${CONFIG_FILE_SUFFIX}"
  local exe_dir="$spec_dir/exe"

  if [[ -d "$exe_dir" ]]; then
    local candidate
    candidate=$(find "$exe_dir" -maxdepth 1 -type f -name "*${suffix}" -print -quit 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  return 1
}

copy_reference_payload() {
  local bench="$1"
  local spec_dir="$2"
  local dest_dir="$3"
  local bench_type="$4"

  if copy_tree_contents "$spec_dir/run/run_ref" "$dest_dir"; then
    echo "Copied run_ref payload for $bench"
  else
    local dataset_dir
    if [[ "$bench_type" == "rate" ]]; then
      dataset_dir="$spec_dir/data/refrate"
    else
      dataset_dir="$spec_dir/data/refspeed"
    fi

    if copy_tree_contents "$dataset_dir" "$dest_dir"; then
      echo "Copied reference dataset for $bench"
    fi
  fi

  local dest_lib_dir="$dest_dir/lib"
  if [[ ! -d "$dest_lib_dir" ]] && copy_tree_contents "$spec_dir/lib" "$dest_lib_dir"; then
    echo "Copied lib directory for $bench"
  fi

  return 0
}

benchmark_type() {
  local bench="$1"
  if [[ "$bench" =~ _r$ ]]; then
    echo "rate"
    return 0
  elif [[ "$bench" =~ _s$ ]]; then
    echo "speed"
    return 0
  fi
  return 1
}

for bench in "${BENCHMARKS[@]}"; do
  BENCH_DIR="$CPU2017_DIR/$bench"

  if [[ ! -d "$BENCH_DIR" ]]; then
    echo "Warning: Directory $BENCH_DIR does not exist, skipping..."
    continue
  fi

  BENCH_TYPE=$(benchmark_type "$bench") || {
    echo "Warning: Unknown benchmark type for $bench, skipping..."
    continue
  }

  BENCH_SPEC_DIR=$(resolve_benchspec_dir "$bench")
  if [[ -z "$BENCH_SPEC_DIR" || ! -d "$BENCH_SPEC_DIR" ]]; then
    echo "Warning: Spec directory for $bench not found under $INSTALL_DIR/benchspec/CPU"
    continue
  fi

  EXECUTABLE_PATH=$(find_executable_path "$BENCH_SPEC_DIR")
  if [[ -z "$EXECUTABLE_PATH" || ! -f "$EXECUTABLE_PATH" ]]; then
    echo "Warning: Could not locate executable for $bench"
    continue
  fi

  EXECUTABLE_NAME="$(basename "$EXECUTABLE_PATH")"
  echo "Copying $EXECUTABLE_NAME -> $BENCH_DIR/"
  cp "$EXECUTABLE_PATH" "$BENCH_DIR/$EXECUTABLE_NAME"
  chmod +x "$BENCH_DIR/$EXECUTABLE_NAME"

  copy_reference_payload "$bench" "$BENCH_SPEC_DIR" "$BENCH_DIR" "$BENCH_TYPE"
done

echo "=========================================="
echo "Installation completed!"
echo "=========================================="
echo "CPU SPEC 2017 installed at: $INSTALL_DIR"
echo "Benchmarks copied to: $CPU2017_DIR"
echo ""
echo "You can now run workloads using:"
echo "  cd $CPU2017_DIR"
echo "  ./run.sh w.txt"
