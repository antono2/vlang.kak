#!/usr/bin/env python3
"""Exercise the explorer state across a small nested V project."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


helper = Path(sys.argv[1])


def run(*args):
    return subprocess.check_output([str(helper), *map(str, args)], text=True)


with tempfile.TemporaryDirectory(prefix="vlang-kak-explorer-") as temporary:
    root = Path(temporary)
    (root / "v.mod").write_text("Module { name: 'tree_test' }\n")
    source = root / "src"
    source.mkdir()
    file = source / "it's.v"
    file.write_text("module main\n\nfn hello() {}\n")
    (root / ".hidden.v").write_text("module main\n")
    state_path = root / "state.json"

    run("init", state_path, file)
    tree = run("render", state_path, file)
    assert "q back" in tree
    assert "q close pane" in run("render", state_path, file, "true")
    assert "▸ src/" in tree
    assert "it's.v" not in tree and ".hidden.v" not in tree
    state = json.loads(state_path.read_text())
    source_line = next(index + 1 for index, row in enumerate(state["rows"])
                       if row and row["path"] == str(source))

    assert run("action", state_path, source_line, "expand").strip() == "v-tree-refresh"
    tree = run("render", state_path, file)
    assert "▾ src/" in tree and "it's.v" in tree
    state = json.loads(state_path.read_text())
    file_line = next(index + 1 for index, row in enumerate(state["rows"])
                     if row and row["path"] == str(file))
    assert "fn hello()" in run("action", state_path, file_line, "preview")
    assert "it''s.v" in run("action", state_path, file_line, "open")

    run("hidden", state_path)
    assert ".hidden.v" in run("render", state_path, file)
    run("action", state_path, source_line, "collapse")
    assert "it's.v" not in run("render", state_path, file)
    run("cleanup", state_path)
    assert not state_path.exists()

print("ok - built-in project explorer")
