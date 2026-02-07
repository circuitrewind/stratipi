#!/bin/sh
set -eu


ZPOOL=stratipi
LABEL=STRATIPI
IMAGE_SIZE=2G
ARCH=aarch64
ABI=FreeBSD:15:$ARCH
OSVERSION=1500000

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGE=$SCRIPT_DIR/${ZPOOL}.img
PARTITION=mbr
DEVICE=""


# PRETTY PRINT A STATUS LINE
println() {
	printf "\n\033[32m[\033[34m$LABEL\033[32m]\033[1;37m %s\033[0m\n" "$*"
}


# SAFER WAY TO UNMOUNT AND BAIL ON ERROR
safe_umount() {
	if mount | awk '{print $3}' | grep -qx "$1"; then
		println "Unmounting: $1"
		umount "$1" || {
			echo "ERROR: failed to unmount $1" >&2
			exit 1
		}
	fi
}


# SAFER WAY TO ZPOOL EXPORT AND BAIL ON ERROR
safe_export() {
	if zpool list -H -o name 2>/dev/null | grep -qx "$1"; then
		println "Exporting zpool: $1"
		zpool export "$1" || {
			echo "ERROR: failed to export zpool $1" >&2
			zpool status "$1" >&2 || true
			exit 1
		}
	fi
}


# DO ALL THE CLEANUP STUFF
cleanup() {
	println "Running cleanup job ..."
	safe_umount "/$ZPOOL/boot/efi" || true
	safe_export $ZPOOL || true
	mdconfig -d -u $DEVICE 2>/dev/null || true
}


# ALLOW TO RUN PARTS OF THIS SCRIPT AUTOMAGICALLY
case "${1-}" in
    "clean")
        cleanup
        exit 0
        ;;
esac


# INSTALL OUR TRAPS LATE, IN CASE OF CUSTOM COMMAND ABOVE
trap cleanup EXIT INT TERM


# THINGS WE'LL NEED LATER ON IN THE SCRIPT
println "Installing local build dependencies"
pkg install -y rpi-firmware


# REMOVE THE OLD IMAGE FILE IF IT STILL EXISTS
rm $IMAGE || true
rm $IMAGE.zst || true


# CREATE A NEW MEMORY DEVICE FOR THE IMAGE FILE
println "Creating $IMAGE of size $IMAGE_SIZE"
truncate -s $IMAGE_SIZE $IMAGE
DEVICE=/dev/$(mdconfig -a -t vnode -f $IMAGE)
println "New Memory Device: $DEVICE"


# RECREATE PARTITION TABLE FROM SCRATCH
println "Creating $PARTITION partition table on $DEVICE"
gpart create -s $PARTITION $DEVICE
if [ "$PARTITION" = "mbr" ]; then
	gpart add -a 4M -t fat32 -s 100M $DEVICE
	gpart add -a 4M -t freebsd $DEVICE
	SLICE=s
elif [ "$PARTITION" = "gpt" ]; then
	gpart add -a 4M -t ms-basic-data -s 100M -l "EFIBOOT" $DEVICE
	gpart add -a 4M -t freebsd-zfs -l "${LABEL}" $DEVICE
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
  -O atime=off \
  -O recordsize=16M \
  -O compression=zstd-9 \
  -O sync=disabled \
  $ZPOOL "${DEVICE}${SLICE}2"
zpool list $ZPOOL


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
METALOG=/$ZPOOL/$ZPOOL.metalog
export METALOG
export ABI
export OSVERSION


# INSTALL PACKAGES
println "Installing FreeBSD pkgbase and user packages"
PACKAGES=$(sed 's/#.*//' $SCRIPT_DIR/pkglist)
[ -n "$PACKAGES" ] || { println "No packages to install!"; exit 1; }
pkg -r /$ZPOOL -o REPOS_DIR=/$ZPOOL/etc/pkg install -y $PACKAGES


# STORE PACKAGES/VERSIONS USED FOR THE BUILD IN AN AUDIT LOG
pkg -r /$ZPOOL query '%n-%v' > $SCRIPT_DIR/pkg-manifest.txt


# FIX FILE/FOLDER PERMISSIONS FOR CUSTOM USERS
println "Fixing file and folder permissions"
$SCRIPT_DIR/uid.sh $METALOG /$ZPOOL
rm $METALOG


# INSTALL STRATIPI
println "Installing $ZPOOL files"
touch $SCRIPT_DIR/var/db/last_time
for f in $SCRIPT_DIR/*; do
    [ -f $(basename -- "$f") ] && continue
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
zfs set \
  compression=on \
  recordsize=128k \
  sync=standard \
  $ZPOOL


# CLEANUP ALL THE TEMPORARY STUFF WE DID
cleanup
trap - EXIT INT TERM


# CREATE A COMPRESSED DEPLOYABLE IMAGE
println "Compressing final binary disk image"
zstd --fast=1 -T0 $IMAGE -o $IMAGE.zst
