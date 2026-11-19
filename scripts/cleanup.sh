#!/bin/sh
# Use the system or managed V compiler to run release cleanup.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
want_prefix=false
for argument do
    if [ "$want_prefix" = true ]; then
        prefix=$argument
        want_prefix=false
    else
        case "$argument" in
            --help|-h) echo 'Usage: cleanup.sh [--prefix DIRECTORY] [--apply] [--cache]'; exit 0 ;;
            --prefix) want_prefix=true ;;
        esac
    fi
done
if command -v v >/dev/null 2>&1; then
    exec v run "$script_dir/cleanup.vsh" "$@"
fi
if [ -x "$prefix/opt/vlang-v/current/v" ]; then
    exec "$prefix/opt/vlang-v/current/v" run "$script_dir/cleanup.vsh" "$@"
fi
echo 'Install V or put the managed V compiler on PATH to use cleanup.' >&2
exit 1
