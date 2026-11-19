#!/bin/sh
# Compatibility entry point for the V pane-host installer.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec v run "$script_dir/install-pane-hosts.vsh" "$@"
