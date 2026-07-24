#!/bin/sh
# post-install.sh — stratipi project
# This script runs after packages are installed and the overlay has been
# copied into the image root.  It is invoked by build.sh from the context
# of that script, so $ROOT, $PROJECT, $SCRIPT_DIR, and everything else from
# build.sh's scope is available here.

mkdir -p "$ROOT/etc/cron.d/"

echo "@daily	root	/sbin/zpool scrub $PROJECT" > "$ROOT/etc/cron.d/$PROJECT"
echo "@weekly	root	/sbin/zpool trim $PROJECT" >> "$ROOT/etc/cron.d/$PROJECT"
