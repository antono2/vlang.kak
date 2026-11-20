#!/bin/sh
# Build the V debug client once, then run a debugger action.
set -eu
case ${1:-} in
  --help|-h) echo 'Usage: debug.sh --prepare | configure|run|sync|marks|active|queue DIRECTORY [ACTION [ARGS...]]'; exit ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/helper-cache.sh" debug "$@"
