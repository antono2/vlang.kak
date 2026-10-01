# Changelog

All notable changes to `vlang.kak` will be documented in this file.

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
