#!/bin/sh


SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGE=$SCRIPT_DIR/stratipi.img

ABI=FreeBSD:15:aarch64
OSVERSION=1500000
ZPOOL=stratipi-test

export ABI
export OSVERSION


# UNMOUNT MSDOS FAST32 BOOT PARTITION
if mount | grep -q "on /$ZPOOL/boot/efi "; then
	umount "/$ZPOOL/boot/efi"
fi


# DESTROY ZPOOL IF IT ALREADY EXISTS
if zpool list $ZPOOL >/dev/null 2>&1; then
	zpool destroy $ZPOOL
fi


# DESTROY THE OLD MEMORY DEVICE(s) FOR THE IMAGE FILE
DEVICE=$(mdconfig -l -f $IMAGE)
for DEV in $DEVICE; do
	mdconfig -d -u $DEV
done


# CREATE A NEW MEMORY DEVICE FOR THE IMAGE FILE
truncate -s 7G $IMAGE
DEVICE=$(mdconfig -a -t vnode -f $IMAGE)


# RECREATE PARTITION TABLE FROM SCRATCH
gpart destroy -F $DEVICE
gpart create -s mbr $DEVICE
gpart add -t fat32 -s 100M $DEVICE
gpart add -t freebsd $DEVICE


# CREATE AND MOUNT THE ZPOOL/ZFS FILE SYSTEM
zpool create \
  -o ashift=12 \
  -O recordsize=16M \
  -O compression=zstd \
  $ZPOOL "/dev/${DEVICE}s2"


# CREATE AND MOUNT THE MSDOS FAT32 FILE SYSTEM
newfs_msdos -F 32 -c 1 "/dev/${DEVICE}s1"
mkdir -p /$ZPOOL/boot/efi
mount -t msdosfs "/dev/${DEVICE}s1" "/$ZPOOL/boot/efi"



# PREPARE FREEBSD PKG KEYS
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

# INSTALL PACKAGES
pkg -r /$ZPOOL -o REPOS_DIR=/$ZPOOL/etc/pkg install -y \
  FreeBSD-set-minimal \
  FreeBSD-kernel-generic


# SET ZFS PROPERTIES TO SOMETHING SANE FOR NORMAL USAGE
zfs set recordsize=128k $ZPOOL
