#!/bin/sh
# Build a Kakoune tag or pinned commit without changing the system package.
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/build-kakoune.sh [--latest | --version TAG_OR_COMMIT_OR_master]
                                 [--prefix DIRECTORY] [--jobs NUMBER]
Install the selected Kakoune revision under PREFIX/opt/vlang-kakoune and
create a managed PREFIX/bin/kak launcher. Default: latest stable tag,
PREFIX=$HOME/.local.
EOF
}

version=latest
prefix=$HOME/.local
jobs=2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --latest) version=latest; shift ;;
    --version) version=$2; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --jobs) jobs=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$prefix" in
  *"'"*|*'
'*) echo "The installation prefix cannot contain quotes or newlines." >&2; exit 2 ;;
esac
prefix=$(mkdir -p "$prefix" && CDPATH= cd -- "$prefix" && pwd)

for tool in git make sed sort mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done
compiler=${CXX:-c++}
command -v "$compiler" >/dev/null 2>&1 || {
  echo "Missing C++ compiler: $compiler" >&2
  exit 1
}
printf '' | "$compiler" -std=c++2b -x c++ -fsyntax-only - >/dev/null 2>&1 || {
  echo "Kakoune's current Makefile needs a compiler accepting -std=c++2b." >&2
  exit 1
}

upstream=https://github.com/mawww/kakoune.git
if [ "$version" = latest ]; then
  version=$(git ls-remote --tags --refs "$upstream" 'v20*' |
    sed -n 's,.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$,\1,p' |
    LC_ALL=C sort -r | head -n 1)
fi
if [ "$version" = master ]; then
  version=$(git ls-remote "$upstream" refs/heads/master | awk '{print $1}')
fi
case "$version" in
  v[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]) ;;
  *)
    if ! printf '%s\n' "$version" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$'; then
      echo "Select a stable tag, master, or a full upstream commit hash." >&2
      exit 1
    fi
    ;;
esac

opt_root=$prefix/opt/vlang-kakoune
release_dir=$opt_root/releases/$version
launcher=$prefix/bin/kak
mkdir -p "$opt_root/releases" "$prefix/bin"
if [ -e "$launcher" ] && ! grep -q '^# vlang.kak managed Kakoune launcher$' "$launcher"; then
  echo "Existing unmanaged launcher at $launcher; choose another --prefix." >&2
  exit 1
fi

if [ ! -x "$release_dir/bin/kak" ] || [ ! -d "$release_dir/share/kak/rc" ]; then
  if [ -e "$release_dir" ]; then
    echo "Incomplete managed release at $release_dir; move it aside and retry." >&2
    exit 1
  fi
  temp_base=${TMPDIR:-/tmp}
  build_dir=$(mktemp -d "$temp_base/vlang-kakoune-build.XXXXXXXX")
  stage_dir=$(mktemp -d "$opt_root/releases/.stage-$version.XXXXXXXX")
  trap 'rm -rf -- "$build_dir" "$stage_dir"' EXIT HUP INT TERM
  git init -q "$build_dir/kakoune"
  git -C "$build_dir/kakoune" fetch --depth 1 "$upstream" "$version"
  git -C "$build_dir/kakoune" checkout -q --detach FETCH_HEAD
  git -C "$build_dir/kakoune" rev-parse HEAD > "$stage_dir/.vlang-revision"
  # A shallow commit fetch may contain no reachable tag. Supply Makefile's
  # version file so these builds still report their exact identity.
  printf '%s\n' "${version#v}" > "$build_dir/kakoune/.version"
  make -C "$build_dir/kakoune" -j "$jobs"
  "$build_dir/kakoune/src/kak" -version
  make -C "$build_dir/kakoune" PREFIX="$stage_dir" install
  printf '%s\n' "$version" > "$stage_dir/.vlang-version"
  mv "$stage_dir" "$release_dir"
fi

ln -sfn "releases/$version" "$opt_root/current.next"
mv -Tf "$opt_root/current.next" "$opt_root/current"
cat > "$launcher.tmp" <<EOF
#!/bin/sh
# vlang.kak managed Kakoune launcher
KAKOUNE_RUNTIME='$opt_root/current/share/kak'
export KAKOUNE_RUNTIME
exec '$opt_root/current/bin/kak' "\$@"
EOF
chmod 755 "$launcher.tmp"
mv -f "$launcher.tmp" "$launcher"
"$launcher" -version
echo "Kakoune $version is available at $launcher"
