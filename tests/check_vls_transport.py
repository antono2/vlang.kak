#!/usr/bin/env python3
"""Check live-VLS command ordering and errors against a real Kakoune session."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

spec = importlib.util.spec_from_file_location(
    "check_vls", Path(__file__).resolve().parents[1] / "scripts/check-vls.py"
)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)
kak = sys.argv[1] if len(sys.argv) > 1 else "kak"

with tempfile.TemporaryDirectory(prefix="vlang-command-check-") as directory:
    root = Path(directory)
    session = "vlang-command-" + uuid.uuid4().hex
    client_path = root / "client"
    process = subprocess.Popen(
        [kak, "-n", "-s", session, "-ui", "json", "-e",
         f"echo -to-file {check.kak_quote(client_path)} %val{{client}}"],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    client = None
    try:
        check.wait_for(lambda: client_path.exists() and client_path.read_text().strip(), "test client")
        client = client_path.read_text().strip()
        result = root / "result"
        result.write_text("stale\n")
        # kak -p exits while this shell command is still sleeping. Reading the
        # previous probe's file at that point would accept stale editor state.
        check.send_editor_commands(
            kak, session, client,
            f"nop %sh{{ sleep 0.2 }}\necho -to-file {check.kak_quote(result)} fresh",
            root,
        )
        assert result.read_text().strip() == "fresh", "read stale state before command execution"
        try:
            check.send_editor_commands(kak, session, client, "fail 'transport probe failure'", root)
        except RuntimeError as error:
            assert "transport probe failure" in str(error)
        else:
            raise AssertionError("editor errors must reach the checker")
        check.send_editor_commands(
            kak, session, client, "buffer *not-created-yet*", root, allow_error=True,
        )
        check.send_editor_commands(kak, session, client, "nop", root)
        assert not list(root.glob("command-*")), "command responses were not cleaned up"
    finally:
        if client and process.poll() is None:
            check.send_editor_commands(kak, session, client, "quit!", root, wait=False)
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)
        assert not process.stderr.read(), "Kakoune wrote unexpected stderr"
print("ok - live VLS command execution acknowledgment and errors")
