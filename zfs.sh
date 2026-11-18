#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s <datasets.ini> <root_dataset>\n' "$0" >&2
    exit 1
fi

INI_FILE="$1"
ROOT_DS="${2%/}" # Strip trailing slash if passed (e.g., zroot/ -> zroot)

awk -v root="$ROOT_DS" '
    /^[[:space:]]*(#|;|$)/ { next }

    /^[[:space:]]*\[.*\][[:space:]]*$/ {
        if (ds != "") print opts, ds

        # Extract header inside [...] and strip leading/trailing slashes
        sub(/^[[:space:]]*\[[\/]*/, "")
        sub(/[\/]*\][[:space:]]*$/, "")

        ds = ($0 == "") ? root : root "/" $0
        opts = ""
        next
    }

    /=/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        opts = opts " -o " $0
    }

    END {
        if (ds != "") print opts, ds
    }
' "$INI_FILE" | while IFS= read -r args; do
    cmd="zfs create $args"
    printf '%s\n' "$cmd"
    eval "$cmd"
done
