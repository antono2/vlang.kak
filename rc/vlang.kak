# Integrates V syntax, editor commands and managed helper tools into Kakoune.
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
# NOTE: The .v extension might be assigned to other filetypes.
#       Please put these 2 hooks in your kakrc as well.
#       kakrc is loaded last and ensures filetype=v.
hook global BufCreate .*\.(v|vsh|vv|c\.v)$ %{
  set-option buffer filetype v
}

hook global BufCreate .+v\.mod$ %{
  set-option buffer filetype json
}

provide-module v %§
  # Declare-Options
  # ‾‾‾‾‾‾‾‾‾‾‾‾
  declare-option -hidden bool v_output_to_info_box true
  declare-option -hidden bool v_output_to_debug_buffer true

  declare-option -hidden str v_run_command "v -keepc -cg run ."
  # The formatter reads the buffer from stdin and writes formatted code to stdout.
  declare-option -hidden str v_fmt_command "v fmt"
  declare-option str v_build_command "v ."
  declare-option str v_check_command "v -check"
  declare-option str v_test_command "v test ."
  declare-option str v_test_file_command "v test"
  declare-option str v_vet_command "v vet ."

  # Highlighters
  # ‾‾‾‾‾‾‾‾‾‾‾‾
  add-highlighter shared/v regions
  add-highlighter shared/v/code default-region group

  ## COMMENTS
  add-highlighter shared/v/line_comment1 region '//' $ group
  add-highlighter shared/v/line_comment1/comment fill comment
  add-highlighter shared/v/line_comment1/todo regex (TODO|NOTE|FIXME).*: 0:meta
  add-highlighter shared/v/line_comment2 region '/\*' '\*/' group
  add-highlighter shared/v/line_comment2/comment fill comment
  add-highlighter shared/v/line_comment2/todo regex (TODO|NOTE|FIXME).*: 0:meta
  add-highlighter shared/v/bin_bash region '(?<!\\)(?:\\\\)*(?:^|\h)\K#!' '$' fill comment

  ## ATTRIBUTES
  add-highlighter shared/v/attribute region -recurse '\[' '@\[' '\]' regions
  add-highlighter shared/v/attribute/code default-region fill attribute
  add-highlighter shared/v/attribute/string1 region %{(?<!')"} (?<!\\)(\\\\)*" fill string
  add-highlighter shared/v/attribute/string2 region %{(?<!')'} (?<!\\)(\\\\)*' fill string

  ## STRINGS
  add-highlighter shared/v/string1 region %{(?<!')"} (?<!\\)(\\\\)*" fill string
  add-highlighter shared/v/string2 region %{(?<!')'} (?<!\\)(\\\\)*' fill string
  add-highlighter shared/v/raw_string1 region -match-capture %{(?<!')r"} (?<!\\)(\\\\)*" fill string
  add-highlighter shared/v/raw_string2 region -match-capture %{(?<!')r'} (?<!\\)(\\\\)*' fill string
  add-highlighter shared/v/character region '\x60' '(?<!\\)(\\\\)*\x60' fill value

  ## OPERATORS
  add-highlighter shared/v/code/operators regex (?:>>>=|>>=|<<=|>>>|>>|<<|\|\|=|&&=|\*\*=|\*\*|\+\+|--|:=|<-|!in\b|!is\b|!=|==|<=|>=|\+=|-=|\*=|/=|%=|&=|\|=|\^=|\.\.\.?|\|\||&&|\+|-|/|\*|\^|&|\||!|>|<|%|=|~) 0:operator
  add-highlighter shared/v/code/question_mark regex \? 0:meta

  ## FUNCTIONS
  add-highlighter shared/v/code/function_call regex \b(_?[a-zA-Z]\w*)\h*(?:\[[^\]\n]+\]\h*)?(?=\() 1:function
  add-highlighter shared/v/code/function_declaration regex \bfn\h+(?:\([^\n)]*\)\h+)?(_?\w+)(?:\[[^\]\n]+\])?\h*(?=\() 1:function

  ## KEYWORDS
  add-highlighter shared/v/code/keywords regex \b(?:as|asm|assert|atomic|break|const|continue|defer|dump|else|enum|false|fn|for|go|goto|if|implements|import|in|interface|is|isreftype|lock|match|module|mut|nil|none|or|pub|return|rlock|select|shared|sizeof|spawn|static|struct|true|type|typeof|union|unsafe|volatile|_likely_|_unlikely_|__global|__offsetof)\b 0:keyword
  add-highlighter shared/v/code/compile_time_keywords regex \B\$(?:else|for|if|html|tmpl|env|embed_file|pkgconfig|compile_error|compile_warn|d|res|zero|new|map|array|array_dynamic|array_fixed|int|float|struct|interface|enum|sumtype|alias|function|option|shared|string|pointer|voidptr)\b 0:keyword
  add-highlighter shared/v/code/compile_time_constants regex @[A-Z][A-Z0-9_]*\b 0:meta

  ## VALUES
  add-highlighter shared/v/code/values regex \b(?:true|false|(?:0x[0-9a-fA-F](?:_?[0-9a-fA-F])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*)(?:(?:i|u)(?:8|16|32|64|128|size))?|[0-9](?:_?[0-9])*(?:\.[0-9](?:_?[0-9])*)?(?:[eE][\+\-]?[0-9](?:_?[0-9])*)?(?:(?:i|u)(?:8|16|32|64|128|size)|f(?:32|64))?)\b 0:value

  ## TYPES
  add-highlighter shared/v/code/type_name regex \b[A-Z]\w*\b 0:type
  add-highlighter shared/v/code/builtin_types regex \b(?:bool|byte|byteptr|char|charptr|rune|string|voidptr|int|i8|u8|i16|u16|i32|u32|i64|u64|isize|usize|f32|f64|map|thread)\b 0:type


  # Commands
  # ‾‾‾‾‾‾‾‾
  define-command -docstring 'Enable v lang indentation hooks' v-enable-indenting %{
    hook window InsertChar \n -group v-indent v-indent-on-new-line
    hook window InsertChar \{ -group v-indent v-indent-on-opening-curly-brace
    hook window InsertChar \} -group v-indent v-indent-on-closing-curly-brace
    hook window InsertChar \n -group v-comment-insert v-insert-comment-on-new-line
    hook window InsertChar \n -group v-closing-delimiter-insert v-insert-closing-delimiter-on-new-line
  }

  define-command -docstring 'Disable v lang indentation hooks' v-disable-indenting %{
    remove-hooks window v-.+
  }

  ## ALT FILE
  define-command -hidden -docstring 'Jump to the alternate file (implementation ↔ test)' v-alternative-file %{ evaluate-commands %sh{
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
        # indent after lines ending with an opening { or (
        try %< execute-keys -draft kx <a-k> [({]\h*$ <ret> j<a-gt> >
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
  define-command -params 0 -docstring "Looks for a v.mod file in up to 3 parent directories and runs v in there. If none is found, it runs v in the current directory. The output is printed to the info box and *debug* buffer" v-run %{
    require-module sh

    declare-option -hidden str v_mod_file_dir %sh{
      case $kak_buffile in
        */*) buffer_dir=${kak_buffile%/*} ;;
        *) buffer_dir=. ;;
      esac

      run_dir=$buffer_dir
      search_dir=$buffer_dir
      level=0
      while [ "$level" -le 3 ]; do
        if [ -f "$search_dir/v.mod" ]; then
          run_dir=$search_dir
          break
        fi

        parent_dir=${search_dir%/*}
        test -n "$parent_dir" || parent_dir=/
        test "$parent_dir" != "$search_dir" || break
        search_dir=$parent_dir
        level=$((level + 1))
      done

      printf %s "$run_dir"
    }

    # print v output to debug buffer and info box
    declare-option -hidden str v_output %sh{
      cd "$kak_opt_v_mod_file_dir" || exit 1
      eval "$kak_opt_v_run_command" 2>&1 || true
    }

    # prepare if v_output should be printed to info box
    declare-option -hidden str v_info_box_output_command %sh{
      if [ "${kak_opt_v_output_to_info_box}" = "true" ]; then
        echo 'info %opt{v_output}'
      else
        echo ''
      fi
    }

    # prepare if v_output should be echoed to *debug* buffer
    declare-option -hidden str v_debug_buffer_output_command %sh{
      if [ "${kak_opt_v_output_to_debug_buffer}" = "true" ]; then
        echo 'echo -debug %opt{v_output}'
      else
        echo ''
      fi
    }

    #info %opt{v_output}
    eval %opt{v_info_box_output_command}

    #echo -debug %opt{v_output}
    eval %opt{v_debug_buffer_output_command}
  }

  define-command -params 0 -docstring "Formats the current buffer and saves it" v-fmt %{
    declare-option -hidden str current_formatcmd %opt{formatcmd}
    set window formatcmd %opt{v_fmt_command}
    try %{
      eval format-buffer
      set window formatcmd %opt{current_formatcmd}
      eval write
    } catch %{
      set window formatcmd %opt{current_formatcmd}
      fail "%val{error}"
    }
  }
§


# Initialization
# ‾‾‾‾‾‾‾‾‾‾‾‾‾‾
hook global WinSetOption filetype=v %§
  require-module v

  set-option buffer comment_line "//"
  set-option buffer comment_block_begin "/*"
  set-option buffer comment_block_end "*/"

  # Set indentation commands
  # cleanup trailing whitespaces when exiting insert mode
  hook window ModeChange pop:insert:.* -group v-trim-indent %{ try %{ execute-keys -draft xs^\h+$<ret>d } }
  v-enable-indenting

  alias window alt v-alternative-file

  # remove all v-... hooks when changing to any other filetype
  hook -once -always window WinSetOption filetype=.* %{
    v-disable-indenting
    unalias window alt v-alternative-file
  }
§

hook -group v-highlight global WinSetOption filetype=v %§
    add-highlighter window/v ref v
    #remove all window/v == /shared/v highlighters when changing to any other filetype
    hook -once -always window WinSetOption filetype=.* %{ remove-highlighter window/v }
§


# The IDE commands are available when kak-lsp is loaded. Syntax support above is independent.
declare-option bool v_explorer_enabled true
declare-option bool v_live_search_enabled true
declare-option str v_pane_mode auto
declare-option str v_window_backend auto
declare-option -hidden str v_plugin_source %val{source}
declare-option -hidden str v_tree_state
declare-option -hidden str v_tree_origin
declare-option -hidden str v_tree_target_client
declare-option -hidden bool v_tree_is_pane false
declare-option -hidden str v_history_repo
declare-option -hidden str v_history_commit
declare-option -hidden str v_history_path
declare-option -hidden str v_history_buffer
declare-option str v_lsp_servers %{
  [vls]
  root_globs = ["v.mod", ".git"]
}
declare-option str v_lsp_semantic_tokens %{
  [
    {face="keyword", token="keyword"},
    {face="comment", token="comment"},
    {face="string", token="string"},
    {face="value", token="number"},
    {face="type", token="type"},
    {face="function", token="function"},
  ]
}

# Result lists keep navigation separate from accepting a location.
declare-option -hidden str v_results_origin
declare-option -hidden str v_results_selection
declare-option -hidden str v_results_modeline
declare-option -hidden str-to-str-map v_results_origins
declare-option -hidden str-to-str-map v_results_selections
define-command -hidden -params 2 v-results-remember %{
  set-option -add global v_results_origins "%val{client}=%arg{1}"
  set-option -add global v_results_selections "%val{client}=%arg{2}"
}
define-command -hidden v-results-prepare %{
  evaluate-commands -try-client %opt{toolsclient} -verbatim -- v-results-remember %val{bufname} %val{selection_desc}
}
define-command -hidden v-results-next %{
  evaluate-commands -save-regs / %{
    set-option buffer jump_current_line %val{cursor_line}
    try %{ jump-select-next } catch %{ echo 'No results to browse; q or Esc returns to source' }
  }
}
define-command -hidden v-results-previous %{
  evaluate-commands -save-regs / %{
    set-option buffer jump_current_line %val{cursor_line}
    try %{ jump-select-previous } catch %{ echo 'No results to browse; q or Esc returns to source' }
  }
}
define-command -hidden -params 2 v-results-return %{
  buffer %arg{1}
  select %arg{2}
}
define-command -hidden v-results-cancel %{
  v-results-return %opt{v_results_origin} %opt{v_results_selection}
}
hook -group v-results global WinSetOption filetype=lsp-(document-symbol|goto|diagnostics) %{
  # WinSetOption runs without a client; defer until the result window is active.
  hook -once -group v-results-init window NormalIdle .* %{ v-results-init }
  hook -once -always window WinSetOption filetype=.* %{ remove-hooks window v-results-init }
}
define-command -hidden v-results-init %{
  remove-hooks window v-results-init
  evaluate-commands %sh{
    origin=
    selection=
    eval "set -- $kak_quoted_opt_v_results_origins"
    for entry do
      [ "${entry%%=*}" != "$kak_client" ] || origin=${entry#*=}
    done
    eval "set -- $kak_quoted_opt_v_results_selections"
    for entry do
      [ "${entry%%=*}" != "$kak_client" ] || selection=${entry#*=}
    done
    [ -n "$origin" ] || exit
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'set-option window v_results_origin %s\n' "$(kak_quote "$origin")"
    printf 'set-option window v_results_selection %s\n' "$(kak_quote "$selection")"
    cat <<'KAK'
set-option window v_results_modeline %opt{modelinefmt}
set-option -add window modelinefmt '  [Tab/S-Tab browse | Enter open | q/Esc back]'
map window normal <tab> ':v-results-next<ret>' -docstring 'Next result'
map window normal <s-tab> ':v-results-previous<ret>' -docstring 'Previous result'
map window normal q ':v-results-cancel<ret>' -docstring 'Return to source'
map window normal <esc> ':v-results-cancel<ret>' -docstring 'Return to source'
hook -once -always window WinSetOption filetype=.* %{
  try %{ unmap window normal <tab> ':v-results-next<ret>' }
  try %{ unmap window normal <s-tab> ':v-results-previous<ret>' }
  try %{ unmap window normal q ':v-results-cancel<ret>' }
  try %{ unmap window normal <esc> ':v-results-cancel<ret>' }
  set-option window modelinefmt %opt{v_results_modeline}
}
KAK
  }
  v-refresh-keys
}

define-command v-definition -docstring 'Go to the V symbol definition' %{ v-results-prepare; lsp-definition }
define-command v-declaration -docstring 'Go to the V symbol declaration' %{ v-results-prepare; lsp-declaration }
define-command v-references -docstring 'Find V symbol references' %{ v-results-prepare; lsp-references }
define-command v-highlight-references -docstring 'Highlight uses of the V symbol in this file' %{
  lsp-highlight-references
}
define-command v-select-syntax -docstring 'Expand and contract the V syntax selection' %{
  try %{ lsp-selection-range } catch %{
    # Kakoune releases before selection_count support still allow the main selection.
    lsp-send textDocument/selectionRange %val{cursor_line} %val{cursor_column} 1 %val{selection_desc}
  }
}
define-command v-implementation -docstring 'Find V implementations' %{ v-results-prepare; lsp-implementation }
define-command v-type-definition -docstring 'Go to the V type definition' %{ v-results-prepare; lsp-type-definition }
define-command v-rename -docstring 'Rename a V symbol' %{ lsp-rename-prompt }
define-command -params 1 v-rename-to -docstring 'Rename a V symbol to the given name' %{
  lsp-rename %arg{1}
}
define-command v-code-actions -docstring 'Show VLS code actions' %{ lsp-code-actions }
define-command v-organize-imports -docstring 'Choose the VLS action to organize V imports' %{
  lsp-code-actions -auto-single source.organizeImports
}
define-command v-hover -docstring 'Show VLS hover information' %{ lsp-hover }
declare-option -hidden str-to-str-map v_doc_origins
declare-option -hidden str-to-str-map v_doc_selections
declare-option -hidden str v_doc_origin
declare-option -hidden str v_doc_selection
define-command -hidden -params 1 v-doc-remember %{
  set-option -add global v_doc_origins "%arg{1}=%val{bufname}"
  set-option -add global v_doc_selections "%arg{1}=%val{selection_desc}"
}
define-command v-doc -docstring 'Show VLS documentation; q or Esc returns to source' %{
  evaluate-commands %sh{
    target=${kak_opt_docsclient:-$kak_client}
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'v-doc-remember %s\n' "$(kak_quote "$target")"
  }
  lsp-hover-buffer
}
define-command -hidden v-doc-init %{
  evaluate-commands %sh{
    [ "$kak_bufname" = '*hover*' ] || exit
    origin=; selection=
    eval "set -- $kak_quoted_opt_v_doc_origins"
    for entry do [ "${entry%%=*}" != "$kak_client" ] || origin=${entry#*=}; done
    eval "set -- $kak_quoted_opt_v_doc_selections"
    for entry do [ "${entry%%=*}" != "$kak_client" ] || selection=${entry#*=}; done
    [ -n "$origin" ] || exit
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'set-option window v_doc_origin %s\nset-option window v_doc_selection %s\n' \
      "$(kak_quote "$origin")" "$(kak_quote "$selection")"
  }
}
define-command v-doc-return -docstring 'Return from documentation to the original source selection' %{
  v-results-return %opt{v_doc_origin} %opt{v_doc_selection}
}
hook -group v-doc global WinDisplay .* %{ v-doc-init }

define-command v-signature -docstring 'Show signature and parameter help at a V function call' %{ lsp-signature-help }
define-command v-symbols -docstring 'Browse V document symbols; Enter opens, q returns' %{ v-results-prepare; lsp-document-symbol }
define-command v-workspace-symbols -docstring 'Enter a query, then browse V project symbols' %{
  v-results-prepare
  prompt 'Project symbol query (Enter to list): ' %{ v-workspace-symbols-query %val{text} }
}
define-command -hidden -params 1 v-workspace-symbols-query %{
  # Send from the source context before displaying results. kak-lsp sends no
  # editor response for an empty result, so keep a cancellable empty view.
  lsp-workspace-symbol %arg{1}
  lsp-show-goto-buffer *symbols* lsp-goto %{} 'No matches displayed yet. Results appear here when available; q/Esc returns.'
  evaluate-commands -try-client %opt{toolsclient} %{ v-results-init }
}
define-command v-diagnostics -docstring 'Show V project diagnostics' %{ v-results-prepare; lsp-diagnostics }
define-command v-incoming-calls -docstring 'Find callers of the V function' %{ v-results-prepare; lsp-incoming-calls }
define-command v-outgoing-calls -docstring 'Find functions called here' %{ v-results-prepare; lsp-outgoing-calls }
define-command v-code-lens -docstring 'Run a VLS code lens' %{ lsp-code-lens }
define-command v-inlay-hints-enable -docstring 'Show VLS inlay hints' %{ lsp-inlay-hints-enable window }
define-command v-inlay-hints-disable -docstring 'Hide VLS inlay hints' %{ lsp-inlay-hints-disable window }
define-command v-format -docstring 'Format the V buffer with VLS without saving it' %{ lsp-formatting }
define-command v-next-diagnostic -docstring 'Go to the next V diagnostic' %{ lsp-find-error }
define-command v-previous-diagnostic -docstring 'Go to the previous V diagnostic' %{
  lsp-find-error --previous
}

# Project navigation and search use Kakoune's own UI.
define-command v-files -docstring 'Open a file with Kakoune path completion' %{
  execute-keys ':edit<space>'
}
define-command -hidden -params 1 v-search-preview %{
  evaluate-commands %sh{
    [ "$kak_opt_v_live_search_enabled" = true ] || exit
    [ -n "$1" ] || { printf 'info -title %s %s\n' "'Project search'" "'Type a pattern; Enter opens all results'"; exit; }
    case "$kak_buffile" in
      /*) file=$kak_buffile ;;
      '') file=$PWD/ ;;
      *) file=$PWD/$kak_buffile ;;
    esac
    root=${file%/*}
    [ -n "$root" ] || root=/
    current=$root
    while :; do
      if [ -f "$current/v.mod" ] || [ -d "$current/.git" ]; then
        root=$current
        break
      fi
      parent=${current%/*}
      [ -n "$parent" ] || parent=/
      [ "$parent" != "$current" ] || break
      current=$parent
    done
    if command -v rg >/dev/null 2>&1; then
      matches=$(cd "$root" && rg -n --no-heading --color never -e "$1" . 2>/dev/null | head -n 12)
    else
      matches=$(cd "$root" && grep -RHn --exclude-dir=.git -e "$1" . 2>/dev/null | head -n 12)
    fi
    [ -n "$matches" ] || matches='No matches yet'
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'info -title %s %s\n' "$(kak_quote 'Project search · Enter for all')" \
      "$(kak_quote "$(printf '%s\n' "$matches" | cut -c 1-140)")"
  }
}
define-command v-search -docstring 'Search project files: enter a pattern; the project directory is chosen automatically' %{
  prompt -on-change %{ v-search-preview %val{text} } 'Search project pattern (regex): ' %{
    evaluate-commands %sh{
      [ -n "$kak_text" ] || exit
      case "$kak_buffile" in
        /*) file=$kak_buffile ;;
        '') file=$PWD/ ;;
        *) file=$PWD/$kak_buffile ;;
      esac
      root=${file%/*}
      [ -n "$root" ] || root=/
      current=$root
      while :; do
        if [ -f "$current/v.mod" ] || [ -d "$current/.git" ]; then
          root=$current
          break
        fi
        parent=${current%/*}
        [ -n "$parent" ] || parent=/
        [ "$parent" != "$current" ] || break
        current=$parent
      done
      kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
      if [ "$kak_opt_grepcmd" = 'grep -RHn' ]; then
        if command -v rg >/dev/null 2>&1; then
          printf 'set-option window grepcmd %s\n' "$(kak_quote 'rg -n --no-heading')"
        else
          printf 'set-option window grepcmd %s\n' "$(kak_quote 'grep -RHn --exclude-dir=.git')"
        fi
      fi
      printf 'grep -e %s %s\n' "$(kak_quote "$kak_text")" "$(kak_quote "$root")"
      if [ "$kak_opt_grepcmd" = 'grep -RHn' ]; then
        printf 'unset-option window grepcmd\n'
      fi
    }
  }
}
define-command v-find -docstring 'Find text in the current buffer' %{
  execute-keys '/'
}

# Kakoune filters these candidates as the user types; no external picker is needed.
define-command -params 1 v-project-edit -docstring 'Open a file from the current V project' %{
  edit -existing -- %arg{1}
}
complete-command -menu v-project-edit shell-script-candidates %{
  case "$kak_buffile" in
    /*) file=$kak_buffile ;;
    '') file=$PWD/ ;;
    *) file=$PWD/$kak_buffile ;;
  esac
  directory=${file%/*}
  [ -n "$directory" ] || directory=/
  root=$directory
  current=$directory
  while :; do
    if [ -f "$current/v.mod" ] || [ -d "$current/.git" ]; then
      root=$current
      break
    fi
    parent=${current%/*}
    [ -n "$parent" ] || parent=/
    [ "$parent" != "$current" ] || break
    current=$parent
  done
  if command -v rg >/dev/null 2>&1; then
    (cd "$root" && rg --files --hidden --glob '!.git')
  elif git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files --cached --others --exclude-standard
  else
    (cd "$root" && find . -type f -not -path './.git/*')
  fi | while IFS= read -r path; do
    printf '%s/%s\n' "$root" "${path#./}"
  done
}
define-command v-project-files -docstring 'Find a project file using path completion' %{
  execute-keys ':v-project-edit<space>'
}
define-command -hidden -params 1 v-tree-start %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/explorer.sh
    [ -f "$script" ] || { echo "fail 'Project explorer helper is missing'"; exit; }
    state=$(mktemp "${TMPDIR:-/tmp}/vlang-kak-tree.XXXXXXXX.json") || exit
    "$script" init "$state" "$1" || {
      rm -f "$state"
      echo "fail 'Project explorer could not start; check V on PATH and *debug*'"
      exit
    }
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'edit -scratch %s\nset-option buffer v_tree_state %s\nset-option buffer v_tree_origin %s\n' \
      "$(kak_quote "*v-tree-$kak_client*")" "$(kak_quote "$state")" "$(kak_quote "$1")"
  }
  set-option buffer filetype v-tree
  hook -once buffer BufClose .* %{ nop %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/explorer.sh
    "$script" cleanup "$kak_opt_v_tree_state"
  } }
  map buffer normal <ret> ':v-tree-action open<ret>' -docstring 'Open file or toggle directory'
  map buffer normal l ':v-tree-action expand<ret>' -docstring 'Expand directory'
  map buffer normal h ':v-tree-action collapse<ret>' -docstring 'Collapse directory or move to parent'
  map buffer normal p ':v-tree-action preview<ret>' -docstring 'Preview file'
  map buffer normal . ':v-tree-hidden<ret>' -docstring 'Toggle hidden files'
  map buffer normal r ':v-tree-refresh<ret>' -docstring 'Refresh project tree'
  map buffer normal q ':v-tree-close<ret>' -docstring 'Return to source or close tree pane'
}
define-command v-tree -docstring 'Open the interactive project explorer' %{
  evaluate-commands %sh{
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'try %%{ buffer %s\nset-option buffer v_tree_origin %s } catch %%{ v-tree-start %s }\n' \
      "$(kak_quote "*v-tree-$kak_client*")" "$(kak_quote "$kak_buffile")" \
      "$(kak_quote "$kak_buffile")"
  }
  v-tree-refresh
}
define-command -hidden v-tree-refresh %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/explorer.sh
    content=$("$script" render "$kak_opt_v_tree_state" "$kak_opt_v_tree_origin" "$kak_opt_v_tree_is_pane") || {
      echo "fail 'Project explorer could not render; check *debug*'"
      exit
    }
    printf "set-register v '%s'\n" "$(printf %s "$content" | sed "s/'/''/g")"
  }
  set-option buffer readonly false
  execute-keys <percent>
  execute-keys c<c-r>v<esc>
  set-option buffer readonly true
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/explorer.sh
    "$script" focus "$kak_opt_v_tree_state"
  }
  v-refresh-keys
}
define-command -hidden -params 1 v-tree-action %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/explorer.sh
    result=$("$script" action "$kak_opt_v_tree_state" "$kak_cursor_line" "$1") || exit
    if [ "$kak_opt_v_tree_is_pane" = true ] && [ "$1" = open ] &&
       [ -n "$kak_opt_v_tree_target_client" ]; then
      case "$result" in
        'edit -existing -- '*)
          kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
          printf 'evaluate-commands -client %s %s\n' \
            "$(kak_quote "$kak_opt_v_tree_target_client")" "$(kak_quote "$result")"
          exit
          ;;
      esac
    fi
    printf '%s\n' "$result"
  }
}
define-command -hidden v-tree-hidden %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/explorer.sh
    "$script" hidden "$kak_opt_v_tree_state"
  }
}
define-command -hidden v-tree-close %{
  evaluate-commands %sh{
    if [ "$kak_opt_v_tree_is_pane" = true ]; then
      printf 'quit\n'
    else
      kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
      printf 'buffer %s\n' "$(kak_quote "$kak_opt_v_tree_origin")"
    fi
  }
}
define-command -hidden -params 2 v-tree-pane-init %{
  edit -existing -- %arg{1}
  v-tree
  set-option buffer v_tree_target_client %arg{2}
  set-option buffer v_tree_is_pane true
  v-tree-refresh
}
define-command v-window-status -docstring 'Show the active client window backend' %{
  evaluate-commands %sh{
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" \
      "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/windowing.sh
    backend=$("$helper" detect "$kak_opt_v_window_backend") || exit
    printf "echo 'Window backend: %s; pane mode: %s'\n" "$backend" "$kak_opt_v_pane_mode"
  }
}
define-command v-tree-pane -docstring 'Open the project explorer in another view when supported' %{
  evaluate-commands %sh{
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" \
      "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
    mode=$kak_opt_v_pane_mode
    case "$mode" in
      off) echo v-tree; exit ;;
      auto|always) ;;
      *) echo "fail 'v_pane_mode must be auto, always, or off'"; exit ;;
    esac
    [ -n "$kak_buffile" ] || { echo v-tree; exit; }
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/windowing.sh
    backend=$("$helper" detect "$kak_opt_v_window_backend") || exit
    if [ "$backend" = none ]; then
      if [ "$mode" = always ]; then
        echo "fail 'No supported window backend is active; run v-window-status'"
      else
        echo v-tree
      fi
      exit
    fi
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    initial="v-tree-pane-init $(kak_quote "$kak_buffile") $(kak_quote "$kak_client")"
    if ! "$helper" open "$backend" left "$kak_session" "$initial"; then
      if [ "$mode" = always ]; then
        echo "fail 'Opening the project tree pane failed'"
      else
        echo v-tree
      fi
    fi
  }
}
define-command -hidden -params 3 v-peek-definition-init %{
  edit -existing -- %arg{1}
  evaluate-commands %sh{ printf 'select %s.%s,%s.%s\n' "$2" "$3" "$2" "$3" }
  map window normal q ':v-close-view<ret>' -docstring 'Close definition peek'
  set-option -add window modelinefmt '  [peek: q close]'
  v-definition
  echo 'Definition peek: press q to close this pane'
}
define-command v-peek-definition -docstring 'Peek at a definition in another view; without pane support show documentation' %{
  evaluate-commands %sh{
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" \
      "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
    mode=$kak_opt_v_pane_mode
    case "$mode" in
      off) echo v-doc; exit ;;
      auto|always) ;;
      *) echo "fail 'v_pane_mode must be auto, always, or off'"; exit ;;
    esac
    [ -n "$kak_buffile" ] || { echo "fail 'Peek definition needs a saved V file'"; exit; }
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/windowing.sh
    backend=$("$helper" detect "$kak_opt_v_window_backend") || exit
    if [ "$backend" = none ]; then
      if [ "$mode" = always ]; then
        echo "fail 'No supported window backend is active; run v-window-status'"
      else
        echo v-doc
      fi
      exit
    fi
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    initial="v-peek-definition-init $(kak_quote "$kak_buffile") $kak_cursor_line $kak_cursor_column"
    if ! "$helper" open "$backend" right "$kak_session" "$initial"; then
      if [ "$mode" = always ]; then
        echo "fail 'Opening the definition pane failed'"
      else
        echo v-doc
      fi
    fi
  }
}
define-command v-project-path -docstring 'Open the project explorer, or a project path prompt when disabled' %{
  evaluate-commands %sh{
    if [ "$kak_opt_v_explorer_enabled" = true ]; then
      printf 'v-tree-pane\n'
      exit
    fi
    case "$kak_buffile" in
      /*) file=$kak_buffile ;;
      '') file=$PWD/ ;;
      *) file=$PWD/$kak_buffile ;;
    esac
    root=${file%/*}
    [ -n "$root" ] || root=/
    current=$root
    while :; do
      if [ -f "$current/v.mod" ] || [ -d "$current/.git" ]; then
        root=$current
        break
      fi
      parent=${current%/*}
      [ -n "$parent" ] || parent=/
      [ "$parent" != "$current" ] || break
      current=$parent
    done
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'prompt -file-completion -init %s %s %%{ edit -existing -- %%val{text} }\n' \
      "$(kak_quote "$root/")" "$(kak_quote 'Project path: ')"
  }
}
define-command v-new-view -docstring 'Open another view of the current file in the same session' %{
  evaluate-commands %sh{
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" \
      "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/windowing.sh
    backend=$("$helper" detect "$kak_opt_v_window_backend") || exit
    [ "$backend" != none ] || { echo "fail 'No supported window backend is active; run v-window-status'"; exit; }
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    initial="buffer $(kak_quote "$kak_bufname"); select $kak_cursor_line.$kak_cursor_column,$kak_cursor_line.$kak_cursor_column"
    "$helper" open "$backend" right "$kak_session" "$initial" || echo "fail 'Opening a Kakoune client failed'"
  }
}
define-command v-close-view -docstring 'Close this Kakoune client and its pane or window' %{
  quit
}

# The managed kak-v launcher restarts on exit status 75 and sources this state.
declare-option -hidden str v_update_resume_file
declare-option -hidden int v_update_resume_line 1
declare-option -hidden int v_update_resume_column 1

define-command -hidden -params .. v-update-one-client %{
  evaluate-commands %sh{
    [ "${VLANG_KAK_RESTART_ALLOWED:-0}" = 1 ] || {
      printf 'fail "Restart requires a session started by kak-v"\n'
      exit
    }
    [ "$#" -eq 1 ] || printf 'fail "Restart requires one Kakoune client in the session"\n'
  }
}

define-command -hidden -params .. v-update-save-state %{
  evaluate-commands %sh{
    state=${VLANG_KAK_RESTART_STATE:-}
    [ -n "$state" ] || {
      printf 'fail "Restart requires the managed kak-v launcher"\n'
      exit
    }
    temporary=$state.tmp
    printf 'nop\n' > "$temporary" || {
      printf 'fail "Cannot write Kakoune restart state"\n'
      exit
    }
    kak_quote() {
      printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"
    }
    for name do
      if [ -f "$name" ]; then
        quoted=$(kak_quote "$name")
        printf 'try %%{ buffer %s } catch %%{ edit -- %s }\n' \
          "$quoted" "$quoted" >> "$temporary"
      fi
    done
    resume_file=$kak_buffile
    resume_line=$kak_cursor_line
    resume_column=$kak_cursor_column
    if [ ! -f "$resume_file" ]; then
      resume_file=$kak_opt_v_update_resume_file
      resume_line=$kak_opt_v_update_resume_line
      resume_column=$kak_opt_v_update_resume_column
    fi
    if [ -f "$resume_file" ]; then
      printf 'buffer %s\nselect %s.%s,%s.%s\n' \
        "$(kak_quote "$resume_file")" \
        "$resume_line" "$resume_column" "$resume_line" "$resume_column" >> "$temporary"
    fi
    mv "$temporary" "$state" || printf 'fail "Cannot install Kakoune restart state"\n'
  }
}

define-command v-restart -docstring 'Restart the managed V IDE and reopen file buffers' %{
  v-debug-require-inactive
  v-update-one-client %val{client_list}
  v-update-save-state %val{buflist}
  quit 75
}

define-command -params .. v-update -docstring 'Update the managed V IDE, then restart this client' %{
  v-debug-require-inactive
  v-update-one-client %val{client_list}
  evaluate-commands %sh{
    [ -n "${VLANG_KAK_RESTART_STATE:-}" ] &&
      [ -x "$VLANG_KAK_REPO/scripts/update-session.sh" ] ||
      printf 'fail "Update requires the managed kak-v launcher"\n'
  }
  set-option global v_update_resume_file %val{buffile}
  set-option global v_update_resume_line %val{cursor_line}
  set-option global v_update_resume_column %val{cursor_column}
  evaluate-commands %sh{
    shell_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    command=$(shell_quote "$VLANG_KAK_REPO/scripts/update-session.sh")
    for value in "$VLANG_KAK_PREFIX" "$kak_session" "$kak_client" "$kak_client_pid" "$@"; do
      command="$command $(shell_quote "$value")"
    done
    printf 'v-make-command %s\n' "$(kak_quote "$command")"
  }
}

# Keep historical content in a scratch buffer so the working tree is untouched.
define-command -params 1 v-history-file -docstring 'Open this file at a Git revision in a read-only V scratch buffer' %{
  evaluate-commands %sh{
    file=$kak_buffile
    [ -f "$file" ] || { echo "fail 'Open a saved V file before browsing history'"; exit; }
    file=$(readlink -f "$file")
    repo=$(git -C "${file%/*}" rev-parse --show-toplevel 2>/dev/null) || {
      echo "fail 'The current file is not in a Git repository'"
      exit
    }
    case "$file" in
      "$repo"/*) path=${file#"$repo"/} ;;
      *) echo "fail 'The current file is outside the Git repository'"; exit ;;
    esac
    ref=$1
    case "$ref" in
      ''|-*) echo "fail 'Pass a branch, tag, or commit name'"; exit ;;
    esac
    commit=$(git -C "$repo" rev-parse --verify "$ref^{commit}" 2>/dev/null) || {
      echo "fail 'Unknown Git revision'"
      exit
    }
    git -C "$repo" cat-file -e "$commit:$path" 2>/dev/null || {
      echo "fail 'This file does not exist at that revision'"
      exit
    }
    short=$(git -C "$repo" rev-parse --short=12 "$commit")
    name="*v-history:$short:$path*"
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'set-option window v_history_repo %s\n' "$(kak_quote "$repo")"
    printf 'set-option window v_history_commit %s\n' "$(kak_quote "$commit")"
    printf 'set-option window v_history_path %s\n' "$(kak_quote "$path")"
    printf 'set-option window v_history_buffer %s\n' "$(kak_quote "$name")"
  }
  evaluate-commands -save-regs v %{
    set-register v %sh{
      git -C "$kak_opt_v_history_repo" show "$kak_opt_v_history_commit:$kak_opt_v_history_path"
    }
    edit! -scratch -- %opt{v_history_buffer}
    execute-keys i<c-r>v<esc>
    set-option buffer filetype v
    set-option buffer readonly true
  }
}

define-command v-history -docstring 'Pick a recent version of the current V file' %{
  evaluate-commands %sh{
    file=$kak_buffile
    [ -f "$file" ] || { echo "fail 'Open a saved V file before browsing history'"; exit; }
    file=$(readlink -f "$file")
    repo=$(git -C "${file%/*}" rev-parse --show-toplevel 2>/dev/null) || {
      echo "fail 'The current file is not in a Git repository'"
      exit
    }
    case "$file" in
      "$repo"/*) path=${file#"$repo"/} ;;
      *) echo "fail 'The current file is outside the Git repository'"; exit ;;
    esac
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'menu %s %s' "$(kak_quote 'HEAD  current commit')" "$(kak_quote 'v-history-file HEAD')"
    git -C "$repo" log -n 30 --format='%h %s' HEAD -- "$path" |
      while read -r hash subject; do
        [ -n "$hash" ] || continue
        printf ' %s %s' "$(kak_quote "$hash  $subject")" "$(kak_quote "v-history-file $hash")"
      done
    printf '\n'
  }
}

# Tasks run through Kakoune's asynchronous *make* buffer, with navigable output.
declare-option -hidden str v_last_test_command
declare-option str v_task_error_pattern '(?: (?:fatal )?error:| fn test_)'
declare-option -hidden str v_task_command
declare-option -hidden str v_task_origin
declare-option -hidden str v_task_selection
declare-option -hidden bool v_task_output false
declare-option -hidden bool v_task_available false
hook -group v-task-context global BufOpenFifo \*make\* %{ set-option global v_task_available false }
hook -group v-task-context global BufClose \*make\* %{ set-option global v_task_available false }
hook -group v-task-context global BufOpenFifo .* %{ set-option buffer v_task_output false }
define-command -hidden -params 1 v-make-command %{
  # Capture the source before make switches to the tools client/buffer.
  evaluate-commands %sh{
    quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    if [ "$kak_opt_v_task_output" = true ]; then
      origin=$kak_opt_v_task_origin
      selection=$kak_opt_v_task_selection
    else
      origin=$kak_bufname
      selection=$kak_selection_desc
    fi
    printf 'v-make-run %s %s %s %s %s\n' "$(quote "$1")" "$(quote "$origin")" "$(quote "$selection")" "$(quote "$kak_opt_makecmd")" "$(quote "$kak_bufname")"
  }
}
define-command -hidden -params 5 v-make-run %{
  set-option window makecmd %arg{1}
  try %{ make } catch %{
    set-option window makecmd %arg{4}
    fail %val{error}
  }
  v-make-restore %val{bufname} %val{selection_desc} %arg{5} %arg{4}
  evaluate-commands -buffer '*make*' %{
    set-option buffer v_task_command %arg{1}
    set-option buffer v_task_origin %arg{2}
    set-option buffer v_task_selection %arg{3}
    set-option buffer v_task_output true
    set-option global v_task_available true
  }
  evaluate-commands -try-client %opt{toolsclient} %{ v-refresh-keys }
}
define-command -hidden -params 4 v-make-restore %{
  buffer %arg{3}
  set-option window makecmd %arg{4}
  buffer %arg{1}
  select %arg{2}
}
define-command v-repeat-task -docstring 'Rerun the task displayed in this output buffer' %{
  v-make-command %opt{v_task_command}
}
define-command v-task-return -docstring 'Return to the source of this V task' %{
  v-results-return %opt{v_task_origin} %opt{v_task_selection}
}

define-command -params 1 v-task -docstring 'Run a V check, build, run, test, or vet task' %{
  evaluate-commands %sh{
    task=$1
    case "$task" in
      build) command=$kak_opt_v_build_command ;;
      check) command=$kak_opt_v_check_command ;;
      run) command=$kak_opt_v_run_command ;;
      test) command=$kak_opt_v_test_command ;;
      vet) command=$kak_opt_v_vet_command ;;
      *) printf "fail 'Unknown V task: %s'\n" "$1"; exit ;;
    esac
    file=$kak_buffile
    if [ -z "$file" ]; then
      echo "fail 'Open a V file before running a project task'"
      exit
    fi
    file=$(readlink -f "$file")
    directory=${file%/*}
    [ "$directory" != "$file" ] || directory=.
    root=$directory
    current=$directory
    while :; do
      if [ -f "$current/v.mod" ] || [ -d "$current/.git" ]; then
        root=$current
        break
      fi
      parent=${current%/*}
      [ -n "$parent" ] || parent=/
      [ "$parent" != "$current" ] || break
      current=$parent
    done
    shell_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }
    if [ "$task" = check ]; then command="$command $(shell_quote "$file")"; fi
    if [ "$task" = run ]; then
      if [ -n "$kak_opt_v_project_cwd" ]; then root=$kak_opt_v_project_cwd; fi
      if [ -n "$kak_opt_v_project_target" ]; then
        case "$command" in *' .') command=${command% .}; command="$command $(shell_quote "$kak_opt_v_project_target")" ;; esac
      fi
      eval "set -- $kak_quoted_opt_v_project_args"
      for argument do command="$command $(shell_quote "$argument")"; done
    fi
    shell_command="cd $(shell_quote "$root") && printf 'V task output\\n' && $command"
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    if [ "$task" = test ]; then
      printf 'set-option global v_last_test_command %s\n' "$(kak_quote "$shell_command")"
    fi
    printf 'v-make-command %s\n' "$(kak_quote "$shell_command")"
  }
}
define-command v-build -docstring 'Build V project' %{ v-task build }
define-command v-check-file -docstring 'Check the current V file' %{ v-task check }
define-command v-run-project -docstring 'Run V project in *make*' %{ v-task run }
define-command v-test -docstring 'Test V project' %{ v-task test }
define-command v-test-nearest -docstring 'Run the test function above the cursor in this V test file' %{
  evaluate-commands %sh{
    file=$kak_buffile
    case "$file" in
      *_test.v) ;;
      *) echo "fail 'Open a _test.v file to run a test at the cursor'"; exit ;;
    esac
    [ "$kak_modified" = false ] || {
      echo "fail 'Save the test file before running a test at the cursor'"
      exit
    }
    [ -f "$file" ] || { echo "fail 'Save the test file first'"; exit; }
    file=$(readlink -f "$file")
    test_name=$(awk -v cursor="$kak_cursor_line" '
      /^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+test_[A-Za-z0-9_]+[[:space:]]*\(/ {
        name = $0
        sub(/^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+/, "", name)
        sub(/[[:space:]]*\(.*/, "", name)
        if (NR <= cursor) before = name
        else if (after == "") after = name
      }
      END { if (before != "") print before; else print after }
    ' "$file")
    [ -n "$test_name" ] || { echo "fail 'No test_ function found in this file'"; exit; }
    directory=${file%/*}
    root=$directory
    current=$directory
    while :; do
      if [ -f "$current/v.mod" ] || [ -d "$current/.git" ]; then
        root=$current
        break
      fi
      parent=${current%/*}
      [ -n "$parent" ] || parent=/
      [ "$parent" != "$current" ] || break
      current=$parent
    done
    shell_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    shell_command="cd $(shell_quote "$root") && printf 'V task output\\n' && $kak_opt_v_test_file_command -run-only $(shell_quote "$test_name") $(shell_quote "$file")"
    printf 'set-option global v_last_test_command %s\n' "$(kak_quote "$shell_command")"
    printf 'v-make-command %s\n' "$(kak_quote "$shell_command")"
  }
}
define-command v-repeat-test -docstring 'Rerun the last V test command' %{
  evaluate-commands %sh{
    [ -n "$kak_opt_v_last_test_command" ] || {
      echo "fail 'Run v-test or v-test-nearest first'"
      exit
    }
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'v-make-command %s\n' "$(kak_quote "$kak_opt_v_last_test_command")"
  }
}
define-command -hidden v-prepare-task-errors %{
  evaluate-commands -buffer '*make*' %{
    evaluate-commands %sh{
      pattern=$kak_opt_v_task_error_pattern
      case "$kak_opt_make_error_pattern" in
        ^*) pattern="^([^:\\n]+):(\\d+):(?:(\\d+):)?(${pattern}\\N*)" ;;
      esac
      kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
      printf 'set-option buffer make_error_pattern %s\n' "$(kak_quote "$pattern")"
    }
  }
}
define-command v-next-task-error -docstring 'Jump to the next V compiler error or failed assertion' %{
  v-prepare-task-errors
  make-next-error
}
define-command v-previous-task-error -docstring 'Jump to the previous V compiler error or failed assertion' %{
  v-prepare-task-errors
  make-previous-error
}
define-command v-vet -docstring 'Check project with v vet' %{ v-task vet }

# Less frequent source actions use context-aware submenus.
declare-user-mode v-testing
declare-user-mode v-investigation
declare-user-mode v-maintenance
define-command v-testing-menu -docstring 'Show testing and quality checks' %{ enter-user-mode v-testing }
define-command v-investigation-menu -docstring 'Show additional investigation actions' %{ enter-user-mode v-investigation }
define-command v-maintenance-menu -docstring 'Show IDE maintenance actions' %{ enter-user-mode v-maintenance }

define-command -hidden v-default-source-keys %{
  map window user d ':v-definition<ret>' -docstring 'Go to definition'
  map window user g ':v-peek-definition<ret>' -docstring 'Peek at definition'
  map window v-investigation c ':v-declaration<ret>' -docstring 'Go to declaration'
  map window v-investigation D ':v-type-definition<ret>' -docstring 'Go to type definition'
  map window user r ':v-references<ret>' -docstring 'Find references'
  map window v-investigation m ':v-highlight-references<ret>' -docstring 'Highlight references'
  map window v-investigation z ':v-select-syntax<ret>' -docstring 'Select syntax range'
  map window v-investigation i ':v-implementation<ret>' -docstring 'Find implementations'
  map window user R ':v-rename<ret>' -docstring 'Rename symbol…'
  map window user a ':v-code-actions<ret>' -docstring 'Code actions…'
  map window user o ':v-organize-imports<ret>' -docstring 'Organize imports…'
  map window user h ':v-hover<ret>' -docstring 'Show documentation popup'
  map window user H ':v-doc<ret>' -docstring 'Open documentation'
  map window user ( ':v-signature<ret>' -docstring 'Call signature help'
  map window user s ':v-symbols<ret>' -docstring 'Symbols in this file'
  map window user S ':v-workspace-symbols<ret>' -docstring 'Find project symbols…'
  map window user e ':v-diagnostics<ret>' -docstring 'Project diagnostics'
  map window user n ':v-next-diagnostic<ret>' -docstring 'Next diagnostic'
  map window user N ':v-previous-diagnostic<ret>' -docstring 'Previous diagnostic'
  map window v-investigation j ':v-incoming-calls<ret>' -docstring 'Find callers'
  map window v-investigation k ':v-outgoing-calls<ret>' -docstring 'Find called functions'
  map window v-investigation l ':v-code-lens<ret>' -docstring 'Code lens actions…'
  map window user f ':v-format<ret>' -docstring 'Format buffer'
  map window user b ':v-build<ret>' -docstring 'Build V project'
  map window v-testing C ':v-check-file<ret>' -docstring 'Check file for compile errors'
  map window v-testing t ':v-test<ret>' -docstring 'Test V project'
  map window v-testing T ':v-test-nearest<ret>' -docstring 'Test at cursor'
  map window v-testing x ':v-repeat-test<ret>' -docstring 'Rerun last test'
  map window user ] ':v-next-task-error<ret>' -docstring 'Next task error'
  map window user [ ':v-previous-task-error<ret>' -docstring 'Previous task error'
  map window user u ':v-run-project<ret>' -docstring 'Run V project'
  map window v-testing v ':v-vet<ret>' -docstring 'Check project with v vet'
  map window user p ':v-files<ret>' -docstring 'Open file by path…'
  map window user P ':v-project-files<ret>' -docstring 'Find project file…'
  map window user F ':v-project-path<ret>' -docstring 'Project explorer'
  map window user w ':v-new-view<ret>' -docstring 'Open another view of this file'
  map window user q ':v-close-view<ret>' -docstring 'Close this view'
  map window user t ':v-testing-menu<ret>' -docstring 'Testing…'
  map window user i ':v-investigation-menu<ret>' -docstring 'Investigation…'
  map window user U ':v-maintenance-menu<ret>' -docstring 'Maintenance…'
  map window v-maintenance u ':v-update<ret>' -docstring 'Update and restart V IDE'
  map window v-maintenance r ':v-restart<ret>' -docstring 'Restart V IDE'
  map window v-maintenance w ':v-window-status<ret>' -docstring 'Show pane backend'
  map window v-maintenance S ':v-session-save<ret>' -docstring 'Save recovery checkpoint'
  map window v-maintenance R ':v-restart-recover<ret>' -docstring 'Restart with buffer/view recovery…'
  map window v-maintenance C ':v-cleanup-apply<ret>' -docstring 'Remove unused tools…'
  map window v-maintenance h ':v-health<ret>' -docstring 'IDE health'
  map window v-maintenance s ':v-settings<ret>' -docstring 'IDE settings…'
  map window v-maintenance p ':v-project-settings<ret>' -docstring 'Project run/debug settings'
  map window v-maintenance t ':v-project-targets<ret>' -docstring 'Choose runnable V target…'
  map window v-maintenance c ':v-cleanup<ret>' -docstring 'Preview unused tool cleanup'
  map window v-maintenance x ':v-removal-preview<ret>' -docstring 'Preview IDE removal'
  map window v-maintenance b ':v-rollback<ret>' -docstring 'Restore previous tool stack'
  map window v-maintenance f ':v-repair<ret>' -docstring 'Repair managed installation'
  map window v-maintenance n ':v-check-updates<ret>' -docstring 'Check for a release'
  map window v-maintenance v ':v-update-release<ret>' -docstring 'Update to verified release'
  map window v-maintenance d ':v-diagnostic-report<ret>' -docstring 'Prepare diagnostic report'
  map window v-investigation V ':v-history<ret>' -docstring 'View file at Git revision…'
  map window user / ':v-search<ret>' -docstring 'Search project text…'
}

define-command -hidden v-unbind-keys %{
  try %{ unmap window normal q ':v-recovery-close<ret>' }
  try %{ unmap window user q ':v-recovery-close<ret>' }
  try %{ unmap window normal q ':v-doc-return<ret>' }
  try %{ unmap window normal <esc> ':v-doc-return<ret>' }
  try %{ unmap window user q ':v-doc-return<ret>' }
  try %{ unmap window user <esc> ':v-doc-return<ret>' }
  try %{ unmap window user <ret> ':v-tree-action open<ret>' }
  try %{ unmap window user l ':v-tree-action expand<ret>' }
  try %{ unmap window user h ':v-tree-action collapse<ret>' }
  try %{ unmap window user p ':v-tree-action preview<ret>' }
  try %{ unmap window user . ':v-tree-hidden<ret>' }
  try %{ unmap window user r ':v-tree-refresh<ret>' }
  try %{ unmap window user q ':v-tree-close<ret>' }
  try %{ unmap window v-testing C ':v-check-file<ret>' }
  try %{ unmap window v-testing t ':v-test<ret>' }
  try %{ unmap window v-testing T ':v-test-nearest<ret>' }
  try %{ unmap window v-testing x ':v-repeat-test<ret>' }
  try %{ unmap window v-testing v ':v-vet<ret>' }
  try %{ unmap window v-investigation c ':v-declaration<ret>' }
  try %{ unmap window v-investigation D ':v-type-definition<ret>' }
  try %{ unmap window v-investigation i ':v-implementation<ret>' }
  try %{ unmap window v-investigation m ':v-highlight-references<ret>' }
  try %{ unmap window v-investigation z ':v-select-syntax<ret>' }
  try %{ unmap window v-investigation j ':v-incoming-calls<ret>' }
  try %{ unmap window v-investigation k ':v-outgoing-calls<ret>' }
  try %{ unmap window v-investigation l ':v-code-lens<ret>' }
  try %{ unmap window v-investigation V ':v-history<ret>' }
  try %{ unmap window v-maintenance u ':v-update<ret>' }
  try %{ unmap window v-maintenance r ':v-restart<ret>' }
  try %{ unmap window v-maintenance w ':v-window-status<ret>' }
  try %{ unmap window v-maintenance S ':v-session-save<ret>' }
  try %{ unmap window v-maintenance R ':v-restart-recover<ret>' }
  try %{ unmap window v-maintenance C ':v-cleanup-apply<ret>' }
  try %{ unmap window v-maintenance h ':v-health<ret>' }
  try %{ unmap window v-maintenance s ':v-settings<ret>' }
  try %{ unmap window v-maintenance p ':v-project-settings<ret>' }
  try %{ unmap window v-maintenance t ':v-project-targets<ret>' }
  try %{ unmap window v-maintenance c ':v-cleanup<ret>' }
  try %{ unmap window v-maintenance x ':v-removal-preview<ret>' }
  try %{ unmap window v-maintenance b ':v-rollback<ret>' }
  try %{ unmap window v-maintenance f ':v-repair<ret>' }
  try %{ unmap window v-maintenance n ':v-check-updates<ret>' }
  try %{ unmap window v-maintenance v ':v-update-release<ret>' }
  try %{ unmap window v-maintenance d ':v-diagnostic-report<ret>' }
  try %{ unmap window user t ':v-testing-menu<ret>' }
  try %{ unmap window user i ':v-investigation-menu<ret>' }
  try %{ unmap window user U ':v-maintenance-menu<ret>' }
  v-debug-unbind-keys
  try %{ unmap window user r ':v-repeat-task<ret>' }
  try %{ unmap window user q ':v-task-return<ret>' }
  try %{ unmap window user <ret> ':make-jump<ret>' }
  try %{ unmap window user n ':v-results-next<ret>' }
  try %{ unmap window user N ':v-results-previous<ret>' }
  try %{ unmap window user q ':v-results-cancel<ret>' }
  try %{ unmap window user <ret> ':jump<ret>' }
  try %{ unmap window user f ':v-fmt<ret>' }

  try %{ unmap window user d ':v-definition<ret>' }
  try %{ unmap window user g ':v-peek-definition<ret>' }
  try %{ unmap window user c ':v-declaration<ret>' }
  try %{ unmap window user D ':v-type-definition<ret>' }
  try %{ unmap window user r ':v-references<ret>' }
  try %{ unmap window user m ':v-highlight-references<ret>' }
  try %{ unmap window user z ':v-select-syntax<ret>' }
  try %{ unmap window user i ':v-implementation<ret>' }
  try %{ unmap window user R ':v-rename<ret>' }
  try %{ unmap window user a ':v-code-actions<ret>' }
  try %{ unmap window user o ':v-organize-imports<ret>' }
  try %{ unmap window user h ':v-hover<ret>' }
  try %{ unmap window user H ':v-doc<ret>' }
  try %{ unmap window user ( ':v-signature<ret>' }
  try %{ unmap window user s ':v-symbols<ret>' }
  try %{ unmap window user S ':v-workspace-symbols<ret>' }
  try %{ unmap window user e ':v-diagnostics<ret>' }
  try %{ unmap window user n ':v-next-diagnostic<ret>' }
  try %{ unmap window user N ':v-previous-diagnostic<ret>' }
  try %{ unmap window user j ':v-incoming-calls<ret>' }
  try %{ unmap window user k ':v-outgoing-calls<ret>' }
  try %{ unmap window user l ':v-code-lens<ret>' }
  try %{ unmap window user f ':v-format<ret>' }
  try %{ unmap window user b ':v-build<ret>' }
  try %{ unmap window user C ':v-check-file<ret>' }
  try %{ unmap window user t ':v-test<ret>' }
  try %{ unmap window user T ':v-test-nearest<ret>' }
  try %{ unmap window user x ':v-repeat-test<ret>' }
  try %{ unmap window user ] ':v-next-task-error<ret>' }
  try %{ unmap window user [ ':v-previous-task-error<ret>' }
  try %{ unmap window user u ':v-run-project<ret>' }
  try %{ unmap window user v ':v-vet<ret>' }
  try %{ unmap window user p ':v-files<ret>' }
  try %{ unmap window user P ':v-project-files<ret>' }
  try %{ unmap window user F ':v-project-path<ret>' }
  try %{ unmap window user w ':v-new-view<ret>' }
  try %{ unmap window user q ':v-close-view<ret>' }
  try %{ unmap window user U ':v-update<ret>' }
  try %{ unmap window user V ':v-history<ret>' }
  try %{ unmap window user / ':v-search<ret>' }
}

# Debugging uses a V helper and the standard Debug Adapter Protocol.
declare-option bool v_debug_enabled true
declare-option bool v_debug_pretty_print true
declare-option bool v_debug_status true
declare-option -hidden bool v_debug_status_visible false
declare-option str v_debug_adapter gdb
declare-option str-list v_debug_adapter_args -q -nx --interpreter=dap
declare-option str v_debug_build_command 'v -g -cc gcc'
declare-option bool v_debug_build true
declare-option str v_debug_program
declare-option str v_debug_cwd
declare-option str-list v_debug_args
declare-option str-to-str-map v_debug_env
declare-option str v_debug_entry
declare-option bool v_debug_break_on_failure true
declare-option -hidden str v_debug_directory
declare-option -hidden str v_debug_phase idle
declare-option -hidden bool v_debug_has_watches false
declare-option -hidden str v_debug_message
declare-option -hidden bool v_debug_source false
declare-option -hidden int v_debug_current_line 0
declare-option -hidden line-specs v_debug_breakpoint_lines

define-command -hidden v-debug-require-inactive %{
  evaluate-commands %sh{
    case "$kak_opt_v_debug_phase" in
      building|starting|running|stopped) echo "fail 'Stop debugging with v-debug-stop before updating or restarting'" ;;
    esac
  }
}

define-command -hidden -params 1.. v-debug-call %{
  evaluate-commands %sh{
    # Referencing these values makes Kakoune export them to the V helper.
    : "$kak_buffile" "$kak_modified" "$kak_client" "$kak_opt_v_debug_adapter" \
      "$kak_quoted_opt_v_debug_adapter_args" "$kak_opt_v_debug_build_command" \
      "$kak_opt_v_debug_pretty_print" "$kak_opt_v_debug_build" "$kak_opt_v_debug_program" "$kak_opt_v_debug_cwd" \
      "$kak_opt_v_project_target" "$kak_quoted_opt_v_debug_args" "$kak_quoted_opt_v_debug_env" "$kak_opt_v_debug_entry" "$kak_opt_v_debug_break_on_failure"
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/debug.sh
    directory=$kak_opt_v_debug_directory
    if [ -z "$directory" ]; then
      identity=$(printf %s "$kak_session" | cksum | cut -d ' ' -f 1)
      directory=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak/debug-$identity
    fi
    mkdir -p "$directory"
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'set-option global v_debug_directory %s\n' "$(kak_quote "$directory")"
    if [ "$1" = start ]; then
      output=$("$helper" configure "$directory") || { printf '%s\n' "$output"; exit; }
      nohup "$helper" run "$directory" > "$directory/daemon.log" 2>&1 < /dev/null &
      daemon=$!
      attempts=0
      while kill -0 "$daemon" 2>/dev/null; do
        "$helper" active "$directory" && break
        attempts=$((attempts + 1))
        [ "$attempts" -lt 100 ] || break
        sleep 0.02
      done
      printf 'set-option global v_debug_phase building\necho %s\n' "$(kak_quote 'Building the debug target; output opens automatically')"
    else
      shift
      "$helper" queue "$directory" "$@"
    fi
  }
}
define-command v-debug -docstring 'Build and launch the V project or current test under GDB' %{
  evaluate-commands %sh{
    case "$kak_opt_filetype" in v-debug-*) echo v-debug-return ;; esac
  }
  evaluate-commands %sh{ [ "$kak_opt_v_debug_enabled" = true ] || echo "fail 'Debugging is disabled; set v_debug_enabled true to enable it'" }
  evaluate-commands -buffer * %{ evaluate-commands %sh{
    if [ "$kak_opt_filetype" = v ] && [ -n "$kak_buffile" ] && [ "$kak_modified" = true ]; then
      echo "fail 'Save modified V buffers before launching the debugger'"
    fi
  } }
  v-debug-call start
  v-debug-output
}
define-command v-debug-breakpoint -docstring 'Toggle a breakpoint on the current saved source line' %{ v-debug-call action toggle %val{buffile} %val{cursor_line} }
define-command -params 1 v-debug-breakpoint-if -docstring 'Toggle a conditional breakpoint on the current line' %{ v-debug-call action toggle %val{buffile} %val{cursor_line} %arg{1} }
define-command v-debug-continue -docstring 'Continue the paused debug program' %{ v-debug-call action continue }
define-command v-debug-next -docstring 'Step over the current source line' %{ v-debug-call action next }
define-command v-debug-step-in -docstring 'Step into the current function' %{ v-debug-call action stepIn }
define-command v-debug-step-out -docstring 'Finish the current function' %{ v-debug-call action stepOut }
define-command v-debug-run-to-cursor -docstring 'Continue to a one-time breakpoint at the cursor' %{
  evaluate-commands %sh{
    [ "$kak_opt_v_debug_phase" = stopped ] || { echo "fail 'Pause debugging before running to the cursor'"; exit; }
    [ "$kak_modified" = false ] && [ -n "$kak_buffile" ] && [ -f "$kak_buffile" ] && [ "$kak_opt_readonly" = false ] || { echo "fail 'Run to cursor requires an unmodified saved source file'"; exit; }
  }
  v-debug-call action runToCursor %val{buffile} %val{cursor_line}
}
define-command v-debug-pause -docstring 'Pause the running debug program' %{ v-debug-call action pause }
define-command v-debug-stop -docstring 'Stop debugging and terminate the launched program' %{ v-debug-call action stop }
define-command v-debug-evaluate -docstring 'Evaluate a debugger expression in the selected stack frame' %{ prompt 'Debug expression: ' %{ v-debug-call action evaluate %val{text} } }
define-command v-debug-watch -docstring 'Watch an expression at subsequent stops' %{ prompt 'Watch expression: ' %{ v-debug-call action watch %val{text} } }
define-command -params 0..1 v-debug-unwatch -docstring 'Remove a watched debugger expression' %{
  evaluate-commands %sh{
    if [ "$#" -eq 0 ]; then
      echo "prompt 'Remove watch expression: ' %{ v-debug-call action unwatch %val{text} }"
    else
      printf "v-debug-call action unwatch '%s'\n" "$(printf %s "$1" | sed "s/'/''/g")"
    fi
  }
}
define-command v-debug-console -docstring 'Run a native debugger command' %{ prompt 'Debugger command: ' %{ v-debug-call action console %val{text} } }
define-command v-debug-input -docstring 'Send a line of input to the debug program' %{
  evaluate-commands %sh{
    [ "$kak_opt_v_debug_phase" = running ] || { echo "fail 'Program input is available while running; continue the debugger first'"; exit; }
    echo "prompt 'Program input: ' %{ v-debug-call action input %val{text} }"
  }
}
declare-user-mode v-debug
define-command v-debug-menu -docstring 'Show available debugging actions' %{ enter-user-mode v-debug }
define-command -hidden v-debug-accept %{
  evaluate-commands %sh{
    case "$kak_opt_filetype" in
      v-debug-output) echo v-debug-input ;;
      *) echo v-debug-select ;;
    esac
  }
}

define-command -hidden -params 2 v-debug-render %{
  try %{
    evaluate-commands -buffer %arg{1} -save-regs v %{
      set-option buffer readonly false
      set-register v %arg{2}
      execute-keys -draft '%"vR'
      set-option buffer readonly true
    }
  }
}
define-command -hidden -params 3 v-debug-location %{
  try %{
    evaluate-commands -client %arg{1} %{
      edit -existing %arg{2} %arg{3}
      set-option buffer v_debug_source true
      select %arg{3}.1,%arg{3}.1
    }
  }
}
define-command -hidden -params 1 v-debug-show %{
  evaluate-commands %sh{
    directory=$kak_opt_v_debug_directory
    [ -n "$directory" ] || { echo "fail 'Launch the debugger or set a breakpoint first'"; exit; }
    name=$1
    kak_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'edit -scratch %s\n' "$(kak_quote "*v-debug-$name*")"
    printf 'set-option buffer readonly false\n'
    printf 'set-register v %s\n' "$(kak_quote "$(cat "$directory/$name.txt" 2>/dev/null || true)")"
    printf 'execute-keys '\''%%"vR'\''\n'
    printf 'set-option buffer filetype v-debug-%s\nset-option buffer readonly true\nv-refresh-keys\n' "$name"
  }
}
define-command v-debug-stack -docstring 'Browse debugger stack frames' %{ evaluate-commands -save-regs v %{ v-debug-show stack } }
define-command v-debug-variables -docstring 'Browse variables in the selected frame' %{ evaluate-commands -save-regs v %{ v-debug-show variables } }
define-command v-debug-output -docstring 'Show debugger and program output' %{ evaluate-commands -save-regs v %{ v-debug-show output } }
define-command v-debug-breakpoints -docstring 'Show configured breakpoints' %{ evaluate-commands -save-regs v %{ v-debug-show breakpoints } }
define-command v-debug-return -docstring 'Return to the debug source location' %{
  evaluate-commands %sh{
    directory=$kak_opt_v_debug_directory
    source=$(readlink -f "$kak_opt_v_plugin_source")
    "${source%/rc/vlang.kak}/scripts/debug.sh" location "$directory"
  }
}
define-command -hidden -params 1 v-debug-panel-row %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    "${source%/rc/vlang.kak}/scripts/debug.sh" panel-row "$kak_opt_v_debug_directory" "$kak_opt_filetype" "$1" "$kak_cursor_line"
  }
}
define-command v-debug-delete -docstring 'Remove the selected watch or breakpoint' %{ v-debug-panel-row delete }
define-command -hidden v-debug-select %{
  evaluate-commands %sh{
    [ "$kak_opt_filetype" != v-debug-breakpoints ] || echo 'v-debug-panel-row open'
  }
  evaluate-commands -draft -save-regs v %{
    execute-keys 'x"vy'
    evaluate-commands %sh{
      line=$kak_reg_v
      case "$kak_opt_filetype" in
        v-debug-stack) number=${line%%:*}; action=frame ;;
        v-debug-variables) number=${line%%|*}; action=expand ;;
        *) exit ;;
      esac
      case "$number" in ''|*[!0-9]*) exit ;; esac
      printf 'v-debug-call action %s %s\n' "$action" "$number"
    }
  }
}
define-command -hidden v-debug-status %{
  evaluate-commands %sh{
    suffix='  [debug: %opt{v_debug_phase}]'
    show=false
    if [ "$kak_opt_v_debug_status" = true ]; then
      case "$kak_opt_v_debug_phase:$kak_opt_filetype:$kak_opt_v_debug_source" in
        building:v:*|starting:v:*|running:v:*|stopped:v:*|building:v-debug-*|starting:v-debug-*|running:v-debug-*|stopped:v-debug-*|building:*:true|starting:*:true|running:*:true|stopped:*:true) show=true ;;
      esac
    fi
    if [ "$show" = true ] && [ "$kak_opt_v_debug_status_visible" != true ]; then
      printf "set-option -add window modelinefmt '%s'\nset-option window v_debug_status_visible true\n" "$suffix"
    elif [ "$show" = false ] && [ "$kak_opt_v_debug_status_visible" = true ]; then
      current=$kak_opt_modelinefmt
      case "$current" in
        *"$suffix") printf "set-option window modelinefmt '%s'\n" "$(printf %s "${current%"$suffix"}" | sed "s/'/''/g")" ;;
      esac
      echo 'set-option window v_debug_status_visible false'
    fi
  }
}
hook -group v-debug-status global WinDisplay .* %{ v-debug-status }
hook -group v-debug-status global WinSetOption (v_debug_phase|v_debug_status|filetype)=.* %{ v-debug-status }
face global VDebugCurrent default,yellow
face global VDebugBreakpoint red
define-command -hidden v-debug-marks %{
  evaluate-commands %sh{
    [ "$kak_opt_filetype" = v ] && [ -n "$kak_opt_v_debug_directory" ] && [ -n "$kak_buffile" ] || exit
    source=$(readlink -f "$kak_opt_v_plugin_source")
    "${source%/rc/vlang.kak}/scripts/debug.sh" marks "$kak_opt_v_debug_directory" "$kak_buffile"
  }
}
hook -group v-debug global WinDisplay .* %{ v-debug-marks }
hook -group v-debug global WinSetOption filetype=v %{
  add-highlighter window/v-debug-current line '%opt{v_debug_current_line}' VDebugCurrent
  add-highlighter window/v-debug-breakpoints flag-lines VDebugBreakpoint v_debug_breakpoint_lines
  hook -once -always window WinSetOption filetype=.* %{
    try %{ remove-highlighter window/v-debug-current }
    try %{ remove-highlighter window/v-debug-breakpoints }
  }
}
hook -group v-debug global WinSetOption filetype=v-debug-.* %{
  map window normal <tab> j -docstring 'Next debug row'
  map window normal <s-tab> k -docstring 'Previous debug row'
  evaluate-commands %sh{
    case "$kak_opt_filetype" in
      v-debug-stack) label='Open selected stack frame' ;;
      v-debug-variables) label='Expand selected value' ;;
      v-debug-breakpoints) label='Open breakpoint source' ;;
      v-debug-output) label='Send program input' ;;
    esac
    printf "map window normal <ret> ':v-debug-accept<ret>' -docstring '%s'\n" "$label"
  }
  map window normal q ':v-debug-return<ret>' -docstring 'Return to debug source'
  evaluate-commands %sh{
    case "$kak_opt_filetype" in v-debug-breakpoints|v-debug-variables)
      echo "map window normal <del> ':v-debug-delete<ret>' -docstring 'Remove selected breakpoint or watch'" ;;
    esac
  }
  hook -once -always window WinSetOption filetype=.* %{
    try %{ unmap window normal <tab> j }
    try %{ unmap window normal <s-tab> k }
    try %{ unmap window normal <ret> ':v-debug-accept<ret>' }
    try %{ unmap window normal q ':v-debug-return<ret>' }
    try %{ unmap window normal <del> ':v-debug-delete<ret>' }
  }
}
hook -group v-debug global KakEnd .* %{ try %{ v-debug-stop } }

define-command -hidden v-debug-unbind-keys %{
  try %{ unmap window user B ':v-debug-menu<ret>' }
  try %{ unmap window user <ret> ':v-debug-input<ret>' }
  try %{ unmap window user 'B' ':v-debug<ret>' }
  try %{ unmap window user '!' ':v-debug-breakpoint<ret>' }
  try %{ unmap window user G ':v-debug-run-to-cursor<ret>' }
  try %{ unmap window user 'E' ':v-debug-continue<ret>' }
  try %{ unmap window user 'O' ':v-debug-next<ret>' }
  try %{ unmap window user 'I' ':v-debug-step-in<ret>' }
  try %{ unmap window user 'A' ':v-debug-step-out<ret>' }
  try %{ unmap window user 'K' ':v-debug-pause<ret>' }
  try %{ unmap window user 'Z' ':v-debug-stop<ret>' }
  try %{ unmap window user 'M' ':v-debug-stack<ret>' }
  try %{ unmap window user 'L' ':v-debug-variables<ret>' }
  try %{ unmap window user 'Q' ':v-debug-output<ret>' }
  try %{ unmap window user '?' ':v-debug-evaluate<ret>' }
  try %{ unmap window user W ':v-debug-watch<ret>' }
  try %{ unmap -- window user '-' ':v-debug-unwatch<ret>' }
  try %{ unmap window user J ':v-debug-input<ret>' }
  try %{ unmap window user ':' ':v-debug-console<ret>' }
  try %{ unmap window user Y ':v-debug-breakpoints<ret>' }
  try %{ unmap window user q ':v-debug-return<ret>' }
  try %{ unmap window user <ret> ':v-debug-select<ret>' }
  try %{ unmap window v-debug 'B' ':v-debug<ret>' }
  try %{ unmap window v-debug '!' ':v-debug-breakpoint<ret>' }
  try %{ unmap window v-debug G ':v-debug-run-to-cursor<ret>' }
  try %{ unmap window v-debug 'E' ':v-debug-continue<ret>' }
  try %{ unmap window v-debug 'O' ':v-debug-next<ret>' }
  try %{ unmap window v-debug 'I' ':v-debug-step-in<ret>' }
  try %{ unmap window v-debug 'A' ':v-debug-step-out<ret>' }
  try %{ unmap window v-debug 'K' ':v-debug-pause<ret>' }
  try %{ unmap window v-debug 'Z' ':v-debug-stop<ret>' }
  try %{ unmap window v-debug 'M' ':v-debug-stack<ret>' }
  try %{ unmap window v-debug 'L' ':v-debug-variables<ret>' }
  try %{ unmap window v-debug 'Q' ':v-debug-output<ret>' }
  try %{ unmap window v-debug '?' ':v-debug-evaluate<ret>' }
  try %{ unmap window v-debug W ':v-debug-watch<ret>' }
  try %{ unmap -- window v-debug '-' ':v-debug-unwatch<ret>' }
  try %{ unmap window v-debug J ':v-debug-input<ret>' }
  try %{ unmap window v-debug ':' ':v-debug-console<ret>' }
  try %{ unmap window v-debug Y ':v-debug-breakpoints<ret>' }
  try %{ unmap window v-debug q ':v-debug-return<ret>' }
  try %{ unmap window v-debug <ret> ':v-debug-select<ret>' }
}
define-command -hidden v-debug-bind-keys %{
  evaluate-commands %sh{
    mode=v-debug
    phase=$kak_opt_v_debug_phase
    case "$phase" in building|starting|running|stopped) mode=user ;; esac
    case "$kak_opt_filetype" in v-debug-*) mode=user ;; *)
      [ "$kak_opt_v_debug_source" != true ] || [ "$kak_opt_filetype" = v ] || mode=user ;;
    esac
    map_key() {
      if [ "$mode" = v-debug ]; then
        printf "map window user B ':v-debug-menu<ret>' -docstring 'Debugging…'\n"
      fi
      printf "map -docstring '%s' -- window %s '%s' ':%s<ret>'\n" "$3" "$mode" "$1" "$2"
    }
    phase=$kak_opt_v_debug_phase
    if [ "$mode" = user ] && [ -n "$kak_opt_v_debug_directory" ] && [ "$kak_opt_v_debug_enabled" = true ]; then
      case "$phase" in idle|failed|exited) map_key B v-debug 'Relaunch debugger' ;; esac
    fi
    if [ "$kak_opt_v_debug_enabled" = true ] && [ "$kak_modified" = false ] && [ "$kak_opt_filetype" = v ] && [ -n "$kak_buffile" ] && [ -f "$kak_buffile" ]; then
      if command -v "$kak_opt_v_debug_adapter" >/dev/null 2>&1; then
        case "$phase" in running) ;; *) map_key '!' v-debug-breakpoint 'Toggle breakpoint' ;; esac
        map_key Y v-debug-breakpoints 'Breakpoints'
        case "$phase" in idle|failed|exited)
          label='Build and debug'
          [ "$kak_opt_v_debug_build" != false ] || label='Debug executable'
          case "$kak_buffile" in *_test.v) label='Debug V test' ;; esac
          map_key B v-debug "$label"
          ;; esac
      fi
    fi
    if [ -n "$kak_opt_v_debug_directory" ]; then map_key Q v-debug-output 'Program and debugger output'; fi
    case "$phase" in
      building|starting|running|stopped)
        map_key Z v-debug-stop 'Stop debugging'
        map_key Q v-debug-output 'Program and debugger output'
        ;;
    esac
    case "$phase" in
      stopped)
        map_key E v-debug-continue 'Continue debugging'
        map_key O v-debug-next 'Step over'
        map_key I v-debug-step-in 'Step into'
        map_key A v-debug-step-out 'Step out'
        if [ "$kak_modified" = false ] && [ "$kak_opt_readonly" = false ] && [ -n "$kak_buffile" ] && [ -f "$kak_buffile" ]; then
          map_key G v-debug-run-to-cursor 'Run to cursor'
        fi
        map_key M v-debug-stack 'Stack frames'
        map_key L v-debug-variables 'Variables and watches'
        map_key '?' v-debug-evaluate 'Evaluate expression'
        map_key W v-debug-watch 'Add watch…'
        [ "$kak_opt_v_debug_has_watches" != true ] || map_key '-' v-debug-unwatch 'Remove watch'
        map_key ':' v-debug-console 'Debugger command'
        ;;
      running)
        map_key K v-debug-pause 'Pause debugging'
        map_key J v-debug-input 'Send program input'
        if [ "$kak_opt_filetype" = v-debug-output ]; then
          map_key '<ret>' v-debug-input 'Send program input'
        fi
        ;;
    esac
  }
}

# Refresh on editor context changes without replacing the normal-mode Space mapping.
declare-option bool v_context_keys true
declare-option -hidden str v_keys_context
declare-option -hidden str v_menu_lsp fail
define-command -hidden v-bind-keys %{
  set-option window v_keys_context ''
  v-refresh-keys
}
define-command v-refresh-keys -docstring 'Refresh context-aware V user-menu bindings' %{
  set-option window v_menu_lsp fail
  try %{ set-option window v_menu_lsp %opt{lsp_fail_if_disabled} }
  evaluate-commands %sh{
    context=$kak_opt_filetype
    if [ "$kak_bufname" = '*hover*' ] && [ -n "$kak_opt_v_doc_origin" ]; then context=v-doc; fi
    case "$context" in
      v|v-tree|v-doc|v-recovery|v-debug-stack|v-debug-variables|v-debug-output|v-debug-breakpoints) ;;
      make) if [ "$kak_opt_v_task_output" != true ]; then
        echo "v-unbind-keys; set-option window v_keys_context ''"
        exit
      fi ;;
      lsp-document-symbol|lsp-goto|lsp-diagnostics) [ -n "$kak_opt_v_results_origin" ] || exit ;;
      *)
        case "$kak_opt_v_debug_phase:$kak_opt_v_debug_source" in
          building:true|starting:true|stopped:true|running:true) context=debug-source ;;
          *) [ -z "$kak_opt_v_keys_context" ] || echo "v-unbind-keys; set-option window v_keys_context ''"; exit ;;
        esac ;;
    esac
    saved=false; test_file=false; history=false
    if [ -n "$kak_buffile" ] && [ -f "$kak_buffile" ]; then
      saved=true
      case "$kak_buffile" in *_test.v) [ "$kak_modified" = false ] && grep -Eq '^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+test_[A-Za-z0-9_]+[[:space:]]*\(' "$kak_buffile" && test_file=true ;; esac
      git -C "$(dirname "$kak_buffile")" ls-files --error-unmatch -- "$(basename "$kak_buffile")" >/dev/null 2>&1 && history=true
    fi
    repeat=false; [ -z "$kak_opt_v_last_test_command" ] || repeat=true
    output=$kak_opt_v_task_available
    backend=none
    if [ "$context" = v ]; then
      : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
        "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
        "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
      source=$(readlink -f "$kak_opt_v_plugin_source")
      helper=${source%/rc/vlang.kak}/scripts/windowing.sh
      if [ -x "$helper" ]; then backend=$("$helper" detect "$kak_opt_v_window_backend"); fi
    fi
    update=${VLANG_KAK_RESTART_ALLOWED:-0}
    eval "set -- $kak_quoted_client_list"
    [ "$#" -eq 1 ] || update=0
    case "$kak_opt_v_debug_phase" in building|starting|running|stopped) update=0 ;; esac
    signature="$context:$kak_opt_v_pane_mode:$kak_opt_v_explorer_enabled:$kak_opt_v_tree_is_pane:$kak_opt_v_doc_origin:$saved:$test_file:$history:$repeat:$output:$update:$backend:$kak_opt_readonly:$kak_opt_v_debug_enabled:$kak_opt_v_debug_adapter:$kak_opt_v_debug_build:$kak_modified:$kak_opt_v_context_keys:$kak_opt_v_menu_lsp:$kak_opt_v_task_output:$kak_opt_v_debug_phase:$kak_opt_v_debug_has_watches"
    [ "$signature" != "$kak_opt_v_keys_context" ] || exit
    quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    printf 'v-unbind-keys\nset-option window v_keys_context %s\n' "$(quote "$signature")"
    map_key() { printf 'map window user %s %s -docstring %s\n' "$(quote "$1")" "$(quote ":$2<ret>")" "$(quote "$3")"; }
    if [ "$context" = v ]; then
      echo v-default-source-keys
      if [ "$kak_opt_v_explorer_enabled" != true ]; then
        map_key F v-project-path 'Open project path…'
      fi
      if [ "$backend" = none ] || [ "$kak_opt_v_pane_mode" = off ]; then
        map_key g v-peek-definition 'Open documentation (peek fallback)'
      fi
      if [ "$kak_opt_v_context_keys" = false ]; then
        echo 'v-debug-bind-keys'
        echo 'trigger-user-hook VKeysApplied'
        exit
      fi
      if [ "$backend" = none ] || [ "$kak_opt_v_pane_mode" = off ]; then
        echo 'try %{ unmap window user g }'
      fi
      [ "$backend" != none ] || echo 'try %{ unmap window user w }'
      [ "$output" = true ] || echo "try %{ unmap window user '[' }; try %{ unmap window user ']' }"
      if [ "$kak_opt_v_menu_lsp" != nop ] || [ -z "$kak_buffile" ]; then
        for key in d g r R a o h H '(' s S e n N; do
          printf 'try %%{ unmap window user %s }\n' "$(quote "$key")"
        done
        for key in c D i m z j k l; do
          printf 'try %%{ unmap window v-investigation %s }\n' "$(quote "$key")"
        done
        [ "$history" = true ] || echo 'try %{ unmap window user i }'
        map_key f v-fmt 'Format and save with V'
      fi
      if [ "$kak_opt_readonly" = true ] || [ -z "$kak_buffile" ]; then
        for key in R a o f; do printf 'try %%{ unmap window user %s }\n' "$key"; done
      fi
      [ "$saved" = true ] || {
        for key in b t u; do printf 'try %%{ unmap window user %s }\n' "$key"; done
        for key in C t T v; do printf 'try %%{ unmap window v-testing %s }\n' "$key"; done
      }
      if [ "$test_file" = true ]; then
        map_key T v-test-nearest 'Test at cursor'
        [ "$repeat" = false ] || map_key x v-repeat-test 'Rerun last test'
      else
        echo 'try %{ unmap window v-testing T }'
      fi
      [ "$repeat" = true ] || echo 'try %{ unmap window v-testing x }'
      [ "$history" = true ] || echo 'try %{ unmap window v-investigation V }'
      [ "$update" = 1 ] || echo 'try %{ unmap window v-maintenance u }; try %{ unmap window v-maintenance r }'
      [ "$update" = 1 ] || echo 'try %{ unmap window v-maintenance v }'
      if [ -z "${VLANG_KAK_PREFIX:-}" ]; then
        for key in b f c C x R; do printf 'try %%{ unmap window v-maintenance %s }\n' "$key"; done
      fi

    elif [ "$context" = v-tree ]; then
      map_key '<ret>' 'v-tree-action open' 'Open file or toggle directory'
      map_key l 'v-tree-action expand' 'Expand directory'
      map_key h 'v-tree-action collapse' 'Collapse directory or move to parent'
      map_key p 'v-tree-action preview' 'Preview file'
      map_key '.' v-tree-hidden 'Toggle hidden files'
      map_key r v-tree-refresh 'Refresh project tree'
      label='Return to source'
      [ "$kak_opt_v_tree_is_pane" != true ] || label='Close tree pane'
      map_key q v-tree-close "$label"
    elif [ "$context" = v-recovery ]; then
      map_key q v-recovery-close 'Close recovered output buffer'
      echo "map window normal q ':v-recovery-close<ret>' -docstring 'Close recovered output buffer'"
    elif [ "$context" = v-doc ]; then
      map_key q v-doc-return 'Return to source'
      echo "map window normal q ':v-doc-return<ret>' -docstring 'Return to source'"
      echo "map window normal <esc> ':v-doc-return<ret>' -docstring 'Return to source'"
    elif [ "${context#v-debug-}" != "$context" ]; then
      map_key q v-debug-return 'Return to debug source'
      case "$context" in
        v-debug-stack) map_key '<ret>' v-debug-select 'Open selected stack frame' ;;
        v-debug-variables) map_key '<ret>' v-debug-select 'Expand selected value' ;;
        v-debug-breakpoints) map_key '<ret>' v-debug-select 'Open breakpoint source' ;;
      esac
    elif [ "$context" = debug-source ]; then
      :
    elif [ "$context" = make ]; then
      map_key r v-repeat-task 'Rerun this task'
      map_key q v-task-return 'Return to source'
      map_key '<ret>' make-jump 'Open location on this line'
      map_key ']' v-next-task-error 'Next task error'
      map_key '[' v-previous-task-error 'Previous task error'
      [ "$repeat" = false ] || map_key x v-repeat-test 'Rerun last test'
    else
      map_key n v-results-next 'Next result'
      map_key N v-results-previous 'Previous result'
      map_key q v-results-cancel 'Return to source'
      map_key '<ret>' jump 'Open selected result'
    fi
    [ "$repeat" = true ] || echo 'try %{ unmap window user x }'
    echo 'v-debug-bind-keys'
    case "$context" in
      v) echo 'trigger-user-hook VKeysApplied' ;;
      make) echo 'trigger-user-hook VTaskKeysApplied' ;;
      v-tree) echo 'trigger-user-hook VTreeKeysApplied' ;;
      v-doc) echo 'trigger-user-hook VDocKeysApplied' ;;
      v-debug-*|debug-source) echo 'trigger-user-hook VDebugKeysApplied' ;;
      *) echo 'trigger-user-hook VResultsKeysApplied' ;;
    esac
  }
}
hook -group v-context-menu global ModeChange pop:insert:normal %{ v-refresh-keys }
hook -group v-context-menu global WinSetOption (v_context_keys|v_pane_mode|v_explorer_enabled|readonly|lsp_fail_if_disabled|v_debug_phase|v_debug_has_watches|v_debug_enabled|v_debug_adapter|v_debug_build|v_debug_source)=.* %{ v-refresh-keys }
hook -group v-context-menu global BufWritePost .* %{ v-refresh-keys }
hook -group v-context-menu global WinDisplay .* %{ v-refresh-keys }
hook -group v-context-menu global WinSetOption filetype=(v|v-tree|make|lsp-document-symbol|lsp-goto|lsp-diagnostics|v-debug-.*) %{
  hook -group v-context-menu window NormalIdle .* %{ v-refresh-keys }
  hook -once -always window WinSetOption filetype=.* %{
    v-unbind-keys
    set-option window v_keys_context ''
    remove-hooks window v-context-menu
  }
}

hook -group v-ide global WinSetOption filetype=v %{
  require-module v
  try %{
    set-option buffer lsp_servers %opt{v_lsp_servers}
    lsp-enable-window
  }
  try %{
    set-option buffer lsp_semantic_tokens %opt{v_lsp_semantic_tokens}
    hook window -group v-ide-semantic NormalIdle .* %{ try %{ lsp-semantic-tokens } }
    hook window -group v-ide-semantic InsertIdle .* %{ try %{ lsp-semantic-tokens } }
    hook window -group v-ide-semantic BufReload .* %{ try %{ lsp-semantic-tokens } }
  }
  v-bind-keys
  hook -once -always window WinSetOption filetype=.* %{
    v-unbind-keys
    remove-hooks window v-ide-semantic
  }
}

# Managed lifecycle and project preferences.
declare-option bool v_update_check_enabled false
declare-option str-list v_project_args
declare-option str v_project_cwd
declare-option str v_project_target

define-command -hidden -params 1.. v-maintenance-task %{
  evaluate-commands %sh{
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}" "$kak_opt_v_window_backend"
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/$1.sh
    shift
    shell_quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }
    command=$(shell_quote "$script")
    for argument do command="$command $(shell_quote "$argument")"; done
    printf "v-make-command '%s'\n" "$(printf %s "$command" | sed "s/'/''/g")"
  }
}
define-command v-health -docstring 'Check IDE tools and configuration' %{ v-maintenance-task health }
define-command v-diagnostic-report -docstring 'Prepare a report to review before sharing' %{ v-maintenance-task health --report }
define-command v-repair -docstring 'Repair managed links and launchers using installed tools' %{ v-debug-require-inactive; v-maintenance-task health --repair }
define-command v-rollback -docstring 'Restore the previous managed tool stack' %{ v-debug-require-inactive; v-maintenance-task rollback }
define-command v-cleanup -docstring 'Preview unused managed tool releases' %{ v-maintenance-task cleanup }
define-command v-cleanup-apply -docstring 'Remove unchanged unused tool releases' %{
  prompt 'Remove the releases listed by v-cleanup? Type yes: ' %{ evaluate-commands %sh{
    [ "$kak_text" != yes ] || echo 'v-maintenance-task cleanup --apply'
  } }
}
define-command v-removal-preview -docstring 'Preview removal of this managed installation' %{ v-maintenance-task uninstall }
define-command v-check-updates -docstring 'Check for a published V IDE release' %{ v-maintenance-task check-updates }
define-command v-update-release -docstring 'Update to the latest published, release-tested tool combination' %{ v-update --release }
define-command v-settings-file -docstring 'Open personal V IDE customization' %{
  evaluate-commands %sh{
    config=${VLANG_KAK_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/kak/vlang-user.kak
    printf "edit -existing '%s'\n" "$(printf %s "$config" | sed "s/'/''/g")"
  }
}
define-command -params 2 v-setting -docstring 'Persist an IDE setting and apply it now' %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    "${source%/rc/vlang.kak}/scripts/settings.sh" "$@" || echo "fail 'Setting could not be saved; inspect the error in *debug*'"
  }
}
define-command v-settings -docstring 'Customize IDE behavior and open personal settings' %{
  evaluate-commands %sh{
    toggle() { if [ "$1" = true ]; then echo false; else echo true; fi; }
    printf 'menu '
    printf "'Explorer: %s (toggle)' 'v-setting v_explorer_enabled %s' " "$kak_opt_v_explorer_enabled" "$(toggle "$kak_opt_v_explorer_enabled")"
    printf "'Live search: %s (toggle)' 'v-setting v_live_search_enabled %s' " "$kak_opt_v_live_search_enabled" "$(toggle "$kak_opt_v_live_search_enabled")"
    printf "'Weekly release check: %s (toggle)' 'v-setting v_update_check_enabled %s' " "$kak_opt_v_update_check_enabled" "$(toggle "$kak_opt_v_update_check_enabled")"
    for value in auto always off; do printf "'Pane mode: %s (current: %s)' 'v-setting v_pane_mode %s' " "$value" "$kak_opt_v_pane_mode" "$value"; done
    printf "'Edit all personal settings' 'v-settings-file' 'Project run/debug settings' 'v-project-settings'\n"
  }
}
define-command -hidden -params 1.. v-project-preference %{
  require-module v
  evaluate-commands %sh{
    [ -n "$kak_buffile" ] || { echo "fail 'Open a project file first'"; exit; }
    source=$(readlink -f "$kak_opt_v_plugin_source")
    command=$1; shift
    "${source%/rc/vlang.kak}/scripts/preferences.sh" "$command" "$kak_buffile" "$@"
  }
}
define-command -params .. v-project-arguments -docstring 'Remember run/debug arguments for this project' %{ v-project-preference args %arg{@} }
define-command -params 1 -file-completion v-project-directory -docstring 'Remember the project working directory' %{ v-project-preference cwd %arg{1} }
define-command -params 1 -file-completion v-project-target -docstring 'Remember the V file or directory to run/debug' %{ v-project-preference target %arg{1} }
define-command v-project-reset -docstring 'Clear stored run/debug preferences for this project' %{ v-project-preference reset }
define-command v-project-settings -docstring 'Show project run/debug preferences and how to change them' %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    script=${source%/rc/vlang.kak}/scripts/preferences.sh
    quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/'\\\\''/g")"; }
    command="$(quote "$script") show $(quote "$kak_buffile")"
    printf "v-make-command '%s'\n" "$(printf %s "$command" | sed "s/'/''/g")"
  }
}
define-command v-project-targets -docstring 'List runnable V entry points for this project' %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/preferences.sh
    printf 'menu '
    "$helper" targets "$kak_buffile" | while IFS= read -r path; do
      label=$(printf %s "$path" | sed "s/'/''/g")
      command=$(printf "v-project-target '%s'" "$label" | sed "s/'/''/g")
      printf "'%s' '%s' " "$label" "$command"
    done
    printf "'Choose another V target…' 'prompt -file-completion Target: %{ v-project-target %%val{text} }'\n"
  }
}
hook -group v-project-preferences global WinDisplay .* %{ try %{ evaluate-commands %sh{
  [ "$kak_opt_filetype" = v ] && [ -n "$kak_buffile" ] || exit
  command -v v >/dev/null 2>&1 || exit
  source=$(readlink -f "$kak_opt_v_plugin_source")
  "${source%/rc/vlang.kak}/scripts/preferences.sh" load "$kak_buffile"
} } }

# Recovery snapshots contain buffers and each client's selections. Files on disk
# are never saved by this mechanism; private copies remain available afterward.
declare-option -hidden str v_session_checkpoint
declare-option -hidden int v_session_client_count 0

define-command -hidden -params 1 v-session-save-buffer %{
  evaluate-commands -buffer %arg{1} %{
    evaluate-commands %sh{
      source=$(readlink -f "$kak_opt_v_plugin_source")
      : "$kak_bufname" "$kak_buffile" "$kak_modified" "$kak_opt_filetype" "$kak_opt_readonly" "$kak_opt_v_session_checkpoint"
      "${source%/rc/vlang.kak}/scripts/session-buffer.sh"
    }
  }
}
define-command -hidden -params .. v-session-save-buffers %{
  evaluate-commands %sh{
    for name do printf "v-session-save-buffer '%s'\n" "$(printf %s "$name" | sed "s/'/''/g")"; done
  }
}
define-command -hidden -params 1 v-session-save-client %{
  evaluate-commands -client %arg{1} %{
    evaluate-commands %sh{
      quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
      identity=$(printf %s "$kak_client" | sha256sum | cut -d ' ' -f 1)
      printf 'rename-client %s\nbuffer %s\nselect %s\n' "$(quote "$kak_client")" "$(quote "$kak_bufname")" "$kak_selections_desc" > "$kak_opt_v_session_checkpoint/client-$identity.kak"
      printf '%s\n' "$identity" >> "$kak_opt_v_session_checkpoint/clients"
    }
  }
}
define-command -hidden -params .. v-session-save-clients %{
  evaluate-commands %sh{
    for client do printf "v-session-save-client '%s'\n" "$(printf %s "$client" | sed "s/'/''/g")"; done
  }
}
define-command v-session-save -docstring 'Checkpoint buffers and client positions without saving project files' %{
  v-debug-require-inactive
  evaluate-commands %sh{
    umask 077
    root=${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak/sessions
    mkdir -p "$root"
    directory=$(mktemp -d "$root/checkpoint.XXXXXXXX") || exit
    printf "set-option global v_session_checkpoint '%s'\n" "$(printf %s "$directory" | sed "s/'/''/g")"
  }
  v-session-save-buffers %val{buflist}
  v-session-save-clients %val{client_list}
  evaluate-commands %sh{
    identity=$(printf %s "$kak_client" | sha256sum | cut -d ' ' -f 1)
    printf '%s\n' "$identity" > "$kak_opt_v_session_checkpoint/main-client"
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/windowing.sh
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
    "$helper" detect "$kak_opt_v_window_backend" > "$kak_opt_v_session_checkpoint/backend"
    ln -sfn "$kak_opt_v_session_checkpoint" "${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak/sessions/latest"
    echo 'echo -debug "Session checkpoint saved; v-session-restore reopens it"'
  }
}
define-command -hidden -params .. v-session-require-clean %{
  evaluate-commands %sh{
    for name do
      printf "evaluate-commands -buffer '%s' %%{ evaluate-commands %%sh{ [ \"\$kak_modified\" != true ] || [ \"\$kak_bufname\" = '*debug*' ] || echo \"fail 'Restore in a fresh session or save/checkpoint existing edits first'\" } }\n" "$(printf %s "$name" | sed "s/'/''/g")"
    done
  }
}
define-command -params 0..1 -file-completion v-session-restore -docstring 'Restore the last recovery checkpoint, including scratch and unsaved buffers' %{
  v-session-require-clean %val{buflist}
  evaluate-commands %sh{
    directory=${1:-${XDG_CACHE_HOME:-$HOME/.cache}/vlang.kak/sessions/latest}
    [ -f "$directory/buffers.kak" ] || { echo "fail 'No session checkpoint found'"; exit; }
    # Restore into a fresh session to avoid replacing newer edits.
    printf "source '%s'\n" "$(printf %s "$directory/buffers.kak" | sed "s/'/''/g")"
    identity=$(cat "$directory/main-client")
    printf "source '%s'\n" "$(printf %s "$directory/client-$identity.kak" | sed "s/'/''/g")"
  }
}
define-command -hidden v-restart-recover-now %{
  v-debug-require-inactive
  evaluate-commands %sh{
    [ "${VLANG_KAK_RESTART_ALLOWED:-0}" = 1 ] || echo "fail 'Recovery restart requires the owning kak-v client'"
  }
  v-session-save
  evaluate-commands %sh{
    quote() { printf "'%s'" "$(printf %s "$1" | sed "s/'/''/g")"; }
    directory=$kak_opt_v_session_checkpoint
    identity=$(cat "$directory/main-client")
    backend=$(cat "$directory/backend")
    count=$(wc -l < "$directory/clients")
    if [ "$count" -gt 1 ] && [ "$backend" = none ]; then echo "fail 'Restoring extra views requires a supported pane host; checkpoint saved'"; exit; fi
    printf 'source %s\nsource %s\n' "$(quote "$directory/buffers.kak")" "$(quote "$directory/client-$identity.kak")" > "$VLANG_KAK_RESTART_STATE"
    while IFS= read -r other; do
      [ "$other" != "$identity" ] || continue
      printf 'v-session-open-client %s %s\n' "$(quote "$directory/client-$other.kak")" "$(quote "$backend")" >> "$VLANG_KAK_RESTART_STATE"
    done < "$directory/clients"
    eval "set -- $kak_quoted_client_list"
    for client do
      [ "$client" != "$kak_client" ] || continue
      printf 'evaluate-commands -client %s %%{ quit! }\n' "$(quote "$client")"
    done
  }
  quit! 75
}
define-command -hidden -params 2 v-session-open-client %{
  evaluate-commands %sh{
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/windowing.sh
    : "${kak_client_env_TMUX:-}" "${kak_client_env_TMUX_PANE:-}" "${kak_client_env_ZELLIJ:-}" "${kak_client_env_ZELLIJ_SESSION_NAME:-}" "${kak_client_env_ZELLIJ_PANE_ID:-}" \
      "${kak_client_env_WEZTERM_PANE:-}" "${kak_client_env_WEZTERM_UNIX_SOCKET:-}" "${kak_client_env_KITTY_WINDOW_ID:-}" "${kak_client_env_KITTY_LISTEN_ON:-}" \
      "${kak_client_env_STY:-}" "${kak_client_env_WINDOW:-}" "${kak_client_env_SCREENDIR:-}" "${kak_opt_termcmd:-}" "${kak_client_env_XAUTHORITY:-}" "${kak_client_env_XDG_RUNTIME_DIR:-}" "${kak_client_env_ITERM_SESSION_ID:-}" "${kak_client_env_WAYLAND_DISPLAY:-}" "${kak_client_env_DISPLAY:-}"
    initial="source '$(printf %s "$1" | sed "s/'/''/g")'"
    "$helper" open "$2" right "$kak_session" "$initial" || echo "echo -debug 'A view could not reopen; its checkpoint remains available'"
  }
}
define-command v-restart-recover -docstring 'Restart with recovery copies and recreate additional views' %{
  prompt 'Restart with recovery copies and recreate views? Type yes: ' %{ evaluate-commands %sh{
    [ "$kak_text" != yes ] || echo v-restart-recover-now
  } }
}

define-command -hidden v-update-check-background %{
  evaluate-commands %sh{
    [ "$kak_opt_v_update_check_enabled" = true ] && [ -n "${VLANG_KAK_PREFIX:-}" ] || exit
    source=$(readlink -f "$kak_opt_v_plugin_source")
    helper=${source%/rc/vlang.kak}/scripts/check-updates.sh
    (
      "$helper" --background > /dev/null 2>&1 || exit
      state=$VLANG_KAK_PREFIX/opt/vlang-state
      [ -f "$state/update-status" ] || exit
      grep -q '^Release available:' "$state/update-status" || exit
      cmp -s "$state/update-status" "$state/update-notified" && exit
      text=$(cat "$state/update-status" | sed "s/'/''/g")
      client=$(printf %s "$kak_client" | sed "s/'/''/g")
      printf "evaluate-commands -client '%s' %%{ echo '%s' }\n" "$client" "$text" | kak -p "$kak_session" || exit
      cp "$state/update-status" "$state/update-notified"
    ) > /dev/null 2>&1 < /dev/null &
  }
}
hook -group v-update-check global ClientCreate .* %{ v-update-check-background }

define-command v-recovery-close -docstring 'Close recovered auxiliary output; checkpoint stays available' %{
  evaluate-commands %sh{
    case "$kak_buffile" in /*) echo "fail 'Only recovered scratch output can be closed here'" ;; esac
  }
  delete-buffer!
}
