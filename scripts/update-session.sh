#!/bin/sh
# Update managed tools, then ask the original Kakoune client to restart.
set -eu

case ${1:-} in
  --help|-h)
    echo 'Usage: update-session.sh PREFIX SESSION CLIENT CLIENT_PID [update options]'
    exit 0 ;;
esac

if [ "$#" -lt 4 ]; then
  echo 'Usage: update-session.sh PREFIX SESSION CLIENT CLIENT_PID [update options]' >&2
  exit 2
fi
prefix=$1
session=$2
client=$3
client_pid=$4
shift 4
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for option in "$@"; do
  case "$option" in
    --prefix) echo 'The in-editor update keeps the current installation prefix.' >&2; exit 2 ;;
  esac
done

case "$client_pid" in
  *[!0-9]*|'') echo 'Invalid Kakoune client PID.' >&2; exit 2 ;;
esac
old_kak=$(readlink -f "/proc/$client_pid/exe")
[ -x "$old_kak" ] || { echo 'Cannot locate the running Kakoune executable.' >&2; exit 1; }

"$script_dir/update.sh" --prefix "$prefix" "$@"
echo 'Update installed. Requesting restart.'
echo 'If Kakoune remains open, check *debug* for the restart error. Save edits, close additional clients or stop debugging, then run :v-restart.'
echo 'For unsaved buffers and multiple views, use :v-restart-recover and confirm the recovery restart.'
quoted_client=$(printf %s "$client" | sed "s/'/''/g")
if ! printf "evaluate-commands -client '%s' %%{ v-restart }\n" "$quoted_client" |
  "$old_kak" -p "$session"; then
  echo 'The update succeeded, but the original session could not receive the restart request.' >&2
  echo "Run '$prefix/bin/kak-v' to start the updated IDE; existing recovery checkpoints are kept." >&2
  exit 1
fi
