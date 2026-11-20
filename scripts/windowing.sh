#!/bin/sh
# Use the native pane adapter when V is available.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache_home=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
if [ -n "$cache_home" ] && [ "${1:-}" != --help ] && [ "${1:-}" != -h ] && command -v v >/dev/null 2>&1; then
    exec "$script_dir/helper-cache.sh" windowing "$@"
fi
exec "$script_dir/windowing-posix" "$@"
