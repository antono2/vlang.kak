#!/bin/sh
# Serialize setup and restore the previous complete activation on failure.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
mkdir "$state/lock" 2>/dev/null || { echo 'Another setup/removal operation is active.' >&2; exit 1; }
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
    echo 'Setup failed. Previous managed tool activation restored.' >&2
    [ "$restored" = false ] || rm -rf "$snapshot"
  else
    rm -rf "$state/previous"
    mv "$snapshot" "$state/previous"
  fi
  for tool in kakoune kak-lsp vls v; do rm -f "$prefix/opt/vlang-$tool/candidate"; done
  rmdir "$state/lock"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
"$script_dir/managed-state.sh" snapshot "$prefix" "$snapshot"
touch "$snapshot/ready"
repo_dir=$(dirname "$script_dir")
if [ -d "$repo_dir/.git" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ]; then
  git -C "$repo_dir" rev-parse HEAD > "$snapshot/plugin-revision"
  printf '%s\n' "$repo_dir" > "$snapshot/plugin-repo"
fi
VLANG_KAK_STAGE=1
VLANG_KAK_TRANSACTION=$snapshot
export VLANG_KAK_STAGE VLANG_KAK_TRANSACTION
"$script_dir/setup-impl.sh" "$@"
