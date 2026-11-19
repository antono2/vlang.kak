#!/bin/sh
# Compatibility entry point for the VLS installer.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v v >/dev/null 2>&1; then
  exec v run "$script_dir/install-vls.vsh" "$@"
fi
# --v-command also works on machines that have no V compiler on PATH.
find_explicit_compiler() {
  compiler=
  while [ "$#" -ge 2 ]; do
    if [ "$1" = --v-command ]; then compiler=$2; fi
    shift 2
  done
  [ -n "$compiler" ] && [ -x "$compiler" ]
}
if find_explicit_compiler "$@"; then
  exec "$compiler" run "$script_dir/install-vls.vsh" "$@"
fi
echo 'V compiler is required to build VLS; install V or use --vls PATH with setup.sh.' >&2
exit 1
