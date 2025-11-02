#!/bin/bash
SRC_DIR="/mnt/sda4/redis/src"
BIN_DIR="/usr/local/bin"
arr=( redis-benchmark redis-check-aof redis-check-rdb redis-cli redis-sentinel redis-server )

for ((i = 0; i < ${#arr[@]}; i++)); do
	exe=${arr[$i]}
	sudo ln -s ${SRC_DIR}/$exe ${BIN_DIR}/$exe
done
