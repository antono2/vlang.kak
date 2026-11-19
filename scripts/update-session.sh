#!/bin/sh
# Keep the in-editor update usable when the installed compiler needs repair.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case ${1:-} in
  --help|-h) exec "$script_dir/update-session-posix" "$@" ;;
esac

if command -v v >/dev/null 2>&1 && stage=$(mktemp -d "${TMPDIR:-/tmp}/vlang-kak-update.XXXXXXXX"); then
  trap 'rm -f "$stage/update-session"; rmdir "$stage"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if v -skip-running -o "$stage/update-session" "$script_dir/update-session.vsh" >/dev/null 2>&1 &&
    "$stage/update-session" --help >/dev/null 2>&1; then
    # A failed update must not be retried through the fallback.
    "$stage/update-session" "$@"
    exit
  fi
  rm -f "$stage/update-session"
  rmdir "$stage"
  trap - EXIT HUP INT TERM
fi
exec "$script_dir/update-session-posix" "$@"
