#!/usr/bin/env python3
"""Assert rendered Kakoune faces from its JSON UI output."""

import json
import sys
from pathlib import Path


FACE_COLORS = {
    "attribute": "rgb:101001",
    "comment": "rgb:202002",
    "function": "rgb:303003",
    "keyword": "rgb:404004",
    "meta": "rgb:505005",
    "operator": "rgb:606006",
    "string": "rgb:707007",
    "type": "rgb:808008",
    "value": "rgb:909009",
}


def load_draw(path: Path):
    draws = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        message = json.loads(raw_line)
        if message.get("method") == "draw":
            draws.append(message)
    if not draws:
        raise AssertionError("Kakoune emitted no draw message")
    return draws[-1]["params"][0]


def rendered_line(atoms):
    text = ""
    colors = []
    for atom in atoms:
        contents = atom["contents"].removesuffix("\n")
        text += contents
        colors.extend([atom["face"]["fg"]] * len(contents))
    return text, colors


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: assert_highlighting.py UI_OUTPUT EXPECTATIONS", file=sys.stderr)
        return 2

    lines = load_draw(Path(sys.argv[1]))
    failures = []
    for raw_line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
        if not raw_line or raw_line.startswith("#"):
            continue
        line_text, needle, face = raw_line.split("\t")
        line_number = int(line_text)
        if line_number > len(lines):
            failures.append(
                f"line {line_number}: outside rendered viewport ({len(lines)} lines)"
            )
            continue
        rendered, colors = rendered_line(lines[line_number - 1])
        start = rendered.find(needle)
        if start < 0:
            failures.append(f"line {line_number}: text not rendered: {needle!r}")
            continue
        expected = FACE_COLORS[face]
        actual = set(colors[start : start + len(needle)])
        if actual != {expected}:
            failures.append(
                f"line {line_number}: {needle!r} expected {face} ({expected}), got {sorted(actual)}"
            )

    if failures:
        print("highlighting assertions failed:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"ok - rendered syntax highlighting ({Path(sys.argv[2]).stem})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
