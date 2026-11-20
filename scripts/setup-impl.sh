#!/bin/sh
# Install or update a user-local V IDE without replacing distribution packages.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
. "$script_dir/managed-v.inc"
if [ "${1:-}" = --prepared-options ]; then
  shift
  # The prepared payload contains one argument for each field below.
  [ "$#" -eq 16 ] || { echo 'Incomplete prepared setup options.' >&2; exit 2; }
  prefix=$1
  integrate=$2
  explorer=$3
  live_search=$4
  pane_mode=$5
  window_backend=$6
  kakoune_version=$7
  lsp_version=$8
  vls_path=$9
  vls_mode=${10}
  vls_ref=${11}
  update=${12}
  managed_v=${13}
  repair=${14}
  build=${15}
  install_lsp=${16}
else
  . "$script_dir/setup-options-posix"
fi
config_home=${VLANG_KAK_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}
# Older launchers exported only their isolated XDG directory. Recover the
# personal path from our generated source line when updating those sessions.
if [ -z "${VLANG_KAK_CONFIG_HOME:-}" ] &&
   [ "$config_home" = "$prefix/opt/vlang-kakoune/ide-config" ]; then
  legacy_status=125
  if legacy_compiler=$(find_maintenance_v --prefix "$prefix"); then
    legacy_status=0
    original_config=$(run_maintenance_program "$legacy_compiler" \
      "$script_dir/setup-legacy-config.vsh" "$config_home") || legacy_status=$?
    if [ "$legacy_status" -eq 125 ]; then
      echo 'V could not prepare the legacy config reader. Using shell recovery.' >&2
    fi
  fi
  case "$legacy_status" in
    0) ;;
    125)
      original_config=$(sed -n "s|^source '\(.*\)/kak/vlang-user.kak'$|\1|p" \
        "$config_home/kak/kakrc" | tail -n 1 | sed "s/''/'/g")
      if [ -z "$original_config" ] || [ ! -f "$original_config/kak/vlang-user.kak" ]; then
        echo 'Cannot locate personal configuration; rerun setup from a regular shell with XDG_CONFIG_HOME set.' >&2
        exit 1
      fi
      ;;
    *) exit "$legacy_status" ;;
  esac
  config_home=$original_config
fi
case "$config_home" in *"$(printf '\t')"*|*'
'*) echo 'Tabs/newlines in configuration paths are unsupported.' >&2; exit 2 ;; esac
mkdir -p "$config_home"
config_home=$(CDPATH= cd -- "$config_home" && pwd)
settings_file=$prefix/opt/vlang-kakoune/ide-config/kak/kakrc
if [ ! -f "$settings_file" ]; then settings_file=$config_home/kak/kakrc; fi
defaults_status=125
if defaults_compiler=$(find_maintenance_v --prefix "$prefix"); then
  defaults_status=0
  setup_defaults=$(run_maintenance_program "$defaults_compiler" "$script_dir/setup-defaults.vsh" \
    "$settings_file" "$config_home/kak/kakrc" "$integrate" "$explorer" "$live_search" \
    "$pane_mode" "$window_backend") || defaults_status=$?
  if [ "$defaults_status" -eq 125 ]; then
    echo 'V could not prepare the setup defaults command. Using shell defaults.' >&2
  fi
fi
case "$defaults_status" in
  0)
    # Read one value per line without treating kakrc contents as shell code.
    {
      IFS= read -r integrate
      IFS= read -r explorer
      IFS= read -r live_search
      IFS= read -r pane_mode
      IFS= read -r window_backend
    } <<EOF
$setup_defaults
EOF
    ;;
  125) . "$script_dir/setup-defaults-posix" ;;
  *) exit "$defaults_status" ;;
esac
case "$prefix" in
  *"'"*|*'
'*) echo "The installation prefix cannot contain quotes or newlines." >&2; exit 2 ;;
esac
prefix=$(mkdir -p "$prefix" && CDPATH= cd -- "$prefix" && pwd)

# Validate user-facing paths before any download or build.
check_setup_paths() {
  setup_paths_phase=$1
  if setup_paths_compiler=$(find_maintenance_v --prefix "$prefix"); then
    setup_paths_status=0
    run_maintenance_program "$setup_paths_compiler" "$script_dir/setup-paths.vsh" \
      "$setup_paths_phase" "$prefix" "$repo_dir" "$config_home" "$integrate" || setup_paths_status=$?
    [ "$setup_paths_status" -eq 125 ] || return "$setup_paths_status"
    echo 'V could not prepare the setup path checks. Using shell path checks.' >&2
  fi
  . "$script_dir/setup-paths-posix"
  case "$setup_paths_phase" in all|personal) check_personal_paths ;; esac
  case "$setup_paths_phase" in all|managed) check_managed_paths ;; esac
}
if [ "$repair" = true ]; then
  check_setup_paths personal
  "$script_dir/managed-state.sh" repair-links "$prefix"
  check_setup_paths managed
else
  check_setup_paths all
fi

if [ "$update" = true ] && [ "${VLANG_KAK_SKIP_PULL:-0}" != 1 ]; then
  refresh_status=125
  if refresh_compiler=$(find_maintenance_v --prefix "$prefix"); then
    refresh_status=0
    run_maintenance_program "$refresh_compiler" "$script_dir/setup-repository.vsh" "$repo_dir" || refresh_status=$?
    if [ "$refresh_status" -eq 125 ]; then
      echo 'V could not prepare the checkout updater. Using shell Git update.' >&2
    fi
  fi
  if [ "$refresh_status" -eq 125 ]; then
    if [ -d "$repo_dir/.git" ] && [ -z "$(git -C "$repo_dir" status --porcelain)" ]; then
      git -C "$repo_dir" pull --ff-only
    else
      echo "Keeping local vlang.kak checkout: it has uncommitted changes or is not a Git clone."
    fi
  elif [ "$refresh_status" -ne 0 ]; then
    exit "$refresh_status"
  fi
fi

setup_vls() {
  if vls_compiler=$(find_maintenance_v --prefix "$2"); then
    vls_status=0
    run_maintenance_program "$vls_compiler" "$script_dir/setup-vls.vsh" "$@" || vls_status=$?
    [ "$vls_status" -eq 125 ] || return "$vls_status"
    echo 'V could not prepare VLS selection. Using shell VLS selection.' >&2
  fi
  . "$script_dir/setup-vls-posix"
}
if [ "$vls_mode" = auto ]; then
  vls_mode=$(setup_vls select "$prefix")
  if [ "$vls_mode" = skip ]; then
    echo 'Keeping externally linked VLS. Use --vls-upstream to switch to managed upstream VLS.'
  fi
fi

# Resolve compiler policy before installing or building any tools.
compiler_plan_status=125
if compiler=$(find_maintenance_v --prefix "$prefix"); then
  compiler_plan_status=0
  compiler_plan=$(run_maintenance_program "$compiler" "$script_dir/setup-compiler.vsh" \
    "$prefix" "$settings_file" "$managed_v" "$build" "$install_lsp" "$explorer" "$vls_mode") || compiler_plan_status=$?
  if [ "$compiler_plan_status" -eq 125 ]; then
    echo 'V could not prepare the compiler selector. Using shell compiler selection.' >&2
  fi
fi
case "$compiler_plan_status" in
  0)
    # The first three lines are fixed values. The final dot preserves even a
    # trailing newline in PATH through POSIX command substitution.
    line_break='
'
    compiler_policy=${compiler_plan%%"$line_break"*}
    compiler_plan=${compiler_plan#*"$line_break"}
    managed_v=${compiler_plan%%"$line_break"*}
    compiler_plan=${compiler_plan#*"$line_break"}
    install_managed_v=${compiler_plan%%"$line_break"*}
    compiler_plan=${compiler_plan#*"$line_break"}
    PATH=${compiler_plan%.}
    export PATH
    ;;
  125) . "$script_dir/setup-compiler-posix" ;;
  *) exit "$compiler_plan_status" ;;
esac
if [ "$install_managed_v" = true ]; then
  "$script_dir/install-v.sh" "$prefix"
  PATH="$prefix/opt/vlang-v/candidate:$PATH"
  export PATH
  managed_v=true
fi

if [ "$build" = true ]; then
  v run "$script_dir/build-kakoune.vsh" --version "$kakoune_version" --prefix "$prefix"
  kak_runtime=$prefix/opt/vlang-kakoune/candidate/share/kak
else
  runtime_status=125
  if runtime_compiler=$(find_maintenance_v --prefix "$prefix"); then
    runtime_status=0
    runtime_path=$(run_maintenance_program "$runtime_compiler" "$script_dir/setup-runtime.vsh" "$prefix") || runtime_status=$?
    if [ "$runtime_status" -eq 125 ]; then
      echo 'V could not prepare runtime discovery. Using shell runtime discovery.' >&2
    fi
  fi
  case "$runtime_status" in
    0) ;;
    125) runtime_path=$(. "$script_dir/setup-runtime-posix") ;;
    *) exit "$runtime_status" ;;
  esac
  # Protect trailing newlines in a path passed through command substitution.
  kak_runtime=${runtime_path%.}
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
  vls_path=$(setup_vls external "$prefix" "$vls_path")
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
activation_status=125
if compiler=$(find_maintenance_v --prefix "$prefix"); then
  activation_status=0
  run_maintenance_program "$compiler" "$script_dir/setup-activation.vsh" "$prefix" "$vls_mode" "$vls_path" || activation_status=$?
  if [ "$activation_status" -eq 125 ]; then
    echo 'V could not prepare tool activation. Using shell activation.' >&2
  fi
fi
case "$activation_status" in
  0) ;;
  125) . "$script_dir/setup-activation-posix" ;;
  *) exit "$activation_status" ;;
esac
managed_kak=false
if [ "$build" = true ] || [ -d "$prefix/opt/vlang-kakoune/current/share/kak" ]; then
  kak_runtime=$prefix/opt/vlang-kakoune/current/share/kak
  managed_kak=true
fi
if [ "$install_lsp" = true ]; then lsp_bin=$prefix/opt/vlang-kak-lsp/current/bin/kak-lsp; fi

# Generate the configuration through V when the selected compiler can run it.
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
