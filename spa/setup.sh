#!/bin/bash
sudo apt update
sudo apt install -y libgfortran5
sudo apt install -y vmtouch
sudo apt install -y libxmu6
./install-perf.sh
echo "DONE"
