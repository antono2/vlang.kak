#!/bin/sh
# Run setup checks in V when possible, including before compiler bootstrap.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case ${1:-} in --help|-h) echo 'Usage: preflight.sh [setup options]'; exit 0 ;; esac
. "$script_dir/managed-v.inc"
if compiler=$(find_maintenance_v "$@"); then
  status=0
  run_maintenance_program "$compiler" "$script_dir/setup-checks.vsh" preflight "$@" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
fi
exec sh "$script_dir/preflight-posix" "$@"
