#!/bin/sh
# Install or update a user-local V IDE without replacing distribution packages.
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [--update] [--integrate]
                        [--vls PATH | --vls-upstream | --no-vls]
                        [--vls-ref GIT_REF] [--prefix DIRECTORY]
                        [--kakoune-version TAG_OR_COMMIT_OR_master] [--lsp-version TAG]
                        [--no-build] [--no-lsp]
                        [--explorer | --no-explorer] [--live-search | --no-live-search]
                        [--pane-mode auto|always|off]
                        [--window-backend auto|tmux|zellij|wezterm|kitty|screen|native]
Installs Kakoune, kak-lsp, and upstream VLS under $HOME/.local by default, links this plugin
into an isolated kak-v configuration. --integrate explicitly opts into adding
links and a marked block to your regular Kakoune configuration.
--update also fast-forwards a clean vlang.kak checkout.
EOF
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
prefix=$HOME/.local
integrate=
explorer=
live_search=
pane_mode=
window_backend=
kakoune_version=latest
lsp_version=latest
vls_path=
vls_mode=auto
vls_ref=
update=false
build=true
install_lsp=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --update) update=true; shift ;;
    --integrate) integrate=true; shift ;;
    --explorer) explorer=true; shift ;;
    --no-explorer) explorer=false; shift ;;
    --live-search) live_search=true; shift ;;
    --no-live-search) live_search=false; shift ;;
    --pane-mode) pane_mode=$2; shift 2 ;;
    --window-backend) window_backend=$2; shift 2 ;;
    --vls) vls_path=$2; vls_mode=external; shift 2 ;;
    --vls-upstream) vls_mode=upstream; shift ;;
    --no-vls) vls_mode=skip; shift ;;
    --vls-ref) vls_ref=$2; vls_mode=upstream; shift 2 ;;
    --prefix) prefix=$2; shift 2 ;;
    --kakoune-version) kakoune_version=$2; shift 2 ;;
    --lsp-version) lsp_version=$2; shift 2 ;;
    --no-build) build=false; shift ;;
    --no-lsp) install_lsp=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
config_home=${VLANG_KAK_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}
# Older launchers exported only their isolated XDG directory. Recover the
# personal path from our generated source line when updating those sessions.
if [ -z "${VLANG_KAK_CONFIG_HOME:-}" ] &&
   [ "$config_home" = "$prefix/opt/vlang-kakoune/ide-config" ]; then
  original_config=$(sed -n "s|^source '\(.*\)/kak/vlang-user.kak'$|\1|p" \
    "$config_home/kak/kakrc" | tail -n 1 | sed "s/''/'/g")
  if [ -z "$original_config" ] || [ ! -f "$original_config/kak/vlang-user.kak" ]; then
    echo 'Cannot locate personal configuration; rerun setup from a regular shell with XDG_CONFIG_HOME set.' >&2
    exit 1
  fi
  config_home=$original_config
fi
mkdir -p "$config_home"
config_home=$(CDPATH= cd -- "$config_home" && pwd)
settings_file=$prefix/opt/vlang-kakoune/ide-config/kak/kakrc
if [ ! -f "$settings_file" ]; then settings_file=$config_home/kak/kakrc; fi
if [ -z "$integrate" ]; then
  if [ -f "$settings_file" ]; then
    integrate=$(sed -n 's/^# vlang.kak integrate: //p' "$settings_file" | tail -n 1)
  fi
  if [ -z "$integrate" ] && [ -f "$config_home/kak/kakrc" ] &&
     grep -q '^# >>> vlang.kak managed >>>$' "$config_home/kak/kakrc"; then
    integrate=true
  fi
fi
integrate=${integrate:-false}
if [ -f "$settings_file" ]; then
  [ -n "$explorer" ] || explorer=$(sed -n 's/^set-option global v_explorer_enabled //p' "$settings_file" | tail -n 1)
  [ -n "$live_search" ] || live_search=$(sed -n 's/^set-option global v_live_search_enabled //p' "$settings_file" | tail -n 1)
  [ -n "$pane_mode" ] || pane_mode=$(sed -n 's/^set-option global v_pane_mode //p' "$settings_file" | tail -n 1)
  [ -n "$window_backend" ] || window_backend=$(sed -n 's/^set-option global v_window_backend //p' "$settings_file" | tail -n 1)
fi
explorer=${explorer:-true}
live_search=${live_search:-true}
pane_mode=${pane_mode:-auto}
window_backend=${window_backend:-auto}
case "$explorer:$live_search" in
  true:true|true:false|false:true|false:false) ;;
  *) echo 'Explorer and live search choices must be true or false.' >&2; exit 2 ;;
esac
case "$pane_mode" in auto|always|off) ;; *) echo "Unknown pane mode: $pane_mode" >&2; exit 2 ;; esac
case "$window_backend" in
  auto|tmux|zellij|wezterm|kitty|screen|native) ;;
  *) echo "Unknown window backend: $window_backend" >&2; exit 2 ;;
esac
if [ "$explorer" = true ] && ! command -v v >/dev/null 2>&1; then
  echo 'V is required for the project explorer. Pass --no-explorer to use path completion.' >&2
  exit 1
fi
case "$prefix" in
  *"'"*|*'
'*) echo "The installation prefix cannot contain quotes or newlines." >&2; exit 2 ;;
esac
prefix=$(mkdir -p "$prefix" && CDPATH= cd -- "$prefix" && pwd)

check_managed_file() {
  if [ -L "$1" ] || { [ -e "$1" ] && ! grep -q -F -x "$2" "$1"; }; then
    echo "Existing unmanaged file: $1. Choose another --prefix or move it yourself." >&2
    exit 1
  fi
}
check_managed_file "$prefix/bin/kak-v" '# vlang.kak managed IDE launcher'
check_managed_file "$prefix/opt/vlang-kakoune/ide-config/kak/kakrc" '# vlang.kak managed isolated configuration'
for link in "$prefix/opt/vlang-kakoune/ide-config/kak/autoload/vlang.kak" \
            "$prefix/opt/vlang-kakoune/ide-config/kak/autoload/vlang-site-runtime"; do
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "Existing unmanaged autoload entry: $link. Choose another --prefix." >&2
    exit 1
  fi
done

if [ "$update" = true ] && [ "${VLANG_KAK_SKIP_PULL:-0}" != 1 ]; then
  if [ -d "$repo_dir/.git" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ]; then
    git -C "$repo_dir" pull --ff-only
  else
    echo "Keeping local vlang.kak checkout: it has uncommitted changes or is not a Git clone."
  fi
fi

if [ "$build" = true ]; then
  "$script_dir/build-kakoune.sh" --version "$kakoune_version" --prefix "$prefix"
  kak_runtime=$prefix/opt/vlang-kakoune/current/share/kak
else
  kak_path=$(command -v kak || true)
  [ -n "$kak_path" ] || { echo "Kakoune is not installed." >&2; exit 1; }
  if [ -d "$prefix/opt/vlang-kakoune/current/share/kak" ]; then
    kak_runtime=$prefix/opt/vlang-kakoune/current/share/kak
  else
    kak_runtime=${KAKOUNE_RUNTIME:-$(dirname "$(dirname "$(readlink -f "$kak_path")")")/share/kak}
  fi
fi
[ -d "$kak_runtime/rc" ] || {
  echo "Kakoune runtime not found at $kak_runtime" >&2
  exit 1
}

if [ "$install_lsp" = true ]; then
  "$script_dir/install-kak-lsp.sh" --version "$lsp_version" --prefix "$prefix"
fi
lsp_bin=$prefix/opt/vlang-kak-lsp/current/bin/kak-lsp
if [ ! -x "$lsp_bin" ]; then
  lsp_bin=$(command -v kak-lsp || true)
fi

if [ "$vls_mode" = auto ]; then
  if [ -L "$prefix/bin/vls" ] &&
     [ "$(readlink -f "$prefix/bin/vls")" != "$(readlink -f "$prefix/opt/vlang-vls/current/bin/vls" 2>/dev/null || true)" ]; then
    vls_mode=skip
    echo 'Keeping externally linked VLS. Use --vls-upstream to switch to managed upstream VLS.'
  else
    vls_mode=upstream
  fi
fi
if [ "$vls_mode" = upstream ]; then
  if [ -n "$vls_ref" ]; then
    "$script_dir/install-vls.sh" --ref "$vls_ref" --prefix "$prefix"
  else
    "$script_dir/install-vls.sh" --prefix "$prefix"
  fi
elif [ "$vls_mode" = external ]; then
  [ -x "$vls_path" ] || { echo "VLS is not executable: $vls_path" >&2; exit 1; }
  vls_path=$(readlink -f "$vls_path")
  mkdir -p "$prefix/bin"
  if [ -e "$prefix/bin/vls" ] && [ ! -L "$prefix/bin/vls" ]; then
    echo "Existing unmanaged VLS at $prefix/bin/vls; choose another --prefix." >&2
    exit 1
  fi
  ln -sfn "$vls_path" "$prefix/bin/vls"
fi
if ! PATH="$prefix/bin:$PATH" command -v vls >/dev/null 2>&1; then
  echo "VLS is not on PATH. Pass --vls /path/to/vls after building it." >&2
fi

kak_config=$config_home/kak
autoload=$kak_config/autoload
mkdir -p "$kak_config"
kak_config=$(CDPATH= cd -- "$kak_config" && pwd)
autoload=$kak_config/autoload
user_config=$kak_config/vlang-user.kak
if [ -L "$user_config" ] && [ ! -e "$user_config" ]; then
  echo "Broken personal configuration link: $user_config. Resolve it before setup." >&2
  exit 1
fi
if [ ! -e "$user_config" ]; then
  printf '# Personal V IDE settings. setup.sh and update.sh keep this file.\n' > "$user_config"
fi
quoted_user_config=$(printf %s "$user_config" | sed "s/'/''/g")
if [ "$integrate" = true ]; then
  kakrc=$kak_config/kakrc
  if [ -L "$kakrc" ] && [ ! -e "$kakrc" ]; then
    echo "Broken kakrc link: $kakrc. Resolve it before --integrate." >&2
    exit 1
  fi
  if [ -f "$kakrc" ] && ! awk '
    /^# >>> vlang.kak managed >>>$/ { if (opened || count++) exit 1; opened=1 }
    /^# <<< vlang.kak managed <<<$/{ if (!opened) exit 1; opened=0 }
    END { if (opened) exit 1 }
  ' "$kakrc"; then
    echo "Malformed managed block in $kakrc; refusing to rewrite user settings." >&2
    exit 1
  fi
  site_link=$autoload/vlang-site-runtime
  plugin_link=$autoload/vlang.kak
  for link in "$site_link" "$plugin_link"; do
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "Existing unmanaged autoload entry at $link" >&2
      exit 1
    fi
  done
  if [ -L "$plugin_link" ] && [ "$(readlink -f "$plugin_link")" != "$repo_dir/rc/vlang.kak" ]; then
    echo "Conflicting plugin link: $plugin_link. Keep it or move it yourself before --integrate." >&2
    exit 1
  fi
  if [ -L "$site_link" ] && [ "$(readlink -f "$site_link")" != "$(readlink -f "$kak_runtime/rc")" ] &&
     { [ ! -f "$kak_config/kakrc" ] || ! grep -q '^# >>> vlang.kak managed >>>$' "$kak_config/kakrc"; }; then
    echo "Conflicting runtime link: $site_link. Resolve it before --integrate." >&2
    exit 1
  fi
  mkdir -p "$autoload"
  # A user autoload directory suppresses Kakoune's system autoload directory.
  ln -sfn "$kak_runtime/rc" "$site_link"
  ln -sfn "$repo_dir/rc/vlang.kak" "$plugin_link"

  touch "$kakrc"
  kakrc_target=$(readlink -f "$kakrc")
  temporary=$(mktemp "$kakrc_target.XXXXXXXX")
  trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
  if grep -q '^# >>> vlang.kak managed >>>$' "$kakrc_target"; then
    sed '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/{d;}' \
      "$kakrc_target" > "$temporary"
  else
    cat "$kakrc_target" > "$temporary"
  fi
  existing_lsp=false
  if grep -E '^[^#]*kak-lsp' "$temporary" >/dev/null 2>&1; then
    existing_lsp=true
  fi
  if [ -s "$temporary" ] &&
     [ "$(tail -c 1 "$temporary" | od -An -tu1 | tr -d '[:space:]')" != 10 ]; then
    printf '\n' >> "$temporary"
  fi
  {
    printf '# >>> vlang.kak managed >>>\n'
    if [ "$existing_lsp" = false ] && [ -x "$lsp_bin" ]; then
      printf 'eval %%sh{ PATH="%s/bin:$PATH" "%s" }\n' "$prefix" "$lsp_bin"
      printf 'set-option global lsp_cmd %s\n' "'\"$lsp_bin\" --session \"\$kak_session\"'"
    fi
    printf 'set-option global v_explorer_enabled %s\n' "$explorer"
    printf 'set-option global v_live_search_enabled %s\n' "$live_search"
    printf 'set-option global v_pane_mode %s\n' "$pane_mode"
    printf 'set-option global v_window_backend %s\n' "$window_backend"
    printf "source '%s'\n" "$quoted_user_config"
    printf '# <<< vlang.kak managed <<<\n'
  } >> "$temporary"
  if cmp -s "$temporary" "$kakrc_target"; then
    echo "Configuration unchanged: $kakrc_target"
  else
    backup=$(mktemp "$kakrc_target.vlang-backup.XXXXXXXX")
    cp -p "$kakrc_target" "$backup"
    cat "$temporary" > "$kakrc_target"
    echo "Configured $kakrc_target (backup: $backup)"
  fi
  if [ "$existing_lsp" = true ]; then
    echo "Existing kak-lsp startup kept. Check that it uses the installed kak-lsp and VLS."
  fi

fi

# A clean launcher is useful when an existing kakrc has unrelated or stale hooks.
isolated_config=$prefix/opt/vlang-kakoune/ide-config/kak
mkdir -p "$isolated_config/autoload" "$prefix/bin"
ln -sfn "$kak_runtime/rc" "$isolated_config/autoload/vlang-site-runtime"
ln -sfn "$repo_dir/rc/vlang.kak" "$isolated_config/autoload/vlang.kak"
{
  printf '# vlang.kak managed isolated configuration\n'
  printf '# vlang.kak integrate: %s\n' "$integrate"
  if [ -x "$lsp_bin" ]; then
    printf 'eval %%sh{ PATH="%s/bin:$PATH" "%s" }\n' "$prefix" "$lsp_bin"
    printf 'set-option global lsp_cmd %s\n' "'\"$lsp_bin\" --session \"\$kak_session\"'"
  fi
  printf 'set-option global v_explorer_enabled %s\n' "$explorer"
  printf 'set-option global v_live_search_enabled %s\n' "$live_search"
  printf 'set-option global v_pane_mode %s\n' "$pane_mode"
  printf 'set-option global v_window_backend %s\n' "$window_backend"
  printf "source '%s'\n" "$quoted_user_config"
  printf '%s\n' 'hook -once global ClientCreate .* %{ evaluate-commands %sh{'
  printf '%s\n' '  if [ -n "${VLANG_KAK_RESTART_SOURCE:-}" ]; then'
  printf '%s\n' '    printf "source '\''%s'\''\\n" "$VLANG_KAK_RESTART_SOURCE"'
  printf '%s\n' '  fi'
  printf '%s\n' '} }'
} > "$isolated_config/kakrc"
ide_launcher=$prefix/bin/kak-v
if [ -e "$ide_launcher" ] &&
   ! grep -q '^# vlang.kak managed IDE launcher$' "$ide_launcher"; then
  echo "Existing unmanaged launcher at $ide_launcher; choose another --prefix." >&2
  exit 1
fi
cat > "$ide_launcher.tmp" <<EOF
#!/bin/sh
# vlang.kak managed IDE launcher
XDG_CONFIG_HOME='$prefix/opt/vlang-kakoune/ide-config'
VLANG_KAK_CONFIG_HOME='$(printf %s "$config_home" | sed "s/'/'\\\\''/g")'
PATH='$prefix/bin':\$PATH
VLANG_KAK_PREFIX='$prefix'
VLANG_KAK_REPO='$(printf %s "$repo_dir" | sed "s/'/'\\\\''/g")'
VLANG_KAK_RESTART_ALLOWED=1
for argument in "\$@"; do
  case "\$argument" in
    -c|-C|-d|-p|-f) VLANG_KAK_RESTART_ALLOWED=0 ;;
  esac
done
restart_dir=\$(mktemp -d '$prefix/opt/vlang-kakoune/restart.XXXXXXXX') || exit 1
VLANG_KAK_RESTART_STATE=\$restart_dir/state.kak
export XDG_CONFIG_HOME PATH VLANG_KAK_CONFIG_HOME VLANG_KAK_PREFIX VLANG_KAK_REPO \
  VLANG_KAK_RESTART_STATE VLANG_KAK_RESTART_ALLOWED
trap 'rm -f "\$restart_dir/state.kak" "\$restart_dir/replay.kak"; rmdir "\$restart_dir"' EXIT
while :; do
  if [ -s "\$VLANG_KAK_RESTART_STATE" ]; then
    mv "\$VLANG_KAK_RESTART_STATE" "\$restart_dir/replay.kak"
    VLANG_KAK_RESTART_SOURCE="\$restart_dir/replay.kak" kak "\$@"
    status=\$?
    rm -f "\$restart_dir/replay.kak"
  else
    kak "\$@"
    status=\$?
  fi
  if [ "\$status" -ne 75 ] || [ ! -s "\$VLANG_KAK_RESTART_STATE" ]; then
    exit "\$status"
  fi
done
EOF
chmod 755 "$ide_launcher.tmp"
mv -f "$ide_launcher.tmp" "$ide_launcher"
if [ "$explorer" = true ]; then
  "$script_dir/explorer.sh" --prepare
fi
if command -v gdb >/dev/null 2>&1 && command -v v >/dev/null 2>&1; then
  "$script_dir/debug.sh" --prepare
else
  echo "Debugging: install GDB 14 or newer with Python support, then use Space B."
fi
echo "Explorer: $explorer. Live search: $live_search. Pane mode: $pane_mode. Customize $user_config."
echo "Launch with $ide_launcher or run scripts/check.sh."
