#!/bin/sh
# Install, exercise, update, and recheck a real stack in an isolated configuration.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repo_dir/tests/release.env"
KAKOUNE_VERSION=${VLANG_RELEASE_KAKOUNE_REF:-$KAKOUNE_VERSION}
case ${1:-} in
  --help|-h) echo 'Usage: tests/release.sh [ARTIFACT_DIRECTORY] (requires V, build tools, tmux, GDB with DAP, Python 3, and network)'; exit 0 ;;
esac
root=${1:-$(mktemp -d "${TMPDIR:-/tmp}/vlang-release.XXXXXXXX")}
mkdir -p "$root"
root=$(CDPATH= cd -- "$root" && pwd)
prefix=$root/prefix
XDG_CONFIG_HOME=$root/config
XDG_CACHE_HOME=$root/cache
VLANG_KAK_PREFIX=$prefix
VLANG_KAK_SKIP_PULL=1
VLANG_LSP_ARTIFACTS=$root/lsp
unset VLANG_KAK_CONFIG_HOME
export XDG_CONFIG_HOME XDG_CACHE_HOME VLANG_KAK_PREFIX VLANG_KAK_SKIP_PULL VLANG_LSP_ARTIFACTS
printf 'Release test artifacts: %s\n' "$root"
"$repo_dir/scripts/setup.sh" --prefix "$prefix" \
  --kakoune-version "$KAKOUNE_VERSION" --lsp-version "$LSP_VERSION" --vls-ref "$VLS_REF"
PATH="$prefix/bin:$PATH"
export PATH
"$repo_dir/scripts/check.sh" --live-lsp
python3 "$repo_dir/tests/lifecycle_stack.py" "$prefix"
"$repo_dir/tests/acceptance.sh" "$prefix" "$root/acceptance"
"$repo_dir/scripts/update.sh" --prefix "$prefix" \
  --kakoune-version "$KAKOUNE_VERSION" --lsp-version "$LSP_VERSION" --vls-ref "$VLS_REF"
"$repo_dir/scripts/check.sh" --live-lsp
printf 'ok - clean managed installation, live navigation, debugging, panes, restart, and update\n'
