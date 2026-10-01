#!/bin/sh
# Build the V debug client once, then run a debugger action.
set -eu
case ${1:-} in
  --help|-h) echo 'Usage: debug.sh --prepare | configure|run|sync|marks|active|queue DIRECTORY [ACTION [ARGS...]]'; exit ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak
identity=$(printf %s "$script_dir/debug.v" | cksum | cut -d ' ' -f 1)
binary=$cache/debug-$identity
mkdir -p "$cache"
if [ ! -x "$binary" ] || [ "$script_dir/debug.v" -nt "$binary" ]; then
  command -v v >/dev/null 2>&1 || { echo 'Debugging requires V on PATH.' >&2; exit 1; }
  temporary=$binary.$$.tmp
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  if v help build-c 2>/dev/null | grep -q -- -old-compiler; then
    v -old-compiler -o "$temporary" "$script_dir/debug.v"
  else
    v -o "$temporary" "$script_dir/debug.v"
  fi
  mv -f "$temporary" "$binary"
  trap - EXIT HUP INT TERM
fi
[ "${1:-}" != --prepare ] || exit 0
exec "$binary" "$@"
