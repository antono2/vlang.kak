#!/bin/sh
# Select the checkpoint helper and keep session saves available without V.
set -eu
case ${1:-} in
  --help|-h) echo 'Usage: session-buffer.sh [begin ROOT|buffer|client|main|finish BACKEND|--prepare DIRECTORY|restore DIRECTORY|restart DIRECTORY STATE|restart-files [FILE...]]'; exit 0 ;;
  begin|restore|restart|restart-files)
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    if command -v v >/dev/null 2>&1; then
      exec "$script_dir/helper-cache.sh" checkpoint --read "$@"
    fi
    exec "$script_dir/session-checkpoint-posix" "$@" ;;
  --prepare)
    [ "$#" = 2 ] || exit 2
    if command -v v >/dev/null 2>&1; then
      script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      if ! "$script_dir/helper-cache.sh" checkpoint "$2"; then
        rm -f -- "$2/session-checkpoint"
        echo 'V checkpoint writer could not build; using the POSIX writer.' >&2
      fi
    fi
    exit 0 ;;
esac
if [ "$#" -eq 0 ]; then set -- buffer; fi
helper=${kak_opt_v_session_checkpoint:?}/session-checkpoint
if [ -x "$helper" ]; then
  exec "$helper" "$@"
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/session-checkpoint-posix" "$@"
