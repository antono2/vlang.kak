# Checks that V task commands open the make buffer with captured output.
hook global RuntimeError "\d+:\d+: (.+)" %{
  echo -to-file failure "%val{hook_param_capture_1}"
  kill! 1
}

try %§
  set-option buffer v_test_file_command "printf 'task-smoke\\n'"
  v-test-nearest
  evaluate-commands -buffer '*make*' %{
    evaluate-commands %sh{
      test "$kak_opt_filetype" = make || echo "fail 'V task did not open the make buffer'"
    }
  }
  echo -to-file task-dispatch-ok ok
  quit
§ catch %§
  echo -to-file failure "%val{error}"
  kill! 1
§
