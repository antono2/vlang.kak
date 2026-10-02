# Release support and verification

The managed IDE targets Linux x86_64. Other architectures can use a manually
installed kak-lsp with `--no-lsp`; they are not covered by the managed release
gate. The first full IDE release includes local GDB DAP debugging; see
[debugging](debugging.md) for its verified workflow and limits.

## Tested tool combination

The release gate pins Kakoune in `tests/release.env`, kak-lsp `v21.0.2`, V commit
`c9b806b294234408af3794f419439599a293a0ea`, and VLS commit
`436058d058b2ae9cb17d329d7b7f73ec129b2b8a`. The machine-readable
versions are in `tests/release.env` and the CI workflow. Normal setup and update
still select the latest tools. A newer upstream version is not automatically
covered by the pinned release results.

The V 0.5.2 release archive lacks the `json2` standard library required by this
VLS revision. The fast plugin tests still cover V 0.5.2. The release job builds
the newer V revision separately using VC bootstrap commit
`21490f7811a2dd366c3daa39bef8e53c1e3e5727`. Setup preserves your existing V installation. It can build the tested compiler
in its own prefix when needed; `--system-v` requires your own compatible compiler.
A prebuilt VLS can be supplied with `--vls /path/to/vls`.

Setup leaves regular Kakoune settings untouched unless `--integrate` is explicitly
requested (or an existing managed integration is being maintained). Personal
configuration files are preserved. Conflicting files and links stop setup with
a diagnostic so the user can choose another prefix or resolve them manually.

The fast integration suite also runs against the Ubuntu-packaged Kakoune.
This provides compatibility coverage; it does not establish a minimum version
for every feature of the complete IDE.

## Verification

See [automated acceptance](release-candidate.md) for a single command covering the
IDE workflows. No manual user test pass is required.

Run `./tests/run.sh` for syntax, editing, keys, project tasks, history, explorer,
and restart checks. Run `python3 tests/debugger.py /path/to/kak` for real
GDB/editor interaction. Run `./tests/release.sh /absolute/artifact-directory` for a
fresh managed installation, real VLS interaction, real tmux clients, an
in-editor restart, real GDB debugging, a managed tool update, and another live VLS check. The latter
requires network access, V, C++ build tools, Python 3, tmux, and GDB with DAP. Its configuration,
cache, and installed tools stay under the supplied directory for inspection.
It never updates the plugin checkout from Git.

The release CI job runs that same script on Ubuntu 24.04. Its result must be
green for the exact commit being released; a successful local run does not
replace that check. Version 1.1.0 is the first full IDE release.

| Interface | Verification status |
| --- | --- |
| Single-client navigation and live VLS | Automated editor interaction checks, including symbols, empty results, cancellation, rename, and diagnostics |
| Local GDB 15.1 | Real editor tests: conditional V breakpoints, source jumps, stepping, stack/variables, expandable V values/watches, run to cursor, pause, input/output, relaunch, prebuilt executable and failure cleanup |
| tmux | Automated real clients: repeated tree/peek/view opening and closing, independent same-file cursors, and preserved source position |
| Zellij 0.45.1 | Automated real clients: tree file opening, closing, peeking, independent views, unsaved edits and repeated use |
| WezTerm 20240203-110809-5046fc22 | Automated real mux clients with a separate socket: the same pane workflows and unsaved-edit checks |
| kitty 0.49.2 | Automated real clients under Xvfb with socket remote control: the same pane workflows and unsaved-edit checks |
| GNU Screen 4.9.1 | Automated real clients in separate Screen windows: tree/open/close, peek, independent cursors, unsaved edits and repeated use |
| X11 / Xterm 390 | Automated real terminal windows under a private Xvfb display, with the daemon outside X11: the same workflows and unsaved-edit checks |
| Wayland / Foot 1.16.2 on Sway 1.9 | Automated real windows on an isolated software-rendered headless compositor: keyboard-driven browsing, peek, close, independent cursors and unsaved edits |

Other native terminals, Wayland compositor combinations and macOS window adapters remain experimental. Screen and Xterm create separate windows rather than split panes. No pane host is
required for editing or VLS navigation; `v_pane_mode off` selects the single-client
interface. The additional host versions and archive checksums are pinned in
`tests/pane-hosts.env`. These results cover the tested Linux configurations;
custom host keymaps, plugins and other versions can affect behavior.

The CI managed-installation job also runs `tests/pane_hosts.py` for each pinned
host. Zellij uses an attached terminal on a private tmux socket; WezTerm uses
a private mux server; Screen uses a private socket directory and attached terminal; kitty and Xterm use isolated Xvfb displays; Foot uses an isolated headless Sway compositor and virtual keyboard input. Logs and pane captures
are included in the release-verification artifact. No user terminal configuration
or active session is changed.

CI caches the pinned V compiler at its permanent source path (V embeds those
paths), with keys covering both source pins, compiler installer, runner architecture
and GCC version. Completed compiler builds and verified archives are saved before
acceptance runs, so unrelated test failures do not discard them. Terminal archives are cached by their pins and verified against
SHA-256 on every use before fresh extraction. Managed installation, ownership,
upgrade and live acceptance checks still run against fresh installation prefixes.

Promoting another adapter to verified support requires automated real-client
coverage for tree opening, source-client file opening, definition peeking,
same-file views, closing and repeated use. Those tests must include paths with
spaces and a source buffer containing unsaved edits.

## Weekly Kakoune master updates

Every Monday at 04:17 UTC, the Test workflow resolves Kakoune master to an
immutable commit hash, builds a clean managed installation and runs the full
IDE acceptance suite, including a managed update and repeat live VLS checks.
Only a passing run proposes a pull request advancing `tests/release.env` to that
exact revision. It does not merge the pull request automatically. Logs are
uploaded on success and failure. A failed candidate leaves the verified pin
unchanged. Another PR is not opened for a revision already proposed.

The workflow must be on the repository's default branch and Actions must be
enabled. Under Settings → Actions → General → Workflow permissions, allow
GitHub Actions to create pull requests. GitHub may require a maintainer to
approve CI on bot-created PRs; this is repository administration, not a manual
IDE test requirement. The schedule uses UTC and GitHub can delay scheduled runs.
If the PR reports no checks, look for an approval-required Test run in Actions
and choose **Approve and run** after reviewing the pin change. A separate
workflow-dispatch run can verify the branch, but its checks do not satisfy
GitHub's required PR checks. See [GitHub's status-check guidance](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks). Do not bypass the merge rules.
Use Run workflow with `kakoune_master` selected to exercise the same process
on demand. The schedule is active once this workflow is on the default branch.

The scheduled process updates the project's verified tool pin. Installed user
sessions and settings are not modified by CI. To install current master locally:

```sh
./scripts/update.sh --kakoune-version master
```

The installer resolves `master` to a full commit hash before building, stores
the actual revision in `.vlang-revision`, and retains previous installations.
Use the same flag on subsequent updates, or supply a verified full hash from
`tests/release.env`. Omitting the flag continues to select the latest stable tag.
Inside Kakoune, use `:v-update --kakoune-version master`; restart safety
checks still apply. Weekly verification is against a specific hash, so a newer
master commit may not have passed yet.

## Limits and recovery

Stop debugging before updating or restarting.

Normal in-editor update/restart requires one client and saved buffers. It restores
disk-backed files and the active main cursor. Scratch buffers, other selections,
and additional clients are not restored. Runtime-only option and key changes
are not serialized; save settings in `vlang-user.kak` before restarting.
Use `:v-session-save` for a private checkpoint and `:v-restart-recover` for a
confirmed restart that restores unsaved text, scratch buffers, complete selections
and multiple client views. Multiple views require a supported pane host; pane
geometry, running tasks and runtime-only customizations are not restored.
Auxiliary views return as closeable text snapshots. See
[session recovery](automation.md#session-recovery) for storage and recovery commands.
A failed update leaves the editor
running. Setup stages all builds and verifies VLS before activating the tool stack.
Failure restores the previous managed activation; `:v-rollback` restores the
previous successful snapshot. See [automation and recovery](automation.md) for
power-loss limits and the standalone installers.

To recover, keep the current session open, inspect `*make*`, and rerun the update
from a regular shell after fixing the reported problem. Select known versions
with `--kakoune-version`, `--lsp-version`, and `--vls-ref`. For example:

```sh
./scripts/update.sh --kakoune-version v2026.05.21 --lsp-version v21.0.2 \
  --vls-ref 436058d058b2ae9cb17d329d7b7f73ec129b2b8a
```

This requires network access to resolve or fetch the chosen revisions even
when some binaries are already installed. Keep the matching V compiler on
PATH. Setup retains previous tool releases and backs up kakrc before replacing
its managed block. For a bad plugin update, check out the desired plugin tag
or commit and run `scripts/setup.sh` with the same tool-version flags.

The launcher records the original configuration directory, so in-editor
updates keep sourcing the same personal `vlang-user.kak`. Older launchers are
migrated from their generated source line. If that path cannot be recovered,
setup stops and asks for an external setup run with the original XDG path.

## Removing a managed installation

Preview removal with `scripts/uninstall.sh --prefix /absolute/prefix`. Close
managed sessions, review the paths, then repeat with `--apply`. It removes only
unchanged recorded files and integration blocks, preserving modified files,
personal settings, external tools and shared runtimes. Older installations need
one setup run to record ownership. See [ownership and safe removal](automation.md#ownership-and-safe-removal).

## Publishing checklist

- All intended source, scripts, fixtures, and documentation are included in the commit; generated Python caches are excluded.
- The changelog describes the IDE additions and the direct Space bindings.
- Fast tests and the managed release job pass for the release commit.
- The automated v1.1.1 and v1.2.0 upgrade checks preserve personal settings and external tools, and cover rollback and safe removal.
- Backend support claims match the table above.
- Release notes state the restart limitations and tool versions.
- Choose the release version, create its tag, and publish the release only after reviewing those results.
