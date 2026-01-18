#!/bin/sh
set -e


SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
IMAGE=$SCRIPT_DIR/stratipi.img
#IMAGE_SIZE=7G
IMAGE_SIZE=3G  # temporary while debugging initially to build faster


ARCH=aarch64
ABI=FreeBSD:15:$ARCH
OSVERSION=1500000
ZPOOL=stratipi


# UNMOUNT MSDOS FAST32 BOOT PARTITION
if mount | grep -q "on /$ZPOOL/boot/efi "; then
	umount "/$ZPOOL/boot/efi"
fi


# DESTROY ZPOOL IF IT ALREADY EXISTS
if zpool list $ZPOOL >/dev/null 2>&1; then
	zpool destroy $ZPOOL
fi


# DESTROY THE OLD MEMORY DEVICE(s) FOR THE IMAGE FILE
set +e
DEVICE=$(mdconfig -l -f $IMAGE)
set -e
for DEV in $DEVICE; do
	mdconfig -d -u $DEV
done


# CREATE A NEW MEMORY DEVICE FOR THE IMAGE FILE
truncate -s $IMAGE_SIZE $IMAGE
DEVICE=$(mdconfig -a -t vnode -f $IMAGE)


# RECREATE PARTITION TABLE FROM SCRATCH
gpart destroy -F $DEVICE || true
gpart create -s mbr $DEVICE
gpart add -t fat32 -s 100M $DEVICE
gpart add -t freebsd $DEVICE


# CREATE AND MOUNT THE ZPOOL/ZFS FILE SYSTEM
zpool create -f \
  -o ashift=12 \
  -o autoexpand=on \
  -o autotrim=on \
  -O recordsize=16M \
  -O compression=zstd \
  $ZPOOL "/dev/${DEVICE}s2"


# CREATE AND MOUNT THE MSDOS FAT32 FILE SYSTEM
newfs_msdos -F 32 -c 1 -L "STRATIPI" "/dev/${DEVICE}s1"
mkdir -p /$ZPOOL/boot/efi
mount -t msdosfs "/dev/${DEVICE}s1" "/$ZPOOL/boot/efi"


# INSTALL THE RASPBERRY PI FIRMWARE LOCALLY
# AND COPY THE CONTENTS TO OUR MSDOS PARTITION
pkg install -y rpi-firmware
cp -r /usr/local/share/rpi-firmware/* /$ZPOOL/boot/efi/



# CREATE A LOCAL CACHE DIR OUTSIDE OF STRATIPI BUILDER
# THIS ALSO SPEEDS UP REBUILDING STRATIPI FOR DEVELOPMENT
mkdir -p /var/cache/stratipi/$ARCH/repos/
mkdir -p /$ZPOOL/var/cache/
#mkdir -p /$ZPOOL/var/db/pkg/
ln -s /var/cache/stratipi/$ARCH/ /$ZPOOL/var/cache/pkg
#ln -s /var/cache/stratipi/$ARCH/repos/ /$ZPOOL/var/db/pkg/repos



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


# WARNING, DON'T MOVE THIS EARLIER IN THE SCRIPT
# OR ELSE YOU RISK BREAKING YOUR ENTIRE OPERATING SYSTEM
export ABI
export OSVERSION


# INSTALL PACKAGES
PACKAGES=$(sed 's/#.*//' pkglist)
pkg -r /$ZPOOL -o REPOS_DIR=/$ZPOOL/etc/pkg install -y $PACKAGES


# INSTALL STRATIPI
for f in $SCRIPT_DIR/*; do
    [ $(basename -- "$f") = "stratipi.img" ] && continue
    [ $(basename -- "$f") = "build.sh" ] && continue
    [ $(basename -- "$f") = "pkglist" ] && continue
    cp -r "$f" /$ZPOOL/
done


# INSTALL THE BOOTLOADER
mkdir -p /$ZPOOL/boot/efi/EFI/BOOT/
cp /$ZPOOL/boot/loader.efi /$ZPOOL/boot/efi/EFI/BOOT/bootaa64.efi


# CREATE ZPOOL SCRUB CRONJOB
mkdir -p /$ZPOOL/etc/cron.d/
echo "@daily	root	/sbin/zpool scrub $ZPOOL" > /$ZPOOL/etc/cron.d/scrub



# CLEANUP TEMPORARY CACHE SYMLINK
rm /$ZPOOL/var/cache/pkg


# SET ZFS PROPERTIES TO SOMETHING SANE FOR NORMAL USAGE
zfs set recordsize=128k $ZPOOL
