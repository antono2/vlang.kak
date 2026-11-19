#!/bin/sh
# Build separately so the installed compiler can itself be removed.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for argument do
    case "$argument" in
        --help|-h)
            echo 'Usage: uninstall.sh [--prefix DIRECTORY] [--apply] [--verbose]'
            echo 'Default: preview. Personal settings, modified files and external tools are kept.'
            exit 0 ;;
    esac
done
. "$script_dir/managed-v.inc"
compiler=$(find_maintenance_v "$@") || { echo 'Install V or put the managed V compiler on PATH to use removal.' >&2; exit 1; }
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vlang-uninstall.XXXXXXXX")
trap 'rm -f -- "$temporary/uninstall"; rmdir -- "$temporary"' EXIT
trap 'exit 130' HUP INT TERM
"$compiler" -skip-running -o "$temporary/uninstall" "$script_dir/uninstall.vsh"
"$temporary/uninstall" "$@"
