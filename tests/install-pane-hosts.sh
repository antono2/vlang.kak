#!/bin/sh
# Test-only downloads; installs nothing into the user's terminal configuration.
set -eu
case ${1:-} in
  --help|-h|'') echo 'Usage: tests/install-pane-hosts.sh ARTIFACT_DIRECTORY (Linux x86_64)'; exit 0 ;;
esac
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo 'Pinned pane-host test downloads require Linux x86_64.' >&2; exit 1;
}
test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$test_dir/pane-hosts.env"
mkdir -p "$1"
root=$(CDPATH= cd -- "$1" && pwd)
download() {
  curl --fail --location --retry 3 --output "$root/$1" "$2"
  printf '%s  %s\n' "$3" "$root/$1" | sha256sum --check
}
download zellij.tar.gz \
  "https://github.com/zellij-org/zellij/releases/download/v$ZELLIJ_VERSION/zellij-x86_64-unknown-linux-musl.tar.gz" "$ZELLIJ_SHA256"
download wezterm.tar.xz \
  "https://github.com/wezterm/wezterm/releases/download/$WEZTERM_VERSION/wezterm-$WEZTERM_VERSION.Debian12.tar.xz" "$WEZTERM_SHA256"
download kitty.txz \
  "https://github.com/kovidgoyal/kitty/releases/download/v$KITTY_VERSION/kitty-$KITTY_VERSION-x86_64.txz" "$KITTY_SHA256"
mkdir -p "$root/zellij" "$root/wezterm" "$root/kitty"
tar -xzf "$root/zellij.tar.gz" -C "$root/zellij"
tar -xJf "$root/wezterm.tar.xz" -C "$root/wezterm"
tar -xJf "$root/kitty.txz" -C "$root/kitty"
"$root/zellij/zellij" --version
"$root/wezterm/wezterm/usr/bin/wezterm" --version
"$root/kitty/bin/kitty" --version
printf 'PATH directories: %s:%s:%s\n' "$root/zellij" "$root/wezterm/wezterm/usr/bin" "$root/kitty/bin"
