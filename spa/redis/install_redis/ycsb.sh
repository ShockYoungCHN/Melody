#!/bin/bash

sudo apt install maven -y

cd /tdata
[[ -d ycsb ]] && rm -rf redis && "ycsb removed"

git clone http://github.com/brianfrankcooper/YCSB.git

cd YCSB
mvn -pl site.ycsb:redis-binding -am clean package
