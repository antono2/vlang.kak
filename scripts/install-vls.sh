#!/bin/sh
# Build upstream VLS in a versioned user-local installation.
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/install-vls.sh [--ref GIT_REF] [--prefix DIRECTORY] [--v-command PATH]
Build the latest vlang/vls default branch, or a chosen tag or commit, using V.
Install it under PREFIX/opt/vlang-vls and link PREFIX/bin/vls.
Default: latest upstream commit, PREFIX=$HOME/.local, V command from PATH.
EOF
}

ref=
prefix=$HOME/.local
v_command=$(command -v v || true)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref) ref=$2; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --v-command) v_command=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -n "$v_command" ] && [ -x "$v_command" ] || {
  echo 'V compiler is required to build VLS; install V or use --vls PATH with setup.sh.' >&2
  exit 1
}
command -v git >/dev/null 2>&1 || { echo 'Git is required to build VLS.' >&2; exit 1; }
prefix=$(mkdir -p "$prefix" && CDPATH= cd -- "$prefix" && pwd)
opt_root=$prefix/opt/vlang-vls
mkdir -p "$opt_root/releases" "$prefix/bin"
if [ -e "$prefix/bin/vls" ] && [ ! -L "$prefix/bin/vls" ]; then
  echo "Existing unmanaged VLS at $prefix/bin/vls; choose another --prefix." >&2
  exit 1
fi

build_dir=$(mktemp -d "${TMPDIR:-/tmp}/vlang-vls-build.XXXXXXXX")
stage_dir=
trap 'rm -rf -- "$build_dir" "$stage_dir"' EXIT HUP INT TERM
upstream=https://github.com/vlang/vls.git
if [ -n "$ref" ]; then
  git clone --depth 1 --no-checkout "$upstream" "$build_dir/vls"
  git -C "$build_dir/vls" fetch --depth 1 origin "$ref"
  git -C "$build_dir/vls" checkout --detach FETCH_HEAD
else
  git clone --depth 1 "$upstream" "$build_dir/vls"
fi
commit=$(git -C "$build_dir/vls" rev-parse HEAD)
release_dir=$opt_root/releases/$commit
if [ ! -x "$release_dir/bin/vls" ]; then
  if [ -e "$release_dir" ]; then
    echo "Incomplete managed release at $release_dir; move it aside and retry." >&2
    exit 1
  fi
  stage_dir=$(mktemp -d "$opt_root/releases/.stage-$commit.XXXXXXXX")
  if ! (cd "$build_dir/vls" && "$v_command" -o "$stage_dir/vls" .); then
    echo "VLS build failed with $("$v_command" version)." >&2
    echo 'Upstream VLS requires a compatible recent V compiler (including json2).' >&2
    echo 'See docs/release.md for the tested revision, or supply an existing VLS with setup.sh --vls PATH.' >&2
    echo 'Your V compiler and current VLS installation have not been replaced.' >&2
    exit 1
  fi
  [ -x "$stage_dir/vls" ] || { echo 'VLS build did not produce an executable.' >&2; exit 1; }
  mkdir -p "$stage_dir/bin"
  mv "$stage_dir/vls" "$stage_dir/bin/vls"
  printf '%s\n' "$commit" > "$stage_dir/.vlang-commit"
  mv "$stage_dir" "$release_dir"
  stage_dir=
fi
if [ "${VLANG_KAK_STAGE:-0}" = 1 ]; then
  ln -sfn "$release_dir" "$opt_root/candidate"
  echo "Prepared $release_dir"
  exit 0
fi

ln -sfn "releases/$commit" "$opt_root/current.next"
mv -Tf "$opt_root/current.next" "$opt_root/current"
ln -sfn "$opt_root/current/bin/vls" "$prefix/bin/vls"
echo "VLS $commit is available at $prefix/bin/vls"
