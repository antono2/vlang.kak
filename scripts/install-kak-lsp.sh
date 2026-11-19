#!/bin/sh
# Compatibility entry point for the V kak-lsp installer.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec v run "$script_dir/install-kak-lsp.vsh" "$@"
