
# vlang.kak
![Screenshot](https://i.imgur.com/uZ8lCAj.png)

`vlang.kak` enables support for the [V programming language](https://vlang.io/) in the [Kakoune](https://github.com/mawww/kakoune) text editor.
It provides syntax highlighting and includes functions to run your program and review the output.
`v fmt` is available for key mappings and shell commands are customizable.


## Installation

### With [plug.kak](https://github.com/andreyorst/plug.kak)

Add this to your `kakrc`:

```kak
plug "antono2/vlang.kak"
```

Source your `kakrc`, or restart Kakoune. Then execute `:plug-install`.
If you don't want to restart Kakoune or source its config, simply run `plug-install antono2/vlang.kak`.

### Without plugin manager

```sh
git clone https://github.com/antono2/vlang.kak.git
```
You can put this repo in your `autoload` directory or manually `source` the `vlang.kak` script in your configuration file.
[Read all about installing plugins here.](https://github.com/mawww/kakoune/wiki/Installing-Plugins)






## Usage

You will have syntax highlighting for these V file types:
`v` `vsh` `vv` `v.mod` `c.v`

The plugin provides the commands
-  `vlang_run` to run v in the `v.mod` directory.
 It looks for the v.mod file in up to 3 parent directories and executes v.
 The output is put into the info box and the \*debug\* buffer.
 Default `"v -keepc -cg run ."`
 
- `vlang_fmt` to run `v fmt -w` on the current file and save it.
Default `"v fmt -w $kak_buffile"`

You can change each shell command by setting one or both options in your `kekrc`
```kak
# Use filetype hook to ensure the options are defined
hook global WinSetOption filetype=v %{
  set-option buffer vlang_run_command 'YOUR RUN COMMAND'
  set-option buffer vlang_fmt_command 'YOUR FMT COMMAND'
}
```
**Note**: Be veeery careful when changing the `vlang_fmt_command`, because it also saves the file and any issue will break your V code. Best test it on the hello world program before adding it to your `kekrc`.
You can set the option from inside Kakoune by typing
`:set-option buffer vlang_fmt_command 'YOUR FMT COMMAND'`
and then test it by pressing the vlang_fmt key mapped below.

## Kakrc

It might be useful to map the commands to some keys whenever a V file is opened.

```kak
hook global WinSetOption filetype=v %{
  require-module v
  
  map -docstring "Save current file"         window normal <F5> ":vlang_fmt<ret>"
  map -docstring 'Run v in v.mod directory'  window normal <F6> ":vlang_run<ret>"
  map -docstring 'Switch to debug buffer'    window normal <F7> ":buffer *debug*<ret>"
  map -docstring 'Switch to previous buffer' global normal <F8> ":buffer-previous;delete-buffer *debug*<ret>"
  
  # set true or false for displaying the vlang_output in the info box and/or debug buffer.
  set-option buffer vlang_output_to_info_box true
  set-option buffer vlang_output_to_debug_buffer true
}
```
Make sure to adapt the keys to your needs.
Also, you can change `vlang_output_to_info_box` to `false`, if you don't want to see the V output in the info box and the same with `vlang_output_to_debug_buffer` for the \*debug\* buffer.

## Customizing Colors
One may want to change some colors around in order to make them terminal independent. The predefined faces can be looked up [here](https://github.com/mawww/kakoune/blob/master/colors/default.kak), where `default` means terminal color.
Changing colors is pretty easy if you can dig through all the regex in `vlang.kak`. Search for `# Highlighters` and below that you can - for example - go to `## TYPES` and change the color for all the types to yellow by changing `1:type` to `1:yellow`. The function `<regex> <capture_id>:<face>` is described [here.](https://github.com/mawww/kakoune/blob/master/doc/pages/highlighters.asciidoc#general-highlighters)

