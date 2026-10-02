#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
case ${1:-} in --prefix) prefix=$2 ;; --help|-h) echo 'Usage: rollback.sh [--prefix DIRECTORY]'; exit 0 ;; '') ;; *) exit 2 ;; esac
prefix=$(readlink -m "$prefix")
state=$prefix/opt/vlang-state
[ -f "$state/previous/paths" ] || { echo 'No previous installation snapshot.' >&2; exit 1; }
mkdir "$state/lock" 2>/dev/null || { echo 'Another installation operation is active.' >&2; exit 1; }
trap 'rmdir "$state/lock"' EXIT HUP INT TERM
next=$(mktemp -d "$state/rollback.XXXXXXXX")
"$script_dir/managed-state.sh" snapshot "$prefix" "$next"
"$script_dir/managed-state.sh" restore "$prefix" "$state/previous"
old_plugin=
repo=
if [ -f "$state/previous/plugin-revision" ]; then
  old_plugin=$(cat "$state/previous/plugin-revision"); repo=$(cat "$state/previous/plugin-repo")
  if [ -z "$(git -C "$repo" status --porcelain)" ]; then
    git -C "$repo" rev-parse HEAD > "$next/plugin-revision"; printf '%s\n' "$repo" > "$next/plugin-repo"
  else echo 'Plugin checkout has local edits; rolling back tools only.'; old_plugin=; fi
fi
rm -rf "$state/previous"; mv "$next" "$state/previous"
"$script_dir/managed-state.sh" record "$prefix" "$(cat "$state/config-home")"
if [ -n "$old_plugin" ]; then git -C "$repo" checkout --detach "$old_plugin"; fi
echo 'Previous managed tools restored. Restart Kakoune when convenient.'
