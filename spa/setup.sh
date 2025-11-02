#!/bin/bash
sudo apt update
sudo apt install -y libgfortran5
sudo apt install -y vmtouch
sudo apt install -y libxmu6
sudo apt install -y python3-pip gdb
./install-perf.sh

# mount sda4 to /mnt/sda4
# Create sda4 partition if it doesn't exist
if [ ! -b /dev/sda4 ]; then
    echo "Creating sda4 partition..."
    # Fix GPT warning first (if needed), then get sda99 start position dynamically
    echo "fix" | sudo parted /dev/sda ---pretend-input-tty unit GB print 2>/dev/null > /dev/null || true
    SWAP_START=$(echo "fix" | sudo parted /dev/sda ---pretend-input-tty unit GB print 2>/dev/null | grep -E "^ 99|^99" | awk '{print $2}')
    # Create partition using all remaining space (from 69.0GB to just before swap)
    sudo parted -s /dev/sda mkpart primary ext4 69.0GB ${SWAP_START}
    # Update partition table
    sudo partprobe /dev/sda
    sleep 2
fi
sudo mkfs.ext4 -L sda4_data /dev/sda4
# Create mount point if it doesn't exist
sudo mkdir -p /mnt/sda4
sudo mount /dev/sda4 /mnt/sda4

echo "DONE"
