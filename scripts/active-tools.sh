#!/bin/sh
# List executable paths under the prefix and live managed environments.
set -eu
case ${1:-} in --help|-h) echo 'Usage: active-tools.sh PREFIX'; exit 0 ;; esac
prefix=$1
for process in /proc/[0-9]*; do
  executable=$(readlink "$process/exe" 2>/dev/null || true)
  case "$executable" in "$prefix/opt/vlang-"*) printf '%s\n' "$executable" ;; esac
  if [ -r "$process/environ" ] && awk -v expected="VLANG_KAK_PREFIX=$prefix" 'BEGIN { RS="\0" } $0==expected {found=1} END {exit !found}' "$process/environ" 2>/dev/null; then
    printf 'managed-process:%s\n' "${process##*/}"
  fi
done
