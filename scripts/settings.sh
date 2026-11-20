#!/bin/sh
# Dispatch personal settings commands to V, with a fallback for minimal editor installs.
set -eu
case ${1:-} in --help|-h) echo 'Usage: settings.sh SETTING VALUE | --file | --menu EXPLORER SEARCH UPDATE PANE'; exit 0 ;; esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case ${1:-} in
    --file|--menu) exec "$script_dir/helper-cache.sh" settings "$@" ;;
esac
if command -v v >/dev/null 2>&1; then
    exec v run "$script_dir/settings.vsh" "$@"
fi
exec "$script_dir/settings-posix" "$@"
