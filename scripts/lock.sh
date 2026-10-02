#!/bin/sh
# Inspect installation ownership; explicitly clear only a known dead owner.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
clear=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --clear-stale) clear=true; shift ;;
    --help|-h) echo 'Usage: lock.sh [--prefix DIRECTORY] [--clear-stale]'; exit 0 ;;
    *) exit 2 ;;
  esac
done
prefix=$(readlink -m "$prefix")
state=$prefix/opt/vlang-state
. "$script_dir/install-lock.inc"
if [ "$clear" = false ]; then lock_status; exit $?; fi
[ -d "$state/lock" ] || { echo 'No installation lock.'; exit 0; }
mkdir "$state/lock/recovery" 2>/dev/null || { echo 'Another lock recovery is active.' >&2; exit 1; }
trap 'rmdir "$state/lock/recovery" 2>/dev/null || true' EXIT
status=0
lock_status || status=$?
[ "$status" = 3 ] || { echo 'Refusing to clear an active or unknown lock.' >&2; exit 1; }
# Do not remove unexpected files or follow an owner symlink.
[ ! -L "$state/lock" ] && [ ! -L "$state/lock/owner" ] || exit 1
[ "$(find "$state/lock" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 ] || {
  echo 'Unexpected lock contents; inspect manually.' >&2; exit 1;
}
rm "$state/lock/owner"
rmdir "$state/lock/recovery"
rmdir "$state/lock"
trap - EXIT
echo 'Stale lock cleared. Run health.sh before retrying the operation.'
