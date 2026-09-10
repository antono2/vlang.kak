try %{
  echo -to-file detected %opt{filetype}
  quit
} catch %{
  echo -to-file failure "%val{error}"
  kill! 1
}
