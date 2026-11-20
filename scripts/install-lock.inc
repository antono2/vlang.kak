# Shared installation lock. Linux process start times distinguish reused PIDs.
lock_start() {
  [ -r "/proc/$1/stat" ] || return 1
  sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}'
}
lock_status() {
  [ "$(readlink -m "$state")" = "$(readlink -m "$prefix")/opt/vlang-state" ] || { echo "Installation lock: redirected state directory; inspect $state manually."; return 2; }
  [ ! -L "$state/lock" ] || { echo "Installation lock: redirected path; inspect $state/lock manually."; return 2; }
  if [ ! -d "$state/lock" ]; then
    [ ! -e "$state/lock" ] || { echo "Installation lock: unknown owner ($state/lock)."; return 2; }
    echo 'Installation lock: none'; return 0
  fi
  lock_pid= lock_birth= lock_operation=
  if [ -f "$state/lock/owner" ] && [ ! -L "$state/lock/owner" ]; then
    read -r lock_pid lock_birth lock_operation < "$state/lock/owner" || true
  fi
  case "$lock_pid:$lock_birth" in *[!0-9:]*|:*|*:) lock_pid= ;; esac
  case "$lock_operation" in ''|*[[:space:]]*) lock_pid= ;; esac
  if ! [ "$lock_pid" -gt 0 ] 2>/dev/null || ! [ "$lock_pid" -le 2147483647 ] 2>/dev/null; then
    echo "Installation lock: unknown owner ($state/lock); inspect running operations before removing an empty legacy lock."
    return 2
  fi
  lock_now=$(lock_start "$lock_pid" || true)
  if [ "$lock_now" = "$lock_birth" ]; then
    echo "Installation lock: active $lock_operation (PID $lock_pid). Wait for it to finish."
    return 1
  fi
  if [ -z "$lock_now" ]; then
    probe=$(LC_ALL=C kill -0 "$lock_pid" 2>&1) || true
    case "$probe" in *'No such process'*) ;; *)
      echo "Installation lock: owner PID $lock_pid is running but its identity cannot be checked."
      return 2 ;;
    esac
  fi
  echo "Installation lock: stale $lock_operation (PID $lock_pid). Run scripts/lock.sh --prefix '$prefix' --clear-stale."
  return 3
}
lock_acquire() {
  if ! mkdir "$state/lock" 2>/dev/null; then lock_status >&2 || true; return 1; fi
  lock_identity="$$ $(lock_start "$$") $1"
  printf '%s\n' "$lock_identity" > "$state/lock/owner"
}
lock_release() {
  [ "$(cat "$state/lock/owner" 2>/dev/null || true)" = "${lock_identity:-}" ] || return 0
  rm "$state/lock/owner"
  rmdir "$state/lock" || { echo "Kept unexpected lock contents: $state/lock" >&2; return 1; }
}
