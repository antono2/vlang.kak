#!/bin/sh
# Share the release-check lock across the V and V-less entry points.
set -eu
case "${1:-}" in
  --help|-h) echo 'Usage: check-updates.sh [--background]'; exit 0 ;;
esac
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --background ]; }; then
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
state=$prefix/opt/vlang-state
mkdir -p "$state"
mkdir "$state/check-lock" 2>/dev/null || exit 0
trap 'rmdir "$state/check-lock"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if command -v v >/dev/null 2>&1; then
  v run "$script_dir/check-updates.vsh" "$state" "$@"
else
  "$script_dir/check-updates-posix" "$state" "$@"
fi
