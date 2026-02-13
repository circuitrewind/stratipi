#!/bin/sh


# INITIAL CONFIG
DISK="/dev/mmcsd0"
SLICE=2
VDEV="${DISK}s${SLICE}"


# DYNAMICALLY GET ZPOOL NAME
ZPOOL=$(zpool status -P | awk -v d="${VDEV}" '
	/^  pool:/ {p=$2}
	$1 == d { print p; exit }
')


# FAILED TO FIND POOL, BAIL INSTANTLY
if [ -z "$ZPOOL" ]; then
    echo "Unable to determine ZFS pool for ${VDEV}"
    exit 1
fi


# BAIL INSTANTLY IF OUR "EXPANDED" FLAG IS SET
if zpool get -H -o value org.firstboot:expanded "$ZPOOL" 2>/dev/null | grep -q yes; then
    echo "$DISK already expanded; skipping"
    exit 0
fi


# BAIL IF WE'RE NOT IN A SINGLE-DISK ENVIRONMENT
VDEVS=$(zpool status "$ZPOOL" | awk '
	$1 == "config:" { in=1; next }
	in && $1 ~ /^[a-z]/ { print $1 }
')
if echo "$VDEVS" | grep -Eq '(mirror|raid)'; then
	echo "Non-single-disk vdev detected; refusing auto-expand"
	exit 0
fi


# ENSURE WE'RE ONLY DEALING WITH THE LAST PARTITION
LAST_PART=$(gpart show "$DISK" | awk '
	/^[[:space:]]*[0-9]/ && $3 ~ /^[0-9]+$/ {
		end = $1 + $2
		if (end > max) {
			max = end
			last = $3
		}
	}
	END { print last }
')
if [ "$LAST_PART" != "$SLICE" ]; then
    echo "Slice $SLICE is not the final partition; refusing resize"
    exit 0
fi


# DYNAMICALLY PULL IN THE SECTOR SIZE
SECTOR_SIZE=$(diskinfo -v "$DISK" | awk 'NR==2 {print $1}')
if [ -z "$SECTOR_SIZE" ]; then
    echo "Failed to get sector size for $DISK"
    exit 1
fi


# GET THE EXISTING DISK PARTITION GEOMETRY
SLICE_INFO=$(gpart show -l $DISK | awk -v slice="$SLICE" '
  /^[[:space:]]*[0-9]/ {          # lines starting with a number (skip header/free)
    if ($3 == slice) {            # column 3 is the slice number
      print $1, $2                # start, size
      exit
    }
  }
')
if [ -z "$SLICE_INFO" ]; then
	echo "Slice $SLICE not found on $DISK"
	exit 1
fi


# PARSE OUT THE SLICE PARTITION GEOMERY
SLICE_START=$(echo "$SLICE_INFO" | awk '{print $1}')
SLICE_SIZE=$(echo "$SLICE_INFO" | awk '{print $2}')
SLICE_END=$(( SLICE_START + SLICE_SIZE ))
SLICE_MB=$(( SLICE_SIZE * SECTOR_SIZE / 1024 / 1024 ))

# PARSE OUT THE DISK GEOMETRY
DISK_LAST=$(gpart show "$DISK" | awk '/=>/ {print $2 + $3 - 1; exit}')
DISK_MB=$(( DISK_LAST * SECTOR_SIZE / 1024 / 1024 ))


echo "Disk: $DISK"
echo "Sector Size: $SECTOR_SIZE bytes"
echo "Disk Sector Count: $DISK_LAST (${DISK_MB}MB)"
echo "Slice Sector Start: $SLICE_START"
echo "Slice Sector Count: $SLICE_SIZE (${SLICE_MB}MB)"



# NOW LETS DO MATH BECAUSE ITS HARD, OKAY !?
BUFFER_MB=2
BUFFER_SECTORS=$(( BUFFER_MB * 1024 * 1024 / SECTOR_SIZE ))

CLEAR_MB=12
CLEAR_SECTORS=$(( CLEAR_MB * 1024 * 1024 / SECTOR_SIZE ))
CLEAR_SEEK=$(( DISK_LAST - CLEAR_SECTORS ))

NEW_END=$(( DISK_LAST - BUFFER_SECTORS ))
NEW_SIZE=$(( NEW_END - SLICE_START ))
NEW_MB=$(( NEW_SIZE * SECTOR_SIZE / 1024 / 1024 ))

FREE=$(( DISK_LAST - (SLICE_START + SLICE_SIZE) ))
FREE_MB=$(( FREE * SECTOR_SIZE / 1024 / 1024 ))

echo "Free Sectors: $FREE (${FREE_MB}MB)"
echo "New Partition Size: $NEW_SIZE (${NEW_MB}MB)"


# VALIDATE WE HAVE ENOUGH FREE SPACE REMAINING TO DO CHANGES
if [ "$FREE_MB" -lt "$CLEAR_MB" ]; then
	echo "Partition already maximum size"
	zpool set org.firstboot:expanded=yes "$ZPOOL"
	exit 0
fi


# SOME BAD MATH HAPPENED, LET'S BAIL!
# THIS ALSO IMPLIES CLEAR_SEEK > 0
if [ "$CLEAR_SEEK" -le "$SLICE_END" ]; then
    echo "Refusing to zero inside partition"
    exit 1
fi


# CAPTURE THE CURRENT GEOM DEBUG FLAGS
# UPDATE THEM, AND THEN REVERT THEM ON EXIT
OID="kern.geom.debugflags"
FLAGS=$(sysctl -n "$OID")
trap "sysctl $OID=$FLAGS; exit" EXIT INT TERM
sysctl "$OID"=0x10


echo "zpool list - pre-expand"
zpool list "$ZPOOL"

echo "Zeroing last ${CLEAR_MB}MB on $DISK"
dd if=/dev/zero of="$DISK" bs="$SECTOR_SIZE" seek="$CLEAR_SEEK" count="$CLEAR_SECTORS"
sync

echo "Resizing partition ${VDEV}"
gpart resize -a 4M -s "$NEW_SIZE" -i "$SLICE" "$DISK"

echo "Expanding zpool size"
zpool online -e "$ZPOOL" "${VDEV}"

echo "zpool list - post-expand"
zpool list "$ZPOOL"

# SET OUR "EXPANDED" FLAG TO PREVENT IT FROM HAPPENING AGAIN
zpool set org.firstboot:expanded=yes "$ZPOOL"
