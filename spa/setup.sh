#!/bin/bash
sudo apt update
sudo apt install -y libgfortran5
sudo apt install -y vmtouch
sudo apt install -y libxmu6
sudo apt install -y python3-pip gdb
./install-perf.sh

# mount sda4 to /mnt/sda4
sudo mkfs.ext4 -L sda4_data /dev/sda4
sudo mount /dev/sda4 /mnt/sda4

echo "DONE"
