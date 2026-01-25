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
	# STRIP LEADING WHITE-SPACE BEFORE PARSING
	sub(/^[ \t]+/, "", $0)

	# THE FIRST VALUE IS THE PATH
    path = $1

	# SANITIZE THE PATH VALUE
	gsub(/\\s/, " ", path)
	gsub(/\\t/, "\t", path)
	gsub(/\\n/, "\n", path)
	gsub(/\\#/, "#", path)
	gsub(/\\\\/, "\\", path)
	gsub(/"/, "\\\"", path)

	# VALIDATE PATHS
	if (substr(path,1,2) != "./") {
		print "ERROR: path does not start with ./ : " path > "/dev/stderr"
		exit 1
	}

	# HARDEN PATH AGAINST /../ ROOT ESCAPES
	if (path ~ /(^|\/)\.\.(\/|$)/) {
		print "ERROR: path escapes image root: " path > "/dev/stderr"
		exit 1
	}

	# PARSE LINE LOOKING FOR USER NAME AND GROUP NAME
    uname = gname = ""
    for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == "uname") uname = kv[2]
        else if (kv[1] == "gname") gname = kv[2]
    }

    # WE DONT NEED TO CHANGE ROOT/WHEEL, ITS ALREADY SET
    if (uname == "root" && gname == "wheel")
        next

	# LOOK UP UID AND GID
    uid = (uname != "" && uname in passwd) ? passwd[uname] : ""
    gid = (gname != "" && gname in group) ? group[gname] : ""

	# BAIL IF UID NOT FOUND
	if (uname != "" && uid == "") {
		print "ERROR: unknown user in metalog: " uname " for path: " path > "/dev/stderr"
		exit 1
	}

	# BAIL IF GID NOT FOUND
	if (gname != "" && gid == "") {
		print "ERROR: unknown group in metalog: " gname " for path: " path > "/dev/stderr"
		exit 1
	}

    # NOTHING RESOLVABLE > NOTHING TO DO
    if (uid == "" && gid == "")
        next

	# LOGGING
	printf substr(path, 2) " - " uname "(" uid ") " gname "(" gid ")\n"

	# FULL PATH WITH OUR ROOT
    fullpath = root "/" substr(path, 3)

	# CHOWN ALL THE THINGS!
    cmd = "chown -h "
    if (uid != "") cmd = cmd uid
    cmd = cmd ":"
    if (gid != "") cmd = cmd gid
    cmd = cmd " \"" fullpath "\""

	# EXECUTE CHOWN COMMAND
	rc = (cmd | getline dummy)
	close(cmd)

	# WAIT, IT FAILED? LETS BAIL!
	if (rc != 0) {
		print "ERROR: chown failed: " cmd > "/dev/stderr"
		exit 1
	}
}
' "$METALOG"

echo "UID/GID ownership applied successfully"
