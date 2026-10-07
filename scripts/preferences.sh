#!/bin/sh
# Builds and dispatches the project-preferences helper for the active installation.
set -eu
case ${1:-} in --help|-h) echo 'Usage: preferences.sh --prepare | load|show|args|cwd|target|targets|reset FILE [VALUE...]'; exit 0 ;; esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=$script_dir/preferences.v
identity=$(printf %s "$source" | cksum | cut -d ' ' -f 1)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak
binary=$cache/preferences-$identity
mkdir -p "$cache"
if [ ! -x "$binary" ] || [ "$source" -nt "$binary" ]; then
  temporary=$binary.$$.tmp
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  v -o "$temporary" "$source"
  chmod 755 "$temporary"; mv -f "$temporary" "$binary"
fi
[ "${1:-}" != --prepare ] || exit 0
exec "$binary" "$@"
