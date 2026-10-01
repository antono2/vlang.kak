#!/bin/sh
# Install a tagged kakoune-lsp release alongside other user tools.
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/install-kak-lsp.sh [--latest | --version vMAJOR.MINOR.PATCH]
                                   [--prefix DIRECTORY]
Install the selected kak-lsp binary under PREFIX/opt/vlang-kak-lsp.
Default: latest stable tag, PREFIX=$HOME/.local.
EOF
}

version=latest
prefix=$HOME/.local
while [ "$#" -gt 0 ]; do
  case "$1" in
    --latest) version=latest; shift ;;
    --version) version=$2; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
prefix=$(mkdir -p "$prefix" && CDPATH= cd -- "$prefix" && pwd)

for tool in git curl tar sed sort mktemp; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Missing required tool: $tool" >&2
    exit 1
  }
done
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
  echo "The binary installer currently supports Linux x86_64." >&2
  echo "Install kak-lsp with Cargo and configure its path manually." >&2
  exit 1
fi

upstream=https://github.com/kakoune-lsp/kakoune-lsp.git
if [ "$version" = latest ]; then
  version=$(git ls-remote --tags --refs "$upstream" 'v[0-9]*' |
    sed -n 's,.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$,\1,p' |
    LC_ALL=C sort -V | tail -n 1)
fi
case "$version" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Could not resolve a stable kakoune-lsp release tag." >&2; exit 1 ;;
esac

opt_root=$prefix/opt/vlang-kak-lsp
release_dir=$opt_root/releases/$version
mkdir -p "$opt_root/releases"
if [ ! -x "$release_dir/bin/kak-lsp" ]; then
  if [ -e "$release_dir" ]; then
    echo "Incomplete managed release at $release_dir; move it aside and retry." >&2
    exit 1
  fi
  temp_base=${TMPDIR:-/tmp}
  install_dir=$(mktemp -d "$temp_base/vlang-kak-lsp.XXXXXXXX")
  stage_dir=$(mktemp -d "$opt_root/releases/.stage-$version.XXXXXXXX")
  trap 'rm -rf -- "$install_dir" "$stage_dir"' EXIT HUP INT TERM
  archive=kakoune-lsp-$version-x86_64-unknown-linux-musl.tar.gz
  curl --fail --location --retry 3 \
    --output "$install_dir/$archive" \
    "https://github.com/kakoune-lsp/kakoune-lsp/releases/download/$version/$archive"
  tar -xzf "$install_dir/$archive" -C "$install_dir" kak-lsp
  mkdir -p "$stage_dir/bin"
  cp "$install_dir/kak-lsp" "$stage_dir/bin/kak-lsp"
  chmod 755 "$stage_dir/bin/kak-lsp"
  printf '%s\n' "$version" > "$stage_dir/.vlang-version"
  mv "$stage_dir" "$release_dir"
fi
if [ "${VLANG_KAK_STAGE:-0}" = 1 ]; then
  ln -sfn "$release_dir" "$opt_root/candidate"
  echo "Prepared $release_dir"
  exit 0
fi

ln -sfn "releases/$version" "$opt_root/current.next"
mv -Tf "$opt_root/current.next" "$opt_root/current"
"$opt_root/current/bin/kak-lsp" --version
echo "kak-lsp $version is available at $opt_root/current/bin/kak-lsp"
