#!/bin/sh
# Remove only unchanged files recorded by this installation.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/install-lock.inc"
prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
apply=false
verbose=false
locked=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --verbose) verbose=true; shift ;;
    --apply) apply=true; shift ;;
    --help|-h) echo 'Usage: uninstall.sh [--prefix DIRECTORY] [--apply] [--verbose]'; echo 'Default: preview. Personal settings, modified files and external tools are kept.'; exit 0 ;;
    *) exit 2 ;;
  esac
done
prefix=$(readlink -m "$prefix")
state=$prefix/opt/vlang-state
manifest=$state/manifest.tsv
plan=$(mktemp)
cleanup() { rm -f "$plan"; [ "$locked" != true ] || lock_release || true; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
[ -f "$manifest" ] || { echo 'No ownership manifest. Rerun setup to record this installation before removal.' >&2; exit 1; }
if [ -d "$state/lock" ]; then lock_status >&2 || true; exit 1; fi
if [ "$apply" = true ]; then
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  # This uninstall process may inherit the prefix variable from a regular shell;
  # inspect executable paths and let owner markers handle editor environments.
  active=$(env -u VLANG_KAK_PREFIX "$script_dir/active-tools.sh" "$prefix" | sed '/^managed-process:/d')
  [ -z "$active" ] || { echo 'Managed tool processes are still running. Close them before removal.' >&2; exit 1; }
  # Managed launcher markers live until their session exits.
  for restart in "$prefix/opt/vlang-kakoune"/restart.*; do
    [ -d "$restart" ] || continue
    if [ ! -f "$restart/owner-pid" ]; then echo 'Close older managed sessions before removal; inspect stale restart directories manually.' >&2; exit 1; fi
    owner=$(cat "$restart/owner-pid")
    case "$owner" in ''|*[!0-9]*) echo 'Invalid session owner marker; refusing removal.' >&2; exit 1 ;; esac
    if kill -0 "$owner" 2>/dev/null; then echo 'Close managed Kakoune sessions before removal.' >&2; exit 1; fi
    echo "Ignoring stale session marker: $restart"
  done
  lock_acquire uninstall
  locked=true
fi
config=$(cat "$state/config-home")
shared_runtime=
if [ -L "$config/kak/autoload/vlang-site-runtime" ] &&
   find "$config/kak/autoload" -mindepth 1 -maxdepth 1 ! -name vlang.kak ! -name vlang-site-runtime -print | read -r other; then
  shared_runtime=$(readlink -f "$prefix/opt/vlang-kakoune/current" 2>/dev/null || true)
fi
# Reverse path ordering puts children before their directories.
LC_ALL=C sort -t "$(printf '\t')" -k3,3r "$manifest" |
while IFS="$(printf '\t')" read -r kind identity path; do
  case "$path" in "$prefix/bin/kak"|"$prefix/bin/kak-v"|"$prefix/bin/vls"|"$prefix/bin/v"|"$prefix/opt/vlang-kakoune"|"$prefix/opt/vlang-kakoune/"*|"$prefix/opt/vlang-kak-lsp"|"$prefix/opt/vlang-kak-lsp/"*|"$prefix/opt/vlang-vls"|"$prefix/opt/vlang-vls/"*|"$prefix/opt/vlang-v"|"$prefix/opt/vlang-v/"*|"$config/kak/autoload/vlang.kak"|"$config/kak/autoload/vlang-site-runtime"|"$config/kak/kakrc") ;; *) echo "Keep unrecognized path: $path"; continue ;; esac
  [ -e "$path" ] || [ -L "$path" ] || continue
  if [ "$path" = "$config/kak/autoload/vlang-site-runtime" ] &&
     find "$config/kak/autoload" -mindepth 1 -maxdepth 1 ! -name vlang.kak ! -name vlang-site-runtime -print | read -r other; then
    echo "Keep shared runtime required by other autoload entries: $path"; continue
  fi
  # A changed ancestor symlink must not redirect file deletion elsewhere.
  parent=$(readlink -f "$(dirname "$path")")
  case "$path" in "$prefix/"*)
    case "$parent/" in "$prefix/"*) [ "$parent" = "$(dirname "$path")" ] || { echo "Keep redirected path: $path"; continue; } ;; *) echo "Keep redirected path: $path"; continue ;; esac
    ;;
  esac
  if [ -n "$shared_runtime" ]; then
    case "$path" in "$shared_runtime"|"$shared_runtime/"*|"$prefix/opt/vlang-kakoune/current"|"$prefix/opt/vlang-kakoune/releases"|"$prefix/opt/vlang-kakoune")
      echo "Keep shared Kakoune runtime: $path"; continue ;;
    esac
  fi
  matches=false
  case "$kind" in
    file) [ ! -L "$path" ] && [ -f "$path" ] && [ "$(sha256sum "$path" | cut -d ' ' -f 1)" = "$identity" ] && matches=true ;;
    link) [ -L "$path" ] && [ "$(readlink "$path")" = "$identity" ] && matches=true ;;
    dir) [ ! -L "$path" ] && [ -d "$path" ] && matches=true ;;
    block)
      block=$(sed -n '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/p' "$path")
      [ "$(printf '%s\n' "$block" | sha256sum | cut -d ' ' -f 1)" = "$identity" ] && matches=true ;;
  esac
  if [ "$matches" = false ]; then echo "Keep changed: $path"; continue; fi
  printf '%s\t%s\n' "$kind" "$path" >> "$plan"
  if [ "$verbose" = true ]; then echo "Remove $kind: $path"
  else case "$kind:$path" in block:*|file:"$prefix/bin/"*|dir:"$prefix/opt/vlang-kakoune"|dir:"$prefix/opt/vlang-kak-lsp"|dir:"$prefix/opt/vlang-vls"|dir:"$prefix/opt/vlang-v") echo "Eligible $kind: $path" ;; esac; fi
  [ "$apply" = true ] || continue
  case "$kind" in
    dir) rmdir "$path" 2>/dev/null || true ;;
    block)
      target=$(readlink -f "$path")
      backup=$(mktemp "$target.vlang-backup.XXXXXXXX"); cp -p "$target" "$backup"
      temporary=$(mktemp "$target.XXXXXXXX")
      sed '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/{d;}' "$target" > "$temporary"
      cat "$temporary" > "$target"; rm -f "$temporary" ;;
    *) rm -f "$path" ;;
  esac
done
printf 'Eligible recorded entries: %s (use --verbose for every path)\n' "$(wc -l < "$plan")"
printf 'Personal settings kept: %s/kak/vlang-user.kak\n' "$config"
if [ "$apply" = true ]; then
  echo 'Ownership record retained for inspecting any files that were kept.'
else echo 'Preview only. Close managed sessions, then repeat with --apply.'; fi
