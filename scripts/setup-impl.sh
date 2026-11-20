#!/bin/sh
# Install or update a user-local V IDE without replacing distribution packages.
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/setup.sh [--update] [--integrate]
                        [--vls PATH | --vls-upstream | --no-vls]
                        [--vls-ref GIT_REF] [--prefix DIRECTORY]
                        [--kakoune-version TAG_OR_COMMIT_OR_master] [--lsp-version TAG]
                        [--no-build] [--no-lsp] [--managed-v | --system-v] [--install-dependencies]
                        [--explorer | --no-explorer] [--live-search | --no-live-search]
                        [--pane-mode auto|always|off]
                        [--window-backend auto|tmux|zellij|wezterm|kitty|screen|native]
Installs Kakoune, kak-lsp and upstream VLS under $HOME/.local by default, links this plugin
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
managed_v=auto
repair=false
build=true
install_lsp=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dependencies) shift ;;
    --repair) repair=true; shift ;;
    --system-v) managed_v=system; shift ;;
    --managed-v) managed_v=true; shift ;;
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
case "$config_home" in *"$(printf '\t')"*|*'
'*) echo 'Tabs/newlines in configuration paths are unsupported.' >&2; exit 2 ;; esac
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
case "$prefix" in
  *"'"*|*'
'*) echo "The installation prefix cannot contain quotes or newlines." >&2; exit 2 ;;
esac
prefix=$(mkdir -p "$prefix" && CDPATH= cd -- "$prefix" && pwd)

# Validate user-facing paths before any download or build.
check_path=$config_home/kak/kakrc
if [ "$integrate" = true ]; then
  if [ -L "$check_path" ] && [ ! -e "$check_path" ]; then echo "Broken kakrc link: $check_path" >&2; exit 1; fi
  if [ -f "$check_path" ] && ! awk '
    /^# >>> vlang.kak managed >>>$/ { if (opened || count++) exit 1; opened=1 }
    /^# <<< vlang.kak managed <<<$/{ if (!opened) exit 1; opened=0 }
    END { if (opened) exit 1 }
  ' "$check_path"; then echo "Malformed managed block in $check_path" >&2; exit 1; fi
  for item in vlang.kak vlang-site-runtime; do
    link=$config_home/kak/autoload/$item
    if [ -e "$link" ] && [ ! -L "$link" ]; then echo "Existing unmanaged autoload entry: $link" >&2; exit 1; fi
    if [ "$item" = vlang.kak ] && [ -L "$link" ] && [ "$(readlink -f "$link")" != "$repo_dir/rc/vlang.kak" ]; then
      echo "Conflicting plugin link: $link" >&2; exit 1
    fi
  done
fi
check_managed_file() {
  if [ -L "$1" ] || { [ -e "$1" ] && ! grep -q -F -x "$2" "$1"; }; then
    echo "Existing unmanaged file: $1. Choose another --prefix or move it yourself." >&2
    exit 1
  fi
}
if [ "$repair" = true ]; then "$script_dir/managed-state.sh" repair-links "$prefix"; fi
if [ -d "$prefix/opt/vlang-kakoune/current/share/kak" ]; then check_managed_file "$prefix/bin/kak" '# vlang.kak managed Kakoune launcher'; fi
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

if [ "$vls_mode" = auto ]; then
  if [ -L "$prefix/bin/vls" ] &&
     [ "$(readlink -f "$prefix/bin/vls")" != "$(readlink -f "$prefix/opt/vlang-vls/current/bin/vls" 2>/dev/null || true)" ]; then
    vls_mode=skip
    echo 'Keeping externally linked VLS. Use --vls-upstream to switch to managed upstream VLS.'
  else
    vls_mode=upstream
  fi
fi

# Prefer an existing compiler that can compile the helpers and current VLS.
# A fallback lives in the managed prefix and never replaces the system compiler.
compiler_policy=auto
case "$managed_v" in true) compiler_policy=managed ;; system) compiler_policy=system ;; esac
if [ "$managed_v" = auto ]; then
  if [ -f "$settings_file" ] && grep -q '^# vlang.kak compiler-policy: system$' "$settings_file"; then managed_v=system; compiler_policy=system
  elif [ -x "$prefix/opt/vlang-v/current/v" ]; then managed_v=true; fi
fi
if [ "$managed_v" = system ]; then
  old_ifs=$IFS; IFS=:
  filtered=
  for part in $PATH; do
    case "$part" in "$prefix/opt/vlang-v/current"|"$prefix/opt/vlang-v/candidate") continue ;; esac
    filtered=${filtered:+$filtered:}$part
  done
  IFS=$old_ifs; PATH=$filtered; export PATH
elif [ -x "$prefix/opt/vlang-v/current/v" ]; then PATH="$prefix/opt/vlang-v/current:$PATH"; export PATH; fi
compiler_ok=false
probe=$(mktemp -d)
json_import=x.json2
case "$vls_mode" in auto|upstream) json_import=json2 ;; esac
printf 'import %s\nfn main() { _ = json2.Any(0) }\n' "$json_import" > "$probe/probe.v"
if command -v v >/dev/null 2>&1 && v -check "$probe/probe.v" >/dev/null 2>&1; then compiler_ok=true; fi
rm -rf "$probe"
compiler_required=false
if [ "$build" = true ] || [ "$install_lsp" = true ] || [ "$explorer" = true ] || [ "$vls_mode" = auto ] || [ "$vls_mode" = upstream ]; then
  compiler_required=true
fi
if [ "$managed_v" = system ] && [ "$compiler_ok" = false ] && [ "$compiler_required" = true ]; then
  echo 'Selected system V cannot compile the requested stack; use --managed-v or supply a compatible compiler on PATH.' >&2; exit 1
fi
if [ "$managed_v" = true ] || { [ "$managed_v" != system ] && [ "$compiler_ok" = false ] && [ "$compiler_required" = true ]; }; then
  "$script_dir/install-v.sh" "$prefix"
  PATH="$prefix/opt/vlang-v/candidate:$PATH"
  export PATH
  managed_v=true
elif [ "$managed_v" != system ] && [ -x "$prefix/opt/vlang-v/current/v" ]; then
  PATH="$prefix/opt/vlang-v/current:$PATH"; export PATH
fi

if [ "$build" = true ]; then
  v run "$script_dir/build-kakoune.vsh" --version "$kakoune_version" --prefix "$prefix"
  kak_runtime=$prefix/opt/vlang-kakoune/candidate/share/kak
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
  v run "$script_dir/install-kak-lsp.vsh" --version "$lsp_version" --prefix "$prefix"
fi
lsp_bin=$prefix/opt/vlang-kak-lsp/current/bin/kak-lsp
if [ "$install_lsp" = true ]; then lsp_bin=$prefix/opt/vlang-kak-lsp/candidate/bin/kak-lsp; fi
if [ ! -x "$lsp_bin" ]; then
  lsp_bin=$(command -v kak-lsp || true)
fi

if [ "$vls_mode" = upstream ]; then
  v run "$script_dir/install-vls.vsh" --ref "$vls_ref" --prefix "$prefix"
elif [ "$vls_mode" = external ]; then
  [ -x "$vls_path" ] || { echo "VLS is not executable: $vls_path" >&2; exit 1; }
  vls_path=$(readlink -f "$vls_path")
  mkdir -p "$prefix/bin"
  if [ -e "$prefix/bin/vls" ] && [ ! -L "$prefix/bin/vls" ]; then
    echo "Existing unmanaged VLS at $prefix/bin/vls; choose another --prefix." >&2
    exit 1
  fi
  : # Linked during activation below.
fi
if [ "$vls_mode" = skip ] && ! PATH="$prefix/bin:$PATH" command -v vls >/dev/null 2>&1; then
  echo "VLS is not on PATH. Pass --vls /path/to/vls after building it." >&2
fi

if [ "$build" = true ]; then "$prefix/opt/vlang-kakoune/candidate/bin/kak" -version; fi
if [ "$install_lsp" = true ]; then "$lsp_bin" --version; fi
if [ "$vls_mode" = upstream ]; then v run "$script_dir/probe-vls.vsh" "$prefix/opt/vlang-vls/candidate/bin/vls"; fi
if [ "$explorer" = true ]; then "$script_dir/explorer.sh" --prepare; fi
if command -v gdb >/dev/null 2>&1 && command -v v >/dev/null 2>&1; then "$script_dir/debug.sh" --prepare; fi

if command -v v >/dev/null 2>&1; then "$script_dir/preferences.sh" --prepare; fi

# Include integrated configuration in the transaction, after builds so user
# edits made while compiling are captured. Personal preferences are excluded.
if [ "$integrate" = true ] && [ -n "${VLANG_KAK_TRANSACTION:-}" ]; then
  "$script_dir/managed-state.sh" snapshot-personal "$prefix" "$config_home" "$VLANG_KAK_TRANSACTION"
fi

# All builds succeeded. Switch the prepared versions and generate launchers.
for tool in kakoune kak-lsp vls v; do
  root=$prefix/opt/vlang-$tool
  if [ -L "$root/candidate" ]; then
    target=$(readlink "$root/candidate")
    ln -sfn "$target" "$root/current.next"
    mv -Tf "$root/current.next" "$root/current"
    rm "$root/candidate"
  fi
done
managed_kak=false
if [ "$build" = true ] || [ -d "$prefix/opt/vlang-kakoune/current/share/kak" ]; then
  kak_runtime=$prefix/opt/vlang-kakoune/current/share/kak
  managed_kak=true
fi
if [ "$install_lsp" = true ]; then lsp_bin=$prefix/opt/vlang-kak-lsp/current/bin/kak-lsp; fi
if [ "$vls_mode" = upstream ]; then
  ln -sfn "$prefix/opt/vlang-vls/current/bin/vls" "$prefix/bin/vls"
elif [ "$vls_mode" = external ]; then
  ln -sfn "$vls_path" "$prefix/bin/vls"
fi

# Generate the configuration through V when the selected compiler can run it.
. "$script_dir/managed-v.inc"
config_status=125
if compiler=$(find_maintenance_v --prefix "$prefix"); then
  config_status=0
  run_maintenance_program "$compiler" "$script_dir/setup-configuration.vsh" \
    "$prefix" "$repo_dir" "$config_home" "$kak_runtime" "$lsp_bin" "$integrate" \
    "$managed_v" "$compiler_policy" "$explorer" "$live_search" "$pane_mode" "$window_backend" "$managed_kak" || config_status=$?
  if [ "$config_status" -eq 125 ]; then
    echo 'V could not prepare the configuration writer. Using shell configuration.' >&2
  fi
fi
case "$config_status" in
  0) user_config=$config_home/kak/vlang-user.kak; ide_launcher=$prefix/bin/kak-v ;;
  125) . "$script_dir/setup-configuration-posix" ;;
  *) exit "$config_status" ;;
esac
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

"$script_dir/managed-state.sh" record "$prefix" "$config_home" "$vls_mode"
