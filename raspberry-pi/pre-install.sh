#!/bin/sh
# pre-install.sh — raspberry-pi project
# Builds u-boot.env from uboot.txt. Runs after builddeps are installed but
# before the overlay is copied into $ROOT.

(set -x
mkenvimage -s 16384 -o "$PROJECT_DIR/boot/efi/uboot.env" "$PROJECT_DIR/boot/efi/uboot.txt"
)
