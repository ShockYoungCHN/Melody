#!/bin/bash
LOGF=log
sudo apt update
sudo apt install -y libelf-dev libdw-dev libnuma-dev

curr_dir="$PWD"
[[ ! -d linux ]] && git clone https://github.com/torvalds/linux.git
echo "Compiling perf ..."
cd linux/tools/perf
make NO_LIBTRACEEVENT=1 > $LOGF 2>&1 || exit
rm $LOGF
echo "Checking perf ..."
[[ -e perf ]] || exit
echo "Finished checking"
cd ${curr_dir}
