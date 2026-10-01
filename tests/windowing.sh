#!/bin/sh
set -eu

helper=$1
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vlang-kak-windowing.XXXXXXXX")
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

for name in tmux zellij wezterm kitty screen; do
  cat > "$temporary/$name" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$VLANG_WINDOWING_TEST_LOG"
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
kak_client_env_WEZTERM_PANE=7 "$helper" open wezterm right test-session 'v-definition' >/dev/null
grep -qx -- 'split-pane' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- '--right' "$VLANG_WINDOWING_TEST_LOG"
grep -qx -- 'v-definition' "$VLANG_WINDOWING_TEST_LOG"

echo 'ok - pane host detection and client launch arguments'
