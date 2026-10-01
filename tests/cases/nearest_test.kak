hook global RuntimeError "\d+:\d+: (.+)" %{
  echo -to-file failure "%val{hook_param_capture_1}"
  kill! 1
}

declare-option int v_test_make_calls 0
define-command -override make %{
  set-option global v_test_make_calls %sh{ expr "$kak_opt_v_test_make_calls" + 1 }
  echo -to-file nearest-makecmd %opt{makecmd}
  evaluate-commands -draft %{ edit! -scratch '*make*'; set-option buffer filetype make }
}

try %§
  try %{ v-repeat-test } catch %{
    evaluate-commands %sh{
      test "$kak_opt_v_test_make_calls" = 0 || echo "fail 'Rerun started without a previous test'"
    }
  }

  v-test-nearest
  evaluate-commands %sh{
    case "$kak_opt_v_last_test_command" in
      *"-run-only 'test_alpha'"*"nearest_test.v'"*) ;;
      *) echo "fail 'First test was not selected'" ;;
    esac
    test "$kak_opt_v_test_make_calls" = 1 || echo "fail 'First test did not start'"
    test "$kak_opt_makecmd" = make || echo "fail 'makecmd was not restored'"
  }

  execute-keys /fn<space>test_beta<ret>j
  v-test-nearest
  evaluate-commands %sh{
    case "$kak_opt_v_last_test_command" in
      *"-run-only 'test_beta'"*"nearest_test.v'"*) ;;
      *) echo "fail 'Test above cursor was not selected'" ;;
    esac
    test "$kak_opt_v_test_make_calls" = 2 || echo "fail 'Second test did not start'"
  }

  edit -- project/main.v
  v-repeat-test
  evaluate-commands %sh{
    case "$(cat nearest-makecmd)" in
      *"-run-only 'test_beta'"*"nearest_test.v'"*) ;;
      *) echo "fail 'Rerun changed the selected test after switching files'" ;;
    esac
    test "$kak_opt_v_test_make_calls" = 3 || echo "fail 'Rerun did not start'"
  }

  v-test
  evaluate-commands %sh{
    case "$kak_opt_v_last_test_command" in
      *"&& v test .") ;;
      *) echo "fail 'Project test did not become the last test'" ;;
    esac
  }
  v-repeat-test
  evaluate-commands %sh{
    test "$kak_opt_v_test_make_calls" = 5 || echo "fail 'Project test rerun did not start'"
    case "$(cat nearest-makecmd)" in
      *"&& v test .") ;;
      *) echo "fail 'Project test was not rerun'" ;;
    esac
  }

  echo -to-file nearest-ok ok
  quit
§ catch %§
  echo -to-file failure "%val{error}"
  kill! 1
§
