#!/bin/sh


# INITIAL CONFIG
DISK="/dev/mmcsd0"
SLICE=2


# DYNAMICALLY GET ZPOOL NAME
ZPOOL=$(zpool status -P | awk -v d="$DISK" '
	/^  pool:/ {p=$2}
	$0 ~ d {print p; exit}
')

# GET DISK SECTOR SIZE AND TOTAL SECTOR COUNT)
SIZE=$(diskinfo $DISK | awk '{print $2}')
TOTAL=$(diskinfo $DISK | awk '{print $4}')

echo "Disk: $DISK"
echo "Total Sectors: $TOTAL"
echo "Sector Size: $SIZE"


# GET DISK GEOMETRY
LAST=$(gpart show $DISK | awk '
	NF >= 5 && $1 ~ /^[0-9]+$/ {
		start=$2
		size=$3
		end=start+size
		if (end>max) max=end
	}
	END { if (max=="") max=0; print max }
')


# MATH IS HARD, OKAY !?
FREE=$(( TOTAL - LAST ))
MB=$(( FREE * SIZE / 1024 / 1024 ))
TWO_MB=$(( 2 * 1024 * 1024 / SIZE ))
SEEK=$(( TOTAL - TWO_MB ))
echo "Free Space: ${MB} MB"


# LESS THAN 10MB AT END OF DISK, DO NOTHING
if [ "$MB" -lt 10 ]; then
	echo "Partition already maximum size"
	exit 0
fi


# CAPTURE THE CURRENT GEOM DEBUG FLAGS
# UPDATE THEM, AND THEN REVERT THEM ON EXIT
OID="kern.geom.debugflags"
FLAGS=$(sysctl -n "$OID")
trap "sysctl $OID=$FLAGS; exit" EXIT INT TERM
sysctl $OID=0x10


echo "Zeroing last 2MB on $DISK"
dd if=/dev/zero of=$DISK bs=$SIZE seek=$SEEK count=$TWO_MB

echo "Resizing partition ${DISK}s${SLICE}"
gpart resize -a 1M -i ${SLICE} ${DISK}

echo "Expanding zpool size"
zpool online -e $ZPOOL "${DISK}s${SLICE}"
