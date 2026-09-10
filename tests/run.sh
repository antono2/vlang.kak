#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(dirname -- "$script_dir")
kak_input=${KAK:-kak}

case $kak_input in
  /*) kak=$kak_input ;;
  */*) kak=$(CDPATH= cd -- "$(dirname -- "$kak_input")" && pwd)/$(basename -- "$kak_input") ;;
  *) kak=$(command -v "$kak_input" || true) ;;
esac

if [ -z "$kak" ] || [ ! -x "$kak" ]; then
  echo "Kakoune executable not found: $kak_input" >&2
  exit 1
fi

if ! command -v v >/dev/null 2>&1; then
  echo "V executable not found" >&2
  exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "timeout executable not found" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 executable not found" >&2
  exit 1
fi

test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/vlang-kak-tests.XXXXXXXX")
trap 'rm -rf -- "$test_tmp"' EXIT HUP INT TERM

cp -R "$script_dir/fixtures/." "$test_tmp/"
mkdir -p "$test_tmp/config/kak"

plugin_path=$(printf %s "$repo_dir/rc/vlang.kak" | sed "s/'/''/g")
{
  printf "source '%s'\n" "$plugin_path"
  printf '%s\n' \
    'face global attribute rgb:101001' \
    'face global comment rgb:202002' \
    'face global function rgb:303003' \
    'face global keyword rgb:404004' \
    'face global meta rgb:505005' \
    'face global operator rgb:606006' \
    'face global string rgb:707007' \
    'face global type rgb:808008' \
    'face global value rgb:909009'
} > "$test_tmp/config/kak/kakrc"

test_index=0

run_kak() {
  test_name=$1
  test_file=$2
  test_case=$3
  test_index=$((test_index + 1))

  rm -f "$test_tmp/failure"
  ui_in="$test_tmp/ui-in-$test_index"
  ui_out="$test_tmp/ui-out-$test_index"
  session="vlang-kak-test-$$-$test_index"
  case_path=$(printf %s "$test_case" | sed "s/'/''/g")
  mkfifo "$ui_in"

  (
    cd "$test_tmp"
    exec timeout 30s env XDG_CONFIG_HOME="$test_tmp/config" \
      "$kak" "$test_file" -s "$session" -ui json -e "source '$case_path'"
  ) > "$ui_out" < "$ui_in" &
  kak_pid=$!

  exec 3> "$ui_in"
  if wait "$kak_pid"; then
    status=0
  else
    status=$?
  fi
  exec 3>&-
  rm -f "$ui_in"

  if [ "$status" -ne 0 ]; then
    echo "not ok - $test_name (Kakoune exited with $status)" >&2
    if [ -s "$test_tmp/failure" ]; then
      sed 's/^/  /' "$test_tmp/failure" >&2
    fi
    if [ -s "$ui_out" ]; then
      sed 's/^/  ui: /' "$ui_out" >&2
    fi
    return 1
  fi

  if [ -s "$test_tmp/failure" ]; then
    echo "not ok - $test_name" >&2
    sed 's/^/  /' "$test_tmp/failure" >&2
    return 1
  fi

  echo "ok - $test_name"
}

assert_file_equal() {
  expected=$1
  actual=$2
  description=$3

  if ! cmp -s "$expected" "$actual"; then
    echo "not ok - $description" >&2
    diff -u "$expected" "$actual" >&2 || true
    exit 1
  fi
  echo "ok - $description"
}

assert_highlighting() {
  filename=$1
  expectations=$2
  syntax_ui="$test_tmp/$(basename "$filename").jsonl"

  if (
    cd "$test_tmp"
    env XDG_CONFIG_HOME="$test_tmp/config" \
      "$kak" "$filename" -ui json -e 'execute-keys j' < /dev/null > "$syntax_ui"
  ); then
    :
  else
    render_status=$?
    # The JSON UI treats stdin closing after its initial draw as a client error.
    test "$render_status" -eq 255
  fi

  python3 "$script_dir/assert_highlighting.py" "$syntax_ui" "$expectations"
}

echo "Testing with $("$kak" -version) and $(v version)"

run_kak \
  "commands and editing hooks" \
  "$test_tmp/project/main.v" \
  "$script_dir/cases/core.kak"

test "$(sed -n '1p' "$test_tmp/core-ok")" = ok
assert_file_equal \
  "$script_dir/fixtures/expected/formatted.v" \
  "$test_tmp/unformatted.v" \
  "v-fmt formats and saves"
assert_file_equal \
  "$script_dir/fixtures/formatter_failure.v" \
  "$test_tmp/formatter_failure.v" \
  "v-fmt preserves files when formatting fails"
assert_file_equal \
  "$script_dir/fixtures/expected/indent.v" \
  "$test_tmp/indent.v" \
  "newline hook inserts a closing delimiter"

for filename in sample.v sample.vsh sample.vv sample.c.v; do
  rm -f "$test_tmp/detected"
  run_kak \
    "filetype detection for $filename" \
    "$test_tmp/detection/$filename" \
    "$script_dir/cases/filetype.kak"
  test "$(sed -n '1p' "$test_tmp/detected")" = v
done

rm -f "$test_tmp/detected"
run_kak \
  "filetype detection for v.mod" \
  "$test_tmp/detection/v.mod" \
  "$script_dir/cases/filetype.kak"
test "$(sed -n '1p' "$test_tmp/detected")" = json

assert_highlighting syntax.v "$script_dir/fixtures/highlighting.tsv"
assert_highlighting language_features.v "$script_dir/fixtures/language_highlighting.tsv"

v fmt -verify "$test_tmp/syntax.v"
v -check "$test_tmp/syntax.v"
v fmt -verify "$test_tmp/language_features.v"
v -check "$test_tmp/language_features.v"
v test "$test_tmp/project"

echo "All vlang.kak tests passed"
