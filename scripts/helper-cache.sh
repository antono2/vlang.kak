#!/bin/sh
# Bootstrap the cached V dispatcher shared by the editor helpers.
set -eu
case ${1:-} in
    --help|-h) echo 'Usage: helper-cache.sh TOOL [ARGS...] | helper-cache.sh checkpoint DIRECTORY | helper-cache.sh checkpoint --read MODE DIRECTORY [STATE]'; exit 0 ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak
fallback() {
    case "${1:-}:${2:-}" in
        windowing:*|history:*|explorer:prompt|explorer:candidates)
            tool=$1; shift; exec "$script_dir/$tool-posix" "$@" ;;
        checkpoint:--read) shift 2; exec "$script_dir/session-checkpoint-posix" "$@" ;;
    esac
    exit 1
}
signature=$(printf '%s' "$script_dir" | cksum) || fallback "$@"
dispatcher=$cache/helper-dispatch-${signature%% *}
source=$script_dir/helper-cache.vsh
if ! command -v v >/dev/null 2>&1; then
    # An existing install can still have a usable binary in the old cache.
    case "${1:-}:${2:-}" in
        explorer:prompt|explorer:candidates) ;;
        debug:*|explorer:*|preferences:*)
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
prepare() (
    command -v v >/dev/null 2>&1 || {
        echo 'Install V or add it to PATH to build the Kakoune helpers.' >&2
        exit 1
    }
    mkdir -p -- "$cache" || exit 1
    stage=$(mktemp -d "$cache/.helper-dispatch.XXXXXXXX") || exit 1
    trap 'rm -f -- "$stage/dispatcher"; rmdir -- "$stage"' EXIT
    trap 'exit 130' HUP INT TERM
    v -skip-running -o "$stage/dispatcher" "$source" || exit 1
    mv -fT -- "$stage/dispatcher" "$dispatcher" || exit 1
    rmdir -- "$stage" || exit 1
    trap - EXIT HUP INT TERM
)
if [ ! -x "$dispatcher" ] || [ -L "$dispatcher" ] || [ "$source" -nt "$dispatcher" ]; then
    case "${1:-}:${2:-}" in
        windowing:*|history:*|checkpoint:--read|explorer:prompt|explorer:candidates)
            prepare >/dev/null 2>&1 || fallback "$@" ;;
        *) prepare ;;
    esac
fi
exec "$dispatcher" "$cache" "$@"
