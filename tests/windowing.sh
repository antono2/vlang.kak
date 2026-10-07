#!/bin/sh
# Checks terminal and pane-host selection without changing the user installation.
set -eu

helper=$1
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vlang-kak-windowing.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

for name in tmux zellij wezterm kitty screen foot; do
  cat > "$temporary/$name" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$VLANG_WINDOWING_TEST_LOG"
printf '%s\n' "${WEZTERM_UNIX_SOCKET:-}" > "$VLANG_WINDOWING_TEST_LOG.socket"
printf '%s\n' "${WAYLAND_DISPLAY:-}" "${XDG_RUNTIME_DIR:-}" > "$VLANG_WINDOWING_TEST_LOG.runtime"
printf '%s\n' "${VLANG_VIEW_SESSION:-}" > "$VLANG_WINDOWING_TEST_LOG.session"
EOF
  chmod +x "$temporary/$name"
done

PATH="$temporary:$PATH"
export PATH
test "$(kak_client_env_TMUX= kak_client_env_ZELLIJ= kak_client_env_ZELLIJ_SESSION_NAME= kak_client_env_WEZTERM_PANE= \
  kak_client_env_KITTY_WINDOW_ID= kak_client_env_STY= kak_client_env_DISPLAY= \
  "$helper" detect auto)" = none
test "$(kak_client_env_TMUX=socket,1,0 kak_client_env_TMUX_PANE=%0 \
  kak_client_env_ZELLIJ=1 kak_client_env_ZELLIJ_SESSION_NAME=test "$helper" detect auto)" = tmux
test "$(kak_client_env_ZELLIJ=1 kak_client_env_ZELLIJ_SESSION_NAME=test "$helper" detect auto)" = zellij
test "$(kak_client_env_WEZTERM_PANE=7 "$helper" detect auto)" = wezterm
test "$(kak_client_env_KITTY_WINDOW_ID=4 "$helper" detect auto)" = kitty
test "$(kak_client_env_STY=session "$helper" detect auto)" = screen
test "$(kak_client_env_ZELLIJ=1 kak_client_env_ZELLIJ_SESSION_NAME=test "$helper" detect kitty)" = none

VLANG_WINDOWING_TEST_LOG=$temporary/open.log
export VLANG_WINDOWING_TEST_LOG
kak_client_env_ZELLIJ_SESSION_NAME=test kak_client_env_ZELLIJ_PANE_ID=terminal_1 \
  "$helper" open zellij left test-session 'v-tree' >/dev/null
grep -qx -- 'new-pane' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- 'left' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- '--close-on-exit' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- 'v-tree' "$VLANG_WINDOWING_TEST_LOG"
kak_client_env_WEZTERM_PANE=7 kak_client_env_WEZTERM_UNIX_SOCKET='/tmp/socket with spaces' \
  "$helper" open wezterm right test-session 'v-definition' >/dev/null
grep -qx -- 'split-pane' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- '--no-auto-start' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- '/tmp/socket with spaces' "$VLANG_WINDOWING_TEST_LOG.socket"
grep -qx -- '--right' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- 'v-definition' "$VLANG_WINDOWING_TEST_LOG"

kak_client_env_STY='123.session name' kak_client_env_WINDOW=2 \
  "$helper" open screen right test-session 'edit "quoted path"' >/dev/null
grep -qx -- '123.session name' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- '2' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- 'test-session' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- 'edit "quoted path"' "$VLANG_WINDOWING_TEST_LOG"

rm -f "$VLANG_WINDOWING_TEST_LOG" "$VLANG_WINDOWING_TEST_LOG.session"
kak_opt_termcmd= kak_client_env_WAYLAND_DISPLAY=wayland-test \
  kak_client_env_XDG_RUNTIME_DIR='/tmp/runtime with spaces' \
  "$helper" open native right test-session 'edit "quoted path"' >/dev/null
tries=0
while ! grep -qx -- test-session "$VLANG_WINDOWING_TEST_LOG.session" 2>/dev/null; do
  tries=$((tries + 1)); [ "$tries" -lt 50 ]; sleep .1
done
grep -qx -- 'wayland-test' "$VLANG_WINDOWING_TEST_LOG.runtime"
grep -qx -- '/tmp/runtime with spaces' "$VLANG_WINDOWING_TEST_LOG.runtime"
grep -qx -- 'test-session' "$VLANG_WINDOWING_TEST_LOG.session"
grep -qx -- 'sh' "$VLANG_WINDOWING_TEST_LOG"

echo 'ok - pane host detection and client launch arguments'
