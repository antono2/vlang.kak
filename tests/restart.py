#!/usr/bin/env python3
"""Check the managed in-editor update and restart without network access."""

import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


def wait_for(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {description}")


def main():
    kak = Path(sys.argv[1]).resolve()
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="vlang-kak-restart-") as directory:
        root = Path(directory)
        prefix = root / "prefix"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "kak").symlink_to(kak)
        lsp = bin_dir / "kak-lsp"
        real_tools = os.environ.get("VLANG_TEST_REAL_TOOLS_PREFIX")
        if real_tools:
            tools_prefix = Path(real_tools).resolve()
            lsp.symlink_to(tools_prefix / "opt/vlang-kak-lsp/current/bin/kak-lsp")
            vls = str(tools_prefix / "bin/vls")
        else:
            lsp.write_text("#!/bin/sh\nprintf 'declare-option str lsp_cmd \\\"\\\"\\n'\n")
            lsp.chmod(0o755)
            vls = "/bin/true"
        environment = os.environ.copy()
        environment["XDG_CONFIG_HOME"] = str(root / "config")
        environment["PATH"] = str(bin_dir) + os.pathsep + environment["PATH"]
        environment["VLANG_KAK_SKIP_PULL"] = "1"
        environment.pop("VLANG_KAK_CONFIG_HOME", None)
        setup = subprocess.run(
            [
                str(repo / "scripts/setup.sh"),
                "--no-build",
                "--no-lsp",
                "--vls",
                vls,
                "--prefix",
                str(prefix),
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if setup.returncode:
            raise RuntimeError(f"Setup failed: {setup.stdout}\n{setup.stderr}")

        personal = root / "config/kak/vlang-user.kak"
        personal_text = "declare-option str release_test_setting preserved\n"
        personal.write_text(personal_text)

        first = root / "first.txt"
        second = root / "second.txt"
        first.write_text("first line\nsecond line\n")
        second.write_text("other buffer\n")
        session = "vlang-restart-" + uuid.uuid4().hex[:12]
        client_file = root / "client"
        with (root / "ui.jsonl").open("wb") as ui, (root / "stderr").open("wb") as errors:
            process = subprocess.Popen(
                [
                    str(prefix / "bin/kak-v"),
                    "-s",
                    session,
                    "-ui",
                    "json",
                    "-e",
                    f"echo -to-file {client_file} %val{{client}}",
                    str(first),
                ],
                env=environment,
                stdin=subprocess.PIPE,
                stdout=ui,
                stderr=errors,
            )
            try:
                wait_for(client_file.exists, "Kakoune startup")
                client = client_file.read_text().strip()

                def remote(command):
                    result = subprocess.run(
                        [str(kak), "-p", session],
                        input=f"evaluate-commands -client {client} %{{\n{command}\n}}\n",
                        text=True,
                        capture_output=True,
                        timeout=5,
                    )
                    if result.returncode:
                        raise RuntimeError(f"Kakoune remote command failed: {result.stderr}")

                def value(name, expression):
                    path = root / name
                    path.unlink(missing_ok=True)
                    remote(f"echo -to-file {path} {expression}")
                    wait_for(path.exists, name)
                    return path.read_text().strip()

                remote(f"edit -- {second}\nbuffer {first}\nselect 2.2,2.2")
                expected = f"{first} 2 2"
                before = value("before", "%val{buffile} %val{cursor_line} %val{cursor_column}")
                if before != expected:
                    raise RuntimeError(f"Kakoune did not reach the initial cursor position: {before}")
                original_pid = value("old-pid", "%val{client_pid}")
                if value("setting-before", "%opt{release_test_setting}") != "preserved":
                    raise RuntimeError("Personal settings were not loaded")
                failed = subprocess.run(
                    [str(repo / "scripts/update-session.sh"), str(prefix), session,
                     client, original_pid, "--no-build", "--no-lsp", "--vls", str(root / "missing-vls")],
                    env=environment, capture_output=True, text=True, timeout=20,
                )
                if failed.returncode == 0 or "VLS is not executable" not in failed.stderr:
                    raise RuntimeError("Failed update was not reported")
                if value("pid-after-failure", "%val{client_pid}") != original_pid:
                    raise RuntimeError("Failed update restarted the editor")
                client_started_at = client_file.stat().st_mtime_ns
                remote("v-update --no-build --no-lsp")
                wait_for(
                    lambda: client_file.stat().st_mtime_ns != client_started_at,
                    "in-editor update and restart",
                )
                if value("new-pid", "%val{client_pid}") == original_pid:
                    raise RuntimeError("The launcher did not start a new Kakoune process")
                if value("setting-after", "%opt{release_test_setting}") != "preserved":
                    raise RuntimeError("Update stopped loading personal settings")
                if personal.read_text() != personal_text:
                    raise RuntimeError("Update changed personal settings")
                generated = prefix / "opt/vlang-kakoune/ide-config/kak/kakrc"
                if str(personal) not in generated.read_text():
                    raise RuntimeError("Update changed the customization source path")
                if value("after", "%val{buffile} %val{cursor_line} %val{cursor_column}") != expected:
                    raise RuntimeError("Update did not restore the active file and cursor")
                remote(f"buffer {second}")
                if value("other", "%val{buffile}") != str(second):
                    raise RuntimeError("Update did not restore the other open file")

                remote(f"buffer {first}\nselect 1.1,1.1\nexecute-keys iX<esc>")
                pid_before_unsaved = value("pid-before-unsaved", "%val{client_pid}")
                remote("v-restart")
                if value("modified", "%val{modified}") != "true":
                    raise RuntimeError("Unsaved edit disappeared during restart")
                if value("pid-after-unsaved", "%val{client_pid}") != pid_before_unsaved:
                    raise RuntimeError("Kakoune restarted with an unsaved edit")
                if first.read_text().startswith("X"):
                    raise RuntimeError("Restart saved an edit without being asked")
                remote("quit!")
                process.wait(timeout=5)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
                if process.returncode not in (0, None):
                    print((root / "stderr").read_text(errors="replace")[-1500:], file=sys.stderr)
    print("ok - update preserves settings and cursor; failed updates and unsaved edits stay open")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"not ok - in-editor update and restart: {error}", file=sys.stderr)
        sys.exit(1)
