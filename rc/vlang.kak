############################################
###                                      ###
### V lang plugin for Kakoune            ###
###                                      ###
### Author antono2@github                ###
###                                      ###
### License MIT                          ###
###                                      ###
### https://github.com/antono2/vlang.kak ###
###                                      ###
############################################


# Detection
# ‾‾‾‾‾‾‾‾‾
hook global BufCreate .*\.(v|vsh|vv|c\.v)$ %{
  set-option buffer filetype v
  
  declare-option -hidden bool vlang_output_to_info_box true
  declare-option -hidden bool vlang_output_to_debug_buffer true
  
  declare-option -hidden str vlang_run_command "v -keepc -cg run ."
  # $kak_buffile will be expanded to the path of the current file
  declare-option -hidden str vlang_fmt_command "v fmt -w $kak_buffile"
}

hook global BufCreate .*\bv\.mod$ %{
  set-option buffer filetype json
}


# Initialization
# ‾‾‾‾‾‾‾‾‾‾‾‾‾‾
hook global WinSetOption filetype=v %§
  require-module v

  # Set indentation commands
  # cleanup trailing whitespaces when exiting insert mode
  hook window ModeChange pop:insert:.* -group v-trim-indent %{ try %{ execute-keys -draft xs^\h+$<ret>d } }
  hook window InsertChar \n -group v-indent v-indent-on-new-line
  hook window InsertChar \{ -group v-indent v-indent-on-opening-curly-brace
  hook window InsertChar \} -group v-indent v-indent-on-closing-curly-brace
  hook window InsertChar \n -group v-comment-insert v-insert-comment-on-new-line
  hook window InsertChar \n -group v-closing-delimiter-insert v-insert-closing-delimiter-on-new-line

  alias window alt v-alternative-file

  # remove all v-... hooks on any other filetype
  hook -once -always window WinSetOption filetype=.* %{ 
    remove-hooks window v-.+
    unalias window alt v-alternative-file
  }
§

hook -group v-highlight global WinSetOption filetype=v %§
    add-highlighter window/v ref v
    #remove all window/v == /shared/v highlighters on any other filetype
    hook -once -always window WinSetOption filetype=.* %{ remove-highlighter window/v }
§

provide-module v %§

# Highlighters
# ‾‾‾‾‾‾‾‾‾‾‾‾
add-highlighter shared/v regions
add-highlighter shared/v/code default-region group

## COMMENTS
add-highlighter shared/v/line_comment1 region '//[^/]?' $ group
add-highlighter shared/v/line_comment1/comment fill comment
add-highlighter shared/v/line_comment1/todo regex (?i)(TODO|NOTE|FIXME)[^\n]* 0:meta
add-highlighter shared/v/line_comment2 region '/\*[^*]?' '\*/' group
add-highlighter shared/v/line_comment2/comment fill comment
add-highlighter shared/v/line_comment2/todo regex (?i)(TODO|NOTE|FIXME)[^\n]* 0:meta
add-highlighter shared/v/bin_bash region '(?<!\\)(?:\\\\)*(?:^|\h)\K#!' '$' fill comment

## STRINGS
add-highlighter shared/v/string1 region %{(?<!')"} (?<!\\)(\\\\)*" fill string
add-highlighter shared/v/string2 region %{(?<!')'} (?<!\\)(\\\\)*' fill string
add-highlighter shared/v/raw_string1 region -match-capture %{(?<!')r"} (?<!\\)(\\\\)*" fill string
add-highlighter shared/v/raw_string2 region -match-capture %{(?<!')r'} (?<!\\)(\\\\)*' fill string

## OPERATORS
add-highlighter shared/v/code/operators regex (\+|-|/|\*|\^|&|\||!|>|<|%|:=|~|!=|==|<=|>=|\+=|-=|\*=|/=|%=|&=|\|=|\^=|>>=|<<=|>>>=)=? 0:operator
add-highlighter shared/v/code/question_mark regex \? 0:meta

## KEYWORDS
add-highlighter shared/v/code/keywords regex \b(?:as|asm|assert|atomic|break|const|continue|defer|else|enum|false|fn|for|go|goto|if|import|in|interface|is|isreftype|lock|match|module|mut|none|or|pub|return|rlock|select|shared|sizeof|spawn|static|struct|true|type|typeof|union|unsafe|volatile|__global|__offsetof)\b 0:keyword
add-highlighter shared/v/code/compile_time_keywords regex \B(?:\$else|\$embed_file|\$for|\$if|\$Array|\$Map|\$Struct|\$env|\$pkgconfig)\b 0:keyword

## TYPES
add-highlighter shared/v/code/builtin_types regex \b(?:bool|byte|byteptr|rune|string|voidptr|int|i8|u8|i16|u16|i32|u32|i64|u64|f32|f64|enum|struct|interface|type)\b 0:type

## VALUES
add-highlighter shared/v/code/values regex \b(?:true|false|[0-9][_0-9]*(?:\.[0-9][_0-9]*|(?:\.[0-9][_0-9]*)?e[\+\-][_0-9]+)(?:f(?:32|64))?|(?:0x[_0-9a-fA-F]+|0o[_0-7]+|0b[_01]+|[0-9][_0-9]*)(?:(?:i|u|f)(?:8|16|32|64|128|size))?)\b 0:value

## FUNCTIONS
add-highlighter shared/v/code/function_call          regex _?[a-zA-Z]\w*\s*(?=\() 0:function
add-highlighter shared/v/code/generic_function_call  regex _?[a-zA-Z]\w*\s*(?=::<) 0:function
add-highlighter shared/v/code/function_declaration   regex (?:fn\h+)(_?\w+)(?:<[^>]+?>)?\( 1:function


# Commands
# ‾‾‾‾‾‾‾‾
## ALT FILE
define-command -hidden v-alternative-file -docstring 'Jump to the alternate file (implementation ↔ test)' %{ evaluate-commands %sh{
  # looks like _test.c.v files aren't supported by V, so can be ignored
  case $kak_buffile in
    *_test.v)
      altfile=${kak_buffile%_test.v}.v
      test ! -f "$altfile" && echo "fail 'implementation file not found'" && exit
    ;;
    *.v)
      altfile=${kak_buffile%.v}_test.v
      test ! -f "$altfile" && echo "fail 'test file not found'" && exit
    ;;
    *)
      echo "fail 'alternative file not found'" && exit
    ;;
  esac
  printf "edit -- '%s'" "$(printf %s "$altfile" | sed "s/'/''/g")"
}}


## INDENTATION
define-command -hidden v-indent-on-new-line %~
  evaluate-commands -draft -itersel %=
    # preserve previous line indent
    try %{ execute-keys -draft <semicolon>K<a-&> }
    # cleanup trailing white spaces on the previous line
    try %{ execute-keys -draft kx s \h+$ <ret>d }
    try %{
      try %{ # line comment
        execute-keys -draft kx s ^\h*// <ret>
      } catch %{ # block comment
        execute-keys -draft <a-?> /\* <ret> <a-K>\*/<ret>
      }
    } catch %{
      # indent after lines with an unclosed { or (
      try %< execute-keys -draft [c[({],[)}] <ret> <a-k> \A[({][^\n]*\n[^\n]*\n?\z <ret> j<a-gt> >
      # indent after a switch's case/default statements
      try %[ execute-keys -draft kx <a-k> ^\h*(case|default).*:$ <ret> j<a-gt> ]
      # deindent closing brace(s) when after cursor
      try %[ execute-keys -draft x <a-k> ^\h*[})] <ret> gh / [})] <ret> m <a-S> 1<a-&> ]
      }
  =
~

define-command -hidden v-indent-on-opening-curly-brace %[
  # align indent with opening paren when { is entered on a new line after the closing paren
  try %[ execute-keys -draft -itersel h<a-F>)M <a-k> \A\(.*\)\h*\n\h*\{\z <ret> s \A|.\z <ret> 1<a-&> ]
]

define-command -hidden v-indent-on-closing-curly-brace %[
  # align to opening curly brace when alone on a line
  try %[ execute-keys -itersel -draft <a-h><a-k>^\h+\}$<ret>hms\A|.\z<ret>1<a-&> ]
]

define-command -hidden v-insert-comment-on-new-line %[
  evaluate-commands -no-hooks -draft -itersel %[
    # copy // comments prefix and following white spaces
      try %{ execute-keys -draft <semicolon><c-s>kx s ^\h*\K/{2,}\h* <ret> y<c-o>P<esc> }
  ]
]

## CLOSING DELIMITERS FOR { AND (
define-command -hidden v-insert-closing-delimiter-on-new-line %[
  evaluate-commands -no-hooks -draft -itersel %[
    # Wisely add '}'.
    evaluate-commands -save-regs x %[
      # Save previous line indent in register x.
      try %[ execute-keys -draft kxs^\h+<ret>"xy ] catch %[ reg x '' ]
      try %[
        # Validate previous line and that it is not closed yet.
        execute-keys -draft kx <a-k>^<c-r>x.*\{\h*\(?\h*$<ret> j}iJx <a-K>^<c-r>x\)?\h*\}<ret>
        # Insert closing '}'.
        execute-keys -draft o<c-r>x}<esc>
        # Delete trailing '}' on the line below the '{'.
        execute-keys -draft xs\}$<ret>d
      ]
    ]

    # Wisely add ')'.
    evaluate-commands -save-regs x %[
      # Save previous line indent in register x.
      try %[ execute-keys -draft kxs^\h+<ret>"xy ] catch %[ reg x '' ]
      try %[
        # Validate previous line and that it is not closed yet.
        execute-keys -draft kx <a-k>^<c-r>x.*\(\h*$<ret> J}iJx <a-K>^<c-r>x\)<ret>
        # Insert closing ')'.
        execute-keys -draft o<c-r>x)<esc>
        # Delete trailing ')' on the line below the '('.
        execute-keys -draft xs\)\h*\}?\h*$<ret>d
      ]
    ]
  ]
]

## V-LANG COMMANDS
define-command -params 0 -docstring "Looks for a v.mod file in up to 3 parent directories and runs v in there. If none is found, it runs v in the current directory. The output is printed to the info box and *debug* buffer" vlang_run %{
  require-module sh
  
  declare-option -hidden str vlang_mod_file_dir %sh{
    # find v.mod in up to 3 parent dirs 
    # remove 'v.mod' using substitution
    # pipe to xargs to trim the output
    find ./ ../ ../../ ../../../ -maxdepth 1 -iname "v.mod" | sed -ne 's/v.mod//p' | xargs
  }

  # print v output to debug buffer and info box
  declare-option -hidden str vlang_output %sh{ 
    cd "$kak_opt_vlang_mod_file_dir"
    $kak_opt_vlang_run_command
    cd -
  }
  
  # prepare if vlang_output should be printed to info box
  declare-option -hidden str vlang_info_box_output_command %sh{
    if [ "${kak_opt_vlang_output_to_info_box}" = "true" ]; then
      echo 'info %opt{vlang_output}'
    else
      echo ''
    fi
  }
  
  # prepare if vlang_output should be echoed to *debug* buffer
  declare-option -hidden str vlang_debug_buffer_output_command %sh{
    if [ "${kak_opt_vlang_output_to_debug_buffer}" = "true" ]; then
      echo 'echo -debug %opt{vlang_output}'
    else
      echo ''
    fi
  }
  
  #info %opt{vlang_output}
  eval %opt{vlang_info_box_output_command}
  
  #echo -debug %opt{vlang_output}
  eval %opt{vlang_debug_buffer_output_command}
}

define-command -params 0 -docstring "Runs v fmt -w on the current file and saves it" vlang_fmt %{
  execute-keys ":w<ret>"
  declare-option -hidden str current_formatcmd %opt{formatcmd}
  set window formatcmd %opt{vlang_fmt_command}
  execute-keys ":format-buffer<ret>"
  set window formatcmd %opt{current_formatcmd}
  execute-keys ":w<ret>"
}

§
