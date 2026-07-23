#!/bin/sh
set -eu


# WE MUST SPECIFY WHICH IMAGE WE WANT TO BUILD
if [ $# -lt 1 ]; then
	echo "Usage: $0 <target-name> [clean] [-l] [-c <compressor>>" >&2
	exit 1
fi
ZPOOL=$1
shift


# PATHS ARE BASED ON THIS BUILD SCRIPT AND SUBDIR FOR THE BUILD
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/${ZPOOL}"

if [ ! -d "$BUILD_DIR" ]; then
	echo "Error: target directory not found: $BUILD_DIR" >&2
	exit 1
fi


# LOAD A CONFIG FILE INSIDE THE SUBDIR
CONFIG_FILE="$BUILD_DIR/config.ini"
if [ -r "$CONFIG_FILE" ]; then
	while IFS='=' read -r _key _val; do
		case "$_key" in
			\#*|"") continue ;;           # skip comments and blank lines
			*) eval "${_key}=$_val" ;;       # key from config file becomes the variable name
		esac
	done < "$CONFIG_FILE"
fi


# APPLY DEFAULT CONFIGS IF NOT SPECIFIED IN SUBDIR
ARCH=${ARCH:-amd64}
VERSION_MAJOR=${VERSION_MAJOR:-15}
VERSION_MINOR=${VERSION_MINOR:-1}
IMAGE_SIZE=${IMAGE_SIZE:-7G}
ABI=FreeBSD:${VERSION_MAJOR}:$ARCH
OSVERSION=${VERSION_MAJOR}0${VERSION_MINOR}000

LABEL=$(echo "$ZPOOL" | tr '[:lower:]' '[:upper:]')

IMAGE=$SCRIPT_DIR/${ZPOOL}.img
LOG_FILE=$SCRIPT_DIR/${ZPOOL}.log
PARTITION=mbr
DEVICE=""
ROOT=""
POOL=""


# PARSE COMMAND LINE FOR OPTIONAL THINGS
COMPRESS=${compress:-"zstd-9"}
LOGGING=${log:-0}
while getopts :lc: opt; do
	case "$opt" in
		c) COMPRESS="${OPTARG#=}" ;;
		l) LOGGING=1 ;;
	esac
done


# PRETTY PRINT A STATUS LINE
println() {
	printf "\n\033[32m[\033[34m$LABEL\033[32m]\033[1;37m %s\033[0m\n" "$*"
}


# DISPLAY CONFIGURATION SUMMARY
println "Configuration"
printf "%-12s %s\n" "ARCH" "$ARCH"
printf "%-12s %s\n" "FreeBSD" "$VERSION_MAJOR.$VERSION_MINOR ($ABI)"
printf "%-12s %s\n" "OSVERSION" "$OSVERSION"
printf "%-12s %s\n" "IMAGE_SIZE" "$IMAGE_SIZE"
printf "%-12s %s\n" "COMPRESS" "$COMPRESS"
printf "%-12s %s\n" "PARTITION" "$PARTITION"


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
	[ -n "$ROOT" ] && safe_umount "$ROOT/boot/efi" || true
	[ -n "$POOL" ] && safe_export $POOL || true
	mdconfig -d -u $DEVICE 2>/dev/null || true
}


# ALLOW TO RUN PARTS OF THIS SCRIPT AUTOMAGICALLY
case "${1-}" in
	"clean")
		cleanup
		rm -f $IMAGE $IMAGE.zst
		exit 0
		;;
esac


# INSTALL OUR TRAPS LATE, IN CASE OF CUSTOM COMMAND ABOVE
trap cleanup EXIT INT TERM



# THE MAIN BODY OF THE SCRIPT BEGINS HERE
# WRAPPED IN A FUNCTION TO SUPPORT OUR LOGGER BETTER
build() {



# CREATE OUR TEMPORARY DIRECTORY
ROOT=$(mktemp -d -t "${ZPOOL}")
POOL=$(basename $ROOT)
ZROOT=$(dirname $ROOT)


# THINGS WE'LL NEED LATER ON IN THE SCRIPT
BUILDDEPS=$(sed 's/#.*//' "$BUILD_DIR/builddeps" | grep -v '^$' || true)
if [ -n "$BUILDDEPS" ]; then
	println "Installing local build dependencies"
	pkg install -y $BUILDDEPS
fi


# REMOVE THE OLD IMAGE FILES IF THEY STILL EXIST FROM A PREVIOUS BUILD
println "Cleaning up old image files"
[ -f "$IMAGE" ] && rm -v "$IMAGE"
[ -f "$IMAGE.zst" ] && rm -v "$IMAGE.zst"


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
echo ""
gpart show $DEVICE



# CREATE AND MOUNT THE ZPOOL/ZFS FILE SYSTEM
# MUST COME BEFORE FAT32 DUE TO MOUNT POINTS
# SMALL O: ZPOOL PROPERTIES (PAY ATTENTION!)
# BIG O: ZFS DATASET PROPERTIES
println "Creating zpool: $ZPOOL ($POOL) on ${DEVICE}${SLICE}2"
(set -x
zpool create -f \
  -o ashift=12 \
  -o autotrim=off \
  -O atime=off \
  -O recordsize=16M \
  -O compression=$COMPRESS \
  -O sync=disabled \
  -O checksum=sha256 \
  -t $POOL \
  -R $ZROOT \
  $ZPOOL "${DEVICE}${SLICE}2"

zpool set bootfs=$POOL $POOL
)
echo ''
zpool list $POOL


# CREATE AND MOUNT THE MSDOS FAT32 FILE SYSTEM
println "Creating FAT32 file system on ${DEVICE}${SLICE}1"
newfs_msdos -F 32 -S 512 -c 1 -L "EFIBOOT" "${DEVICE}${SLICE}1"


mkdir -p $ROOT/boot/efi
mount -t msdosfs "${DEVICE}${SLICE}1" "$ROOT/boot/efi"



# COPY RASPBERRY PI FIRMWARE TO OUR EFIBOOT PARTITION
println "Copying firmware to EFI partition"
cp -vR /usr/local/share/rpi-firmware/* $ROOT/boot/efi/



# CREATE A LOCAL CACHE DIR OUTSIDE OF THIS BUILDER
# THIS ALSO SPEEDS UP REBUILDING THE IMAGE FOR DEVELOPMENT
println "Setting up local package cache on host machine"
mkdir -p /var/cache/$ZPOOL/$ARCH/repos/
mkdir -p $ROOT/var/cache/
#mkdir -p $ROOT/var/db/pkg/
ln -s /var/cache/$ZPOOL/$ARCH/ $ROOT/var/cache/pkg
#ln -s /var/cache/$ZPOOL/$ARCH/repos/ $ROOT/var/db/pkg/repos



# PREPARE FREEBSD PKG KEYS
println "Setting up package repositories"
mkdir -p $ROOT/usr/share/keys/pkg/trusted
cp -v /usr/share/keys/pkg/trusted/* $ROOT/usr/share/keys/pkg/trusted/

# PREPARE FREEBSD PKG-BASE KEYS
mkdir -p $ROOT/usr/share/keys/pkgbase-15/trusted
cp -v /usr/share/keys/pkgbase-15/trusted/* $ROOT/usr/share/keys/pkgbase-15/trusted/

# PREPARE FREEBSD PKG CONFIGURATION
mkdir -p $ROOT/etc/pkg
cp -v $BUILD_DIR/etc/pkg/FreeBSD.conf $ROOT/etc/pkg/



# WARNING, DON'T MOVE THIS EARLIER IN THE SCRIPT
# OR ELSE YOU RISK BREAKING YOUR ENTIRE HOST OPERATING SYSTEM
METALOG=$ROOT/$ZPOOL.metalog
export METALOG
export ABI
export OSVERSION


# INSTALL PACKAGES
println "Installing FreeBSD pkgbase and user packages"
PACKAGES=$(sed 's/#.*//' "$BUILD_DIR/pkglist")
[ -n "$PACKAGES" ] || { println "No packages to install!"; exit 1; }
pkg -r $ROOT -o REPOS_DIR=$ROOT/etc/pkg install -y $PACKAGES


# STORE PACKAGES/VERSIONS USED FOR THE BUILD IN AN AUDIT LOG
pkg -r $ROOT query '%n-%v' > "$SCRIPT_DIR/$ZPOOL.manifest"


# FIX FILE/FOLDER PERMISSIONS FOR CUSTOM USERS
println "Fixing file and folder permissions"
"$SCRIPT_DIR/uid.sh" "$METALOG" "$ROOT"
rm $METALOG


# BUILDING UBOOT ENV FILE
println "Building uboot file"
(set -x
mkenvimage -s 16384 -o "$BUILD_DIR/boot/efi/uboot.env" "$BUILD_DIR/boot/efi/uboot.txt"
)


# INSTALL THE OVERLAY FILESYSTEM
println "Installing $ZPOOL files"
touch "$BUILD_DIR/var/db/last_time"
for f in "$BUILD_DIR"/*; do
	[ ! -d "$f" ] && continue
	cp -vRP "$f" $ROOT
done


# GENERATE VERSION FILE WITH BUILD DATE
println "Generating version file"
date '+%Y-%m-%d' > $ROOT/etc/version
cat $ROOT/etc/version



# INSTALL THE BOOTLOADER
println "Installing the FreeBSD boot loader"
mkdir -p $ROOT/boot/efi/EFI/BOOT/
cp -v $ROOT/boot/loader.efi $ROOT/boot/efi/EFI/BOOT/bootaa64.efi


# CREATE ZPOOL SCRUB/TRIM CRONJOB
println "Creating zpool scrub and trim cron jobs"
mkdir -p $ROOT/etc/cron.d/
echo "@daily	root	/sbin/zpool scrub $ZPOOL" > $ROOT/etc/cron.d/$ZPOOL
echo "@weekly	root	/sbin/zpool trim $ZPOOL" >> $ROOT/etc/cron.d/$ZPOOL
cat $ROOT/etc/cron.d/$ZPOOL


# CLEANUP TEMPORARY CACHE SYMLINK
println "Unlinking package cache"
rm $ROOT/var/cache/pkg


# SET ZFS PROPERTIES TO SOMETHING SANE FOR NORMAL USAGE
println "Setting 'sane' zpool options for daily usage"
(set -x
zfs set \
  compression=on \
  recordsize=128k \
  sync=standard \
  $POOL
)


# TAKE FACTORY RESET SNAPSHOT
println "Taking 'factory reset' snapshot"
(set -x
zfs snapshot $POOL@factory
)


# SHOW ZPOOL HISTORY AS A FINAL AUDITING STEP
println "zpool history"
zpool history $POOL
#zpool history -il $POOL


# CLEANUP ALL THE TEMPORARY STUFF WE DID
cleanup
trap - EXIT INT TERM


# CREATE A COMPRESSED DEPLOYABLE IMAGE
println "Compressing final binary disk image"
zstd --fast=1 -T0 $IMAGE -o $IMAGE.zst


# END OUR CUSTOM BUILD FUNCTION
}


# LOG STUFF TO FILE AND CONSOLE BOTH AT THE SAME TIME
# FILTER OUT COLORS FROM LOG FILE THOUGH
if [ "$LOGGING" -eq 1 ]; then
	ESC=$(printf '\033')
	> "$LOG_FILE"
	build  2>&1 | tee /dev/tty | sed -e "s/${ESC}\[[0-9;]*[mK]//g" > "$LOG_FILE"

# JUST RUN THE SCRIPT NORMALLY IF NOT IN "LOGGING" MODE
else
	build
fi
