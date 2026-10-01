#!/bin/sh
# Explicit system-package preparation; default is a command preview.
set -eu
apply=false
case ${1:-} in --apply) apply=true ;; --help|-h) echo 'Usage: dependencies.sh [--apply]'; exit 0 ;; '') ;; *) exit 2 ;; esac
if [ ! -r /etc/os-release ]; then echo 'Unknown distribution; install Git, Make, GCC/C++, curl, tar, ripgrep, tmux and GDB 14+ using your package manager.'; exit 1; fi
. /etc/os-release
case "$ID" in
  ubuntu|debian)
    packages='build-essential git curl tar unzip ripgrep tmux gdb'
    printf 'Distribution: %s\nCommands:\nsudo apt-get update\nsudo apt-get install --yes %s\n' "$PRETTY_NAME" "$packages"
    if [ "$apply" = true ]; then
      if [ "$(id -u)" = 0 ]; then apt-get update; apt-get install --yes $packages
      else sudo apt-get update; sudo apt-get install --yes $packages; fi
    fi ;;
  *) echo "No automatic package recipe for $ID. Install Git, Make, GCC/C++ (C++23), curl, tar, ripgrep, tmux and GDB 14+ using your package manager."; exit 1 ;;
esac
[ "$apply" = true ] || echo 'Preview only. Use --apply or setup.sh --install-dependencies to request system changes.'
