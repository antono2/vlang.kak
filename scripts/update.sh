#!/bin/sh
# Select the V updater while keeping a compiler-free upgrade path.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for option do
  case "$option" in --help|-h) echo 'Usage: update.sh [--release] [setup options]'; exec "$script_dir/setup.sh" --help ;; esac
done
. "$script_dir/managed-v.inc"
if compiler=$(find_maintenance_v "$@"); then
  status=0
  run_maintenance_program "$compiler" "$script_dir/update.vsh" "$@" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
  echo 'V could not prepare the update command. Using shell update.' >&2
fi
exec sh "$script_dir/update-posix" "$@"
