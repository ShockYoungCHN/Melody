#!/bin/bash
sudo apt update
# Install TBB libraries: libtbb12 (main TBB library) and libtbbmalloc2 (TBB malloc)
sudo apt install -y libtbb12 libtbbmalloc2 || exit
# Check if libtbb.so.2 exists, if not create symlink from available version (e.g., libtbb.so.12)
if [ ! -e /usr/lib/x86_64-linux-gnu/libtbb.so.2 ]; then
    # Find any libtbb.so file (follow symlinks to find actual file)
    TBB_LIB=$(find /usr/lib/x86_64-linux-gnu -name "libtbb.so.*" -type l 2>/dev/null | head -1)
    if [ -z "$TBB_LIB" ]; then
        TBB_LIB=$(ls -1 /usr/lib/x86_64-linux-gnu/libtbb.so.* 2>/dev/null | head -1)
    fi
    if [ -n "$TBB_LIB" ] && [ -e "$TBB_LIB" ]; then
        TBB_BASE=$(basename $TBB_LIB)
        echo "Creating symlink: libtbb.so.2 -> $TBB_BASE"
        cd /usr/lib/x86_64-linux-gnu
        sudo ln -sf $TBB_BASE libtbb.so.2
    else
        echo "Warning: Could not find libtbb.so library to create symlink"
    fi
fi

# Update dynamic linker cache to recognize the new libraries
sudo ldconfig

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TODO : may need to change to other directory's name
cd /mnt/sda4

echo "Check pbbsbench ..."
[[ -d pbbsbench ]] && rm -rf pbbsbench && echo "pbbsbench removed"

git clone https://github.com/cmuparlay/pbbsbench.git
cd pbbsbench
git checkout 596b670eb946c352368d265ae9888ce08a42468f
git submodule update --init
cp ${SCRIPT_PATH}/pbbs.patch .
git apply pbbs.patch
cp ${SCRIPT_PATH}/Makefile .

make ext -j$(nproc)
