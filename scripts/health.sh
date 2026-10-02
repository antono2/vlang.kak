#!/bin/sh
# Actionable health report, optionally suitable for a bug report.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
if [ -f "$prefix/opt/vlang-kakoune/ide-config/kak/kakrc" ] && grep -q '^# vlang.kak compiler: managed$' "$prefix/opt/vlang-kakoune/ide-config/kak/kakrc"; then PATH="$prefix/opt/vlang-v/current:$PATH"; fi
PATH="$prefix/bin:$PATH"
export PATH
case ${1:-} in
  --help|-h) echo 'Usage: health.sh [--report | --repair] (VLANG_KAK_PREFIX selects installation)'; exit 0 ;;
  --repair)
    echo 'Repairing managed launchers/configuration using the existing tools.'
    exec "$script_dir/setup.sh" --prefix "$prefix" --repair --no-build --no-lsp --no-vls ;;
  --report|'') ;; *) exit 2 ;;
esac
printf 'V IDE health\n\n'
status=0
"$script_dir/check.sh" || status=$?
printf '\nPane backend: '
"$script_dir/windowing.sh" detect "${kak_opt_v_window_backend:-auto}" || true
printf '\nCompiler: '; if command -v v >/dev/null 2>&1; then v version; else echo 'missing; rerun setup for a managed compiler'; fi
printf 'Plugin revision: '; git -C "$script_dir/.." describe --tags --always --dirty 2>/dev/null || echo 'source archive'
for tool in gcc rg git tmux; do
  if command -v "$tool" >/dev/null 2>&1; then printf '%s: available\n' "$tool"; else printf '%s: unavailable\n' "$tool"; fi
done
if [ -f "$prefix/opt/vlang-state/manifest.tsv" ]; then
  printf 'Ownership manifest: present\n'
else echo 'Ownership manifest: missing; rerun setup before automated removal.'; fi
state=$prefix/opt/vlang-state
. "$script_dir/install-lock.inc"
printf '\n'
lock_state=0
lock_status || lock_state=$?
for pending in "$state"/pending.*; do
  [ -d "$pending" ] || continue
  if [ -f "$pending/ready" ]; then
    if [ "$lock_state" = 1 ]; then echo "Setup snapshot (operation active): $pending"; else
    echo "Interrupted setup snapshot: $pending (keep it until recovery is complete)."
    echo "Recover it: scripts/rollback.sh --prefix '$prefix' --recover '$pending'"; fi
  else echo "Incomplete setup snapshot: $pending (activation snapshot was not completed)."; fi
done
[ ! -f "$state/previous/paths" ] || echo 'Previous installation snapshot: available for rollback.'
printf '\nRepair: :v-repair or scripts/health.sh --repair\nRollback: :v-rollback or scripts/rollback.sh\n'
printf 'Missing system dependencies: install through your package manager, then rerun setup.\n'
if [ "${1:-}" = --report ]; then
  echo 'Review this report before sharing: it contains executable and configuration paths.'
fi

exit "$status"
