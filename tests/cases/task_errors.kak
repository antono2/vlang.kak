# Checks failed-task diagnostics and editor error navigation.
hook global RuntimeError "\d+:\d+: (.+)" %{
  echo -to-file failure "%val{hook_param_capture_1}"
  kill! 1
}

try %§
  edit! -scratch -- '*make*'
  set-register v %sh{
    printf 'Testing...\n%s:4: error: first problem\n%s:7: fn test_beta\n' \
      "$PWD/project/nearest_test.v" "$PWD/project/nearest_test.v"
  }
  execute-keys i<c-r>v<esc>
  set-option buffer filetype make
  edit -- project/main.v

  v-next-task-error
  evaluate-commands %sh{
    case "$kak_buffile" in
      */project/nearest_test.v) ;;
      *) echo "fail 'Compiler error did not open the test file'" ;;
    esac
    test "$kak_cursor_line" = 4 || echo "fail 'Compiler error reached line $kak_cursor_line instead of 4'"
  }

  v-next-task-error
  evaluate-commands %sh{
    test "$kak_cursor_line" = 7 || echo "fail 'Assertion failure did not reach line 7'"
  }

  v-previous-task-error
  evaluate-commands %sh{
    test "$kak_cursor_line" = 4 || echo "fail 'Previous task error did not reach line 4'"
  }

  echo -to-file task-errors-ok ok
  quit
§ catch %§
  echo -to-file failure "%val{error}"
  kill! 1
§
