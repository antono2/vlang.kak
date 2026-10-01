hook global RuntimeError "\d+:\d+: (.+)" %{
  echo -to-file failure "%val{hook_param_capture_1}"
  kill! 1
}

define-command lsp-definition %{ echo -to-file keymap-result definition }
define-command lsp-declaration %{ echo -to-file keymap-declaration declaration }
define-command lsp-hover-buffer %{ echo -to-file keymap-doc documentation }
define-command lsp-signature-help %{ echo -to-file keymap-signature signature }
define-command lsp-highlight-references %{ echo -to-file keymap-highlights highlights }
define-command lsp-selection-range %{ echo -to-file keymap-range range }
define-command -params 1 lsp-rename %{ echo -to-file keymap-rename %arg{1} }
define-command -params .. lsp-code-actions %{
  echo -to-file keymap-imports "action %arg{1} %arg{2}"
}

declare-option str lsp_fail_if_disabled nop
v-bind-keys

try %§
  execute-keys '<space>d'
  execute-keys '<space>ic'
  execute-keys '<space>H'
  execute-keys '<space>('
  execute-keys '<space>im'
  execute-keys '<space>iz'
  v-rename-to sum_values
  v-organize-imports
  evaluate-commands %sh{
    test "$(cat keymap-result)" = definition || echo "fail 'Space d did not dispatch'"
    test "$(cat keymap-declaration)" = declaration || echo "fail 'Space i c did not dispatch'"
    test "$(cat keymap-doc)" = documentation || echo "fail 'Space H did not dispatch'"
    test "$(cat keymap-signature)" = signature || echo "fail 'Space ( did not dispatch'"
    test "$(cat keymap-highlights)" = highlights || echo "fail 'Space i m did not dispatch'"
    test "$(cat keymap-range)" = range || echo "fail 'Space i z did not dispatch'"
    test "$(cat keymap-rename)" = sum_values || echo "fail 'Direct rename did not dispatch'"
    test "$(cat keymap-imports)" = 'action -auto-single source.organizeImports' || echo "fail 'Organize imports did not dispatch'"
  }

  define-command -override v-update %{ echo -to-file keymap-update update }
  define-command -override v-restart %{ echo -to-file keymap-restart restart }
  define-command -override v-test %{ echo -to-file keymap-test test }
  set-option global v_context_keys false
  v-bind-keys
  execute-keys '<space>tt'
  execute-keys '<space>Uu'
  execute-keys '<space>Ur'
  evaluate-commands %sh{
    test "$(cat keymap-test)" = test || echo "fail 'Testing submenu did not dispatch'"
    test "$(cat keymap-update)" = update || echo "fail 'Maintenance update did not dispatch'"
    test "$(cat keymap-restart)" = restart || echo "fail 'Maintenance restart did not dispatch'"
  }
  set-option global v_context_keys true
  v-bind-keys

  v-project-edit project/nested/probe.v
  evaluate-commands %sh{
    case "$kak_buffile" in
      */project/nested/probe.v) ;;
      *) echo "fail 'Project file command did not open the requested file'" ;;
    esac
  }
  edit -- project/main.v
  hook global User VKeysApplied %{
    map window user b ':v-check-file<ret>' -docstring 'Check file instead'
    map window user <F6> ':v-test<ret>' -docstring 'Personal test key'
  }
  define-command -override v-check-file %{ echo -to-file keymap-custom check }
  define-command -override v-test %{ echo -to-file keymap-test test }
  map global user d ':echo -to-file keymap-fallback fallback<ret>'
  v-bind-keys
  execute-keys -with-maps '<space>b<space><F6>'
  evaluate-commands %sh{
    test "$(cat keymap-custom)" = check || echo "fail 'User override was not applied'"
    test "$(cat keymap-test)" = test || echo "fail 'Personal binding was not applied'"
  }
  set-option window filetype text
  execute-keys -with-maps '<space>d'
  evaluate-commands %sh{
    test "$(cat keymap-fallback)" = fallback || echo "fail 'V binding survived filetype change'"
  }

  echo -to-file keymaps-ok ok
  quit
§ catch %§
  echo -to-file failure "%val{error}"
  kill! 1
§
