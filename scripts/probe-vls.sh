#!/bin/sh
# A bounded LSP initialization check without a runtime Python dependency.
set -eu
server=$1
root=$(mktemp -d)
pid=
cleanup() { [ -z "$pid" ] || { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }; rm -rf "$root"; }
trap cleanup EXIT HUP INT TERM
mkfifo "$root/input"
# Keep the input open until initialization has completed.
"$server" < "$root/input" > "$root/output" 2> "$root/error" &
pid=$!
exec 3> "$root/input"
body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
printf 'Content-Length: %s\r\n\r\n%s' "${#body}" "$body" >&3
count=0
while [ "$count" -lt 10 ]; do
  if grep -Eq '"id"[[:space:]]*:[[:space:]]*1[,}]' "$root/output" && grep -q '"capabilities"' "$root/output"; then
    echo 'VLS initialization: passed'; exit 0
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 1; count=$((count + 1))
done
cat "$root/error" >&2
echo 'VLS did not complete LSP initialization within 10 seconds.' >&2
exit 1
