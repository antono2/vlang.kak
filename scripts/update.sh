#!/bin/sh
# Fast-forward a clean plugin checkout and update the managed IDE tools.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
for argument in "$@"; do
  case "$argument" in
    --help|-h) exec "$script_dir/setup.sh" --help ;;
  esac
done
if [ "${VLANG_KAK_SKIP_PULL:-0}" = 1 ]; then
  echo 'Keeping local vlang.kak checkout: Git update skipped.'
elif [ -d "$repo_dir/.git" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ]; then
  git -C "$repo_dir" pull --ff-only
else
  echo "Keeping local vlang.kak checkout: it has uncommitted changes or is not a Git clone."
fi
VLANG_KAK_SKIP_PULL=1
export VLANG_KAK_SKIP_PULL
exec "$script_dir/setup.sh" --update "$@"
