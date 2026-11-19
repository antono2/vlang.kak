#!/bin/sh
# Select the native rollback command and retain recovery when V cannot compile.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/managed-v.inc"
for argument do
    case "$argument" in
        --help|-h) echo 'Usage: rollback.sh [--prefix DIRECTORY] [--recover PENDING_SNAPSHOT]'; exit 0 ;;
    esac
done
if compiler=$(find_maintenance_v "$@"); then
    status=0
    run_maintenance_program "$compiler" "$script_dir/rollback.vsh" "$@" || status=$?
    [ "$status" -eq 125 ] || exit "$status"
    echo 'V could not prepare the rollback command. Using shell recovery.' >&2
fi
exec sh "$script_dir/rollback-posix" "$@"
