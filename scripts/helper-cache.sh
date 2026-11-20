#!/bin/sh
# Bootstrap the cached V dispatcher shared by the editor helpers.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak
signature=$(printf '%s' "$script_dir" | cksum)
dispatcher=$cache/helper-dispatch-${signature%% *}
source=$script_dir/helper-cache.vsh
if ! command -v v >/dev/null 2>&1; then
    # An existing install can still have a usable binary in the old cache.
    case "${1:-}" in
        debug|explorer|preferences)
            tool=$1
            helper_source=$script_dir/$tool.v
            legacy_signature=$(printf '%s' "$helper_source" | cksum)
            legacy=$cache/$tool-${legacy_signature%% *}
            if [ -x "$legacy" ] && [ ! "$helper_source" -nt "$legacy" ]; then
                shift
                [ "${1:-}" != --prepare ] || exit 0
                exec "$legacy" "$@"
            fi
            ;;
    esac
fi
if [ ! -x "$dispatcher" ] || [ -L "$dispatcher" ] || [ "$source" -nt "$dispatcher" ]; then
    command -v v >/dev/null 2>&1 || {
        echo 'Install V or add it to PATH to build the Kakoune helpers.' >&2
        exit 1
    }
    mkdir -p -- "$cache"
    stage=$(mktemp -d "$cache/.helper-dispatch.XXXXXXXX")
    trap 'rm -f -- "$stage/dispatcher"; rmdir -- "$stage"' EXIT
    trap 'exit 130' HUP INT TERM
    v -skip-running -o "$stage/dispatcher" "$source"
    mv -fT -- "$stage/dispatcher" "$dispatcher"
    rmdir -- "$stage"
    trap - EXIT HUP INT TERM
fi
exec "$dispatcher" "$cache" "$@"
