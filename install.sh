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

BOOT_START_BYTES=1048576 # 1MiB
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
ryptsetup open /dev/md1 cryptroot

# Create lvm
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
VG_SIZE_BYTES=$(($(sudo vgs --units B --noheadings | awk '{ print substr( $6, 1, length($6)-1 ) }') - 1))

ROOT_LV_SIZE_BYTES="50000000000"
VAR_LV_SIZE_BYTES="10000000000"
TMP_LV_SIZE_BYTES="5000000000"
HOME_LV_SIZE_BYTES=$(( $VG_SIZE_BYTES - $ROOT_LV_SIZE_BYTES - $VAR_LV_SIZE_BYTES - $TMP_LV_SIZE_BYTES))

lvcreate -L "$ROOT_LV_SIZE_BYTES"b vg0 -n root
lvcreate -L "$VAR_LV_SIZE_BYTES"b vg0 -n var
lvcreate -L "$TMP_LV_SIZE_BYTES"b vg0 -n tmp
lvcreate -L "$HOME_LV_SIZE_BYTES"b vg0 -n home

# ext4 filesystem on LVs
mkfs.fat -F32 /dev/md0
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/home
mkfs.ext4 /dev/vg0/var
mkfs.ext4 /dev/vg0/tmp

# mount lvs
mount /dev/vg0/root /mnt
mkdir /mnt/boot && mount /dev/md0 /mnt/boot
mkdir /mnt/home && mount /dev/vg0/home /mnt/home
mkdir /mnt/var && mount /dev/vg0/var /mnt/var
mkdir /mnt/tmp && mount /dev/vg0/tmp /mnt/tmp

# Place config files
rm -rf /mnt/etc/mkinitcpio.conf
rm -rf /mnt/etc/default/grub
cp mkinitcpio.conf /mnt/tmp
cp grub /mnt/tmp

# Edit pacman.conf
echo "[multilib]" >> /mnt/etc/pacman.conf
echo "Include = /etc/pacman.d/mirrorlist" >> /mnt/etc/pacman.conf

# install arch
pacstrap /mnt - < ./required_packages
genfstab -U /mnt >> /mnt/etc/fstab
arch-chroot /mnt

# Configure mkinitcpio
rm -rf /etc/mkinitcpio.conf
cp /tmp/mkinitcpio.conf /etc/mkinitcpio.conf
mkinitcpio -P

# configure mdadm
mdadm --detail --scan >> /etc/mdadm.conf

# Install grub on both ssds
uuid=$(blkid --match-tag UUID -o value /dev/md1)
cp /tmp/grub /etc/default/grub
echo GRUB_CMDLINE_LINUX="cryptdevice=UUID=${uuid}:cryptroot root=/dev/vg0/root" >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck --removable /dev/"$NVME0"
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck --removable /dev/"$NVME1"

grub-mkconfig -o /boot/grub/grub.cfg

# Configure root user password
passwd

# Install DE 
systemctl enable sddm.service
systemctl enable NetworkManager.service