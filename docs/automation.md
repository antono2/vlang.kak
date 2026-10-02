# Setup, maintenance and recovery

## Setup and dependencies

`./scripts/setup.sh` checks build dependencies before downloading tools. Missing
requirements are reported together. It builds all requested tools and prepares
the V helpers before switching the managed installation to those versions.
Managed VLS must answer an LSP initialization request before activation.

If the current V compiler cannot compile the helpers/current VLS, setup builds
the release-tested V revision under `PREFIX/opt/vlang-v`. `kak-v` uses it through
its own PATH. Your existing V compiler and shell configuration remain intact.
`--managed-v` explicitly selects this compiler; `--system-v` requires a compatible
compiler from your external PATH. Setup remembers the choice. Its source tree is retained
because V needs its libraries when compiling. It is updated to the tested pin
on later setup/update runs.

`./scripts/dependencies.sh` previews the system package commands for Debian and
Ubuntu. `--apply`, or `setup.sh --install-dependencies`, explicitly requests those
package changes and may ask for sudo credentials. Other distributions receive
the dependency list. Older distribution packages may not satisfy the C++23 or
GDB DAP requirements; preflight/health report those limitations.

## Ownership and safe removal

Setup records file hashes, symlink targets and managed directories in
`PREFIX/opt/vlang-state/manifest.tsv`. This is data, not executable shell code.
Personal settings and projects are excluded. An isolated installation does not
claim unrelated autoload links or a VLS link supplied outside setup.

Preview removal:

```sh
./scripts/uninstall.sh --prefix /absolute/prefix
```

The preview summarizes eligible entries and lists preserved changes. Add
`--verbose` to inspect every path. Close managed sessions, review the preview,
then repeat with `--apply`.
Only unchanged recorded files/links and empty managed directories are removed.
An unchanged integration block is removed separately, with a backup of kakrc;
other settings remain. Modified, replaced and unrecorded files are kept.
A runtime needed by other autoload entries is kept too. External tool targets,
`vlang-user.kak`, recovery checkpoints and the ownership record remain.
Older installations must run setup once to gain an ownership record.
Pre-existing tool releases without a per-file ownership baseline are retained
as unowned; setup does not adopt possible personal additions or modifications.
Only new releases built by managed setup gain full file ownership. Custom files
in the isolated configuration are never included in the ownership record.

Setup, rollback, cleanup and removal use an installation lock. A process killed
with SIGKILL can leave `PREFIX/opt/vlang-state/lock`. `:v-health` reports its owner,
whether that process is still running, interrupted setup snapshots and rollback
availability. To inspect or explicitly clear a known stale lock:

```sh
scripts/lock.sh --prefix "$HOME/.local"
scripts/lock.sh --prefix "$HOME/.local" --clear-stale
```

PID start times prevent a reused PID from being mistaken for the original owner.
Active locks, unknown/legacy owners and unexpected lock contents are preserved.
For an empty legacy lock, inspect running setup/removal processes before using
`rmdir` on that exact directory. Keep reported `pending.*` snapshots until recovery
is complete. After clearing a known stale lock, restore the snapshot reported by
health:

```sh
scripts/rollback.sh --prefix "$HOME/.local" --recover "$HOME/.local/opt/vlang-state/pending.EXAMPLE"
```

Use the actual snapshot path printed by health. Recovery requires a complete
snapshot from that installation. It preserves personal edits, keeps the recovered
snapshot and the partial activation for inspection, and retains the ordinary
previous-installation rollback target. Active sessions stay open; use
`:v-restart-recover` afterward to preserve unsaved buffers and multiple views.
Repair regenerates managed launchers; ordinary rollback restores the previous
completed installation. Malformed ownership data,
redirected managed paths and unknown ownership are not grounds for deletion.

## Updates, rollback and repair

`Space U` opens maintenance. `u` retains the development/upstream update path;
`v` selects a published release and the versions verified for that release.
Release selection requires a clean checkout, preserves a development revision
already ahead of the latest release, and checks out a newer tag in detached
HEAD state and uses its tool pins. Later updates from a detached checkout stay
on the release path. Externally selected VLS requires the ordinary update path
if you want to preserve that choice; selecting a verified release selects its
managed VLS pin. Local edits are never discarded to select a release.

A failed setup/update restores the previous tool activation. A successful run
retains one previous snapshot. `:v-rollback` restores that snapshot, including
managed configuration and the plugin revision when the checkout is clean;
with local edits it rolls back tools only. Personal settings are preserved.
Rollback swaps snapshots so you can return to the newer combination too.
Keep sessions open until an update has succeeded. Activation changes version
links in a short commit phase; power loss or SIGKILL during that phase may
require explicit rollback. Separate standalone tool installers activate their
own tool, rather than participating in the complete setup transaction.

`:v-health` reports the selected tools/configuration. `:v-repair` repairs missing
owned links and regenerates managed launchers/configuration using installed
tools. Changed links and replacement files are kept. It does not install system
packages. `:v-diagnostic-report` prepares a report containing versions and paths;
review it before copying it into an issue. The live VLS checker remains available
as `scripts/check.sh --live-lsp` and requires Python only for that development
check.

## Settings and project tasks

`:v-settings` shows current values and lets you persist explorer, live search,
pane and update-check choices. Its changes go into a marked preferences block
in `vlang-user.kak`. Other content is retained and edits are backed up. Use
`:v-settings-file` to edit all settings and key overrides; the
[customization guide](customization.md) remains the reference.

Project preferences are stored as JSON under the original configuration home's
`vlang.kak/projects`, keyed by the canonical project root. They are personal data;
the IDE does not execute configuration found in a project checkout.

```kak
v-project-arguments 'one argument with spaces' --verbose
v-project-directory /absolute/working/directory
v-project-target /absolute/path/to/main.v
```

Arguments apply to project run and debugging, working directories are remembered,
and the selected target changes the default run/debug target. Custom run commands
retain their own target syntax. `:v-project-targets` offers V files containing a
`fn main(` entry point; this lightweight scan is a suggestion, not a compiler's
classification. `:v-project-settings` shows the stored values and their location;
`:v-project-reset` clears them. Reopening project buffers applies their settings.

## Session recovery

Normal `:v-restart` continues to require saved files and one client.
`:v-session-save` makes a private checkpoint of source/scratch text and each
client's buffer and complete selections. It does not save project files or run
write hooks. Generated `*debug*` contents are excluded. Other auxiliary output is restored
as a text snapshot with `q`/`Space q` to close it; its live explorer/task/LSP
controls are regenerated when you invoke that feature again.

`:v-restart-recover` asks for confirmation, then restarts the owning `kak-v`
client, restores the checkpoint and reopens additional views through the current
pane host. The views keep their buffers/selections; their previous pane geometry
is not reproduced. Multiple views require a supported host. Stop debugging
first. Runtime-only custom mappings/options and active tasks are not serialized.

`:v-session-restore [CHECKPOINT_DIRECTORY]` restores the latest checkpoint in a
fresh session. It refuses to overwrite existing modified buffers. Checkpoints
remain in `${XDG_CACHE_HOME:-~/.cache}/vlang.kak/sessions` with private permissions,
so they can be recovered if restarting fails. They can contain unsaved private
text; delete them when no longer needed. Automatic updates continue to use the
ordinary safe restart; use recovery restart explicitly when needed.

## Optional checks and cleanup

Enable weekly release discovery through `:v-settings`, or set
`v_update_check_enabled true`. On client creation it starts a background check,
at most once per seven days, and notifies only for a newly discovered release.
It does not schedule a system service or install updates. `:v-check-updates`
checks immediately. The repository's weekly Kakoune-master CI is separate.

`:v-cleanup` previews unchanged inactive tool releases. `:v-cleanup-apply` asks
before removing them. Current, previous and versions recorded by active managed
sessions are retained. Modified/unrecorded releases are retained as a whole.
`scripts/cleanup.sh --cache` also offers compiled helper caches older than 30 days;
`--apply` removes them and helpers rebuild on demand. Session checkpoints,
debugger records and personal preferences are excluded from cache cleanup.
