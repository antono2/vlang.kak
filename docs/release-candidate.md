# Automated IDE acceptance

Users are not required to perform a manual test pass. The acceptance suite drives
real Kakoune clients through its JSON UI and real tmux panes, using upstream VLS
and local GDB DAP. The first full IDE release targets Linux x86_64.

For an existing managed installation, with a compatible V compiler on PATH:

```sh
./tests/acceptance.sh "$HOME/.local" /absolute/path/to/acceptance-logs
```

For a fresh installation and an actual managed tool update:

```sh
./tests/release.sh /absolute/path/to/release-artifacts
```

These commands use isolated configurations, test projects and sessions. They
preserve personal settings and existing editor sessions. Python 3 is required
for the test drivers; installed IDE helpers use V. tmux and GDB with DAP are
required. The fresh installation also needs network and C/C++ build tools.

## Coverage

| Workflow | Automated checks |
| --- | --- |
| Context and tasks | Space menus, saved test-file gating, task rerun, error navigation and source return |
| Language server | Documentation/signature, definition, references, symbols, diagnostics, rename, formatting, result acceptance and cancellation |
| Browsing | Tree expand/preview/open with quoted paths; live search preview, results, source jump, cancellation and no matches; historical file content |
| Multiple views | Real tmux tree/peek/view opening and closing, repeated use, independent same-file cursors and preserved source position; release CI also tests Zellij, WezTerm, kitty, Screen, Xterm and Wayland Foot, including unsaved edits and quoted paths |
| Debugging | Setup/direct context menus, launch, conditional breakpoints, stepping, selected stack frames, Run to Cursor and invalid targets |
| Values | Strings, expandable arrays/structs/watches, watch removal, breakpoint source jumps/removal, printer opt-out and custom modeline preservation |
| Program lifecycle | Input submission and Escape cancellation, pause/resume, normal exit, panic/assertion/native fault, stop/relaunch and build failure cleanup |
| Updates | Managed restart/update, restored disk buffers/cursor, preserved personal settings, rejection of unsaved edits and active debugging |
| Upgrade and maintenance | Actual v1.1.1 and v1.2.0 installations upgraded to the candidate, external tools and symlinked personal settings preserved, failed-update restoration, SIGKILL before/during activation, explicit pending-snapshot recovery, rollback and safe removal |
| Recovery | Private checkpoints, unsaved source and scratch restoration, closeable auxiliary snapshots and real multi-client recovery restart following an interrupted update |

`results.txt` records each suite's pass/fail status. Separate suite logs, tool versions, editor UI traces and
GDB traces are retained in the supplied artifact directory. A failing suite
returns a nonzero exit status. CI runs this same acceptance command as part of
the release gate and retains its logs.

Automation verifies behavior and terminal interaction, not subjective appearance
on every terminal. Tested host versions and experimental adapters are listed
in [release support](release.md). Those limits do not
create a manual testing requirement for users.

Publication requires green CI for the release commit. A successful local pass
is not itself a publication. Issue reports can include an action/key sequence,
expected/actual behavior, versions and backend. Review logs before sharing them:
they may contain program data.
