#!/bin/sh
# Persist only explicitly selected IDE settings in their own marked block.
set -eu
name=${1:-}; value=${2:-}
case "$name:$value" in
  v_explorer_enabled:true|v_explorer_enabled:false|v_live_search_enabled:true|v_live_search_enabled:false|v_update_check_enabled:true|v_update_check_enabled:false|v_pane_mode:auto|v_pane_mode:always|v_pane_mode:off|v_window_backend:auto|v_window_backend:tmux|v_window_backend:zellij|v_window_backend:wezterm|v_window_backend:kitty|v_window_backend:screen|v_window_backend:native) ;;
  *) echo 'Unsupported setting/value.' >&2; exit 2 ;;
esac
config=${VLANG_KAK_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/kak
mkdir -p "$config"
file=$config/vlang-user.kak
[ -e "$file" ] || { [ ! -L "$file" ] || exit 1; touch "$file"; }
target=$(readlink -f "$file")
mkdir "$config/.vlang-settings-lock" 2>/dev/null || { echo 'Settings are being edited by another command.' >&2; exit 1; }
temporary=$(mktemp "$target.XXXXXXXX")
trap 'rm -f "$temporary"; rmdir "$config/.vlang-settings-lock"' EXIT HUP INT TERM
awk '
  /^# >>> vlang.kak preferences >>>$/ { if (opened || count++) exit 1; opened=1 }
  /^# <<< vlang.kak preferences <<<$/{ if (!opened) exit 1; opened=0 }
  END { if (opened) exit 1 }
' "$target" || { echo 'Malformed preferences block; edit vlang-user.kak to repair it.' >&2; exit 1; }
awk -v name="$name" -v value="$value" '
  /^# >>> vlang.kak preferences >>>$/ { inside=1; found=1 }
  /^# <<< vlang.kak preferences <<<$/{
    if (name=="v_update_check_enabled") print "try %{ set-option global " name " " value " }"
    else print "set-option global " name " " value
    inside=0
  }
  !(inside && index($0,"set-option global " name " ")>0) { print }
  END { if (!found) {
    print "\n# >>> vlang.kak preferences >>>"
    if (name=="v_update_check_enabled") print "try %{ set-option global " name " " value " }"
    else print "set-option global " name " " value
    print "# <<< vlang.kak preferences <<<"
  } }
' "$target" > "$temporary"
backup=$(mktemp "$target.vlang-backup.XXXXXXXX"); cp -p "$target" "$backup"
cat "$temporary" > "$target"
printf 'set-option global %s %s\nv-refresh-keys\n' "$name" "$value"

if [ "$name:$value" = v_update_check_enabled:true ]; then echo v-update-check-background; fi
