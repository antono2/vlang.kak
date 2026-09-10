hook global RuntimeError "\d+:\d+: (.+)" %{
  echo -to-file failure "%val{hook_param_capture_1}"
  kill! 1
}

try %§
  evaluate-commands %sh{
    test "$kak_opt_filetype" = v || echo "fail 'expected filetype v'"
    test "$kak_opt_comment_line" = // || echo "fail 'expected V line comments'"
    test "$kak_opt_comment_block_begin" = '/*' || echo "fail 'expected V block comments'"
  }

  set-option global v_output_to_info_box false
  set-option global v_output_to_debug_buffer false
  v-run
  evaluate-commands %sh{
    test "$kak_opt_v_output" = 'hello from V' || echo "fail 'unexpected v-run output'"
  }

  edit -- project/nested/probe.v
  set-option global v_run_command pwd
  v-run
  evaluate-commands %sh{
    project_dir=${kak_buffile%/nested/probe.v}
    test "$kak_opt_v_output" = "$project_dir" || echo "fail 'v-run did not find the buffer project root'"
  }

  edit -- project/main.v
  alt
  evaluate-commands %sh{
    case $kak_buffile in
      */project/main_test.v) ;;
      *) echo "fail 'alt did not open main_test.v'" ;;
    esac
  }
  alt

  edit -- unformatted.v
  v-fmt
  evaluate-commands %sh{
    test "$kak_modified" = false || echo "fail 'v-fmt left the buffer modified'"
  }

  edit -- formatter_failure.v
  declare-option -hidden bool v_test_formatter_failed false
  set-option window formatcmd 'printf original-formatter'
  set-option buffer v_fmt_command false
  try %{
    v-fmt
  } catch %{
    set-option global v_test_formatter_failed true
  }
  evaluate-commands %sh{
    test "$kak_opt_v_test_formatter_failed" = true || echo "fail 'v-fmt ignored a formatter failure'"
    test "$kak_opt_formatcmd" = 'printf original-formatter' || echo "fail 'v-fmt did not restore formatcmd'"
    test "$kak_modified" = false || echo "fail 'failed v-fmt modified the buffer'"
  }

  edit -- indent.v
  execute-keys -with-hooks /\x7b<ret>a<ret><esc>
  write

  edit -- indent_content.v
  execute-keys -with-hooks "/\x7b<ret>a<ret>println('ok')<esc>"
  write

  edit -- indent_nested.v
  execute-keys -with-hooks "/if<space>true<space>\x7b<ret>a<ret>println('nested')<esc>"
  write

  edit -- comment.v
  execute-keys -with-hooks /first<ret>a<ret>second<esc>
  write

  edit -- parenthesis.v
  execute-keys -with-hooks "/println\x28<ret>a<ret>'paired'<esc>"
  write

  echo -to-file core-ok ok
  quit
§ catch %§
  echo -to-file failure "%val{error}"
  kill! 1
§
