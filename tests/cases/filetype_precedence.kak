# Reproduce a later runtime detector, restore V precedence, and retain user overrides.
try %{
  hook -group competing-filetype global BufCreate .*\.v$ %{ set-option buffer filetype coq }
  edit collision-before.v
  echo -to-file precedence-before %opt{filetype}
  v-enable-filetype-detection
  v-enable-filetype-detection
  edit collision-after.v
  echo -to-file precedence-after %opt{filetype}
  hook -group custom-filetype global BufCreate .*\.v$ %{ set-option buffer filetype coq }
  edit collision-custom.v
  echo -to-file precedence-custom %opt{filetype}
  quit!
} catch %{
  echo -to-file failure "%val{error}"
  kill! 1
}
