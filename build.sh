#!/bin/sh
set -eu


# WE MUST SPECIFY WHICH IMAGE WE WANT TO BUILD
if [ $# -lt 1 ]; then
	echo "Usage: $0 <target-name> [clean] [-l] [-c <compressor>>" >&2
	exit 1
fi
export PROJECT=$1
shift



# PATHS ARE BASED ON THIS BUILD SCRIPT AND PROJECT FOR THIS BUILD
export SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export BUILD_DIR="$SCRIPT_DIR/${PROJECT}"

if [ ! -d "$BUILD_DIR" ]; then
	echo "Error: target directory not found: $BUILD_DIR" >&2
	exit 1
fi



# PULL FULL DEPENDENCY TREE FOR THIS PROJECT
DEPS=$($SCRIPT_DIR/dependency.sh "$PROJECT")


# ITERATE OVER DEPENDENCIES, AND DO "SOMETHING" WITH THEM
for_dep() {
	_block="$1"; shift
	if [ -n "$DEPS" ]; then
		while IFS= read -r proj; do
			PROJECT="$proj"
			PROJECT_DIR="$SCRIPT_DIR/$proj"
			export PROJECT PROJECT_DIR
			eval "$_block" || return 1
		done <<EOF
$DEPS
EOF
	fi
}


# RUN A SCRIPT IF IT EXISTS, FAILING ON NON-ZERO EXIT CODE
run_hook() {
	if [ -f "$1" ]; then
		"$@"
		return $?
	fi
	return 0
}


# LOAD CONFIG FILE FROM EACH PROJECT/DEPENDENCY
for_dep 'if [ -r "$PROJECT_DIR/config" ]; then
	while IFS="=" read -r _key _val; do
		case "$_key" in
			\#*|"") continue ;;
			*) eval "${_key}=$_val" ;;
		esac
	done < "$PROJECT_DIR/config"
fi'



# APPLY DEFAULT CONFIGS IF NOT SPECIFIED IN PROJECTS
ARCH=${ARCH:-amd64}
VERSION_MAJOR=${VERSION_MAJOR:-15}
VERSION_MINOR=${VERSION_MINOR:-1}
IMAGE_SIZE=${IMAGE_SIZE:-7G}
ABI=FreeBSD:${VERSION_MAJOR}:$ARCH
OSVERSION=${VERSION_MAJOR}0${VERSION_MINOR}000

LABEL=$(echo "$PROJECT" | tr '[:lower:]' '[:upper:]')

FREEBSD_RELEASE="releng/$VERSION_MAJOR.$VERSION_MINOR"
GITHUB_BASE="https://raw.githubusercontent.com/freebsd/freebsd-src/$FREEBSD_RELEASE"

IMAGE=$SCRIPT_DIR/${PROJECT}.img
LOG_FILE=$SCRIPT_DIR/${PROJECT}.log
PARTITION=${PARTITION:-gpt}
EFI_SIZE=${EFI_SIZE:-100M}
GPART_ALIGN=${GPART_ALIGN:-1M}
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
printf "%-12s %s\n" "GPART_ALIGN" "$GPART_ALIGN"



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
ROOT=$(mktemp -d -t "${PROJECT}")
POOL=$(basename $ROOT)
ZROOT=$(dirname $ROOT)



# COLLECT HOST-LEVEL ITEMS FROM EVERY DEPENDENCY PROJECT (topologically ordered)
BUILDDEPS=""
PKG_LIST=""

for_dep 'if [ -f "$PROJECT_DIR/builddeps" ]; then
	_deps=$(sed "s/#.*//" "$PROJECT_DIR/builddeps" | grep -v "^$" || true)
	if [ -n "$_deps" ]; then
		BUILDDEPS="$BUILDDEPS $_deps"
	fi
fi' || exit 1

for_dep 'if [ -f "$PROJECT_DIR/pkglist" ]; then
	_pkgl=$(sed "s/#.*//" "$PROJECT_DIR/pkglist" | grep -v "^$" || true)
	if [ -n "$_pkgl" ]; then
		PKG_LIST="$PKG_LIST $_pkgl"
	fi
fi' || exit 1

if [ -n "$BUILDDEPS" ]; then
	println "Installing build dependencies"
	(set -x
	pkg install -y $BUILDDEPS
	)
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
	gpart add -a $GPART_ALIGN -t fat32 -s $EFI_SIZE $DEVICE
	gpart add -a $GPART_ALIGN -t freebsd $DEVICE
	SLICE=s
elif [ "$PARTITION" = "gpt" ]; then
	gpart add -a $GPART_ALIGN -t ms-basic-data -s $EFI_SIZE -l "EFIBOOT" $DEVICE
	gpart add -a $GPART_ALIGN -t freebsd-zfs -l "${LABEL}" $DEVICE
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
println "Creating zpool: $PROJECT ($POOL) on ${DEVICE}${SLICE}2"
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
  $PROJECT "${DEVICE}${SLICE}2"

zpool set bootfs=$POOL $POOL
)
echo ''
zpool list $POOL



# CREATE AND MOUNT THE MSDOS FAT32 FILE SYSTEM
println "Creating FAT32 file system on ${DEVICE}${SLICE}1"
newfs_msdos -F 32 -S 512 -c 1 -L "EFIBOOT" "${DEVICE}${SLICE}1"



# CREATE PLACE TO DROP UEFI BOOT FILES
mkdir -p $ROOT/boot/efi
mount -t msdosfs "${DEVICE}${SLICE}1" "$ROOT/boot/efi"



# COPY PROJECT EFI FILES INTO BOOT PARTITION
if [ -n "$EFI_FILES" ]; then
	println "Copying EFI files to boot partition"
	cp -vR $EFI_FILES/* $ROOT/boot/efi/
fi



# CREATE A LOCAL CACHE DIR OUTSIDE OF THIS BUILDER
# THIS ALSO SPEEDS UP REBUILDING THE IMAGE FOR DEVELOPMENT
println "Setting up local package cache on host machine"
mkdir -p /var/cache/$PROJECT/$ARCH/repos/
mkdir -p $ROOT/var/cache/
#mkdir -p $ROOT/var/db/pkg/
ln -s /var/cache/$PROJECT/$ARCH/ $ROOT/var/cache/pkg
#ln -s /var/cache/$PROJECT/$ARCH/repos/ $ROOT/var/db/pkg/repos



# PREPARE FREEBSD PKG KEYS
println "Setting up package repositories"
mkdir -p $ROOT/usr/share/keys/pkg/trusted
fetch -o "$ROOT/usr/share/keys/pkg/trusted/pkg.freebsd.org.2013102301" \
  "$GITHUB_BASE/share/keys/pkg/trusted/pkg.freebsd.org.2013102301"

# PREPARE FREEBSD PKG-BASE KEYS
mkdir -p $ROOT/usr/share/keys/pkgbase-$VERSION_MAJOR/trusted
for key in awskms backup-signing; do
	fetch -o "$ROOT/usr/share/keys/pkgbase-$VERSION_MAJOR/trusted/${key}-$VERSION_MAJOR" \
		"$GITHUB_BASE/share/keys/pkgbase-$VERSION_MAJOR/trusted/${key}-$VERSION_MAJOR"
done

# PREPARE FREEBSD PKG CONFIGURATION
mkdir -p $ROOT/etc/pkg
cp -v $BUILD_DIR/etc/pkg/FreeBSD.conf $ROOT/etc/pkg/



# WARNING, DON'T MOVE THIS EARLIER IN THE SCRIPT
# OR ELSE YOU RISK BREAKING YOUR ENTIRE HOST OPERATING SYSTEM
METALOG=$ROOT/$PROJECT.metalog
export METALOG
export ABI
export OSVERSION
export ROOT
export ZROOT
export POOL
export DEVICE



# RUN PRE-PACKAGE HOOK FOR EVERY DEPENDENCY
for_dep 'run_hook "$PROJECT_DIR/pre-package.sh"' || exit 1


# INSTALL PACKAGES FOR EVERY DEPENDENCY
println "Installing FreeBSD pkgbase and user packages"
[ -n "$PKG_LIST" ] || { println "No packages to install!"; exit 1; }
pkg -r $ROOT -o REPOS_DIR=$ROOT/etc/pkg install -y $PKG_LIST


# STORE PACKAGES/VERSIONS USED FOR THE BUILD IN AN AUDIT LOG
pkg -r $ROOT query '%n-%v' > "$SCRIPT_DIR/$PROJECT.manifest"


# FIX FILE/FOLDER PERMISSIONS FOR CUSTOM USERS
println "Fixing file and folder permissions"
"$SCRIPT_DIR/uid.sh" "$METALOG" "$ROOT"
rm $METALOG


# RUN POST-PACKAGE HOOK FOR EVERY DEPENDENCY
for_dep 'run_hook "$PROJECT_DIR/post-package.sh"' || exit 1




# RUN PRE-INSTALL HOOK FOR EVERY DEPENDENCY
for_dep 'run_hook "$PROJECT_DIR/pre-install.sh"' || exit 1



# INSTALL THE OVERLAY FILESYSTEM
println "Installing $PROJECT files"
for_dep 'for f in "$PROJECT_DIR"/*; do
	[ ! -d "$f" ] && continue # ONLY DIRECTORIES
	cp -vRP "$f" $ROOT
done'
touch "$BUILD_DIR/var/db/last_time"



# GENERATE VERSION FILE WITH BUILD DATE
println "Generating version file"
date '+%Y-%m-%d' > $ROOT/etc/version
cat $ROOT/etc/version



# INSTALL THE BOOTLOADER
println "Installing the FreeBSD boot loader"
mkdir -p $ROOT/boot/efi/EFI/BOOT/

case "$ARCH" in
	aarch64)	cp -v $ROOT/boot/loader.efi $ROOT/boot/efi/EFI/BOOT/bootaa64.efi;;
	amd64)		cp -v $ROOT/boot/loader.efi $ROOT/boot/efi/EFI/BOOT/BOOTX64.EFI;;
esac



# RUN POST-INSTALL HOOK FOR EVERY DEPENDENCY
for_dep 'run_hook "$PROJECT_DIR/post-install.sh"' || exit 1



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
