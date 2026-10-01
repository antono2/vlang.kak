#!/bin/sh
# Compare the installed plugin with the latest published release; never installs.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$script_dir/..
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
state=$prefix/opt/vlang-state
mkdir -p "$state"
case ${1:-} in --help|-h) echo 'Usage: check-updates.sh [--background]'; exit 0 ;; --background)
  [ ! -f "$state/update-checked" ] || [ "$(find "$state/update-checked" -mtime +6 -print)" ] || exit 0 ;;
  '') ;; *) exit 2 ;;
esac
command -v git >/dev/null 2>&1 || exit 1
# A lock prevents simultaneous launchers from making duplicate network requests.
mkdir "$state/check-lock" 2>/dev/null || exit 0
trap 'rmdir "$state/check-lock"' EXIT HUP INT TERM
latest=$(git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 ls-remote --tags --refs https://github.com/antono2/vlang.kak.git 'v[0-9]*' | sed -n 's,.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$,\1,p' | sort -V | tail -n 1)
[ -n "$latest" ] || exit 1
installed=$(git -C "$repo" describe --tags --always 2>/dev/null || echo unknown)
if [ "$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)" = "$(git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=10 ls-remote https://github.com/antono2/vlang.kak.git "refs/tags/$latest^{}" | cut -f 1)" ]; then
  echo "Up to date: $latest" > "$state/update-status"
elif [ "$(printf '%s\n%s\n' "$installed" "$latest" | sort -V | tail -n 1)" = "$latest" ] && [ "$installed" != "$latest" ]; then
  printf 'Release available: %s (installed: %s). Use :v-update-release to install it.\n' "$latest" "$installed" > "$state/update-status"
else printf 'Installed: %s. Latest release: %s.\n' "$installed" "$latest" > "$state/update-status"; fi
date -u +%FT%TZ > "$state/update-checked"
cat "$state/update-status"
