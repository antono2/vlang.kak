#!/bin/sh
# Select the V installation-lock command with a compiler-free fallback.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for argument do
  case "$argument" in --help|-h) echo 'Usage: lock.sh [--prefix DIRECTORY] [--clear-stale]'; exit 0 ;; esac
done
. "$script_dir/managed-v.inc"
if compiler=$(find_maintenance_v "$@"); then
  status=0
  run_maintenance_program "$compiler" "$script_dir/lock.vsh" "$@" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
fi
exec sh "$script_dir/lock-posix" "$@"
