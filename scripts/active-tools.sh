#!/bin/sh
# List executable paths under the prefix and live managed environments.
set -eu
case ${1:-} in --help|-h) echo 'Usage: active-tools.sh PREFIX'; exit 0 ;; esac
if [ "$#" -ne 1 ]; then
  echo 'Usage: active-tools.sh PREFIX' >&2
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/managed-v.inc"
if compiler=$(find_maintenance_v --prefix "$1"); then
  status=0
  run_maintenance_program "$compiler" "$script_dir/active-tools.vsh" "$1" || status=$?
  [ "$status" -eq 125 ] || exit "$status"
  echo 'V could not prepare the process inspector. Using shell inspection.' >&2
fi
. "$script_dir/active-tools-posix"
