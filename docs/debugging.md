# Debugging V in Kakoune

The default debugger is GDB using its Debug Adapter Protocol (DAP). The
installed helper is written in V. GDB needs its own Python support for DAP;
you do not need to run a Python plugin script. Use GDB 14 or newer built with
Python/DAP support; the real editor tests currently use GDB 15.1 on Linux.
`./scripts/check.sh` reports whether the default adapter can start.

On Debian/Ubuntu, install the debugger with `sudo apt install gdb gcc`.
Setup prepares the helper when GDB is present. Otherwise it is compiled on
first use. Updating the plugin rebuilds a changed helper automatically.
The installer does not install system packages or replace your settings.

## First debug session

Before launch, `Space B` opens the debugging submenu. During an active
session, useful controls are promoted directly under Space in source,
V task output and VLS results: execution, stack, variables, output and stop.
Running sessions show pause/input; stopped sessions show stepping and run to
cursor. Evaluation, watches, native GDB commands and the breakpoint list
are also direct controls while debugging. Debugger panels and selected native caller
frames offer all applicable controls directly under Space. Escape dismisses
either menu. All `:v-debug-*` commands remain available.

1. Open a saved V file with `kak-v`. Save modified V buffers before building.
2. Put the cursor on an executable line and press `Space B !` to toggle a
   breakpoint. A red `●` marks the requested line. Use `Space B Y` to inspect
   whether GDB verified it or moved it to another executable line. In the
   breakpoint panel, Enter opens the source location and Delete removes the
   selected breakpoint (pause first during a running session). While
   debugging, use `Space !` and `Space Y` directly.
3. Press `Space B B` to build and launch. A project is built from its nearest
   `v.mod` or Git root; otherwise from the file's directory. A `_test.v` file
   builds that test executable. With breakpoints set, execution runs directly
   to a matching breakpoint. Without breakpoints, it keeps running normally.
   V panics, assertion failures and native runtime faults stop execution for
   inspection; normal completion exits without an artificial stop at `main`.
4. At a stop, `Space O` steps over, `Space I` steps into, and `Space A` steps
   out. The active source line is highlighted yellow. Stops inside unavailable
   runtime/system source leave the current editor buffer open; use the stack
   to select a V caller. `Space E` continues. In an unmodified saved source
   buffer, move to an executable line and use `Space G` (or
   `:v-debug-run-to-cursor`) to continue to a temporary breakpoint there.
   The command resumes only after GDB accepts the location. Existing
   breakpoints or failures can stop execution first; continue to proceed to
   the requested line. The one-time breakpoint disappears when hit and does
   not change your configured breakpoint list. If that line is never reached,
   it remains pending until reached or the debug session ends. GDB may resolve
   a non-executable line to a nearby executable line.
5. Use `Space M` for stack frames and `Space L` for arguments, locals and
   watches. Tab/Shift-Tab browse rows; Enter selects a stack frame or expands a variable with children.
   `q` returns to the selected source location. These are ordinary scratch
   buffers; another Kakoune client can view them too.
6. `Space ?` evaluates an expression. `Space W` adds a watch which updates at
   later stops; `Space -` prompts to remove one. `:v-debug-unwatch EXPRESSION`
   removes a watch directly. Enter expands watched arrays and structs too;
   Delete on a watch row removes it. The remove-watch menu action appears
   only when a watch exists. Out-of-scope watches
   show an unavailable message. Expressions and conditional breakpoints use
   GDB's native expression syntax, not a V interpreter; primitive locals such
   as `a + b` work. V strings show escaped text; arrays show their length and
   expand to elements; structs show their V name and expand to fields.
7. Launching opens combined build, debugger and program output; `Space Q`
   returns to it later. While the program runs, **Enter in the output buffer**
   opens `Program input:`. Type your answer and press Enter again to send the
   line (including its newline); Escape cancels. The output header shows this
   shortcut. `Space J` also prompts for input from source, and `Space K`
   pauses execution. Input is unavailable while paused: continue first.
   This supports line input, not full-screen terminal applications.
   `Space :` at a stop opens the native GDB command prompt.
8. `Space Z` stops and terminates the launched program. `Space B B` launches
   again. To opt into an initial entry stop, set `v_debug_entry main__main`. Breakpoints and watches survive repeated launches in the same
   Kakoune session. They are not serialized by editor restart.

Debug controls are available in V source, V task output, VLS results, debug
panels and selected native caller frames when applicable. Stepping and expression commands appear only while
paused. Save edits before launching; pause before changing active breakpoints.
Use `:v-debug-breakpoint-if 'a == 2'` to toggle a conditional breakpoint.
Debugging requires saved files, so locations refer to the executable's source.
Editing while paused does not rebuild or reload that executable.

Failure stops follow the general pattern of
[Visual Studio's exception settings](https://learn.microsoft.com/en-us/visualstudio/debugger/managing-exceptions-with-the-debugger?view=vs-2022):
run normally and pause to inspect failures. V errors handled through `or {}`
continue normally. The V failure hooks depend on runtime symbols in the
executable; stripped prebuilt programs may lack them. Ordinary nonzero process
exit is reported in the output/status and cannot restore a terminated stack.

## Customize the debugger

Put persistent settings in your `vlang-user.kak`; see
[customization](customization.md). Options accept normal
Kakoune scopes, so buffer/project hooks can choose different commands.

| Option | Default | Meaning |
| --- | --- | --- |
| `v_debug_pretty_print` | `true` | Render V strings, arrays and structs using GDB’s built-in Python runtime; set false to inspect generated C layouts. |
| `v_debug_status` | `true` | Append debugger phase to the modeline while active, preserving the existing format. |
| `v_debug_enabled` | `true` | Enables launch/breakpoint menu actions; set `false` to opt out. Stop an active debugger first. |
| `v_debug_adapter` | `gdb` | GDB executable or absolute path. |
| `v_debug_adapter_args` | `-q -nx --interpreter=dap` | Argument list passed directly to GDB. `-nx` avoids loading personal GDB init files. |
| `v_debug_build_command` | `v -g -cc gcc` | Shell command to build; the helper appends a quoted output path and project/test path. |
| `v_debug_build` | `true` | Set `false` to debug an existing executable. |
| `v_debug_program` | Private cached executable | Absolute path, or path relative to `v_debug_cwd`. Required for a custom prebuilt executable. |
| `v_debug_cwd` | Detected project root | Build and program working directory. |
| `v_debug_args` | Empty | Program argument list; quoted values can contain spaces. |
| `v_debug_env` | Empty | Environment overrides in `NAME=value` form. Other environment variables are inherited. |
| `v_debug_entry` | Empty | Optional initial function breakpoint used only when no source breakpoints are set. Set `main__main` to opt into stopping at entry. |
| `v_debug_break_on_failure` | `true` | Stop on V panics and assertion failures, including the default V test runner. Native fault signals retain GDB’s default handling. |

```kak
set-option global v_debug_args '--verbose' 'argument with spaces'
set-option global v_debug_env 'MODE=development'
# For a prebuilt application:
set-option buffer v_debug_build false
set-option buffer v_debug_program '/absolute/path/to/application'
# Or disable the debugger's source menu entries:
# set-option global v_debug_enabled false
```

With the default build command, V versions advertising `-old-compiler` use
that compatibility mode (V may cache a compatibility compiler on first use): the newer compiler currently emits generated C
locations on the locally tested revision, while compatibility mode emits V
file/line information. A custom build command is used as written. If breakpoints
remain unverified, rebuild with debug information and inspect the output and
breakpoint panels. The debugger does not change your V installation.

Override source mappings with `VKeysApplied`, and debug-panel mappings with
`VDebugKeysApplied`. For example:

```kak
hook global User VDebugKeysApplied .* %{
  map window user '<f5>' ':v-debug-continue<ret>' -docstring 'Continue debugging'
}
```

All shortcuts have corresponding `:v-debug-*` commands. The hidden
`v_debug_phase` and `v_debug_message` options expose current status for personal
status lines; they are read-only status by convention. Do not edit debugger
cache JSON files while the helper is running.

Value display bounds string reads to 4096 bytes and array expansion to 100
elements. Long strings show an ellipsis and larger arrays identify the limit.
Unknown layouts fall back to GDB’s native view; maps, interfaces and sum types
do not have dedicated V printers. Pretty printing uses GDB’s existing Python
runtime; it adds no Python executable or installed Python helper script.

## Support and recovery

The verified interface is local Linux GDB launch, including prebuilt programs
and V test executables, including project paths containing spaces. The DAP connection currently uses GDB-specific setup;
changing `v_debug_adapter` to LLDB or another adapter is not supported. Remote
and attach workflows and multi-thread selection
are not part of this release.

A failed build keeps diagnostics in `Space B Q` from source. An adapter without DAP reports
an initialization failure. Stop before editor update/restart; those commands
refuse an active debugging session. Closing Kakoune requests debugger shutdown.
Process locks are released by the operating system on helper exit, so a stale
lock file does not prevent a new launch.

`VDebugCurrent` and `VDebugBreakpoint` are customizable Kakoune faces for
the active line and breakpoint marker.

Session artifacts live under `$XDG_CACHE_HOME/vlang.kak/debug-SESSION_HASH`
(default `~/.cache/vlang.kak/`). They include build/program output,
`daemon.log`, debugger status and the debug executable. These files are local and are not uploaded by the plugin.

To run the real editor integration test:

```sh
python3 tests/debugger.py /absolute/path/to/kak
```

The test uses temporary source/configuration and checks V locations, conditional
breakpoints, stack selection, locals, watches, stepping, pause, program
input/output, relaunch, prebuilt execution, build failures, build cancellation, normal execution without breakpoints, panic/assertion/fault stops and shutdown. Some V assertions map their
source line to the failure branch only; put a breakpoint on an ordinary statement
or the test function entry to stop before a successful assertion.
