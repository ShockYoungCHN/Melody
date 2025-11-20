#!/bin/bash
#
# Sync SPEC CPU2017 benchmark payloads + fix permissions for local runs.
# Usage: ./prepare_workloads.sh [bench_list_file]

set -euo pipefail

CPU2017_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_INSTALL_DIR="${SPEC_DIR:-/opt/cpu2017}"
BENCH_LIST_FILE="${1:-$CPU2017_DIR/w.txt}"
CONFIG_LABEL="${SPEC_CONFIG_LABEL:-mytest}"
CONFIG_BITS="${SPEC_CONFIG_BITS:-64}"
CONFIG_SUFFIX="${CONFIG_LABEL}-m${CONFIG_BITS}"
WORK_OWNER="${SPEC_WORK_OWNER:-$USER}"
WORK_GROUP="${SPEC_WORK_GROUP:-$(id -gn "$WORK_OWNER")}"
SKIP_CHOWN="${SPEC_SKIP_CHOWN:-0}"

if [[ ! -f "$BENCH_LIST_FILE" ]]; then
  echo "Bench list '$BENCH_LIST_FILE' not found" >&2
  exit 1
fi

if [[ ! -d "$SPEC_INSTALL_DIR" ]]; then
  echo "SPEC install dir '$SPEC_INSTALL_DIR' not found" >&2
  exit 1
fi

if [[ ! -f "$CPU2017_DIR/w.txt" ]]; then
  echo "Expected workload list $CPU2017_DIR/w.txt missing" >&2
  exit 1
fi

SUDO_HELPER=""
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  SUDO_HELPER="sudo"
fi

maybe_sudo() {
  if [[ -n "$SUDO_HELPER" ]]; then
    "$SUDO_HELPER" "$@"
  else
    "$@"
  fi
}

copy_tree() {
  local src="$1"
  local dest="$2"
  [[ -d "$src" ]] || return 1
  mkdir -p "$dest"
  local rsync_flags=(-a --no-owner --no-group --no-perms --no-times)
  if command -v rsync >/dev/null 2>&1; then
    if ! rsync "${rsync_flags[@]}" "$src"/ "$dest"/ >/dev/null; then
      return 1
    fi
  else
    if ! cp -a "$src"/. "$dest"/ >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

resolve_benchspec_dir() {
  local bench="$1"
  local direct="$SPEC_INSTALL_DIR/benchspec/CPU/$bench"
  if [[ -d "$direct" ]]; then
    printf '%s\n' "$direct"
    return 0
  fi
  local suffix="${bench#*.}"
  local alt="$SPEC_INSTALL_DIR/benchspec/CPU/$suffix"
  if [[ -d "$alt" ]]; then
    printf '%s\n' "$alt"
    return 0
  fi
  find "$SPEC_INSTALL_DIR/benchspec/CPU" -maxdepth 1 -type d -name "*.${suffix}" -print -quit 2>/dev/null
}

find_executable() {
  local spec_dir="$1"
  local exe_dir="$spec_dir/exe"
  [[ -d "$exe_dir" ]] || return 1
  find "$exe_dir" -maxdepth 1 -type f -name "*_base.${CONFIG_SUFFIX}" -print 2>/dev/null
}

ensure_cmd_executable() {
  local cmd="$1/cmd.sh"
  if [[ -f "$cmd" ]]; then
    maybe_sudo chmod +x "$cmd"
  fi
}

copy_run_payload() {
  local run_root="$1"
  local dest="$2"
  local run_dir=""
  if [[ -d "$run_root" ]]; then
    run_dir="$(find "$run_root" -maxdepth 1 -type d -name "run_base_*${CONFIG_SUFFIX}*" | sort | tail -n 1)"
    if [[ -z "$run_dir" ]]; then
      run_dir="$(find "$run_root" -maxdepth 1 -type d -name "run_base.${CONFIG_SUFFIX}" -print -quit 2>/dev/null)"
    fi
  fi
  if [[ -n "$run_dir" && -d "$run_dir" ]]; then
    copy_tree "$run_dir" "$dest"
    return 0
  fi
  return 1
}

sync_benchmark() {
  local bench="$1"
  local bench_dir="$CPU2017_DIR/$bench"
  local spec_dir
  spec_dir="$(resolve_benchspec_dir "$bench")"
  if [[ -z "$spec_dir" || ! -d "$spec_dir" ]]; then
    echo "[WARN] Spec directory for $bench not found under $SPEC_INSTALL_DIR" >&2
    return
  fi

  mkdir -p "$bench_dir"

  if [[ "$SKIP_CHOWN" != "1" ]]; then
    maybe_sudo chown -R "$WORK_OWNER:$WORK_GROUP" "$bench_dir" >/dev/null 2>&1 || true
    maybe_sudo chmod -R u+rwX "$bench_dir" >/dev/null 2>&1 || true
  fi

  local exe_copied=0
  while IFS= read -r exe_path; do
    [[ -n "$exe_path" ]] || continue
    if [[ -f "$exe_path" ]]; then
      maybe_sudo install -m 755 "$exe_path" "$bench_dir/$(basename "$exe_path")"
      exe_copied=1
    fi
  done < <(find_executable "$spec_dir")
  if [[ "$exe_copied" -eq 0 ]]; then
    echo "[WARN] Executables for $bench not located; skipping copy" >&2
  fi

  local copied_run=0
  if copy_run_payload "$spec_dir/run" "$bench_dir"; then
    copied_run=1
  fi

  if [[ "$copied_run" -eq 0 ]]; then
    local dataset_dir="$spec_dir/data"
    local dataset_flavor="refspeed"
    [[ "$bench" =~ _r$ ]] && dataset_flavor="refrate"
    local dataset_root="$dataset_dir/$dataset_flavor"
    if [[ -d "$dataset_root/input" ]]; then
      copy_tree "$dataset_root/input" "$bench_dir" || true
    fi
    if [[ -d "$dataset_root/data" ]]; then
      copy_tree "$dataset_root/data" "$bench_dir/data" || true
    fi
    if [[ -d "$dataset_root/output" ]]; then
      copy_tree "$dataset_root/output" "$bench_dir/output" || true
    fi
    if [[ -f "$dataset_root/refpower" ]]; then
      cp -f "$dataset_root/refpower" "$bench_dir/refpower" 2>/dev/null || true
    fi
    if [[ -f "$dataset_root/reftime" ]]; then
      cp -f "$dataset_root/reftime" "$bench_dir/reftime" 2>/dev/null || true
    fi
  fi

  if [[ -d "$spec_dir/lib" ]]; then
    copy_tree "$spec_dir/lib" "$bench_dir/lib" || true
  fi

  ensure_cmd_executable "$bench_dir"

  if [[ "$SKIP_CHOWN" != "1" ]]; then
    if maybe_sudo chown -R "$WORK_OWNER:$WORK_GROUP" "$bench_dir" >/dev/null 2>&1; then
      maybe_sudo chmod -R u+rwX "$bench_dir"
    else
      echo "[WARN] Unable to change ownership of $bench_dir; r.sh creation may still fail" >&2
    fi
  fi
}

mapfile -t BENCHMARKS < <(awk 'NF{print $1}' "$BENCH_LIST_FILE")

for bench in "${BENCHMARKS[@]}"; do
  sync_benchmark "$bench"
done

echo "Prepared ${#BENCHMARKS[@]} benchmarks under $CPU2017_DIR"
