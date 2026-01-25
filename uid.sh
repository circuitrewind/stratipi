#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 METALOG IMAGE_ROOT" >&2
    exit 1
fi

METALOG=$1
ROOT=$2


# VALIDATE PASSED IN PATHS EXISTS
if [ ! -f "$METALOG" ]; then
    echo "ERROR: metalog not found: $METALOG" >&2
    exit 1
fi

if [ ! -d "$ROOT" ]; then
    echo "ERROR: disk image root not found: $ROOT" >&2
    exit 1
fi

# PATHS FOR THE USER AND GROUP DATABASES
PASSWD="$ROOT/etc/passwd"
GROUP="$ROOT/etc/group"

# VALIDATE THESE FILES EXIST
if [ ! -f "$PASSWD" ] || [ ! -f "$GROUP" ]; then
    echo "ERROR: image root lacks /etc/passwd or /etc/group" >&2
    exit 1
fi


################################################################################
# PROCESS THE METALOG FILE - THIS IS WHERE ALL THE REAL WORK HAPPENS!
################################################################################
awk -v root="$ROOT" -v passwd_file="$PASSWD" -v group_file="$GROUP" '
BEGIN {
    FS = "[ \t]+"

    # Load passwd map: name -> uid
    while ((getline < passwd_file) > 0) {
        split($0, f, ":")
        passwd[f[1]] = f[3]
    }
    close(passwd_file)

    # Load group map: name -> gid
    while ((getline < group_file) > 0) {
        split($0, f, ":")
        group[f[1]] = f[3]
    }
    close(group_file)
}

{
    path = $1
    uname = gname = ""

    for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "uname") uname = kv[2]
        else if (kv[1] == "gname") gname = kv[2]
    }

    # Skip default ownership entirely
    if (uname == "root" && gname == "wheel")
        next

    uid = (uname != "" && uname in passwd) ? passwd[uname] : ""
    gid = (gname != "" && gname in group) ? group[gname] : ""

    # Nothing resolvable → nothing to do
    if (uid == "" && gid == "")
        next

    fullpath = root "/" substr(path, 3)

    cmd = "chown "
    if (uid != "") cmd = cmd uid
    cmd = cmd ":"
    if (gid != "") cmd = cmd gid
    cmd = cmd " \"" fullpath "\""

	printf cmd "\n"
    system(cmd)
}
' "$METALOG"

echo "UID/GID ownership applied successfully"
