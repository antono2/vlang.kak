try %{
  echo -to-file detected %opt{filetype}
  quit
} catch %{
  echo -to-file failure -end-of-line "%val{error}"
  kill! 1
}
