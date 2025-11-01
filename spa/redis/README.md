## Install Redis
+ The scripts are in `install_redis`: 
	1. Download and install Redis:
		> *Note: The default path is `/mnt/sda4`.*
		```
		./install.sh
	  	```
	2. Install YCSB and packages:
		> *Note: The default path is `/tdata`.*
		```
		./ycsb.sh
		```
		```
		./pkgdep.sh
		```
## Run
+ `REDIS_SERVER=10.10.1.1` `REDIS_CLIENT=10.10.1.2`
+ Use `sudo ./run.sh` for running workloads
+ *Note: The default paths (`/mnt/sda4` and `/tdata`) may require to be changed to other names on different machines.*
