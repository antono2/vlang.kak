#!/bin/sh
# Remove unchanged inactive releases while keeping current and rollback targets.
set -eu
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
apply=false
cache_cleanup=false
while [ "$#" -gt 0 ]; do case "$1" in --cache) cache_cleanup=true; shift ;; --prefix) prefix=$2; shift 2 ;; --apply) apply=true; shift ;; --help|-h) echo 'Usage: cleanup.sh [--prefix DIRECTORY] [--apply] [--cache]'; exit 0 ;; *) exit 2 ;; esac; done
prefix=$(readlink -m "$prefix")
state=$prefix/opt/vlang-state
[ -f "$state/manifest.tsv" ] || { echo 'Run setup to record ownership first.' >&2; exit 1; }
mkdir "$state/lock" 2>/dev/null || { echo 'Another installation operation is active.' >&2; exit 1; }
trap 'rmdir "$state/lock"' EXIT HUP INT TERM
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
active_executables=$("$script_dir/active-tools.sh" "$prefix" | sed '/^managed-process:/d')
for tool in kakoune kak-lsp vls v; do
  root=$prefix/opt/vlang-$tool
  current=$(readlink -f "$root/current" 2>/dev/null || true)
  previous=$(readlink -f "$state/previous/opt/vlang-$tool/current" 2>/dev/null || true)
  for release in "$root"/releases/*; do
    [ -d "$release" ] && [ ! -L "$release" ] || continue
    [ "$release" != "$current" ] && [ "$release" != "$previous" ] || continue
    active=false
    case "$active_executables" in *"$release/"*) active=true ;; esac
    for session in "$prefix/opt/vlang-kakoune"/restart.*; do
      [ -d "$session" ] || continue
      if [ ! -f "$session/owner-pid" ]; then active=true; break; fi
      owner=$(cat "$session/owner-pid")
      case "$owner" in ''|*[!0-9]*) active=true; break ;; esac
      if kill -0 "$owner" 2>/dev/null && { [ ! -f "$session/tool-releases" ] || grep -Fxq "$release" "$session/tool-releases"; }; then active=true; break; fi
    done
    if [ "$active" = true ]; then echo "Keep release used by an active session: $release"; continue; fi
    # Any modified or unrecorded file makes the whole release ineligible.
    safe=true
    inventory=$(mktemp "$state/inventory.XXXXXXXX")
    find "$release" -type f -o -type l > "$inventory"
    while IFS= read -r path; do
      entry=$(awk -F '\t' -v p="$path" '$3==p {print $1 "\t" $2}' "$state/manifest.tsv")
      if [ -L "$path" ]; then expected="link$(printf '\t')$(readlink "$path")"; else expected="file$(printf '\t')$(sha256sum "$path" | cut -d ' ' -f 1)"; fi
      if [ "$entry" != "$expected" ]; then safe=false; break; fi
    done < "$inventory"
    rm "$inventory"
    if [ "$safe" = true ]; then
      echo "Remove unused release: $release"
      [ "$apply" != true ] || rm -rf -- "$release"
    else echo "Keep changed/unrecorded release: $release"; fi
  done
done
if [ "$cache_cleanup" = true ]; then
  cache=$(cat "$state/cache-home")/vlang.kak
  if [ -d "$cache" ]; then
    find "$cache" -maxdepth 1 -type f -mtime +30 \( -name 'explorer-[0-9]*' -o -name 'debug-[0-9]*' -o -name 'preferences-[0-9]*' \) -print |
    while IFS= read -r path; do
      [ -x "$path" ] || continue
      echo "Remove old compiled helper (rebuilds on demand): $path"
      [ "$apply" != true ] || rm -f "$path"
    done
  fi
fi
[ "$apply" = true ] || echo 'Preview only; repeat with --apply to clean up.'
