

# vlang.kak
![Screenshot](https://i.imgur.com/uZ8lCAj.png)

`vlang.kak` enables support for the [V programming language](https://vlang.io/) in the [Kakoune](https://github.com/mawww/kakoune) text editor.
It provides syntax highlighting and includes functions to run your program and review the output.
`v fmt` is available for key mappings and shell commands are customizable.


## Installation

Put this repo in your `autoload` directory. [Read all about installing plugins here.](https://github.com/mawww/kakoune/wiki/Installing-Plugins)

```sh
cd YOUR/AUTOLOAD/DIRECTORY/
git clone https://github.com/antono2/vlang.kak.git
```
Alternatively you can manually source the `vlang.kak` script in your configuration file

```source "path_to/rc/vlang.kak"```


## Usage

You will have syntax highlighting for these V file types:
`v` `vsh` `vv` `v.mod` `c.v`

The plugin provides the commands
-  `v-run` to run v in the `v.mod` directory.
 It looks for the v.mod file in up to 3 parent directories and executes v.
 The output is put into the info box and the \*debug\* buffer.
 Default `"v -keepc -cg run ."`
 
- `v-fmt` to run `v fmt -w` on the current file and save it.
Default `"v fmt -w $kak_buffile"`

- `v-enable-indenting` and `v-disable-indenting` to set the indenting as you wish. Default on.

You can change each shell command by setting one or both options in your `kakrc`
```kak
# Use filetype hook to ensure the options are defined
hook global WinSetOption filetype=v %{
  set-option buffer v_run_command 'YOUR RUN COMMAND'
  set-option buffer v_fmt_command 'YOUR FMT COMMAND'
}
```
**Note**: Be veeery careful when changing the `v_fmt_command`, because it also saves the file and any issue will break your V code. Best test it on the hello world program before adding it to your `kakrc`.
You can set the option from inside Kakoune by typing
`:set-option buffer v_fmt_command 'YOUR FMT COMMAND'`
and then test it by pressing the v_fmt key mapped below. Look at the current value with
`:echo %opt{v_fmt_command}`

## Kakrc

You can map these commands to some keys whenever a V file is opened.</br>For example you could map `<F5> - <F8>` to quickly format -> run -> read output -> go back.

```kak
hook global WinSetOption filetype=v %{
  require-module v
  
  map -docstring "Format and save file"      window normal <F5> ":v-fmt<ret>"
  map -docstring 'Run v in v.mod directory'  window normal <F6> ":v-run<ret>"
  map -docstring 'Switch to *debug* buffer'  window normal <F7> ":buffer *debug*<ret>"
  map -docstring 'Switch to previous buffer' global normal <F8> ":buffer-previous;delete-buffer *debug*<ret>"
  
  # Optionally set true or false for displaying the v_output in the info box and/or debug buffer.
  set-option buffer v_output_to_info_box     true
  set-option buffer v_output_to_debug_buffer true
}
```
Make sure to adapt the keys to your needs.
Also, you can change `v_output_to_info_box` to `false`, if you don't want to see the V output in the info box and the same with `v_output_to_debug_buffer` for the \*debug\* buffer. The default values are set to `true`, so these don't need to be set in your `kakrc`.

## Test Files
This plugin supports the `:alt` command of Kakoune, which switches the buffer to the corresponding V test file and back. You can bind it to a key the same way as described above.
-  currently editing `main.v` will try to open `main_test.v`
-  currently editing `main.c.v` will try to open `main.c_test.v`


## Customizing Colors
Colors are called faces in Kakoune. The predefined faces can be looked up in [the /share/kak/colors directory](https://github.com/mawww/kakoune/blob/master/colors/default.kak).
Changing colors is pretty easy if you can dig through all the regex in `vlang.kak`.</br>Search for `# Highlighters` and below that you can - for example - go to `## TYPES` and change the color for all the types to yellow by changing `0:type` to `0:yellow`. Take a look at the [`<regex> <capture_id>:<face>`](https://github.com/mawww/kakoune/blob/master/doc/pages/highlighters.asciidoc#general-highlighters) function.

## Code Completion
Although this is completely separate from vlang.kak, I can still tell you how to set it up. *Who could stop me?*
*Nobody can stop you with all that raw code editing power at your fingertips!*</br>

The goal is to get [v-analyzer](https://github.com/v-analyzer/v-analyzer/) to work with Kakoune's [kak-lsp](https://github.com/mawww/kakoune-lsp#installation) and get the [full list of capabilities](https://github.com/v-analyzer/v-analyzer/#v-analyzer).</br>
Install `kak-lsp` -> put start command in `kakrc` -> install `v-analyzer` -> configure `kak-lsp` -> ggnore.

First install the [Kakoune language server protocol client](https://github.com/mawww/kakoune-lsp#installation).</br>
**Note**: Get the most current download URL for your system from the [releases](https://github.com/kak-lsp/kak-lsp/releases).

After`kak-lsp` is found in `$PATH`, you can add the start command to your Kakoune configuration file.
```
eval %sh{kak-lsp --kakoune -s $kak_session}
```
**Note**: The [kak-lsp toml config file path](https://github.com/mawww/kakoune-lsp#configuration) can be configured with `--config`.

Then install the v-analyzer as [described here](https://github.com/v-analyzer/v-analyzer/#installation) or build from source, as I've done.
```
# Replace the `workspace` directory with wherever you want to store it
cd ~/workspace
git clone https://github.com/v-analyzer/v-analyzer/
cd v-analyzer
# Update v itself
v up
# Check the v.mod file for dependecies and take care of them
v install
# Build the actual thing
v build.vsh release
```
In any case, afterwards you'll also need to put the `v-analyzer/bin` directory into your PATH variable, so that kak-lsp can execute it. For example with bash you could add this to your `~/.bashrc` or look up how to do it for your system.
```
export PATH="$HOME/PATH_TO_WHERE_YOU_STORED_IT/v-analyzer/bin:$PATH"
```

Now you can restart your terminal to load the new bash configuration.
Test that v-analyzer is found in PATH, e.g. `v-analyzer --help` should print some helpful information.

Finally `kak-lsp` can be configured to run v-analyzer whenever kakoune recognizes a V language file.
Use this in your [configuration toml file](https://github.com/mawww/kakoune-lsp#configuration).
```
[language.v]
# The filetype variable is set in vlang.kak for .v, .vsh, .vv, .c.v under the name "v"
filetypes = ["v"]
roots = ["mod.v"]
command = "v-analyzer"
```
**NOTE**: Assuming `mod.v` is present in any V project, otherwise just add more roots as you wish, e.g. `roots = ["mod.v", ".git/", "my_notes.txt"]`, as long as the file (or directory? not sure) is located at the root directory of your project.

Start your Kakoune on a V file and type `:lsp-enable` to check if all the lsp-commands are defined and finish up your `kakrc`. Here I've added a custom path to the kak-lsp config and set hooks to enable and disable lsp.
```
eval %sh{ kak-lsp --kakoune --config $HOME/PATH_TO_YOUR_CONFIG_TOML/kak-lsp/config.toml -s $kak_session }
# Enable kak-lsp for V files
hook global WinSetOption filetype=v %{ lsp-enable-window }

# Close kak-lsp when kakoune is closed
hook global KakEnd .* lsp-exit
```
You can start typing and switch through the autocomplete suggestions with [CTRL+N] or [CTRL+P].

![V autocompletion](https://i.imgur.com/H1XOSqV.png)
Also check out [SPACE+L] to get a nice list of things you can do with your newly acquired V language server.

The rest is trivial and left to the reader.

