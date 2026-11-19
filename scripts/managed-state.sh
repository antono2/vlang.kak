#!/bin/sh
# Ownership records and snapshots. No manifest entry is executed as shell code.
set -eu
case ${1:-} in --help|-h) echo 'Usage: managed-state.sh record PREFIX CONFIG_HOME | snapshot PREFIX DIRECTORY | snapshot-personal PREFIX CONFIG_HOME DIRECTORY | restore PREFIX DIRECTORY | repair-links PREFIX'; exit 0 ;; esac
operation=${1:-help}
prefix=${2:-${VLANG_KAK_PREFIX:-$HOME/.local}}
case "$prefix" in /*) ;; *) echo 'Use an absolute prefix.' >&2; exit 2 ;; esac
state=$prefix/opt/vlang-state
case "$operation" in snapshot|snapshot-personal|restore)
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  . "$script_dir/managed-v.inc"
  if compiler=$(find_maintenance_v --prefix "$prefix") && snapshot_runtime=$(mktemp -d); then
    trap 'rm -rf -- "$snapshot_runtime"' EXIT
    trap 'exit 130' HUP INT TERM
    # Compile independently so simultaneous operations on distinct prefixes cannot collide.
    if TMPDIR="$snapshot_runtime" "$compiler" -skip-running -o "$snapshot_runtime/snapshot" "$script_dir/managed-snapshot.vsh" &&
       [ -x "$snapshot_runtime/snapshot" ]; then
      case "$operation" in
        snapshot-personal) "$snapshot_runtime/snapshot" "$operation" "$3" "$4" ;;
        *) "$snapshot_runtime/snapshot" "$operation" "$prefix" "$3" ;;
      esac
      exit
    fi
    echo 'V could not prepare the snapshot command. Using shell recovery.' >&2
  fi
  # Snapshot recovery must also work on editor-only installations without V.
  ;;
esac
tool_paths='bin/kak bin/kak-v bin/vls bin/v opt/vlang-kakoune/current opt/vlang-kak-lsp/current opt/vlang-vls/current opt/vlang-v/current opt/vlang-kakoune/ide-config/kak/kakrc opt/vlang-kakoune/ide-config/kak/autoload/vlang.kak opt/vlang-kakoune/ide-config/kak/autoload/vlang-site-runtime'
personal_paths='kak/kakrc kak/autoload/vlang.kak kak/autoload/vlang-site-runtime'
validate_paths() {
  while IFS= read -r item || [ -n "$item" ]; do
    match=false
    for expected in $2; do
      if [ "$item" = "$expected" ]; then match=true; break; fi
    done
    [ "$match" = true ] || { echo "Unexpected snapshot path: $item" >&2; return 1; }
  done < "$1"
}
case "$operation" in
  record)
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    . "$script_dir/managed-v.inc"
    if compiler=$(find_maintenance_v --prefix "$prefix"); then
      exec "$compiler" run "$script_dir/record-managed-state.vsh" "$prefix" "$3" "${4:-}"
    fi
    # Editor-only installations may record ownership before V is available.
    config=$3
    mkdir -p "$state"
    manifest=$state/manifest.tsv
    temporary=$(mktemp "$state/manifest.XXXXXXXX")
    trap 'rm -f "$temporary"' EXIT HUP INT TERM
    echo 'Recording managed file ownership...'
    # A prior ownership record is retained for files changed outside setup.
    record() {
      path=$1
      case "$path" in *"$(printf '\t')"*|*'
'*) echo 'Tabs/newlines in installed paths are unsupported.' >&2; exit 1 ;; esac
      if [ -L "$path" ]; then kind=link; identity=$(readlink "$path")
      elif [ -f "$path" ]; then kind=file; identity=$(sha256sum "$path" | cut -d ' ' -f 1)
      elif [ -d "$path" ]; then kind=dir; identity=-
      else return 0; fi
      printf '%s\t%s\t%s\n' "$kind" "$identity" "$path" >> "$temporary"
    }
    for tool in kakoune kak-lsp vls v; do
      root=$prefix/opt/vlang-$tool
      [ -d "$root" ] || continue
      # Only releases identified by the tool installer belong to us.
      for release in "$root"/releases/*; do
        if [ -f "$state/unowned-releases" ] && grep -Fxq "$release" "$state/unowned-releases"; then continue; fi
        [ -f "$release/.vlang-version" ] || [ -f "$release/.vlang-commit" ] || [ -f "$release/.vlang-revision" ] || continue
        find "$release" -depth -print | while IFS= read -r path; do record "$path"; done
      done
      record "$root/current"; record "$root/candidate"; record "$root/releases"; record "$root"
    done
    isolated=$prefix/opt/vlang-kakoune/ide-config
    if [ -f "$isolated/kak/kakrc" ]; then
      for relative in kak/kakrc kak/autoload/vlang.kak kak/autoload/vlang-site-runtime kak/autoload kak; do
        record "$isolated/$relative"
      done
      record "$isolated"
    fi
    for launcher in kak kak-v v; do
      path=$prefix/bin/$launcher
      [ -f "$path" ] && grep -q '^# vlang.kak managed ' "$path" && record "$path"
    done
    if [ -L "$prefix/bin/vls" ]; then
      if [ "${4:-}" = external ] || [ "$(readlink -f "$prefix/bin/vls")" = "$(readlink -f "$prefix/opt/vlang-vls/current/bin/vls" 2>/dev/null || true)" ] ||
         { [ -f "$manifest" ] && awk -F '\t' -v p="$prefix/bin/vls" '$3==p {found=1} END {exit !found}' "$manifest"; }; then
        record "$prefix/bin/vls"
      fi
    fi
    integrated=false
    [ ! -f "$prefix/opt/vlang-kakoune/ide-config/kak/kakrc" ] || ! grep -q "^# vlang.kak integrate: true$" "$prefix/opt/vlang-kakoune/ide-config/kak/kakrc" || integrated=true
    if [ "$integrated" = true ]; then
    for link in vlang.kak vlang-site-runtime; do
      path=$config/kak/autoload/$link
      [ ! -L "$path" ] || record "$path"
    done
    if [ -f "$config/kak/kakrc" ]; then
      block=$(sed -n '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/p' "$config/kak/kakrc")
      if [ -n "$block" ]; then
        printf 'block\t%s\t%s\n' "$(printf '%s\n' "$block" | sha256sum | cut -d ' ' -f 1)" "$config/kak/kakrc" >> "$temporary"
      fi
    fi
    fi
    if [ -f "$manifest" ]; then
      awk -F "\t" 'function release(p, a,b,n) { n=split(p,a,"/releases/"); if (n<2) return ""; split(a[2],b,"/"); return a[1] "/releases/" b[1] } NR==FNR { old[$3]=$0; r=release($3); if (r!="") known[r]=1; next } { r=release($3); if (r!="" && r in known) { if ($3 in old) print old[$3] } else print }' "$manifest" "$temporary" > "$temporary.merge"
      mv "$temporary.merge" "$temporary"
    fi
    LC_ALL=C sort -u "$temporary" > "$manifest.next"
    mv "$manifest.next" "$manifest"
    printf '%s\n' "$config" > "$state/config-home"
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}" > "$state/cache-home"
    ;;
  repair-links)
    script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    . "$script_dir/managed-v.inc"
    if compiler=$(find_maintenance_v --prefix "$prefix"); then
      exec "$compiler" run "$script_dir/repair-managed-links.vsh" "$prefix"
    fi
    # Editor-only installations may repair links without a compiler installed.
    manifest=$state/manifest.tsv
    [ -f "$manifest" ] || exit 0
    while IFS="$(printf '\t')" read -r kind target path; do
      [ "$kind" = link ] || continue
      case "$path" in "$prefix/"*|"$(cat "$state/config-home")/kak/autoload/"*) ;; *) continue ;; esac
      if [ -L "$path" ]; then
        [ "$(readlink "$path")" = "$target" ] || echo "Keep changed link: $path"
      elif [ -e "$path" ]; then echo "Keep replacement file: $path"
      else mkdir -p "$(dirname "$path")"; ln -s "$target" "$path"; echo "Repaired link: $path"; fi
    done < "$manifest"
    ;;
  snapshot)
    mkdir -p "$state"
    destination=$3
    mkdir -p "$destination"
    for path in $tool_paths; do
      mkdir -p "$destination/$(dirname "$path")"
      if [ -e "$prefix/$path" ] || [ -L "$prefix/$path" ]; then cp -Pp "$prefix/$path" "$destination/$path"; fi
      printf '%s\n' "$path" >> "$destination/paths"
    done
    ;;
  snapshot-personal)
    config=$3
    destination=$4
    printf '%s\n' "$config" > "$destination/config-home"
    for path in $personal_paths; do
      mkdir -p "$destination/personal/$(dirname "$path")"
      if [ -f "$config/$path" ] || [ -L "$config/$path" ]; then cp -Pp "$config/$path" "$destination/personal/$path"; fi
      printf '%s\n' "$path" >> "$destination/personal-paths"
    done
    if [ -f "$config/kak/kakrc" ]; then
      cp -p "$(readlink -f "$config/kak/kakrc")" "$destination/kakrc-content"
    fi
    ;;
  restore)
    snapshot=$3
    [ -f "$snapshot/paths" ] || { echo 'No previous tool snapshot.' >&2; exit 1; }
    validate_paths "$snapshot/paths" "$tool_paths"
    if [ -f "$snapshot/personal-paths" ]; then
      validate_paths "$snapshot/personal-paths" "$personal_paths"
      config=$(cat "$snapshot/config-home")
      case "$config" in /*) ;; *) echo 'Invalid personal configuration location.' >&2; exit 1 ;; esac
    fi
    while IFS= read -r path; do
      if [ -e "$snapshot/$path" ] || [ -L "$snapshot/$path" ]; then
        mkdir -p "$prefix/$(dirname "$path")"
        cp -Pp "$snapshot/$path" "$prefix/$path.restore"
        mv -Tf "$prefix/$path.restore" "$prefix/$path"
      else rm -f "$prefix/$path"; fi
    done < "$snapshot/paths"
    if [ -f "$snapshot/personal-paths" ]; then
      while IFS= read -r relative; do
        if [ "$relative" = kak/kakrc ] && [ -f "$snapshot/kakrc-content" ]; then
          # Restore only our block; retain unrelated edits since the snapshot.
          target=$(readlink -f "$config/$relative")
          temporary=$(mktemp "$target.XXXXXXXX")
          sed '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/{d;}' "$target" > "$temporary"
          sed -n '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/p' "$snapshot/kakrc-content" >> "$temporary"
          cat "$temporary" > "$target"; rm "$temporary"
        elif [ -e "$snapshot/personal/$relative" ] || [ -L "$snapshot/personal/$relative" ]; then
          cp -Pp "$snapshot/personal/$relative" "$config/$relative.restore"
          mv -Tf "$config/$relative.restore" "$config/$relative"
        else
          if [ "$relative" = kak/kakrc ] && [ -f "$config/$relative" ]; then
            target=$(readlink -f "$config/$relative")
            temporary=$(mktemp "$target.XXXXXXXX")
            sed '/^# >>> vlang.kak managed >>>$/,/^# <<< vlang.kak managed <<<$/{d;}' "$target" > "$temporary"
            cat "$temporary" > "$target"; rm "$temporary"
          else rm -f "$config/$relative"; fi
        fi
      done < "$snapshot/personal-paths"
    fi
    ;;
  *) echo 'Usage: managed-state.sh record PREFIX CONFIG_HOME | snapshot PREFIX DIRECTORY | restore PREFIX DIRECTORY | repair-links PREFIX' >&2; exit 2 ;;
esac
