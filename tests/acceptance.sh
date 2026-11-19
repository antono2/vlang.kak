#!/bin/sh
# Compatibility entry point for the V IDE acceptance suite.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec v run "$script_dir/acceptance.vsh" "$@"
