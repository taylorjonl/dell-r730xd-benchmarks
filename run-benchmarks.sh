#!/bin/bash

set -eu

declare -A deviceInfoMap
declare -A modelMap
function gatherDeviceInfo() {
  local device
  for device in $@; do
    deviceInfo=$(smartctl -i -j $device)
    deviceInfoMap+=([$device]="$deviceInfo")
    local modelName=$(jq -r '.model_name' <<< "$deviceInfo")
    if [ ${modelMap[$modelName]+_} ]; then
      local models=${modelMap[$modelName]}
      models+=" $device"
      modelMap[$modelName]="$models"
    else
      modelMap+=([$modelName]="$device")
    fi
  done
}
gatherDeviceInfo $@


# ./random/{4k,8k,16k,32k}/{raw,ext4,zfs/{4k,8k,16k}}
# ./sequential/{128k,1m}/{raw,ext4,zfs/{128k,1m}}

function benchmarkDevice() {
  local device=$1

  runRawBenchmarks $device
  runExt4Benchmarks $device
  runZfsBenchmarks $device

  local deviceName=${device:5}
  for mode in random sequential; do
    if [[ -d .results/$mode/raw/$deviceName ]]; then
        for blocksize in $(ls .results/$mode/raw/$deviceName); do
            mkdir -p .results/$mode/$blocksize
            mv .results/$mode/{raw/$deviceName/$blocksize,$blocksize/raw}
        done
    fi
    if [[ -d .results/$mode/ext4/$deviceName ]]; then
        for blocksize in $(ls .results/$mode/ext4/$deviceName); do
            mkdir -p .results/$mode/$blocksize
            mv .results/$mode/{ext4/$deviceName/$blocksize,$blocksize/ext4}
        done
    fi
    if [[ -d .results/$mode/zfs ]]; then
        for recordsize in $(ls .results/$mode/zfs); do
            for blocksize in $(ls .results/$mode/zfs/$recordsize); do
            mkdir -p .results/$mode/$blocksize/zfs
            mv .results/$mode/{zfs/$recordsize/$blocksize,$blocksize/zfs/$recordsize}
            done
        done
    fi
  done

  find .results -empty -delete

  local deviceInfo=$(smartctl -i -j $device)
  local modelName=$(jq -r '.model_name' <<< "$deviceInfo")
  local serialNumber=$(jq -r '.serial_number' <<< "$deviceInfo")

  mkdir -p "results/$modelName/devices/$serialNumber"
  mv .results/{random,sequential} "results/$modelName/devices/$serialNumber"
}

function runRawBenchmarks() {
  local device=$1
  echo "Preparing '$device' for raw benchmarks"
  wipeDevice $device
  runBenchmarks $device raw
}

function runExt4Benchmarks() {
  local device=$1

  echo "Preparing '$device' for ext4 benchmarks"
  wipeDevice $device
  echo "Partitioning device"
  parted -s $device mklabel gpt &> /dev/null
  parted -a opt -s $device mkpart primary 0% 100% &> /dev/null
  sleep 1
  echo "Creating ext4 filesystem"
  local partition="${device}1" # this won't work for NVME drives
  mke2fs -t ext4 $partition &> /dev/null
  local mountPath="/mnt/${device:5}"
  mkdir -p "$mountPath"
  echo "Mounting partition at $mountPath"
  mount $partition $mountPath
  sleep 1

  runBenchmarks $mountPath ext4

  echo "Cleaning '$device' after ext4 benchmarks"
  umount $mountPath
  sleep 1
  rm -rf $mountPath
  wipeDevice $device
}

function runZfsBenchmarks() {
  local device=$1

  echo "Preparing '$device' for ZFS benchmarks"
  wipeDevice $device
  local poolName=${device:5}
  echo "Creating '$poolName' zpool on the device"
  zpool create -o ashift=12 $poolName $device
  for recordsize in 4k 8k 16k 64k 128k 1m; do
    local datasetName="$poolName/$recordsize"
    echo "Creating '$datasetName' dataset with $recordsize recordsize"
    zfs create -o atime=off -o recordsize=$recordsize $datasetName

    runBenchmarks "/$datasetName" zfs

    echo "Destroying '$datasetName' dataset"
    zfs destroy $datasetName
  done

  echo "Destroying '$poolName' zpool"
  zpool destroy $poolName
  echo "Cleaning '$device' after ZFS benchmarks"
  wipeDevice $device
}

function wipeDevice() {
  local device=$1
  local partitions=($(lsblk -J -p -f $device | jq -r '.blockdevices[].children // [] | .[].name'))
  if [[ "${#partitions[@]}" -gt 0 ]]; then
    local partition
    for partition in ${partitions[@]}; do
      wipefs -a $partition > /dev/null
    done
  fi
  wipefs -a $device > /dev/null
}

function runBenchmarks() {
  local target=$1
  local outputPath=$2
  local type
  lsblk $target &> /dev/null && type="device" || type="directory"
  if [[ $type == "device" ]]; then
    bench-fio \
      --type device \
      --target $target \
      --mode randread randwrite \
      -b 4k 8k 16k 32k 64k \
      --iodepth 1 32 64 256 \
      --numjobs 1 \
      --output .results/random/$outputPath
    bench-fio \
      --type device \
      --target $target \
      --mode read write \
      -b 128k 1m \
      --iodepth 1 32 64 256 \
      --numjobs 1 \
      --output .results/sequential/$outputPath
  else
    bench-fio \
      --type directory \
      --target $target \
      --mode randread randwrite \
      --size 150g \
      -b 4k 8k 16k 32k 64k \
      --iodepth 1 32 64 256 \
      --numjobs 1 \
      --output .results/random/$outputPath
    bench-fio \
      --type directory \
      --target $target \
      --mode read write \
      --size 150g \
      -b 128k 1m \
      --iodepth 1 32 64 256 \
      --numjobs 1 \
      --output .results/sequential/$outputPath
  fi
}

benchmarkDevice $1
