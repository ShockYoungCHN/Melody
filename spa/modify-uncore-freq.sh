#!/bin/bash
source "$(dirname "$0")/config.sh"

if [[ $# != 4 ]]; then
  echo "Usage: sudo ./modify-uncore-freq.sh [node0-min] [node0-max] [node1-min] [node1-max]"
  exit 1
fi

echo "setting all cores online ..."
bring_all_cpus_online

ZERO_MIN_UNCORE_FREQ=$1
ZERO_MAX_UNCORE_FREQ=$2
ONE_MIN_UNCORE_FREQ=$3
ONE_MAX_UNCORE_FREQ=$4

# Change node 0 min uncore frequency
change_node_zero_min()
{
  local freq=$ZERO_MIN_UNCORE_FREQ
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz)
  echo $freq > /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/min_freq_khz)
  if [[ $freq == $curfreq ]]; then
    echo "Success! Node 0 min uncore frequency has been set to $curfreq"
  else
    echo "Fail! Current node 0 min uncore frequency: $curfreq"
  fi
}

# Change node 0 max uncore frequency
change_node_zero_max()
{
  local freq=$ZERO_MAX_UNCORE_FREQ
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz)
  echo $freq > /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_00_die_00/max_freq_khz)
  if [[ $freq == $curfreq ]]; then
    echo "Success! Node 0 max uncore frequency has been set to $curfreq"
  else
    echo "Fail! Current node 0 max uncore frequency: $curfreq"
  fi
}

# Change node 1 min uncore frequency
change_node_one_min()
{
  local freq=$ONE_MIN_UNCORE_FREQ
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/min_freq_khz)
  echo $freq > /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/min_freq_khz
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/min_freq_khz)
  if [[ $freq == $curfreq ]]; then
    echo "Success! Node 1 min uncore frequency has been set to $curfreq"
  else
    echo "Fail! Current node 1 min uncore frequency: $curfreq"
  fi
}

# Change node 1 max uncore frequency
change_node_one_max()
{
  local freq=$ONE_MAX_UNCORE_FREQ
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz)
  echo $freq > /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz
  local curfreq=$( cat /sys/devices/system/cpu/intel_uncore_frequency/package_01_die_00/max_freq_khz)
  if [[ $freq == $curfreq ]]; then
    echo "Success! Node 1 max uncore frequency has been set to $curfreq"
  else
    echo "Fail! Current node 1 max uncore frequency: $curfreq"
  fi
}

main()
{
  change_node_zero_min
  change_node_zero_max
  change_node_one_min
  change_node_one_max
}

main
echo "./modify-uncore-freq.sh DONE"
exit
