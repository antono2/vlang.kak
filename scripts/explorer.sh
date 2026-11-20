#!/bin/sh
# Compile the explorer once and refresh it when its V source changes.
set -eu
case "${1:-}" in
  --help|-h)
    echo 'Usage: scripts/explorer.sh --prepare | COMMAND STATE [ARG...]'
    exit 0
    ;;
esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/helper-cache.sh" explorer "$@"
