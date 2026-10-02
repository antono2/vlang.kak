#!/bin/sh
# Report the tools and configuration used by the V IDE.
set -eu

case ${1:-} in
  --help|-h)
    echo 'Usage: scripts/check.sh [--live-lsp] (set VLANG_KAK_PREFIX for a nondefault prefix)'
    exit 0 ;;
  --live-lsp) live_lsp=true ;;
  '') live_lsp=false ;;
  *) echo 'Usage: scripts/check.sh' >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
config_home=${VLANG_KAK_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}
compiler_mode=system
settings=$prefix/opt/vlang-kakoune/ide-config/kak/kakrc
if [ -f "$settings" ] && grep -q '^# vlang.kak compiler: managed$' "$settings"; then compiler_mode=managed; fi
if [ "$compiler_mode" = managed ]; then PATH="$prefix/opt/vlang-v/current:$PATH"; fi
PATH="$prefix/bin:$PATH"
export PATH
status=0

report_command() {
  label=$1
  executable=$2
  if command -v "$executable" >/dev/null 2>&1; then
    printf '%s: %s\n' "$label" "$(command -v "$executable")"
  else
    printf '%s: missing\n' "$label"
    status=1
  fi
}

report_command V v
if [ -x "$prefix/bin/kak" ]; then
  printf 'Kakoune: %s (%s)\n' "$prefix/bin/kak" "$("$prefix/bin/kak" -version)"
elif command -v kak >/dev/null 2>&1; then
  printf 'Kakoune: %s (%s)\n' "$(command -v kak)" "$(kak -version)"
else
  echo 'Kakoune: missing'
  status=1
fi

lsp_bin=$prefix/opt/vlang-kak-lsp/current/bin/kak-lsp
if [ -x "$lsp_bin" ]; then
  printf 'kak-lsp: %s (%s)\n' "$lsp_bin" "$("$lsp_bin" --version)"
else
  report_command kak-lsp kak-lsp
fi
PATH="$prefix/bin:$PATH"
export PATH
report_command VLS vls

autoload=$prefix/opt/vlang-kakoune/ide-config/kak/autoload
if [ -L "$autoload/vlang.kak" ] &&
   [ "$(readlink -f "$autoload/vlang.kak")" = "$repo_dir/rc/vlang.kak" ]; then
  printf 'Plugin: %s\n' "$autoload/vlang.kak"
else
  echo 'Plugin: missing from the managed Kakoune autoload'
  status=1
fi
if [ -L "$autoload/vlang-site-runtime" ] &&
   [ -d "$autoload/vlang-site-runtime" ]; then
  printf 'Kakoune runtime: %s\n' "$(readlink -f "$autoload/vlang-site-runtime")"
else
  echo 'Kakoune runtime: not linked into user autoload'
  status=1
fi

if [ -f "$config_home/kak/vlang-user.kak" ]; then
  printf 'Customization: %s\n' "$config_home/kak/vlang-user.kak"
else
  echo 'Customization: no vlang-user.kak file'
fi

# Debugging is optional for editing; report unavailable DAP support without
# treating it as a broken language-server installation.
if command -v gdb >/dev/null 2>&1; then
  if gdb -q -nx --interpreter=dap < /dev/null > /dev/null 2>&1; then
    printf 'Debugger: %s (GDB DAP available)\n' "$(command -v gdb)"
  else
    echo 'Debugger: GDB lacks DAP support; install GDB 14 or newer with Python support'
  fi
else
  echo 'Debugger: missing GDB; install GDB 14 or newer with Python support to debug'
fi

if [ "$live_lsp" = true ]; then
  if [ "$status" -ne 0 ]; then
    echo 'Live VLS check skipped until the installation checks pass.' >&2
  elif ! command -v python3 >/dev/null 2>&1; then
    echo 'Python 3 is required for the live VLS check.' >&2
    status=1
  elif ! python3 "$script_dir/check-vls.py" --prefix "$prefix"; then
    status=1
  fi
fi
exit "$status"
