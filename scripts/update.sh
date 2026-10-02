#!/bin/sh
# Update development checkout or select a published, tested release.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
release=false
if [ "${VLANG_KAK_SKIP_PULL:-0}" != 1 ] && ! git -C "$repo_dir" symbolic-ref -q HEAD >/dev/null 2>&1; then release=true; fi
for option do case "$option" in --release) release=true ;; --help|-h) echo 'Usage: update.sh [--release] [setup options]'; exec "$script_dir/setup.sh" --help ;; esac; done
if [ "$release" = true ]; then
  [ -d "$repo_dir/.git" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ] || { echo 'Release selection requires a clean Git checkout; local changes were kept.' >&2; exit 1; }
  tag=$(git ls-remote --tags --refs https://github.com/antono2/vlang.kak.git 'v[0-9]*' | sed -n 's,.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$,\1,p' | sort -V | tail -n 1)
  [ -n "$tag" ] || exit 1
  old=$(git -C "$repo_dir" rev-parse HEAD)
  git -C "$repo_dir" fetch origin "refs/tags/$tag:refs/tags/$tag"
  target=$(git -C "$repo_dir" rev-parse "$tag^{}")
  if [ "$old" != "$target" ] && git -C "$repo_dir" merge-base --is-ancestor "$target" "$old"; then
    echo "Checkout already contains release $tag; keeping the newer development revision."
    exit 0
  fi
  git -C "$repo_dir" checkout --detach "$tag"
  . "$repo_dir/tests/release.env"
  prefix=$HOME/.local; previous=
  for argument do [ "$previous" != --prefix ] || prefix=$argument; previous=$argument; done
  if [ -x "$repo_dir/scripts/install-v.sh" ]; then set -- "$@" --managed-v; fi
  # --release owns version selection. Other setup choices remain unchanged.
  set -- "$@" --kakoune-version "$KAKOUNE_VERSION" --lsp-version "$LSP_VERSION" --vls-ref "$VLS_REF"
  count=$#
  while [ "$count" -gt 0 ]; do argument=$1; shift; count=$((count - 1)); [ "$argument" = --release ] || set -- "$@" "$argument"; done
  VLANG_KAK_SKIP_PULL=1 "$repo_dir/scripts/setup.sh" --update "$@" || {
    git -C "$repo_dir" checkout --detach "$old"; exit 1;
  }
  state=$prefix/opt/vlang-state
  if [ -d "$state/previous" ]; then printf '%s\n' "$old" > "$state/previous/plugin-revision"; printf '%s\n' "$repo_dir" > "$state/previous/plugin-repo"; fi
  exit 0
fi
exec "$script_dir/setup.sh" --update "$@"
