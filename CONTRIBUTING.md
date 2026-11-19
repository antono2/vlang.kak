# Contributing

Use [Issues](https://github.com/antono2/vlang.kak/issues) for reproducible bugs and
feature proposals. Use [Discussions](https://github.com/antono2/vlang.kak/discussions)
for questions, configuration examples and workflow feedback.

## Development

Clone the repository and create a branch. The plugin lives in `rc/vlang.kak`;
installed explorer, debugger and pane-host helpers are V programs in `scripts/`.
Shell entry points manage bootstrap, installation and updates. The core tests use V,
Kakoune and tmux.

For a separate managed development installation:

```sh
XDG_CONFIG_HOME="$PWD/.dev-config" ./scripts/setup.sh --prefix "$PWD/.dev-tools"
./.dev-tools/bin/kak-v path/to/main.v
```

Keep those directories outside Git, or use absolute directories outside the
checkout. Your normal Kakoune configuration remains separate. See
[customization](docs/customization.md) for options, keys and hooks.

## Verification

Run `v run tests/run.vsh` with V, Kakoune and tmux on PATH. Set `KAK` to use a
different editor binary. An uninstalled build may also need `KAKOUNE_RUNTIME`.

For changes affecting the full IDE, run
`v run tests/acceptance.vsh /absolute/managed-prefix /absolute/artifact-directory`.
For installer, update or tool-version changes, run
`v run tests/release.vsh /absolute/artifact-directory`. Requirements and coverage are
documented in [automated acceptance](docs/release-candidate.md).

Add regression checks for reported behavior failures. Test actual interactions
where they matter: selection acceptance and cancellation, pane closing, source
position, unsaved edits and settings preservation. Users do not need to complete
a manual testing checklist.

Changes go through pull requests. Both Kakoune compatibility checks and the
managed installation check must pass before merging. Keep contributions focused;
describe verification and compatibility effects in the PR.

## Release and maintenance

Use patch releases for compatible fixes and usability refinements. Document
command, key and settings changes in `CHANGELOG.md`. Promote a pane adapter to
verified support only after automated real-client coverage passes; see
[release support](docs/release.md). Weekly Kakoune-master verification proposes
tool-pin updates for review rather than merging them automatically.
