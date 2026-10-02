#!/bin/sh
# Emit a buffer checkpoint and append its restoration commands.
set -eu
case ${1:-} in --help|-h) echo 'Usage: session-buffer.sh (called by Kakoune with buffer checkpoint environment)'; exit 0 ;; esac
umask 077
[ "$kak_bufname" != "*debug*" ] || exit 0
# Before Kakoune 2026.04, scratch buffers expose their name as buffile.
# File buffers always expose an absolute path.
case "$kak_buffile" in /*|'') ;; *) kak_buffile= ;; esac
directory=$kak_opt_v_session_checkpoint
identity=$(printf %s "$kak_bufname" | sha256sum | cut -d ' ' -f 1)
copy=$directory/buffer-$identity
quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
if [ -n "$kak_buffile" ] && [ "$kak_modified" != true ] && [ -f "$kak_buffile" ]; then
  printf 'edit -existing -- %s\n' "$(quote "$kak_buffile")" >> "$directory/buffers.kak"
else
  if [ -n "$kak_buffile" ]; then
    printf 'edit -existing -- %s\n' "$(quote "$kak_buffile")" >> "$directory/buffers.kak"
  else
    printf 'try %%{ buffer %s } catch %%{ edit -scratch %s }\n' "$(quote "$kak_bufname")" "$(quote "$kak_bufname")" >> "$directory/buffers.kak"
  fi
  # Suppress user write hooks: this is a recovery copy, not a project save.
  printf 'evaluate-commands -no-hooks %%{ write -force -- %s }\n' "$(quote "$copy")"
  command="%|cat -- '$(printf %s "$copy" | sed "s/'/'\\\\''/g")'"
  command=$(printf %s "$command" | sed 's/</<lt>/g')'<ret>'
  printf 'set-option buffer readonly false\nexecute-keys %s\n' "$(quote "$command")" >> "$directory/buffers.kak"
fi
restored_type=$kak_opt_filetype
if [ -z "$kak_buffile" ]; then
  case "$restored_type:$kak_bufname" in
    v-tree:*|v-doc:*|v-debug-*|make:*|lsp-*|*:\*hover\*) restored_type=v-recovery ;;
  esac
fi
printf 'set-option buffer filetype %s\nset-option buffer readonly %s\n' "$(quote "$restored_type")" "$kak_opt_readonly" >> "$directory/buffers.kak"
