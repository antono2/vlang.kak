#!/bin/sh
# Serialize setup and restore the previous complete activation on failure.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname "$script_dir")
. "$script_dir/install-lock.inc"
prefix=$HOME/.local
previous=
for argument do
  if [ "$previous" = --prefix ]; then prefix=$argument; fi
  case "$argument" in --help|-h) exec "$script_dir/setup-impl.sh" --help ;; esac
  previous=$argument
done
case "$prefix" in *:*|*"$(printf '\t')"*|*"'"*|*'
'*) echo 'Colons/quotes/tabs/newlines in installation prefixes are unsupported.' >&2; exit 2 ;; esac
case "$prefix" in /*) ;; *) echo 'Use an absolute installation prefix.' >&2; exit 2 ;; esac
for argument do
  [ "$argument" != --install-dependencies ] || "$script_dir/dependencies.sh" --apply
done
"$script_dir/preflight.sh" "$@"
state=$prefix/opt/vlang-state
mkdir -p "$state"
lock_acquire setup
snapshot=$(mktemp -d "$state/pending.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ]; then
    restored=true
    if [ -f "$snapshot/ready" ]; then
      "$script_dir/managed-state.sh" restore "$prefix" "$snapshot" || restored=false
    fi
    if [ "$restored" = false ]; then echo "Automatic restoration failed; inspect $snapshot" >&2; fi
    if [ -f "$snapshot/plugin-revision" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ]; then
      old=$(cat "$snapshot/plugin-revision")
      [ "$old" = "$(git -C "$repo_dir" rev-parse HEAD)" ] || git -C "$repo_dir" checkout --detach "$old"
    fi
    if [ "$restored" = true ]; then echo 'Setup failed. Previous managed tool activation restored.' >&2; fi
    [ "$restored" = false ] || rm -rf "$snapshot"
  else
    rm -rf "$state/previous"
    mv "$snapshot" "$state/previous"
  fi
  for tool in kakoune kak-lsp vls v; do rm -f "$prefix/opt/vlang-$tool/candidate"; done
  lock_release
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
# Legacy/cached releases have no trustworthy per-file ownership baseline.
# Keep them unowned rather than adopting user additions or edits on migration.
unknown=$(mktemp "$state/unowned.XXXXXXXX")
[ ! -f "$state/unowned-releases" ] || cat "$state/unowned-releases" > "$unknown"
for tool in kakoune kak-lsp vls v; do
  for release in "$prefix/opt/vlang-$tool"/releases/*; do
    [ -d "$release" ] || continue
    if [ ! -f "$state/manifest.tsv" ] || ! awk -F '\t' -v p="$release" '$3==p {found=1} END {exit !found}' "$state/manifest.tsv"; then
      printf '%s\n' "$release" >> "$unknown"
    fi
  done
done
LC_ALL=C sort -u "$unknown" > "$state/unowned-releases.next"
mv "$state/unowned-releases.next" "$state/unowned-releases"
rm "$unknown"
"$script_dir/managed-state.sh" snapshot "$prefix" "$snapshot"
touch "$snapshot/ready"
if [ -d "$repo_dir/.git" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ]; then
  previous_plugin=$(git -C "$repo_dir" rev-parse --verify "${VLANG_KAK_PREVIOUS_PLUGIN_REVISION:-HEAD}^{commit}")
  printf '%s\n' "$previous_plugin" > "$snapshot/plugin-revision"
  printf '%s\n' "$repo_dir" > "$snapshot/plugin-repo"
fi
VLANG_KAK_STAGE=1
VLANG_KAK_TRANSACTION=$snapshot
export VLANG_KAK_STAGE VLANG_KAK_TRANSACTION
"$script_dir/setup-impl.sh" "$@"
