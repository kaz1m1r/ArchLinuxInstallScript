#!/usr/bin/bash

pacman -Sy --noconfirm
pacman -S jq

NVMEs=$(lsblk --json -b -N | jq .blockdevices)
BLOCKDEVICES=$(lsblk --json -b | jq .blockdevices)

NVME0=$(echo "$NVMEs" | jq .[0].name)
NVME1=$(echo "$NVMEs" | jq .[1].name)

NVME0_SIZE_BYTES=$(($(echo "$BLOCKDEVICES" | jq .[0].size) + 0))
NVME1_SIZE_BYTES=$(($(echo "$BLOCKDEVICES" | jq .[1].size) + 0))

if [[ $NVME0_SIZE_BYTES -eq $NVME1_SIZE_BYTES ]]; then
    SMALLEST_DISK_SIZE=$NVME0_SIZE_BYTES
elif [[ $NVME0_SIZE_BYTES -lt $NVME1_SIZE_BYTES ]]; then
    SMALLEST_DISK_SIZE=$NVME0_SIZE_BYTES
else
    SMALLEST_DISK_SIZE=$NVME1_SIZE_BYTES
fi

BOOT_START_BYTES=1048576
BOOT_STOP_BYTES=$((2048 * 1048576 + $BOOT_START_BYTES))

RAID_START_BYTES=$BOOT_STOP_BYTES
RAID_STOP_BYTES=$(($SMALLEST_DISK_SIZE - $RAID_START_BYTES))

# Partition SSD's
parted /dev/"$NVME0" -- mklabel gpt
parted /dev/"$NVME0" -- mkpart ESP fat32 "$BOOT_START_BYTES"b "$BOOT_STOP_BYTES"b
parted /dev/"$NVME0" -- set 1 boot on
parted /dev/"$NVME0" -- mkpart raid "$RAID_START_BYTES"b "$RAID_STOP_BYTES"b

parted /dev/"$NVME1" -- mklabel gpt
parted /dev/"$NVME1" -- mkpart ESP fat32 "$BOOT_START_BYTES"b "$BOOT_STOP_BYTES"b
parted /dev/"$NVME1" -- set 1 boot on
parted /dev/"$NVME1" -- mkpart raid "$RAID_START_BYTES"b "$RAID_STOP_BYTES"b

# Configure raid
mdadm --create --verbose /dev/md0 --level=1 --raid-devices=2 --metadata=0.90 /dev/"$NVME0"p1 /dev/"$NVME1"p1

mdadm --create --verbose /dev/md1 --level=1 --raid-devices=2 --metadata=0.90 /dev/"$NVME0"p2 /dev/"$NVME1"p2

# Encrypt using LUKS
cryptsetup luksFormat /dev/md1
cryptsetup open /dev/md1 cryptroot


pacman -S --noconfirm - < ./required_packages.txt