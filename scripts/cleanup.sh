#!/bin/sh
# Use the system or managed V compiler to run release cleanup.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for argument do
    case "$argument" in
        --help|-h) echo 'Usage: cleanup.sh [--prefix DIRECTORY] [--apply] [--cache]'; exit 0 ;;
    esac
done
. "$script_dir/managed-v.inc"
compiler=$(find_maintenance_v "$@") || { echo 'Install V or put the managed V compiler on PATH to use cleanup.' >&2; exit 1; }
exec "$compiler" run "$script_dir/cleanup.vsh" "$@"
