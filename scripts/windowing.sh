#!/bin/sh
# Detect the active Kakoune client's pane host, then launch another client.
set -eu

usage() {
  echo 'Usage: windowing.sh detect [auto|tmux|zellij|wezterm|kitty|screen|native]'
  echo '       windowing.sh open BACKEND left|right SESSION KAKOUNE_COMMANDS'
}

inside() {
  case "$1" in
    tmux) [ -n "${kak_client_env_TMUX:-}" ] && command -v tmux >/dev/null 2>&1 ;;
    zellij) [ -n "${kak_client_env_ZELLIJ:-}" ] &&
      [ -n "${kak_client_env_ZELLIJ_SESSION_NAME:-}" ] && command -v zellij >/dev/null 2>&1 ;;
    wezterm) [ -n "${kak_client_env_WEZTERM_PANE:-}" ] && command -v wezterm >/dev/null 2>&1 ;;
    kitty) [ -n "${kak_client_env_KITTY_WINDOW_ID:-}" ] &&
      { command -v kitten >/dev/null 2>&1 || command -v kitty >/dev/null 2>&1; } ;;
    screen) [ -n "${kak_client_env_STY:-}" ] && command -v screen >/dev/null 2>&1 ;;
    native) [ -n "${kak_client_env_ITERM_SESSION_ID:-}${kak_client_env_WAYLAND_DISPLAY:-}${kak_client_env_DISPLAY:-}" ] ;;
    *) return 1 ;;
  esac
}

kak_quote() {
  printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"
}

case "${1:-}" in
  -h|--help) usage ;;
  detect)
    requested=${2:-auto}
    case "$requested" in
      auto)
        for provider in tmux zellij wezterm kitty screen native; do
          if inside "$provider"; then
            echo "$provider"
            exit 0
          fi
        done
        echo none
        ;;
      tmux|zellij|wezterm|kitty|screen|native)
        if inside "$requested"; then echo "$requested"; else echo none; fi
        ;;
      *) echo "Unknown window backend: $requested" >&2; exit 2 ;;
    esac
    ;;
  open)
    [ "$#" -eq 5 ] || { usage >&2; exit 2; }
    provider=$2
    side=$3
    session=$4
    initial=$5
    case "$side" in left|right) ;; *) exit 2 ;; esac
    case "$provider" in
      tmux)
        pane=${kak_client_env_TMUX_PANE:-}
        [ -n "$pane" ] || { echo 'Cannot identify the current tmux pane.' >&2; exit 1; }
        if [ "$side" = left ]; then
          TMUX=$kak_client_env_TMUX tmux split-window -h -b -t "$pane" -c "$PWD" \
            kak -c "$session" -e "$initial"
        else
          TMUX=$kak_client_env_TMUX tmux split-window -h -t "$pane" -c "$PWD" \
            kak -c "$session" -e "$initial"
        fi
        ;;
      zellij)
        ZELLIJ_PANE_ID=${kak_client_env_ZELLIJ_PANE_ID:-} \
          zellij --session "$kak_client_env_ZELLIJ_SESSION_NAME" action new-pane \
          --direction "$side" --near-current-pane --close-on-exit --cwd "$PWD" -- \
          kak -c "$session" -e "$initial" >/dev/null
        ;;
      wezterm)
        wezterm cli split-pane --"$side" --pane-id "$kak_client_env_WEZTERM_PANE" --cwd "$PWD" -- \
          kak -c "$session" -e "$initial" >/dev/null
        ;;
      kitty)
        if command -v kitten >/dev/null 2>&1; then kitty_cmd=kitten; else kitty_cmd=kitty; fi
        if [ "$side" = left ]; then location=before; else location=after; fi
        set -- @
        if [ -n "${kak_client_env_KITTY_LISTEN_ON:-}" ]; then
          set -- "$@" "--to=$kak_client_env_KITTY_LISTEN_ON"
        fi
        set -- "$@" launch --type=window --location="$location" --cwd="$PWD" \
          "--match=id:$kak_client_env_KITTY_WINDOW_ID" kak -c "$session" -e "$initial"
        KITTY_LISTEN_ON=${kak_client_env_KITTY_LISTEN_ON:-} "$kitty_cmd" "$@" >/dev/null
        ;;
      screen|native)
        # Kakoune's loaded windowing module handles these hosts.
        printf 'new %s\n' "$(kak_quote "$initial")"
        ;;
      *) echo "Unknown window backend: $provider" >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac
