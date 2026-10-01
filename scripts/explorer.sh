#!/bin/sh
# Compile the explorer once and refresh it when its V source changes.
set -eu
case "${1:-}" in
  --help|-h)
    echo 'Usage: scripts/explorer.sh --prepare | COMMAND STATE [ARG...]'
    exit 0
    ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source=$script_dir/explorer.v
cache_root=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak
identity=$(printf %s "$source" | cksum | cut -d ' ' -f 1)
binary=$cache_root/explorer-$identity
mkdir -p "$cache_root"
if [ ! -x "$binary" ] || [ "$source" -nt "$binary" ]; then
  command -v v >/dev/null 2>&1 || {
    echo 'The project explorer requires V on PATH.' >&2
    exit 1
  }
  temporary=$binary.$$.tmp
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  v -o "$temporary" "$source"
  chmod +x "$temporary"
  mv -f "$temporary" "$binary"
  trap - EXIT HUP INT TERM
fi
[ "${1:-}" != --prepare ] || exit 0
exec "$binary" "$@"
