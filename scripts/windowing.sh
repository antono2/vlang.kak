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
        WEZTERM_UNIX_SOCKET=${kak_client_env_WEZTERM_UNIX_SOCKET:-${WEZTERM_UNIX_SOCKET:-}} \
          wezterm cli --no-auto-start split-pane --"$side" --pane-id "$kak_client_env_WEZTERM_PANE" --cwd "$PWD" -- \
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
      screen)
        [ -n "${kak_client_env_STY:-}" ] || { echo 'Cannot identify the current Screen session.' >&2; exit 1; }
        # Screen windows close when their client exits. Target the requesting
        # client's session/window even when the Kakoune daemon is outside Screen.
        if [ -n "${kak_client_env_SCREENDIR:-}" ]; then export SCREENDIR="$kak_client_env_SCREENDIR"; else unset SCREENDIR; fi
        screen -S "$kak_client_env_STY" -p "${kak_client_env_WINDOW:-0}" -X screen \
          kak -c "$session" -e "$initial"
        ;;
      native)
        termcmd=${kak_opt_termcmd:-}
        if [ -z "$termcmd" ] && [ -n "${kak_client_env_WAYLAND_DISPLAY:-}" ] && command -v foot >/dev/null 2>&1; then
          termcmd='foot sh -c'
        fi
        if [ -n "${kak_client_env_DISPLAY:-}${kak_client_env_WAYLAND_DISPLAY:-}" ] && [ -n "$termcmd" ]; then
          # Use Kakoune's configured terminal command with the requesting
          # client's display/runtime, including a headless daemon.
          if [ -n "${kak_client_env_DISPLAY:-}" ]; then export DISPLAY="$kak_client_env_DISPLAY"; else unset DISPLAY; fi
          [ -z "${kak_client_env_XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="$kak_client_env_XDG_RUNTIME_DIR"
          if [ -n "${kak_client_env_XAUTHORITY:-}" ]; then export XAUTHORITY="$kak_client_env_XAUTHORITY"; else unset XAUTHORITY; fi
          if [ -n "${kak_client_env_WAYLAND_DISPLAY:-}" ]; then export WAYLAND_DISPLAY="$kak_client_env_WAYLAND_DISPLAY"; else unset WAYLAND_DISPLAY; fi
          VLANG_VIEW_SESSION=$session VLANG_VIEW_COMMAND=$initial
          export VLANG_VIEW_SESSION VLANG_VIEW_COMMAND
          setsid sh -c 'exec '"$termcmd"' "$1"' vlang-terminal \
            'exec kak -c "$VLANG_VIEW_SESSION" -e "$VLANG_VIEW_COMMAND"' \
            < /dev/null > /dev/null 2>&1 &
        else
          # Other native hosts use Kakoune's loaded windowing module.
          printf 'new %s\n' "$(kak_quote "$initial")"
        fi
        ;;
      *) echo "Unknown window backend: $provider" >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac
