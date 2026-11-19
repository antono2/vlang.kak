#!/bin/sh
# Build one checkpoint writer for all buffers and clients in a session save.
set -eu
case ${1:-} in
  --help|-h) echo 'Usage: session-buffer.sh [buffer|client|main|--prepare DIRECTORY]'; exit 0 ;;
  --prepare)
    [ "$#" = 2 ] || exit 2
    if command -v v >/dev/null 2>&1; then
      script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
      if ! v -skip-running -o "$2/session-checkpoint" "$script_dir/session-checkpoint.vsh"; then
        rm -f -- "$2/session-checkpoint"
        echo 'V checkpoint writer could not build; using the POSIX writer.' >&2
      fi
    fi
    exit 0 ;;
esac
helper=${kak_opt_v_session_checkpoint:?}/session-checkpoint
if [ -x "$helper" ]; then
  exec "$helper" "${1:-buffer}"
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/session-checkpoint-posix" "${1:-buffer}"
