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
-  `vlang_run` to run v in the `v.mod` directory.
 It looks for the v.mod file in up to 3 parent directories and executes v.
 The output is put into the info box and the \*debug\* buffer.
 Default `"v -keepc -cg run ."`
 
- `vlang_fmt` to run `v fmt -w` on the current file and save it.
Default `"v fmt -w $kak_buffile"`

You can change each shell command by setting one or both options in your `kakrc`
```kak
# Use filetype hook to ensure the options are defined
hook global WinSetOption filetype=v %{
  set-option buffer vlang_run_command 'YOUR RUN COMMAND'
  set-option buffer vlang_fmt_command 'YOUR FMT COMMAND'
}
```
**Note**: Be veeery careful when changing the `vlang_fmt_command`, because it also saves the file and any issue will break your V code. Best test it on the hello world program before adding it to your `kakrc`.
You can set the option from inside Kakoune by typing
`:set-option buffer vlang_fmt_command 'YOUR FMT COMMAND'`
and then test it by pressing the vlang_fmt key mapped below.

## Kakrc

You can map these commands to some keys whenever a V file is opened.</br>For example you could map `<F5> - <F8>` to quickly format -> run -> read output -> go back.

```kak
hook global WinSetOption filetype=v %{
  require-module v
  
  map -docstring "Format and save file"      window normal <F5> ":vlang_fmt<ret>"
  map -docstring 'Run v in v.mod directory'  window normal <F6> ":vlang_run<ret>"
  map -docstring 'Switch to *debug* buffer'  window normal <F7> ":buffer *debug*<ret>"
  map -docstring 'Switch to previous buffer' global normal <F8> ":buffer-previous;delete-buffer *debug*<ret>"
  
  # Optionally set true or false for displaying the vlang_output in the info box and/or debug buffer.
  set-option buffer vlang_output_to_info_box true
  set-option buffer vlang_output_to_debug_buffer true
}
```
Make sure to adapt the keys to your needs.
Also, you can change `vlang_output_to_info_box` to `false`, if you don't want to see the V output in the info box and the same with `vlang_output_to_debug_buffer` for the \*debug\* buffer. The default values are set to `true`, so these don't need to be set in your `kakrc`.

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
**Note**: VLS is early software.

The goal is to get [vlang vls](https://github.com/vlang/vls) to work with Kakoune's [kak-lsp](https://github.com/mawww/kakoune-lsp#installation) and get the [full list of capabilities](https://github.com/vlang/vls/blob/master/CAPABILITIES.md).</br>
Install `kak-lsp` -> put it in `kakrc` -> install `vls` -> configure `kak-lsp` -> configure key mappings.

First install the [Kakoune language server protocol client](https://github.com/mawww/kakoune-lsp#installation).</br>
**Note**: Get the most current download URL for your system from the [releases](https://github.com/kak-lsp/kak-lsp/releases).

After`kak-lsp` is found in `$PATH`, you can add the start script to your Kakoune configuration.
```
eval %sh{kak-lsp --kakoune -s $kak_session}
```
**Note**: The [kak-lsp toml config file](https://github.com/mawww/kakoune-lsp#configuration) path can be configured with `--config`.

Then install the V language server as [described in the README](https://github.com/vlang/vls#via-v-cli-recommended).
```
v ls --install
```
Running it for the first time will give you the message `If you are using this for the first time, please run
  'v ls --install' first to download and install VLS.` So, let's do that.
```
v ls --install
```
Now there should be a new directory `$HOME/.vls` and running `v ls` should give no errors.
If that's the case, you can continue with configuring `kak-lsp` in the next step.

Though on older systems you might get an error like this
```
... /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.34' not found (required by ...
```
There is no fixing this by updating glibc, as it's a system package and changing the version would break the system.</br>
One solution is to [build vls from source](https://github.com/vlang/vls#build-from-source), which then uses the system default.
```
cd ~/.vls
## Clone the project:
git clone https://github.com/vlang/vls && cd vls

## Build the project
## Use "v run build.vsh gcc" if you're compiling VLS with GCC.
v run build.vsh clang

# The binary will be created in the `bin` directory inside the vls folder.
# Move it to ~/.vls/bin and replace the original.
# In case of linux_x64
cp ./bin/vls ../bin/vls_linux_x64
```
Now `kak-lsp` can be configured to recognize the V language.
Use this in your [configuration toml file](https://github.com/mawww/kakoune-lsp#configuration).
```
[language.v]
# The filetype variable is set in vlang.kak for .v, .vsh, .vv, .c.v under the name "v"
filetypes = ["v"]
roots = ["mod.v", ".git/"]
command = "v"
args = ["ls"]
```
Start your Kakoune on a V file and type `:lsp-enable` to check if all the lsp-commands are defined and finish up your `kakrc`.
```
eval %sh{ kak-lsp --kakoune --config $HOME/PATH_TO_YOUR_CONFIG_TOML/kak-lsp/config.toml -s $kak_session }
# Enable kak-lsp for V files
hook global WinSetOption filetype=v %{ lsp-enable-window }

# Close kak-lsp when kakoune is closed
hook global KakEnd .* lsp-exit
# When VLS throws errors after a Kakoune restart is
# when you absolutely, positively, have to kill a process
#hook global KakEnd .* %sh{ kill $(ps ax | grep "kak-lsp" | awk '{print $1}') }
```

You can start typing and switch through the autocomplete suggestions with [Ctrl+n] or [Ctrl+p].
![V autocompletion](https://i.imgur.com/H1XOSqV.png)
The rest is trivial and left to the reader.

