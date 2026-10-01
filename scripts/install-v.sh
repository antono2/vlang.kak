#!/bin/sh
# Build the release-tested compiler in a separate user-local tool directory.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
case ${1:-} in
  --prefix) [ "$#" = 2 ] || exit 2; prefix=$2 ;;
  --help|-h) echo 'Usage: install-v.sh [--prefix PREFIX | PREFIX]'; exit 0 ;;
  '') ;;
  /*) [ "$#" = 1 ] || exit 2; prefix=$1 ;;
  *) echo 'Use an absolute prefix.' >&2; exit 2 ;;
esac
case "$prefix" in /*) ;; *) echo 'Use an absolute prefix.' >&2; exit 2 ;; esac
. "$script_dir/../tests/release.env"
root=$prefix/opt/vlang-v
release=$root/releases/$V_REF
mkdir -p "$root/releases" "$prefix/bin"
if [ ! -x "$release/v" ] || [ "$(cat "$release/.vlang-revision" 2>/dev/null || true)" != "$V_REF" ]; then
  [ ! -e "$release" ] || { echo "Incomplete V release at $release; inspect it before retrying." >&2; exit 1; }
  stage=$(mktemp -d "$root/releases/.stage.XXXXXXXX")
  trap 'rm -rf "$stage"' EXIT HUP INT TERM
  git init -q "$stage"
  git -C "$stage" fetch --depth 1 https://github.com/vlang/v.git "$V_REF"
  git -C "$stage" checkout -q --detach FETCH_HEAD
  git init -q "$stage/vc"
  git -C "$stage/vc" fetch --depth 1 https://github.com/vlang/vc.git "$VC_REF"
  git -C "$stage/vc" checkout -q --detach FETCH_HEAD
  # V embeds source paths, so compile at the permanent versioned path.
  # This directory is not selected by current until setup succeeds.
  [ ! -e "$release" ] || { echo "Incomplete V release at $release; inspect it before retrying." >&2; exit 1; }
  mv "$stage" "$release"
  stage=$release
  mkdir -p "$stage/thirdparty/tcc/lib"
  gcc -O2 -fPIC -DGC_THREADS=1 -DTHREAD_LOCAL_ALLOC=1 -DGC_BUILTIN_ATOMIC=1 -DALL_INTERIOR_POINTERS=1 \
    -I "$stage/thirdparty/libgc/include" -c "$stage/thirdparty/libgc/gc.c" -o "$stage/thirdparty/tcc/lib/gc.o"
  ar rcs "$stage/thirdparty/tcc/lib/libgc.a" "$stage/thirdparty/tcc/lib/gc.o"
  make -C "$stage" local=1 CC=gcc VFLAGS='-cc gcc'
  "$stage/v" version
  printf '%s\n' "$V_REF" > "$stage/.vlang-revision"
  # Source trees are part of a usable compiler; Git metadata is unnecessary.
  rm -rf "$stage/.git" "$stage/vc/.git"
  trap - EXIT HUP INT TERM
fi
ln -sfn "$release" "$root/candidate"
if [ "${VLANG_KAK_STAGE:-0}" != 1 ]; then
  mv -Tf "$root/candidate" "$root/current"
fi

echo "Managed V: $root/current/v (prepared candidate when staging)"
