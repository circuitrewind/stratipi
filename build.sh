#!/bin/sh
set -e


ZPOOL=stratipi
LABEL=STRATIPI
IMAGE_SIZE=2G
ARCH=aarch64
ABI=FreeBSD:15:$ARCH
OSVERSION=1500000

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGE=$SCRIPT_DIR/${ZPOOL}.img
PARTITION=mbr


println() {
	printf "\n[$LABEL] %s\n" "$*"
}

# THINGS WE'LL NEED LATER ON IN THE SCRIPT
println "Installing local build dependencies"
pkg install -y rpi-firmware


# UNMOUNT MSDOS FAST32 BOOT PARTITION
if mount | grep -q "on /$ZPOOL/boot/efi "; then
	println "Unmounting: /$ZPOOL/boot/efi"
	umount "/$ZPOOL/boot/efi"
fi


# DESTROY ZPOOL IF IT ALREADY EXISTS
if zpool list $ZPOOL >/dev/null 2>&1; then
	println "Unmounting: $ZPOOL"
	zpool destroy $ZPOOL
fi


# DESTROY THE OLD MEMORY DEVICE(s) FOR THE IMAGE FILE
set +e
DEVICE=$(mdconfig -l -f $IMAGE)
set -e
for DEV in $DEVICE; do
	println "Destroying device: $DEV"
	mdconfig -d -u $DEV
done


# REMOVE THE OLD IMAGE FILE IF IT STILL EXISTS
set +e
rm $IMAGE
rm $IMAGE.zst
set -e


# CREATE A NEW MEMORY DEVICE FOR THE IMAGE FILE
println "Creating $IMAGE of size $IMAGE_SIZE"
truncate -s $IMAGE_SIZE $IMAGE
DEVICE=/dev/$(mdconfig -a -t vnode -f $IMAGE)
println "New Device: $DEVICE"


# RECREATE PARTITION TABLE FROM SCRATCH
println "Creating $PARTITION partition table on $DEVICE"
gpart destroy -F $DEVICE || true
gpart create -s $PARTITION $DEVICE
if [ "$PARTITION" = "mbr" ]; then
	gpart add -a 1M -t fat32 -s 100M $DEVICE
	gpart add -a 1M -t freebsd $DEVICE
	SLICE=s
elif [ "$PARTITION" = "gpt" ]; then
	gpart add -a 1M -t ms-basic-data -s 100M -l "EFIBOOT" $DEVICE
	gpart add -a 1M -t freebsd-zfs -l "${LABEL}" $DEVICE
	SLICE=p
else
	println "Unknown Partition Table Type"
	exit 1
fi




# CREATE AND MOUNT THE ZPOOL/ZFS FILE SYSTEM
# MUST COME BEFORE FAT32 DUE TO MOUNT POINTS
println "Creating zpool: $ZPOOL on ${DEVICE}${SLICE}2"
zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -O recordsize=16M \
  -O compression=zstd \
  $ZPOOL "${DEVICE}${SLICE}2"

#  -o autoexpand=on \


# CREATE AND MOUNT THE MSDOS FAT32 FILE SYSTEM
println "Creating FAT32 file system on ${DEVICE}${SLICE}1"
newfs_msdos -F 32 -S 512 -c 1 -L "EFIBOOT" "${DEVICE}${SLICE}1"


mkdir -p /$ZPOOL/boot/efi
mount -t msdosfs "${DEVICE}${SLICE}1" "/$ZPOOL/boot/efi"



# COPY RASPBERRY PI FIRMWARE TO OUR EFIBOOT PARTITION
println "Copying firmware to EFI partition"
cp -r /usr/local/share/rpi-firmware/* /$ZPOOL/boot/efi/



# CREATE A LOCAL CACHE DIR OUTSIDE OF STRATIPI BUILDER
# THIS ALSO SPEEDS UP REBUILDING STRATIPI FOR DEVELOPMENT
println "Setting up local package cache on host machine"
mkdir -p /var/cache/stratipi/$ARCH/repos/
mkdir -p /$ZPOOL/var/cache/
#mkdir -p /$ZPOOL/var/db/pkg/
ln -s /var/cache/stratipi/$ARCH/ /$ZPOOL/var/cache/pkg
#ln -s /var/cache/stratipi/$ARCH/repos/ /$ZPOOL/var/db/pkg/repos



# PREPARE FREEBSD PKG KEYS
println "Setting up package repositories"
mkdir -p /$ZPOOL/usr/share/keys/pkg/trusted
cp /usr/share/keys/pkg/trusted/* /$ZPOOL/usr/share/keys/pkg/trusted/

# PREPARE FREEBSD PKG-BASE KEYS
mkdir -p /$ZPOOL/usr/share/keys/pkgbase-15/trusted
cp /usr/share/keys/pkgbase-15/trusted/* /$ZPOOL/usr/share/keys/pkgbase-15/trusted/

# PREPARE FREEBSD PKG CONFIGURATION
mkdir -p /$ZPOOL/etc/pkg
cp /etc/pkg/FreeBSD.conf /$ZPOOL/etc/pkg
sed -i '' 's/: no/: yes/' /$ZPOOL/etc/pkg/FreeBSD.conf
sed -i '' 's/quarterly"/latest"/' /$ZPOOL/etc/pkg/FreeBSD.conf



# WARNING, DON'T MOVE THIS EARLIER IN THE SCRIPT
# OR ELSE YOU RISK BREAKING YOUR ENTIRE OPERATING SYSTEM
export ABI
export OSVERSION


# INSTALL PACKAGES
println "Installing FreeBSD pkgbase and user packages"
PACKAGES=$(sed 's/#.*//' pkglist)
pkg -r /$ZPOOL -o REPOS_DIR=/$ZPOOL/etc/pkg install -y $PACKAGES


# INSTALL STRATIPI
println "Installer $ZPOOL files"
touch var/db/last_time
for f in $SCRIPT_DIR/*; do
    [ $(basename -- "$f") = "stratipi.img" ] && continue
    [ $(basename -- "$f") = "build.sh" ] && continue
    [ $(basename -- "$f") = "pkglist" ] && continue
    cp -r "$f" /$ZPOOL/
done



# INSTALL THE BOOTLOADER
println "Installing the FreeBSD boot loader"
mkdir -p /$ZPOOL/boot/efi/EFI/BOOT/
cp /$ZPOOL/boot/loader.efi /$ZPOOL/boot/efi/EFI/BOOT/bootaa64.efi


# CREATE ZPOOL SCRUB CRONJOB
println "Creating daily zpool scrub cron job"
mkdir -p /$ZPOOL/etc/cron.d/
echo "@daily	root	/sbin/zpool scrub $ZPOOL" > /$ZPOOL/etc/cron.d/scrub



# CLEANUP TEMPORARY CACHE SYMLINK
println "Unlinking package cache"
rm /$ZPOOL/var/cache/pkg


# SET ZFS PROPERTIES TO SOMETHING SANE FOR NORMAL USAGE
println "Setting 'sane' zpool options for daily usage"
zfs set recordsize=128k $ZPOOL


# UNMOUNT THE IMAGE
println "Unmounting partitions"
umount "/$ZPOOL/boot/efi"
zpool export $ZPOOL
mdconfig -d -u $DEVICE


# CREATE A COMPRESSED DEPLOYABLE IMAGE
println "Compressing final binary disk image"
zstd --fast=1 -T0 $IMAGE -o $IMAGE.zst
