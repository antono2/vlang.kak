#!/bin/sh
# Run the documented IDE acceptance pass against an existing managed stack.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case ${1:-} in
  ''|--help|-h)
    echo 'Usage: tests/acceptance.sh PREFIX [ARTIFACT_DIRECTORY]'
    echo 'Requires a managed Kakoune/kak-lsp/VLS stack, V, Python 3, tmux, and GDB DAP.'
    exit 0 ;;
esac
prefix=$(CDPATH= cd -- "$1" && pwd)
root=${2:-$(mktemp -d "${TMPDIR:-/tmp}/vlang-acceptance.XXXXXXXX")}
mkdir -p "$root"
root=$(CDPATH= cd -- "$root" && pwd)
KAK=$prefix/opt/vlang-kakoune/current/bin/kak
KAKOUNE_RUNTIME=$prefix/opt/vlang-kakoune/current/share/kak
PATH="$prefix/bin:$PATH"
XDG_CONFIG_HOME=$root/config
XDG_CACHE_HOME=$root/cache
VLANG_TEST_REAL_TOOLS_PREFIX=$prefix
VLANG_DEBUG_ARTIFACTS=$root/debugger
VLANG_LSP_ARTIFACTS=$root/lsp
unset VLANG_KAK_CONFIG_HOME VLANG_KAK_RESTART_ALLOWED VLANG_KAK_RESTART_STATE
export KAK KAKOUNE_RUNTIME PATH XDG_CONFIG_HOME XDG_CACHE_HOME VLANG_TEST_REAL_TOOLS_PREFIX VLANG_DEBUG_ARTIFACTS VLANG_LSP_ARTIFACTS
printf 'Acceptance artifacts: %s\n' "$root"
printf 'Started: %s\n' "$(date -u +%FT%TZ)" > "$root/results.txt"
{
  "$KAK" -version
  v version
  gdb --version
  printf 'Plugin checkout: %s\n' "$repo_dir"
  git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true
  git -C "$repo_dir" status --short 2>/dev/null || true
} > "$root/versions.log"
run() {
  name=$1
  shift
  printf 'Running %s ...\n' "$name"
  if "$@" > "$root/$name.log" 2>&1; then
    printf 'PASS %s\n' "$name" | tee -a "$root/results.txt"
  else
    status=$?
    printf 'FAIL %s (exit %s)\n' "$name" "$status" | tee -a "$root/results.txt"
    cat "$root/$name.log" >&2
    exit "$status"
  fi
}
run core "$repo_dir/tests/run.sh"
run live-vls python3 "$repo_dir/scripts/check-vls.py" --prefix "$prefix"
run panes python3 "$repo_dir/tests/panes.py" "$prefix"
run debugger python3 "$repo_dir/tests/debugger.py" "$KAK"
printf 'All IDE acceptance checks passed. Logs: %s\n' "$root"
