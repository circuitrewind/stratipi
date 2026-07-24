#!/bin/sh
# dependency.sh — resolve a project's dependencies (and their transitive deps)
# recursively, with dedup and topological ordering.
#
# Usage: ./dependency.sh <project_name>
# Set PROJECTS_DIR env var to override where project folders live
# (defaults to the script's own directory).
#
# Each project folder under PROJECTS_DIR may contain an optional "depends"
# file at <project>/depends  listing the names of other projects it depends
# on (one per line).  Lines starting with # are comments; blank lines are
# ignored.
#
# Produces a flat, deduplicated, topologically-sorted list of project names
# on stdout: a project always appears after every project it depends on.
#
# Pure POSIX sh — no temp files, no bashisms.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ $# -ne 1 ]; then
	echo "Usage: $0 <project_name>" >&2
	exit 1
fi

PROJECTS_DIR="${PROJECTS_DIR:-$SCRIPT_DIR}"

V=""    # |proj1||proj2|…  visited / dedup set
R=""    # result buffer (newline-separated)

done_add() {       # add a project to the result after all its deps resolved
	R="$R$1"$'\n'
}

go() {             # resolve dependencies recursively (DFS, post-order)
	[ -z "$1" ] && return

	# Dedup check — pipe anchors prevent false matches (|boot| won't match
	# inside |bootloader|).
	case "$V" in *"|$1|"*) return ;; esac
	V="$V$1|"

	dep_file="$PROJECTS_DIR/$1/depends"

	if [ -f "$dep_file" ]; then
		while IFS= read -r dep || [ -n "$dep" ]; do
			case "$dep" in ''|\#*) continue ;; esac
			go "$dep"
		done < "$dep_file"
	fi

	done_add "$1"   # all deps resolved — record this project
}

go "$1"

printf '%s' "$R"
