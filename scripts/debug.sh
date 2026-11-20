#!/bin/sh
# Build the V debug client once, then run a debugger action.
set -eu
case ${1:-} in
  --help|-h)
    echo 'Usage: debug.sh --prepare | call DIRECTORY start|action [ARGS...]'
    echo '       debug.sh configure|run|sync|marks|active|queue DIRECTORY [ACTION [ARGS...]]'
    exit 0 ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/helper-cache.sh" debug "$@"
