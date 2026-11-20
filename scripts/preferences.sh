#!/bin/sh
# Builds and dispatches the project-preferences helper for the active installation.
set -eu
case ${1:-} in --help|-h) echo 'Usage: preferences.sh --prepare | load|show|show-command|args|cwd|target|targets|targets-menu|reset FILE [VALUE...]'; exit 0 ;; esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/helper-cache.sh" preferences "$@"
