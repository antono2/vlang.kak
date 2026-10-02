#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
recover=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --recover) recover=$2; shift 2 ;;
    --help|-h) echo 'Usage: rollback.sh [--prefix DIRECTORY] [--recover PENDING_SNAPSHOT]'; exit 0 ;;
    *) exit 2 ;;
  esac
done
prefix=$(readlink -m "$prefix")
state=$prefix/opt/vlang-state
selected=$state/previous
if [ -n "$recover" ]; then
  [ ! -L "$recover" ] || { echo 'Refusing a redirected recovery snapshot.' >&2; exit 1; }
  selected=$(readlink -f "$recover")
  [ "$(dirname "$selected")" = "$state" ] || { echo 'Use a pending snapshot from this installation.' >&2; exit 1; }
  case $(basename "$selected") in pending.*) ;; *) exit 2 ;; esac
  [ -f "$selected/ready" ] || { echo 'The interrupted setup snapshot is incomplete.' >&2; exit 1; }
fi
[ -f "$selected/paths" ] || { echo 'No previous installation snapshot.' >&2; exit 1; }
. "$script_dir/install-lock.inc"
lock_acquire rollback
trap lock_release EXIT
trap 'exit 130' HUP INT TERM
next=$(mktemp -d "$state/rollback.XXXXXXXX")
"$script_dir/managed-state.sh" snapshot "$prefix" "$next"
"$script_dir/managed-state.sh" restore "$prefix" "$selected"
old_plugin=
repo=
if [ -f "$selected/plugin-revision" ]; then
  old_plugin=$(cat "$selected/plugin-revision"); repo=$(cat "$selected/plugin-repo")
  if [ -z "$(git -C "$repo" status --porcelain)" ]; then
    git -C "$repo" rev-parse HEAD > "$next/plugin-revision"; printf '%s\n' "$repo" > "$next/plugin-repo"
  else echo 'Plugin checkout has local edits; rolling back tools only.'; old_plugin=; fi
fi
if [ -z "$recover" ]; then
  rm -rf "$selected"; mv "$next" "$selected"
else
  # Keep the partial activation for investigation; never offer it as rollback.
  echo "Pre-recovery activation snapshot retained: $next"
  recovered_snapshot=$state/recovered.${selected##*/pending.}
fi
if [ -f "$state/config-home" ]; then
  "$script_dir/managed-state.sh" record "$prefix" "$(cat "$state/config-home")"
fi
# Parse the completion commands before checkout can replace this script.
finish_rollback() {
  if [ -n "$old_plugin" ]; then git -C "$repo" checkout --detach "$old_plugin"; fi
  [ -z "$recover" ] || mv "$selected" "$recovered_snapshot"
  echo 'Previous managed tools restored. Restart Kakoune when convenient.'
}
finish_rollback; exit
