#!/bin/sh
# Select the native setup transaction while retaining the first-install bootstrap.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for argument do
  case "$argument" in --help|-h) exec cat "$script_dir/setup-help.txt" ;; esac
done
. "$script_dir/managed-v.inc"
if compiler=$(find_maintenance_v "$@"); then
  status=0
  run_maintenance_program "$compiler" "$script_dir/setup.vsh" "$@" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
fi
exec sh "$script_dir/setup-posix" "$@"
