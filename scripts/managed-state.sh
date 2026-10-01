#!/bin/sh
# Ownership records and snapshots. No manifest entry is executed as shell code.
set -eu
case ${1:-} in --help|-h) echo 'Usage: managed-state.sh record PREFIX CONFIG_HOME | snapshot PREFIX DIRECTORY | restore PREFIX DIRECTORY | repair-links PREFIX'; exit 0 ;; esac
operation=${1:-help}
prefix=${2:-${VLANG_KAK_PREFIX:-$HOME/.local}}
case "$prefix" in /*) ;; *) echo 'Use an absolute prefix.' >&2; exit 2 ;; esac
state=$prefix/opt/vlang-state
case "$operation" in
  record)
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
        [ -f "$release/.vlang-version" ] || [ -f "$release/.vlang-commit" ] || [ -f "$release/.vlang-revision" ] || continue
        find "$release" -depth -print | while IFS= read -r path; do record "$path"; done
      done
      record "$root/current"; record "$root/candidate"; record "$root/releases"; record "$root"
    done
    isolated=$prefix/opt/vlang-kakoune/ide-config
    if [ -f "$isolated/kak/kakrc" ]; then
      find "$isolated" -depth -print | while IFS= read -r path; do record "$path"; done
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
    for path in bin/kak bin/kak-v bin/vls bin/v opt/vlang-kakoune/current opt/vlang-kak-lsp/current opt/vlang-vls/current opt/vlang-v/current opt/vlang-kakoune/ide-config/kak/kakrc opt/vlang-kakoune/ide-config/kak/autoload/vlang.kak opt/vlang-kakoune/ide-config/kak/autoload/vlang-site-runtime; do
      mkdir -p "$destination/$(dirname "$path")"
      if [ -e "$prefix/$path" ] || [ -L "$prefix/$path" ]; then cp -Pp "$prefix/$path" "$destination/$path"; fi
      printf '%s\n' "$path" >> "$destination/paths"
    done
    ;;
  restore)
    snapshot=$3
    [ -f "$snapshot/paths" ] || { echo 'No previous tool snapshot.' >&2; exit 1; }
    while IFS= read -r path; do
      case "$path" in bin/kak|bin/kak-v|bin/vls|bin/v|opt/vlang-*/current|opt/vlang-kakoune/ide-config/kak/*) ;; *) exit 1 ;; esac
      if [ -e "$snapshot/$path" ] || [ -L "$snapshot/$path" ]; then
        mkdir -p "$prefix/$(dirname "$path")"
        cp -Pp "$snapshot/$path" "$prefix/$path.restore"
        mv -Tf "$prefix/$path.restore" "$prefix/$path"
      else rm -f "$prefix/$path"; fi
    done < "$snapshot/paths"
    if [ -f "$snapshot/personal-paths" ]; then
      config=$(cat "$snapshot/config-home")
      while IFS= read -r relative; do
        case "$relative" in kak/kakrc|kak/autoload/vlang.kak|kak/autoload/vlang-site-runtime) ;; *) exit 1 ;; esac
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
  *) echo 'Usage: managed-state.sh record PREFIX CONFIG_HOME | snapshot PREFIX DIRECTORY | restore PREFIX DIRECTORY' >&2; exit 2 ;;
esac
