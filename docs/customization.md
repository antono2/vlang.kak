# Customizing vlang.kak

The managed setup creates `~/.config/kak/vlang-user.kak` (or
`$XDG_CONFIG_HOME/kak/vlang-user.kak`). Put persistent Kakoune settings there.
The `kak-v` launcher sources it after the plugin. Your regular Kakoune
configuration also sources it when you explicitly opt into `setup.sh --integrate`. `setup.sh` and `update.sh` never overwrite this file. Restart
Kakoune after editing startup settings, or `:source` the file in a running
session.

| Location | Purpose | What to edit |
| --- | --- | --- |
| `$XDG_CONFIG_HOME/kak/vlang-user.kak` | Personal V IDE settings | Edit freely; preserved by setup and update. |
| `$XDG_CONFIG_HOME/kak/kakrc` | Usual Kakoune configuration | Untouched by default. With `--integrate`, edit outside the managed block; setup preserves that content and backs up the file. |
| `$XDG_CONFIG_HOME/kak/autoload/vlang.kak` | Optional `--integrate` link to this repository's `rc/vlang.kak` | Edit `rc/vlang.kak` in your clone only when developing the plugin. |
| `$PREFIX/opt/vlang-kakoune/ide-config/kak/kakrc` | Generated `kak-v` configuration | Setup and update regenerate it; use `vlang-user.kak` for personal settings. |
| `$PREFIX/bin/kak-v` | Isolated launcher | Setup and update regenerate it. |

`$XDG_CONFIG_HOME` defaults to `~/.config`; `$PREFIX` defaults to `~/.local`.
If you install with a different `--prefix` or `XDG_CONFIG_HOME`, substitute
those paths. The generated `kak-v` config contains an absolute source path to
the personal file chosen during setup, even though `kak-v` uses an isolated
`XDG_CONFIG_HOME` internally. With plug.kak or a manual installation, source
your personal file from kakrc yourself after loading the plugin.

## Key bindings

Kakoune's `Space` key opens user mode. In V windows, the plugin fills that menu with the currently available V IDE actions. V task output and VLS result lists have their own menus. Press `Space` to see the available keys and descriptions; the [README](../README.md#key-bindings) lists them by group. The plugin removes its window mappings when the window switches to another file type.

To change a V key, add a `User VKeysApplied` hook to `vlang-user.kak`. It runs after the plugin installs or refreshes its bindings, so your mapping takes precedence. Keep the hook safe to run repeatedly. It continues to apply only to V source windows:

```kak
hook global User VKeysApplied %{
  map window user b ':v-check-file<ret>' -docstring 'Check this file'
  map window user <F6> ':v-test<ret>' -docstring 'Test V project'
}
```

Less frequent commands live in `v-testing` (`Space t`), `v-investigation`
(`Space i`), and `v-maintenance` (`Space U`). Customize their keys in the same
`VKeysApplied` hook. For example:

```kak
hook global User VKeysApplied %{
  map window v-testing t ':v-test<ret>' -docstring 'Test project'
  unmap window v-investigation l
  map window user C ':v-check-file<ret>' -docstring 'Check file directly'
}
```

Use `unmap window user t`, `i`, or `U` in that hook to hide an entire group.
Saved test files promote test-at-cursor and repeat-test to the root menu. Test
output and active debugging keep relevant controls directly under Space.

To remove an individual default binding in a V window, use `unmap window user KEY` inside the same hook. You can also add mappings directly to your personal Kakoune configuration. Use `:debug mappings` to inspect active keys and `:doc mapping` for Kakoune's key syntax. Every action remains available as a `:v-*` command.

Use `User VTreeKeysApplied` for tree-menu overrides and `User VDocKeysApplied` for documentation-menu overrides. Documentation q/Escape restores the source selection; tree q returns to source or closes its dedicated pane.

Use `User VTaskKeysApplied` for task-output overrides and `User VResultsKeysApplied` for result-list overrides; these run after their respective defaults.

Menus refresh when a buffer is displayed, after saving or leaving insert mode, and while idle. `:v-refresh-keys` refreshes explicitly. They use local context (saved test files, read-only state, previous tasks, tracked Git files, enabled LSP, pane backend, and restart support); they do not send language-server requests to guess which actions apply to a particular symbol. Hidden actions remain available as commands.

To show all actions within the source menus, add:

```kak
set-option global v_context_keys false
```

Task output provides `Space r` (repeat this task), `Space x` (last test, once available), `Space Enter` (open the current location), `Space [` / `]` (errors), and `Space q` (source and cursor). This applies only to V-created output; ordinary `:make` keeps its own behavior. Result lists provide `Space n` / `N` (browse), `Space Enter` (accept), and `Space q` (return), as well as their direct Tab/Enter/q controls.

## Debugger

See [debugging](debugging.md) for every debugger command and option, build
configuration, program arguments/environment and prerequisites. The helper is
written in V; the supported backend is local GDB DAP. Set
`v_debug_enabled false` in your personal file to hide launch/breakpoint actions.
Debug panels have a separate `VDebugKeysApplied` user hook; source-buffer
shortcuts remain customizable with `VKeysApplied`. Source debugging actions
live in the `v-debug` user mode, opened by `Space B`. During an active session,
all available debugging actions are mapped directly in `user` mode. Run to Cursor uses `Space G` only while paused in an unmodified
saved source buffer. Evaluation, watches and native commands are direct controls while paused. For example:

```kak
hook global User VKeysApplied %{
    map window user '<f6>' ':v-debug-next<ret>' -docstring 'Step over'
    map window v-debug '!' ':v-debug-breakpoint<ret>' -docstring 'Toggle breakpoint'
}
```

Use `unmap window v-debug KEY` in that hook to remove a submenu action,
and `unmap window user KEY` to remove its promoted shortcut.
For panel shortcuts, use `map window user KEY` in `VDebugKeysApplied`.
Set `v_debug_pretty_print false` to use raw GDB values and `v_debug_status false`
to omit the temporary modeline indicator.

Enter in debugger output sends program input while running; its normal-mode
mapping calls `v-debug-accept`, which dispatches according to panel type.

## V commands and project tasks

The plugin's V options are declared in its `v` module. Put `require-module v`
before setting them in `vlang-user.kak`:

```kak
require-module v
set-option global v_build_command 'v -prod .'
set-option global v_test_command 'v test ./tests'
set-option global v_test_file_command 'v test -stats'
set-option global v_vet_command 'v vet .'
set-option global v_run_command 'v -keepc -cg run .'
set-option global v_check_command 'v -check'
set-option global v_fmt_command 'v fmt'
```

| Command | Option | Default | Behavior |
| --- | --- | --- | --- |
| `:v-check-file` | `v_check_command` | `v -check` | Appends the current file's quoted absolute path. |
| `:v-build` | `v_build_command` | `v .` | Runs at the nearest `v.mod` or Git root. |
| `:v-run-project`, `:v-run` | `v_run_command` | `v -keepc -cg run .` | Runs the project; `v-run` is the older info/debug command. |
| `:v-test` | `v_test_command` | `v test .` | Tests the project. |
| `:v-test-nearest` | `v_test_file_command` | `v test` | Appends `-run-only NAME FILE` for the test above the cursor in a saved `_test.v` file. |
| `:v-repeat-task`, `:v-task-return` | — | — | In V task output, rerun the displayed command or return to its original source and cursor. |
| `:v-repeat-test` | — | — | Reruns the last exact `:v-test` or `:v-test-nearest` shell command from this Kakoune session. |
| `:v-next-task-error`, `:v-previous-task-error` | `v_task_error_pattern` | `(?: (?:fatal )?error:| fn test_)` | Jumps through compiler errors and failed test assertions in `*make*`. |
| `:v-vet` | `v_vet_command` | `v vet .` | Vets the project. |
| `:v-fmt` | `v_fmt_command` | `v fmt` | Reads the buffer on stdin and writes formatted text to stdout. |

`:v-check-file`, `:v-build`, `:v-run-project`, `:v-test`,
`:v-test-nearest`, `:v-repeat-test`, and `:v-vet` use
Kakoune's asynchronous `*make*` buffer. You can set an option for one buffer:

```kak
set-option buffer v_test_command 'v test ./tests'
set-option buffer v_test_file_command 'v test -stats'
```

`set-option global` changes the default for future buffers. For a rule that
applies whenever a V window opens, add this to `vlang-user.kak`:

```kak
hook global WinSetOption filetype=v %{
  set-option buffer v_test_command 'v test ./tests'
}
```

After a task, use `Space ]` and `Space [` to move between failures, or
press `<ret>` on a failure line in `*make*`. These commands use the task output;
`Space n` and `Space N` use VLS diagnostics. To recognize another V error
format, change `v_task_error_pattern` in `vlang-user.kak`. The pattern is a
Kakoune regular expression matched after the `file:line:` prefix:

```kak
set-option global v_task_error_pattern '(?: (?:fatal )?error:| fn test_)'
```

The older `:v-run` can be made quiet with
`set-option global v_output_to_info_box false` and/or
`set-option global v_output_to_debug_buffer false`. For compiler messages that
do not navigate correctly in `*make*`, set Kakoune's `make_error_pattern`
option in the personal file.

## VLS and kak-lsp

The managed setup builds upstream VLS by default and links its executable at
`$PREFIX/bin/vls`; the generated launcher and kak-lsp startup include that
directory on `PATH`. Pass `--vls PATH` to link a separate build. You can change the VLS executable without rerunning
setup by overriding the server table in `vlang-user.kak`:

```kak
set-option global v_lsp_servers %{
  [vls]
  command = "/absolute/path/to/vls"
  root_globs = ["v.mod", ".git"]
}
```

`v_lsp_servers` is a Kakoune option containing a [kak-lsp server
table](https://github.com/kakoune-lsp/kakoune-lsp#configuration). Add the
server's `args`, settings, or different `root_globs` there. It is copied to
the buffer's `lsp_servers` option when its filetype becomes `v`; reopen a V
buffer after changing it. The installed VLS version determines which
completion, diagnostics, navigation, code actions, formatting, semantic
tokens, and inlay hints are available.

After installing or rebuilding VLS, run `./scripts/check.sh --live-lsp` to
exercise the server and Kakoune integration with temporary V files. Set
`VLANG_KAK_PREFIX` first if you installed under another prefix. To check a
specific VLS executable before linking it, run
`python3 scripts/check-vls.py --protocol-only --vls /absolute/path/to/vls`.

The plugin maps VLS semantic tokens to Kakoune faces through
`v_lsp_semantic_tokens`. To change them, set that global option to a complete
kak-lsp semantic-token list in your personal file. See its default in
[`rc/vlang.kak`](../rc/vlang.kak). `:v-inlay-hints-enable` and
`:v-inlay-hints-disable` control hints for the current window.

If you maintain kak-lsp yourself, start it in your kakrc and keep `vls` on
`PATH`, or give `v_lsp_servers` an absolute `command` as above. The managed
setup detects an existing kak-lsp startup in your kakrc and leaves it in
place. `kak-v` uses its generated startup instead.

## Search, editing, and appearance

`:v-files` opens Kakoune's `:edit` path completion. `:v-find` opens the
current buffer's `/` search. `:v-search` (`Space /`) prompts only for a
pattern, previews up to 12 project matches as you type, and shows all matches
in a navigable `*grep*` buffer when you press Enter. It searches from the
nearest `v.mod` or Git root. Ripgrep is preferred when available; otherwise
recursive grep excludes `.git`. If you set a custom `grepcmd`, the final
results use that command instead.
Use `:grep [OPTIONS] PATTERN [PATH...]` directly when you need options or a
different search directory. To use ripgrep for Kakoune's direct `:grep` too,
put this in `vlang-user.kak`:

```kak
set-option global grepcmd 'rg -n --no-heading'
```

V files (`.v`, `.vsh`, `.vv`, `.c.v`) are recognized by the `BufCreate` hooks
at the top of `rc/vlang.kak`. Add another extension in your personal file:

```kak
hook global BufCreate .*\.vinc$ %{ set-option buffer filetype v }
```

The plugin supplies indentation hooks and syntax highlighters when a window's
filetype is `v`. Set Kakoune's `tabstop` and `indentwidth` for V windows, or
disable the plugin's indentation hooks, with a hook in your personal file:

```kak
hook global WinSetOption filetype=v %{
  set-option buffer tabstop 4
  set-option buffer indentwidth 4
  # Uncomment to disable the plugin's indentation hooks:
  # v-disable-indenting
}
```

The highlighters use Kakoune's named faces. Change a face globally with a
Kakoune `face` command, such as `face global keyword rgb:ff8800`. To change
which V text receives each face, edit the `shared/v` highlighters in
`rc/vlang.kak` and keep that change in your clone. The V action menu, filetype
hooks, and command definitions live in that same file.

## Investigation workflows

For a quick look at the symbol under the cursor, use `:v-hover` (`Space h`).
For longer documentation, use `:v-doc` (`Space H`); kak-lsp puts the hover
text in a scratch buffer that you can scroll and search. `:buffer` lets you
return to your code. Use `:v-signature` (`Space (`) while inside a call to
show its signature and active parameter. If your VLS supports signature help,
you can enable it automatically while typing:

```kak
hook global WinSetOption filetype=v %{ lsp-auto-signature-help-enable }
```

The scratch buffer shows the `textDocument/hover` response. Upstream VLS at
commit `436058d` returns the declaration and doc comment together when the
cursor is inside the function name. At its first character, this version may
return only the comment. Use `:v-signature` for the call signature and active
parameter while editing a call.

Use `:lsp-capabilities` to see which requests your installed VLS currently
supports. `:v-symbols` (`Space s`) opens a persistent list of symbols in the
current file. Tab and Shift-Tab move through results without leaving the list;
Enter opens the selected location. `q` or Escape returns to the original file
and cursor. You can also use `j`/`k`, arrow keys, or `/` to search the list.
`:v-workspace-symbols` (`Space S`) first asks for a query; press Enter to list
matching project symbols, then browse and select in the same way. References,
call lists, and diagnostics use the same browsing and return keys. The
modeline shows these controls. `:v-references` and
`:v-incoming-calls` help trace a function's use. `:v-highlight-references`
(`Space i m`) marks uses in the current file. `:v-select-syntax` (`Space i z`)
selects the expression under the cursor; Kakoune then offers `k` to expand
the selection and `j` to contract it, with `<esc>` to return to normal mode.
`:v-rename` prompts for a new symbol name; `:v-rename-to new_name` applies a
name directly. Review the edits in Kakoune and save when ready.
`:v-organize-imports` (`Space o`) filters code actions to import
organization; press Enter on the displayed action to sort and deduplicate a
contiguous import block. Review and save the buffer when ready.

To browse files, use `:v-project-files` (`Space P`). Type part of a file
name and select a candidate from Kakoune's completion menu. The picker starts
at the nearest `v.mod` or Git root and lists files using ripgrep when it is
installed. If ripgrep is unavailable, it uses Git's tracked and untracked
files, then `find` outside a Git checkout. Normal `:v-files` (`Space p`)
uses path completion, including files excluded from the project picker.
For a tree view, use `:v-project-path` (`Space F`) or `:v-tree`. Enter opens a
file or expands/collapses a directory. Use `j`/`k` to move, `l` to expand,
`h` to collapse or move to the parent, `p` to preview, `.` to toggle hidden
entries, `r` to refresh, and `q` to return to the source file. The tree starts
at the nearest `v.mod` or Git root. Setup compiles its V helper into your user
cache, and a newer helper is rebuilt automatically. It needs no external Kakoune plugin or terminal
multiplexer.

The explorer and live preview are enabled by default. During setup, use
`--no-explorer` or `--no-live-search` to disable either one. An update keeps
your choices; `--explorer` and `--live-search` reenable them. Inside Kakoune,
use these options for the current session or put them in `vlang-user.kak` for
a persistent preference:

```kak
set-option global v_explorer_enabled false
set-option global v_live_search_enabled false
```

With the explorer off, `:v-project-path` returns to a project-root path
prompt with Tab completion. With live search off, `:v-search` still searches
the project after you press Enter.

### Window and pane management

`v_pane_mode` defaults to `auto`. `:v-project-path` opens a side tree when the
current Kakoune client is inside tmux, Zellij, WezTerm, or kitty. It also uses
GNU Screen or Kakoune's native desktop-terminal adapter when available. The
tree's Enter key opens files in the original client, and `q` closes its client.
`:v-peek-definition` (`Space g`) opens a definition in another client while
keeping the original cursor at the call; its modeline shows `q` as the close
key. In a tree pane, the header also shows `q close pane`. For any extra client,
use `:v-close-view` (`Space q` in a V buffer) to close its pane or window.
Without an active pane host, the tree
uses its normal scratch buffer and definition peek uses `:v-doc`.

Use `:v-window-status` to see the detected backend. Detection checks the
current client, so connecting an existing headless Kakoune session from tmux
will use tmux. The active host must offer its CLI and allow pane creation;
kitty remote control, for example, must be enabled. Configure these options
in `vlang-user.kak`, or use `--pane-mode` and `--window-backend` during setup:

```kak
set-option global v_pane_mode auto
set-option global v_window_backend auto
```

`v_pane_mode` accepts `auto`, `always`, or `off`. `always` reports an error when
it cannot create a second client; `off` keeps navigation in the current client.
`v_window_backend` accepts `auto`, `tmux`, `zellij`, `wezterm`, `kitty`, `screen`,
or `native`. An explicit backend is used only when that host is active.
Updates preserve both setup choices. `:v-tree` always opens the tree in the
current client, and `:v-tree-pane` requests the side view.

### Optional file and search interfaces

The built-in explorer and search work without another plugin. If you prefer a larger
picker, [Peneira](https://github.com/gustavo-hms/peneira) offers fuzzy files,
recent files, lines, and symbols inside Kakoune; it requires its
[Luar](https://github.com/gustavo-hms/luar) dependency. For terminal previews,
live grep, buffer and project pickers, [fzf.kak](https://github.com/andreyorst/fzf.kak)
provides an extensive interface, especially in tmux. Its author states that
it is no longer actively maintained, so treat it as an optional integration.

For a persistent side-panel tree, [kaktree](https://github.com/andreyorst/kaktree)
exists but likewise has no active maintainer and works best with tmux. An
external terminal file manager such as [Yazi](https://yazi-rs.github.io/docs/quick-start/)
is another choice for large directory trees. Yazi's
[`--chooser-file` mode](https://yazi-rs.github.io/docs/tips/#file-tree-picker-in-helix)
can pass a selected path back to an editor, but `vlang.kak` does not install or
configure Yazi. Keep personal plugin loading and key mappings in
`vlang-user.kak`; setup and update preserve that file.

`:v-history` (`Space i V`) shows the current file's recent commits. Choose one
to open a read-only scratch buffer with V syntax. `:v-history-file HEAD~1`
opens a specific revision directly; it also accepts a branch, tag, or commit.
The working file stays unchanged. For a side-by-side comparison, run
`:v-new-view` first, then open history in one client and the live file in the
other with `:buffer`.

Kakoune's bundled Git module also opens textual diffs and historical content
in temporary buffers. Run these commands from the project checkout:

```kak
git diff -- path/to/file.v
git diff HEAD~1 HEAD -- path/to/file.v
git show HEAD~1:path/to/file.v
```

The first shows uncommitted changes, the second compares two revisions, and
the third shows an older file. Replace `HEAD~1` with a tag, branch, or commit.
In a `*git*` diff buffer, `<ret>` on a hunk jumps to its source. You can also
use `:git status`, `:git log`, and `:git blame`.

For two places in the same file, use **two Kakoune clients on one session**.
There is one shared file buffer, so edits appear immediately in both views;
each client keeps its own cursor and selection. In tmux, `:v-new-view` (`Space
v w`, equivalent to `:new`) opens another client. Use `:buffer` in the new
client to select the same file, or select a historical, `*git*`, or
documentation buffer to keep reference material beside the code. You can
also start clients in
separate terminals:

```sh
kak-v -s vwork path/to/main.v
kak-v -c vwork
```

Kakoune's `:new` relies on a configured terminal or multiplexer. The explicit
`-s`/`-c` pair works when you manage terminal windows yourself. The
[Kakoune FAQ](https://github.com/mawww/kakoune/blob/master/doc/pages/faq.asciidoc)
explains its multi-client window model.

## Installation and updates

`scripts/setup.sh --help` lists the installer settings. The default only configures
the isolated `kak-v` environment. `--integrate` is explicit consent to adding the
plugin to regular Kakoune and its V user-menu bindings. Existing integrated
installations retain that choice on update. Conflicting entries and malformed
managed blocks are refused; setup never rewrites the personal `vlang-user.kak`. `--prefix` selects a
user owned install directory; `--kakoune-version` and `--lsp-version` select
release tags; `--no-build` uses an installed Kakoune; `--no-lsp` uses an
installed kak-lsp; `--vls` links an existing VLS executable. By default, setup
builds the latest upstream VLS. `--vls-ref` selects a tag or commit, and
`--no-vls` leaves VLS untouched. `scripts/update.sh`
accepts the same flags and refreshes managed Kakoune, kak-lsp, and VLS builds. It
fast forwards this plugin's checkout only when it is clean, and keeps
`vlang-user.kak`. An externally linked VLS is preserved
unless you pass `--vls-upstream`. Update the V compiler separately. `scripts/check.sh` reports the paths
and versions that the setup currently uses; set `VLANG_KAK_PREFIX` first if
you used a nondefault prefix.

Run `scripts/setup.sh` once after upgrading an older installation so its
launcher gains restart support. Launch with the managed `PREFIX/bin/kak-v`
script to update from inside the editor. Run `:v-update` (`Space U u`) after
saving edits. It runs the same `scripts/update.sh` operation in Kakoune's
`*make*` buffer, then restarts the client when the update succeeds. You can
pass update flags after the command,
such as `:v-update --vls /absolute/path/to/vls` or
`:v-update --kakoune-version v2026.05.21`. It keeps the launcher's prefix, so
pass `--prefix` only to the external setup or update scripts.

The managed launcher restores open files backed by disk and the active file's
main cursor. Scratch buffers, selections other than the main cursor, and other
clients need to be reopened. Run the update from a session started by `kak-v`
with one client; an attached `kak-v -c` client cannot restart its server.
Runtime-only option and key changes are not serialized: save them in
`vlang-user.kak` to have them applied again after restart.
Kakoune keeps unsaved edits open instead of discarding them; save those edits
and run `:v-restart` to finish the restart. If the update fails, its output
stays in `*make*` and the current session remains open. The default in-editor
update refreshes Kakoune, kak-lsp, and managed upstream VLS.

See the [release guide](release.md) for backend verification, update recovery, and removal instructions.
