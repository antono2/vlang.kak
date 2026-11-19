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
