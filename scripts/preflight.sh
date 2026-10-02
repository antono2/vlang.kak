#!/bin/sh
# Read-only dependency checks before download/build work.
set -eu
case ${1:-} in --help|-h) echo 'Usage: preflight.sh [setup options]'; exit 0 ;; esac
build=true; lsp=true; vls=true; explorer=true; managed_v=false
for option do
  case "$option" in --no-build) build=false ;; --no-lsp) lsp=false ;; --no-vls|--vls) vls=false ;; --no-explorer) explorer=false ;; --managed-v) managed_v=true ;; esac
done
status=0
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1 ($2)" >&2; status=1; }; }
for tool in git sed awk sort mktemp sha256sum readlink; do need "$tool" 'installation'; done
if [ "$build" = true ]; then
  need make 'build Kakoune'; need "${CXX:-c++}" 'build Kakoune'
  if command -v "${CXX:-c++}" >/dev/null 2>&1 && ! printf '' | "${CXX:-c++}" -std=c++2b -x c++ -fsyntax-only - >/dev/null 2>&1; then
    echo 'C++ compiler must support -std=c++2b.' >&2; status=1
  fi
fi
if [ "$lsp" = true ]; then need curl 'download kak-lsp'; need tar 'extract kak-lsp'; fi
if [ "$vls" = true ] || [ "$explorer" = true ] || [ "$managed_v" = true ]; then
  need gcc 'V compilation'; need make 'managed compiler fallback'; need ar 'managed compiler fallback'
fi
if [ "$status" != 0 ]; then
  echo 'Install the listed dependencies with your system package manager, then rerun setup. No system packages were changed.' >&2
fi
exit "$status"
