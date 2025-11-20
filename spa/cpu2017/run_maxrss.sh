#!/bin/bash

RUNDIR=$(echo "$(dirname "$PWD")")
CPU2017_RUN_DIR="${RUNDIR}/cpu2017"
RSTDIR="${CPU2017_RUN_DIR}/rst_maxrss"
CSV_PATH="${RSTDIR}/maxrss.csv"
TIME_FORMAT="\nReal: %e %E\nUser: %U\nSys: %S\nCmdline: %C\nMax-RSS-kb: %M\nExit: %x"
LOCAL_BIND_OPTS="numactl --cpunodebind 0 --membind 0 --"

if [[ $# != 1 && $# != 2 ]]; then
  echo ""
  echo "$0 w.txt"
  echo "$0 w.txt 1"
  echo ""
  exit 1
fi

WF=$1
WID=$2
if [[ $# == 1 ]]; then
  warr=($(awk '{print $1}' "$WF"))
  marr=($(awk '{print $2}' "$WF"))
elif [[ $# == 2 ]]; then
  warr=($(awk -v line=$WID 'NR == line {print $1}' "$WF"))
  marr=($(awk -v line=$WID 'NR == line {print $2}' "$WF"))
fi

[[ ${#warr[@]} -gt 0 ]] || { echo "No workloads loaded from $WF"; exit 1; }

source "$RUNDIR/config.sh" || exit 1
[[ -x /usr/bin/time ]] || { echo "Please install GNU time (/usr/bin/time)"; exit 1; }
[[ -d "$RSTDIR" ]] || mkdir -p "$RSTDIR"
if [[ ! -f "$CSV_PATH" ]]; then
  echo "timestamp,workload,mem_hint_kb,real_seconds,real_hms,user_seconds,sys_seconds,max_rss_kb,exit_code" > "$CSV_PATH"
fi

run_one()
{
  local w=$1
  local mem=$2
  local output_dir="$RSTDIR/$w"
  [[ -d "$output_dir" ]] || mkdir -p "$output_dir"

  local logf=${output_dir}/local-maxrss.log
  local timef=${output_dir}/local-maxrss.time
  local output=${output_dir}/local-maxrss.output

  flush_fs_caches
  echo "=> Running [$w] for Max RSS collection, date:$(date)" | tee -a "$logf"
  local run_cmd="$LOCAL_BIND_OPTS bash cmd.sh"

  {
    echo "$run_cmd" > r.sh
    /usr/bin/time -f "${TIME_FORMAT}" -o "${timef}" bash r.sh > "${output}" 2>&1
    rm -f r.sh
  } >> "$logf" 2>&1

  local real_line user_line sys_line max_line exit_line
  real_line=$(grep '^Real:' "$timef" | tail -n1)
  user_line=$(grep '^User:' "$timef" | tail -n1)
  sys_line=$(grep '^Sys:' "$timef" | tail -n1)
  max_line=$(grep '^Max-RSS-kb:' "$timef" | tail -n1)
  exit_line=$(grep '^Exit:' "$timef" | tail -n1)

  local real_seconds real_hms user_seconds sys_seconds max_rss exit_code
  read -r _ real_seconds real_hms <<<"$real_line"
  read -r _ user_seconds <<<"$user_line"
  read -r _ sys_seconds <<<"$sys_line"
  read -r _ max_rss <<<"$max_line"
  read -r _ exit_code <<<"$exit_line"

  local now=$(date +"%F %T")
  local mem_hint=${mem:-NA}
  echo "$now,$w,$mem_hint,$real_seconds,$real_hms,$user_seconds,$sys_seconds,$max_rss,$exit_code" >> "$CSV_PATH"
}

main()
{
  for ((i = 0; i < ${#warr[@]}; i++)); do
    local w=${warr[$i]}
    local m=${marr[$i]}
    echo "Processing $w (mem hint: ${m:-N/A})"
    cd "$CPU2017_RUN_DIR/$w" || { echo "Failed to enter $w"; exit 1; }
    run_one "$w" "$m"
    cd "$CPU2017_RUN_DIR"
  done
}

main
echo "Finished collecting Max RSS metrics."
