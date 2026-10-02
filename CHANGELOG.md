# Changelog

All notable changes to `vlang.kak` will be documented in this file.

## 1.2.1 - 2026-10-02

### Added

- Verify Wayland Foot windows using real keyboard input on headless Sway; forward the requesting client's Wayland display/runtime.
- Verify upgrades from both v1.1.1 and v1.2.0, preserving ownership records, external tools and personal settings.
- Recover a completed pending setup snapshot explicitly, with end-to-end SIGKILL activation and live unsaved-buffer/multiple-view restart tests.
- Verify real GNU Screen and Xterm clients automatically, including closing temporary views, independent cursors and unsaved edits.
- Cache the pinned CI compiler and verified terminal downloads while keeping fresh installation and upgrade coverage.
- Report active/stale installation locks and interrupted setup snapshots; explicitly recover known stale locks without removing unknown contents.

### Fixed

- Target the requesting Screen client's session/window and X11 client's display when the editor daemon runs outside their terminal environment.
- Propagate release-test failures through the CI logging pipeline.
- Report failed restoration and unreachable update/restart sessions accurately.

## 1.2.0 - 2026-10-02

### Added

- Add dependency preflight, an optional system-package recipe, and a managed compatible V compiler fallback.
- Stage complete setup builds, verify VLS initialization, retain rollback snapshots and record file ownership.
- Add previewable safe removal, repair, diagnostics, unused-release/cache cleanup and published-release updates.
- Add persistent settings and project run/debug arguments, working directories and target discovery.
- Add private buffer/client recovery snapshots and confirmed restart with multiple views.
- Add optional weekly release discovery without unattended installation.
- Automatically verify upgrades from v1.1.1, including external tools, symlinked personal settings, rollback and safe removal.

### Fixed

- Fix shell quoting for task/update paths and arguments containing apostrophes.
- Preserve external VLS before deciding whether a newer compiler is required.
- Restore scratch checkpoints on older packaged Kakoune.
- Preserve inherited tool releases without a trusted ownership baseline and custom isolated configuration during removal; retain rollback releases with relative activation links during cleanup.

## 1.1.1 - 2026-10-02

### Added

- Real-client CI coverage for Zellij, WezTerm and kitty, including quoted file paths, unsaved edits, independent cursors, closing and repeated use.
- A reproducible IDE demonstration, issue forms, a pull request template and contribution guidance.

### Fixed

- WezTerm pane commands forward the current client's mux socket and avoid starting an unintended server when that connection fails.

## 1.1.0 - 2026-10-01

### Added
- Automated IDE acceptance with saved logs and expanded browsing, cursor, input-cancellation and restart-safety checks.
- Weekly verification of Kakoune master with passing revision update PRs; installers accept master and immutable commit hashes.
- Bounded V string/array/struct debugger display, expandable watched values, a remove-watch prompt, and an optional phase indicator that preserves the personal modeline.
- Managed Linux setup and update scripts for Kakoune, kak-lsp, and upstream VLS, with an isolated `kak-v` launcher and persistent personal configuration.
- VLS navigation, documentation, signatures, symbols, references, calls, rename, diagnostics, formatting, and code actions.
- Project build/run/check/test tasks, test-at-cursor, rerunning tests, and compiler-error navigation.
- A project explorer implemented in V, live project search, Git history views, and pane-host detection.
- Direct Space user-menu bindings in V buffers, with customization hooks and a full customization guide.
- In-editor update and restart with saved-file/cursor restoration and protection for unsaved edits.
- Live VLS, real tmux interaction, settings preservation, and managed-installation release checks.
- A V debugger helper for local GDB DAP launch: V breakpoints, stepping, stack/variables panels, expression watches, native commands and program input/output, with real editor integration tests.

### Changed
- Clarified picker/explorer, documentation, call signature, formatter saving, caller/callee, history and debugger-panel labels; labels follow explorer and pane availability.
- Grouped infrequent source actions under Testing, Investigation and Maintenance, retaining direct context-specific test and debugger controls.
- Debugger setup is grouped under `Space B`; active sessions expose all applicable debugging controls directly under Space. Run to Cursor uses a one-time breakpoint without changing configured breakpoints. Launch opens output, with an Enter shortcut and visible instructions for sending program input.
- Context-aware Space menus hide unavailable source actions and provide task rerun, error navigation, source return, and result-list controls. `v_context_keys false` retains the full source menu.
- Setup configures the isolated launcher by default. `--integrate` explicitly enables changes to regular Kakoune autoload and the managed kakrc block; existing integrated installations retain their choice.
- Document symbols use a persistent result list. Tab/Shift-Tab browse, Enter selects, and q/Escape returns to the source. Project-symbol search accepts a query before showing results.
- Extra client views start at the current buffer and cursor. Trees and definition peeks display their close controls.

### Fixed
- Added missing project-tree and documentation context menus; documentation q/Escape restores the source selection.
- Debug launch runs normally until a breakpoint, V panic, assertion failure or native runtime fault; stopping at `main` is opt-in through `v_debug_entry`.
- V tasks restore the source window's previous `makecmd` after opening output.
- In-editor updates preserve the original personal configuration path, including migration from older launchers.
- Setup refuses conflicting configuration entries and malformed managed blocks instead of replacing user settings.
- Rerunning setup retains explorer, search, and pane choices unless explicitly changed.
- Project-symbol requests are issued from the source buffer, avoiding empty results from the incremental scratch-buffer prompt.

### Release limits
- The managed installer targets Linux x86_64. tmux and single-client navigation have automated interactive coverage; other pane adapters remain experimental.
- Local debugging is verified with GDB 15.1. Attach/remote debugging and other DAP adapters are not supported.
- Restart requires one client and saved buffers; scratch buffers and secondary selections are not restored.

## 1.0.0 - 2026-09-10

### Added
- Real Kakoune JSON-UI assertions for rendered syntax highlighting.
- Compiling coverage for modern V language constructs.
- Editing-hook coverage for typed content, nested blocks, comments, and parentheses.
- Tested installation guidance for `plug.kak`.

### Changed
- Updated keywords, built-in types, operators, attributes, compile-time constructs, generic calls, receiver methods, and rune highlighting for V 0.5.2.

### Fixed
- Triple-slash comments are now highlighted as comments.
- New lines after opening braces and parentheses now indent the inserted content correctly.
