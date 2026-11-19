# Find V on PATH or in the selected managed prefix.
find_maintenance_v() {
    if command -v v >/dev/null 2>&1; then command -v v; return; fi
    prefix=${VLANG_KAK_PREFIX:-$HOME/.local}
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --prefix) [ "$#" -ge 2 ] || break; prefix=$2; shift ;;
        esac
        shift
    done
    compiler="$prefix/opt/vlang-v/current/v"
    [ -x "$compiler" ] && printf '%s\n' "$compiler"
}

# Build in a private directory. Status 125 is reserved for a bootstrap failure.
run_maintenance_program() (
    maintenance_compiler=$1
    maintenance_source=$2
    shift 2
    maintenance_runtime=$(mktemp -d) || exit 125
    trap 'rm -rf -- "$maintenance_runtime"' EXIT
    trap 'exit 130' HUP INT TERM
    if ! TMPDIR="$maintenance_runtime" "$maintenance_compiler" -skip-running -o "$maintenance_runtime/program" "$maintenance_source" ||
       [ ! -x "$maintenance_runtime/program" ]; then
        exit 125
    fi
    "$maintenance_runtime/program" "$@"
)
