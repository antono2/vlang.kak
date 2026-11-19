#!/bin/sh
# Compatibility entry point for the editor integration suite.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec v run "$script_dir/run.vsh" "$@"
