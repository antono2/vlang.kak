#!/bin/sh
# Share the release-check lock across the V and V-less entry points.
set -eu
case "${1:-}" in
  --help|-h) echo 'Usage: check-updates.sh [--background | --notify SESSION CLIENT]'; exit 0 ;;
esac
case "$#:${1:-}" in
  0:|1:--background) ;;
  3:--notify) [ -n "$2" ] && [ -n "$3" ] || exit 2 ;;
  *) exit 2 ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
state=$prefix/opt/vlang-state
if command -v v >/dev/null 2>&1; then
  . "$script_dir/managed-v.inc"
  status=0
  run_maintenance_program v "$script_dir/check-updates.vsh" "$state" "$@" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
fi
exec "$script_dir/check-updates-posix" "$state" "$@"
