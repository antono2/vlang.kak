# Checks file-history navigation and restoration against a temporary Git repository.
hook global RuntimeError "\d+:\d+: (.+)" %{
  echo -to-file failure "%val{hook_param_capture_1}"
  kill! 1
}

try %§
  v-history-file HEAD
  evaluate-commands %sh{
    case "$kak_bufname" in
      \*v-history:*:main.v\*) ;;
      *) echo "fail 'History did not open a scratch buffer'" ;;
    esac
    test "$kak_opt_filetype" = v || echo "fail 'History buffer did not retain V syntax'"
    test "$kak_opt_readonly" = true || echo "fail 'History buffer is writable'"
  }
  execute-keys <percent>
  echo -to-file history-content %val{selection}
  echo -to-file history-ok ok
  quit
§ catch %§
  echo -to-file failure "%val{error}"
  kill! 1
§
