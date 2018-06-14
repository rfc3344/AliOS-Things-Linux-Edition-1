#!/bin/sh -e
#
# Copyright (c) 2012, Intel Corporation.
# All rights reserved.
#
# install.sh [device_name] [rootfs_name]
#

PATH=/sbin:/bin:/usr/sbin:/usr/bin

# We need 20 Mb for the boot partition
boot_size=200

# 5% for swap
swap_ratio=5

# Get a list of hard drives
hdnamelist=""
live_dev_name=`cat /proc/mounts | grep ${1%/} | awk '{print $1}'`
live_dev_name=${live_dev_name#\/dev/}
# Only strip the digit identifier if the device is not an mmc
case $live_dev_name in
    mmcblk*)
    ;;
    nvme*)
    ;;
    *)
        live_dev_name=${live_dev_name%%[0-9]*}
    ;;
esac

echo "Searching for hard drives ..."

# Some eMMC devices have special sub devices such as mmcblk0boot0 etc
# we're currently only interested in the root device so pick them wisely
devices=`ls /sys/block/ | grep -v mmcblk` || true
mmc_devices=`ls /sys/block/ | grep "mmcblk[0-9]\{1,\}$"` || true
devices="$devices $mmc_devices"

for device in $devices; do
    case $device in
        loop*)
            # skip loop device
            ;;
        sr*)
            # skip CDROM device
            ;;
        ram*)
            # skip ram device
            ;;
        *)
            # skip the device LiveOS is on
            # Add valid hard drive name to the list
            case $device in
                $live_dev_name*)
                # skip the device we are running from
                ;;
                *)
                    hdnamelist="$hdnamelist $device"
                ;;
            esac
            ;;
    esac
done

if [ -z "${hdnamelist}" ]; then
    echo "You need another device (besides the live device /dev/${live_dev_name}) to install the image. Installation aborted."
    exit 1
fi

TARGET_DEVICE_NAME=""
for hdname in $hdnamelist; do
    # Display found hard drives and their basic info
    echo "-------------------------------"
    echo /dev/$hdname
    if [ -r /sys/block/$hdname/device/vendor ]; then
        echo -n "VENDOR="
        cat /sys/block/$hdname/device/vendor
    fi
    if [ -r /sys/block/$hdname/device/model ]; then
        echo -n "MODEL="
        cat /sys/block/$hdname/device/model
    fi
    if [ -r /sys/block/$hdname/device/uevent ]; then
        echo -n "UEVENT="
        cat /sys/block/$hdname/device/uevent
    fi
    echo
done

# Get user choice
while true; do
    echo "Please select an install target or press n to exit ($hdnamelist ): "
    read answer
    if [ "$answer" = "n" ]; then
        echo "Installation manually aborted."
        exit 1
    fi
    for hdname in $hdnamelist; do
        if [ "$answer" = "$hdname" ]; then
            TARGET_DEVICE_NAME=$answer
            break
        fi
    done
    if [ -n "$TARGET_DEVICE_NAME" ]; then
        break
    fi
done

if [ -n "$TARGET_DEVICE_NAME" ]; then
    echo "Installing image on /dev/$TARGET_DEVICE_NAME ..."
else
    echo "No hard drive selected. Installation aborted."
    exit 1
fi

device=/dev/$TARGET_DEVICE_NAME

#
# The udev automounter can cause pain here, kill it
#
rm -f /etc/udev/rules.d/automount.rules
rm -f /etc/udev/scripts/mount*

#
# Unmount anything the automounter had mounted
#
umount ${device}* 2> /dev/null || /bin/true

mkdir -p /tmp

# Create /etc/mtab if not present
if [ ! -e /etc/mtab ] && [ -e /proc/mounts ]; then
    ln -sf /proc/mounts /etc/mtab
fi

disk_size=$(parted ${device} unit mb print | grep '^Disk .*: .*MB' | cut -d" " -f 3 | sed -e "s/MB//")

swap_size=$((disk_size*swap_ratio/100))
rootfs_size=$((disk_size-boot_size-swap_size))

rootfs_start=$((boot_size))
rootfs_end=$((rootfs_start+rootfs_size))
swap_start=$((rootfs_end))

# MMC devices are special in a couple of ways
# 1) they use a partition prefix character 'p'
# 2) they are detected asynchronously (need rootwait)
rootwait=""
part_prefix=""
if [ ! "${device#/dev/mmcblk}" = "${device}" ] || \
   [ ! "${device#/dev/nvme}" = "${device}" ]; then
    part_prefix="p"
    rootwait="rootwait"
fi

# USB devices also require rootwait
if [ -n `readlink /dev/disk/by-id/usb* | grep $TARGET_DEVICE_NAME` ]; then
    rootwait="rootwait"
fi

bootfs=${device}${part_prefix}1
rootfs=${device}${part_prefix}2
swap=${device}${part_prefix}3

echo "*****************"
echo "Boot partition size:   $boot_size MB ($bootfs)"
echo "Rootfs partition size: $rootfs_size MB ($rootfs)"
echo "Swap partition size:   $swap_size MB ($swap)"
echo "*****************"
echo "Deleting partition table on ${device} ..."
dd if=/dev/zero of=${device} bs=512 count=35

echo "Creating new partition table on ${device} ..."
parted ${device} mklabel gpt

echo "Creating boot partition on $bootfs"
parted ${device} mkpart boot fat32 0% $boot_size
parted ${device} set 1 boot on

echo "Creating rootfs partition on $rootfs"
parted ${device} mkpart root ext4 $rootfs_start $rootfs_end

echo "Creating swap partition on $swap"
parted ${device} mkpart swap linux-swap $swap_start 100%

parted ${device} print

partprobe

echo "Formatting $bootfs to vfat..."
mkfs.vfat $bootfs

echo "Formatting $rootfs to ext4..."
mkfs.ext4 $rootfs

echo "Formatting swap partition...($swap)"
mkswap $swap

mkdir /tgt_root
mkdir /src_root
mkdir -p /boot

# Handling of the target root partition
mount $rootfs /tgt_root
mount -o rw,loop,noatime,nodiratime /run/media/$1/$2 /src_root
echo "Copying rootfs files..."
cp -a /src_root/* /tgt_root
if [ -d /tgt_root/etc/ ] ; then
    boot_uuid=$(blkid -o value -s UUID ${bootfs})
    swap_part_uuid=$(blkid -o value -s PARTUUID ${swap})
    echo "/dev/disk/by-partuuid/$swap_part_uuid                swap             swap       defaults              0  0" >> /tgt_root/etc/fstab
    echo "UUID=$boot_uuid              /boot            vfat       defaults              1  2" >> /tgt_root/etc/fstab
    # We dont want udev to mount our root device while we're booting...
    if [ -d /tgt_root/etc/udev/ ] ; then
        echo "${device}" >> /tgt_root/etc/udev/mount.blacklist
    fi
fi

umount /src_root

# Handling of the target boot partition
mount $bootfs /boot
echo "Preparing boot partition..."
# A temporary solution for secure boot.
mv /tgt_root/boot/efi/* /tgt_root/boot/
rm /tgt_root/boot/efi/ -r
mv /tgt_root/boot/bzImage-4.9.49-yocto-standard /tgt_root/boot/bzImage
mv /tgt_root/boot/bzImage-4.9.49-yocto-standard.p7b /tgt_root/boot/bzImage.p7b
mv /tgt_root/boot/secure-core-image-initramfs-4.9.49-yocto-standard.cpio.gz /tgt_root/boot/initrd
mv /tgt_root/boot/secure-core-image-initramfs-4.9.49-yocto-standard.cpio.gz.p7b /tgt_root/boot/initrd.p7b
tar czf /tgt_root/boot.tar.gz -C /tgt_root/boot/ bzImage bzImage.p7b initrd initrd.p7b EFI/
tar xzf /tgt_root/boot.tar.gz -C /boot
rm /tgt_root/boot/* -rf
rm /tgt_root/boot.tar.gz

umount /tgt_root

umount /boot

sync

echo "Remove your installation media, and press ENTER"

read enter

echo "Rebooting..."
reboot -f