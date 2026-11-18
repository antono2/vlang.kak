#!/usr/bin/env python3
"""Check the managed Kakoune launcher and run the V protocol check."""

import argparse
from contextlib import nullcontext
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


SOURCE = """module main

// Adds two values.
fn add(left int, right int) int {
    return left + right
}

fn main() {
    result := add(1, 2)
    println(result)
}
"""
CLEAN = "module main\nfn broken() int { return 1 }\n"
IMPORTS = "module main\n\nimport os\nimport math\n\nfn main() { println(os.args.len) }\n"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def kak_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def wait_for(predicate, description, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {description}")


def send_editor_commands(kak, session, client, commands, root, *, allow_error=False, wait=True):
    """Wait for editor execution, not just kak -p's asynchronous socket write."""
    wrapped = f"evaluate-commands -client {client} %{{\n{commands}\n}}\n"
    acknowledgment = root / ("command-" + uuid.uuid4().hex)
    error_path = acknowledgment.with_suffix(".error")
    if wait:
        wrapped = (
            f"try %{{\n{wrapped}}} catch %{{\n"
            f"echo -to-file {kak_quote(error_path)} %val{{error}}\n}}\n"
            f"echo -to-file {kak_quote(acknowledgment)} done\n"
        )
    try:
        result = subprocess.run(
            [str(kak), "-p", session], input=wrapped, text=True,
            capture_output=True, timeout=10,
        )
        require(result.returncode == 0, f"Kakoune command delivery failed: {result.stderr.strip()}")
        if wait:
            wait_for(
                lambda: acknowledgment.exists() and acknowledgment.read_text().strip() == "done",
                "Kakoune command acknowledgment",
            )
            if error_path.exists() and not allow_error:
                raise RuntimeError(f"Kakoune command failed: {error_path.read_text().strip()}")
    finally:
        acknowledgment.unlink(missing_ok=True)
        error_path.unlink(missing_ok=True)


def ui_events(path):
    if not path.exists():
        return []
    events = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return events


def check_kakoune(kak, launcher, root, main_file):
    session = "vlang-lsp-" + uuid.uuid4().hex[:12]
    client_path = root / "client"
    ui_path = root / "ui.jsonl"
    stderr_path = root / "kak-stderr"
    with ui_path.open("wb") as ui, stderr_path.open("wb") as errors:
        process = subprocess.Popen(
            [
                str(launcher),
                "-s",
                session,
                "-ui",
                "json",
                "-e",
                f"echo -to-file {kak_quote(client_path)} %val{{client}}",
                str(main_file),
            ],
            stdin=subprocess.PIPE,
            stdout=ui,
            stderr=errors,
        )
        client = None

        def remote(commands, *, allow_error=False, wait=True):
            require(process.poll() is None, "Kakoune exited before the LSP check finished")
            send_editor_commands(
                kak, session, client, commands, root, allow_error=allow_error, wait=wait,
            )

        try:
            wait_for(lambda: client_path.exists(), "Kakoune client startup")
            client = client_path.read_text().strip()
            require(client, "Kakoune did not report its client name")

            filetype_path = root / "filetype"
            remote(f"echo -to-file {kak_quote(filetype_path)} %opt{{filetype}}")
            filetype = filetype_path.read_text().strip()
            require(filetype == "v", f"V source detected as {filetype!r}; check filetype hook precedence")

            # Exercise result browsing, not just the LSP response contents.
            navigation_path = root / "navigation"

            def at_location(buffer, line, column=None, results=False):
                # Kakoune abbreviates bufname under HOME; buffile is the actual
                # source path. Keep it separate so paths with spaces work too.
                identity_path = root / "navigation-buffer"
                identity = "%val{buffile}" if Path(str(buffer)).is_absolute() else "%val{bufname}"
                remote(
                    f"echo -to-file {kak_quote(identity_path)} {identity}\n"
                    f"echo -to-file {kak_quote(navigation_path)} "
                    "%val{cursor_line} %val{cursor_column} %opt{modelinefmt}"
                )
                if not navigation_path.exists() or not identity_path.exists():
                    return False
                fields = navigation_path.read_text().split(" ", 2)
                return (
                    len(fields) == 3
                    and identity_path.read_text().strip() == str(buffer)
                    and (line is None or fields[0] == str(line))
                    and (column is None or fields[1] == str(column))
                    and (not results or "Tab/S-Tab browse" in fields[2])
                )

            remote("select 9.15,9.15\nv-symbols")
            wait_for(lambda: at_location("*goto*", None, results=True), "document symbol list")
            remote("execute-keys -with-hooks -with-maps gg<tab>")
            wait_for(lambda: at_location("*goto*", 2), "Tab keeps the symbol list open")
            remote("execute-keys -with-hooks -with-maps <space>n")
            wait_for(lambda: at_location("*goto*", 3), "Space n selects the next symbol")
            remote("execute-keys -with-hooks -with-maps <space>N")
            wait_for(lambda: at_location("*goto*", 2), "Space N selects the previous symbol")
            remote("execute-keys -with-hooks -with-maps <space><ret>")
            wait_for(lambda: at_location(main_file, 4), "Space Enter opens the selected symbol")
            for cancel in ("<esc>", "q", "<space>q"):
                remote("select 9.15,9.15\nv-symbols")
                wait_for(lambda: at_location("*goto*", None, results=True), "reopened symbol list")
                remote(f"execute-keys -with-hooks -with-maps <tab>{cancel}")
                wait_for(lambda: at_location(main_file, 9, 15), "symbol cancellation restores cursor")

            remote("v-workspace-symbols\nexecute-keys -with-hooks -with-maps add<ret>")
            wait_for(lambda: at_location("*symbols*", 1, results=True), "project symbol results")

            def project_symbols_ready():
                path = root / "project-symbols"
                remote(
                    "evaluate-commands -draft %{ execute-keys <percent>; "
                    f"echo -to-file {kak_quote(path)} %val{{selection}} }}"
                )
                return path.exists() and "add (Function)" in path.read_text()

            wait_for(project_symbols_ready, "matching project symbols")
            remote("execute-keys -with-hooks -with-maps <tab><ret>")
            wait_for(lambda: at_location(main_file, 4), "project symbol selection")

            remote("select 9.15,9.15\nv-workspace-symbols\nexecute-keys vlang_no_such_symbol_725<ret>")
            wait_for(lambda: at_location("*symbols*", 1, results=True), "empty project symbol list")
            remote("execute-keys -with-hooks -with-maps <tab>q")
            wait_for(lambda: at_location(main_file, 9, 15), "empty result cancellation")

            def new_info_containing(texts, baseline):
                return any(
                    event.get("method") == "info_show"
                    and all(text in json.dumps(event.get("params", [])) for text in texts)
                    for event in ui_events(ui_path)[baseline:]
                )

            baseline = len(ui_events(ui_path))
            remote("select 9.16,9.16\nv-hover")
            wait_for(
                lambda: new_info_containing(("fn add(left", "Adds two values."), baseline),
                "Kakoune documented hover",
            )

            baseline = len(ui_events(ui_path))
            remote("select 9.22,9.22\nv-signature")
            wait_for(
                lambda: new_info_containing(("right int",), baseline),
                "Kakoune signature help",
            )

            hover_path = root / "hover"
            remote("select 9.16,9.16\nv-doc")

            def hover_ready():
                remote(
                    f"buffer *hover*\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(hover_path)} %val{{selection}}",
                    allow_error=True,
                )
                return (
                    hover_path.exists()
                    and "fn add(left int, right int) int" in hover_path.read_text()
                    and "Adds two values." in hover_path.read_text()
                )

            wait_for(hover_ready, "Kakoune documentation buffer")

            wait_for(lambda: at_location("*hover*", None), "documentation view")
            for cancel in ("q", "<esc>", "<space>q"):
                if cancel != "q":
                    remote(f"buffer {kak_quote(main_file)}\nselect 9.16,9.16\nv-doc")
                    wait_for(lambda: at_location("*hover*", None), "reopened documentation")
                baseline = len(ui_events(ui_path))
                remote("execute-keys -with-hooks -with-maps <space>")
                wait_for(lambda: new_info_containing(("Return to source",), baseline), "documentation Space menu")
                remote("execute-keys <esc>")
                remote(f"execute-keys -with-hooks -with-maps {cancel}")
                wait_for(lambda: at_location(main_file, 9, 16), "documentation return restores cursor")

            range_path = root / "syntax-range"
            remote(f"buffer {kak_quote(main_file)}\nselect 9.15,9.15\nv-select-syntax")

            def syntax_range_ready():
                remote(
                    f"echo -to-file {kak_quote(range_path)} "
                    "%opt{lsp_selection_range_selected}"
                )
                return range_path.exists() and range_path.read_text().strip() == "1"

            wait_for(syntax_range_ready, "Kakoune syntax selection range")
            remote("execute-keys <esc>\nselect 9.15,9.15\nv-highlight-references")

            position_path = root / "position"
            remote(f"buffer {kak_quote(main_file)}\nselect 9.15,9.15\nv-definition")

            def definition_ready():
                remote(
                    f"echo -to-file {kak_quote(position_path)} "
                    "%val{buffile} %val{cursor_line}"
                )
                return position_path.exists() and position_path.read_text().strip().endswith(" 4")

            wait_for(definition_ready, "Kakoune definition jump")

            callers_path = root / "callers"
            remote(f"buffer {kak_quote(main_file)}\nselect 4.5,4.5\nv-incoming-calls")

            def callers_ready():
                remote(
                    f"buffer *callers*\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(callers_path)} %val{{selection}}",
                    allow_error=True,
                )
                return callers_path.exists() and "main" in callers_path.read_text()

            wait_for(callers_ready, "Kakoune callers buffer")

            callees_path = root / "callees"
            remote(f"buffer {kak_quote(main_file)}\nselect 8.5,8.5\nv-outgoing-calls")

            def callees_ready():
                remote(
                    f"buffer *callees*\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(callees_path)} %val{{selection}}",
                    allow_error=True,
                )
                return callees_path.exists() and "add" in callees_path.read_text()

            wait_for(callees_ready, "Kakoune callees buffer")

            renamed_path = root / "renamed"
            remote(f"buffer {kak_quote(main_file)}\nselect 9.15,9.15\nv-rename-to sum_values")

            def rename_ready():
                remote(
                    f"buffer {kak_quote(main_file)}\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(renamed_path)} %val{{selection}}"
                )
                return (
                    renamed_path.exists()
                    and "fn sum_values(left int, right int) int" in renamed_path.read_text()
                    and "result := sum_values(1, 2)" in renamed_path.read_text()
                )

            wait_for(rename_ready, "Kakoune rename", timeout=20)
            require(main_file.read_text() == SOURCE, "Kakoune saved the rename probe unexpectedly")

            imports_file = root / "imports.v"
            imports_file.write_text(IMPORTS)
            baseline = len(ui_events(ui_path))
            remote(f"edit -- {kak_quote(imports_file)}\nv-organize-imports")
            wait_for(
                lambda: any(
                    event.get("method") == "menu_show"
                    and "Organize Imports" in json.dumps(event.get("params", []))
                    for event in ui_events(ui_path)[baseline:]
                ),
                "Kakoune organize-imports action menu",
            )
            remote("execute-keys <ret>")
            organized_path = root / "organized"

            def imports_ready():
                remote(
                    f"buffer {kak_quote(imports_file)}\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(organized_path)} %val{{selection}}"
                )
                return (
                    organized_path.exists()
                    and "import math\nimport os" in organized_path.read_text()
                )

            wait_for(imports_ready, "Kakoune import organization", timeout=20)
            require(imports_file.read_text() == IMPORTS, "Kakoune saved organized imports unexpectedly")

            broken_file = root / "broken.v"
            broken_file.write_text(CLEAN)
            remote(f"edit -- {kak_quote(broken_file)}")
            remote(
                "set-register v %{'wrong'}\n"
                "select 2.26,2.26\n"
                "execute-keys -with-hooks c<c-r>v<esc>"
            )
            diagnostics_path = root / "diagnostics"

            def diagnostics_ready():
                remote(f"buffer {kak_quote(broken_file)}\nv-diagnostics")
                remote(
                    f"buffer *diagnostics*\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(diagnostics_path)} %val{{selection}}",
                    allow_error=True,
                )
                return diagnostics_path.exists() and "cannot use" in diagnostics_path.read_text()

            wait_for(diagnostics_ready, "Kakoune diagnostics buffer", timeout=20)
            require(
                broken_file.read_text() == CLEAN,
                "Kakoune saved the diagnostic probe unexpectedly",
            )

            format_file = root / "format.v"
            unformatted = "module main\nfn format_probe(){println(1)}\n"
            format_file.write_text(unformatted)
            remote(f"edit -- {kak_quote(format_file)}")
            remote("v-format")
            formatted_path = root / "formatted"

            def formatting_ready():
                remote(
                    f"buffer {kak_quote(format_file)}\nexecute-keys <percent>\n"
                    f"echo -to-file {kak_quote(formatted_path)} %val{{selection}}"
                )
                return (
                    formatted_path.exists()
                    and "fn format_probe() {" in formatted_path.read_text()
                )

            wait_for(formatting_ready, "Kakoune VLS formatting", timeout=30)
            require(
                format_file.read_text() == unformatted,
                "VLS formatting saved the file unexpectedly",
            )
        except Exception:
            if client and process.poll() is None:
                try:
                    remote(f"evaluate-commands -buffer *debug* %{{ write -force {kak_quote(root / 'editor-debug')} }}")
                except (OSError, RuntimeError, subprocess.TimeoutExpired):
                    pass
            raise
        finally:
            if client and process.poll() is None:
                try:
                    remote("quit!", wait=False)
                except Exception:
                    pass
            if process.stdin and not process.stdin.closed:
                process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
        stderr_text = stderr_path.read_text(errors="replace")
        require(not stderr_text, f"Kakoune wrote to stderr: {stderr_text[-1000:]}")
    print("ok - Kakoune symbol browsing, hover, syntax, navigation, calls, rename, imports, diagnostics, formatting")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--prefix",
        type=Path,
        default=Path(os.environ.get("VLANG_KAK_PREFIX", "~/.local")).expanduser(),
        help="managed installation prefix (default: ~/.local)",
    )
    parser.add_argument("--vls", type=Path, help="VLS executable (default: PREFIX/bin/vls)")
    parser.add_argument(
        "--protocol-only",
        action="store_true",
        help="check VLS directly without opening the managed Kakoune launcher",
    )
    args = parser.parse_args()
    prefix = args.prefix.expanduser().resolve()
    vls = (args.vls or prefix / "bin/vls").expanduser().resolve()
    managed_kak = prefix / "bin/kak"
    kak = managed_kak if managed_kak.is_file() else Path(shutil.which("kak") or "")
    launcher = prefix / "bin/kak-v"
    v_command = shutil.which("v")
    require(vls.is_file() and os.access(vls, os.X_OK), f"VLS executable missing: {vls}")
    require(v_command, "V compiler missing from PATH")
    if not args.protocol_only:
        require(
            vls == (prefix / "bin/vls").resolve(),
            "Live Kakoune uses PREFIX/bin/vls; link that VLS or pass --protocol-only",
        )
        require(kak.is_file() and os.access(kak, os.X_OK), "Kakoune executable missing")
        require(
            launcher.is_file() and os.access(launcher, os.X_OK),
            f"V IDE launcher missing: {launcher}",
        )
    artifacts = os.environ.get("VLANG_LSP_ARTIFACTS")
    if artifacts:
        Path(artifacts).mkdir(parents=True, exist_ok=True)
        workspace = nullcontext(tempfile.mkdtemp(prefix="vlang-kak-lsp-", dir=artifacts))
    else:
        workspace = tempfile.TemporaryDirectory(prefix="vlang-kak-lsp-")
    with workspace as directory:
        root = Path(directory)
        protocol = Path(__file__).resolve().with_name("check-vls.vsh")
        result = subprocess.run(
            [v_command, "run", str(protocol), "--vls", str(vls), "--project", str(root)],
        )
        require(result.returncode == 0, "VLS protocol check failed")
        if not args.protocol_only:
            check_kakoune(kak, launcher, root, root / "main.v")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired, KeyError, IndexError) as error:
        print(f"not ok - live VLS check: {error}", file=sys.stderr)
        sys.exit(1)
