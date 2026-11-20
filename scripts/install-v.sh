#!/bin/sh
# Use a working V compiler when available and retain the first-install bootstrap.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
case ${1:-} in
  --help|-h) echo 'Usage: install-v.sh [--prefix PREFIX | PREFIX]'; exit 0 ;;
  --prefix) [ "$#" = 2 ] || exit 2; prefix=$2 ;;
  '') ;;
  /*) [ "$#" = 1 ] || exit 2; prefix=$1 ;;
  *) echo 'Use an absolute prefix.' >&2; exit 2 ;;
esac
case "$prefix" in /*) ;; *) echo 'Use an absolute prefix.' >&2; exit 2 ;; esac
. "$script_dir/managed-v.inc"
if compiler=$(find_maintenance_v --prefix "$prefix"); then
  status=0
  run_maintenance_program "$compiler" "$script_dir/install-v.vsh" "$prefix" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
fi
exec sh "$script_dir/install-v-posix" "$prefix"
