#!/bin/sh
# Dispatch the health command through the common compiler bootstrap.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/diagnostics-dispatch" health "$@"
