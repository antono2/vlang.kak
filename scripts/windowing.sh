#!/bin/sh
# Load the cached V pane adapter, with a POSIX path for plugin-only installs.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

prepare() (
    umask 077
    mkdir -p "$cache" || exit 1
    staging=$(mktemp -d "$cache/.windowing.XXXXXXXX") || exit 1
    trap 'rm -f "$staging/windowing"; rmdir "$staging"' EXIT
    trap 'exit 1' HUP INT TERM
    v -o "$staging/windowing" "$source" &&
        [ "$(cksum < "$source")" = "$signature" ] &&
        mv -f "$staging/windowing" "$binary"
)

cache_home=${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}
if [ -n "$cache_home" ] && [ "${1:-}" != --help ] && [ "${1:-}" != -h ] && command -v v >/dev/null 2>&1; then
    cache=$cache_home/vlang.kak
    source=$script_dir/windowing.v
    if signature=$(cksum 2>/dev/null < "$source"); then
        binary=$cache/windowing-${signature% *}-${signature#* }
        if [ -x "$binary" ] || prepare > /dev/null 2>&1; then
            exec "$binary" "$@"
        fi
    fi
fi
exec "$script_dir/windowing-posix" "$@"
