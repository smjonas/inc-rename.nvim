# inc-rename.nvim

A small Neovim plugin that provides a command for LSP renaming with immediate visual
feedback thanks to Neovim's command preview feature.

<div align="center">
<video src="https://user-images.githubusercontent.com/40792180/197186202-d848ba0c-7d3b-4e01-8e99-36ad7d884308.mp4" width="85%">
</div>

## Installation
**This plugin requires at least Neovim 0.8**

Install using your favorite package manager and call the `setup` function.
<details>
    <summary>lazy.nvim</summary>

```lua
{
  "smjonas/inc-rename.nvim",
  config = function()
    require("inc_rename").setup()
  end,
}
```
</details>

<details>
    <summary>packer.nvim</summary>

```lua
use {
  "smjonas/inc-rename.nvim",
  config = function()
    require("inc_rename").setup()
  end,
}
```
</details>

<details>
    <summary>vim-plug</summary>

```vim
Plug 'smjonas/inc-rename.nvim'
```
Somewhere in your init.lua, you will need to call the setup function:
```lua
require("inc_rename").setup()
```
</details>

## Usage
Simply type `:IncRename <new_name>` while your cursor is on an LSP identifier.
You could also create a keymap that types out the command name for you so you only have to
enter the new name:
```lua
vim.keymap.set("n", "<leader>rn", ":IncRename ")
```
If you want to fill in the word under the cursor you can use the following:
```lua
vim.keymap.set("n", "<leader>rn", function()
  return ":IncRename " .. vim.fn.expand("<cword>")
end, { expr = true })
```

<details>
<summary>💥 <code>noice.nvim</code> support</summary>

</br>If you are using [noice.nvim](https://github.com/folke/noice.nvim), you can enable the `inc_rename` preset like this:

```lua
require("noice").setup {
  presets = { inc_rename = true }
}
```

Then simply type the `:IncRename` command (or use the keymap mentioned above).
<div align="center">
<img src="https://user-images.githubusercontent.com/40792180/197182365-31657338-2b17-4996-86b4-002b4c2d837e.png">
</div>
</br>
</details>

<details>
<summary>&#127800; <code>dressing.nvim</code> support</summary>

</br>If you are using [dressing.nvim](https://github.com/stevearc/dressing.nvim),
set the `input_buffer_type` option to `"dressing"`:
```lua
require("inc_rename").setup {
  input_buffer_type = "dressing",
}
```

Then simply type the `:IncRename` command and the new name you enter will automatically be updated in the input buffer as you type.

The result should look something like this:
<div align="center">
<img src="https://user-images.githubusercontent.com/40792180/188309667-0d7e8086-ae48-4a25-8b01-df11d229b8c6.png">
</div>
</br>

> 💡 Tip - Try these `dressing.nvim` settings to position the input box above the
> cursor to not cover the word being renamed (thank you
> [@RaafatTurki](https://github.com/RaafatTurki) for the suggestion!):
```lua
require("dressing").setup {
  input = {
    override = function(conf)
      conf.col = -1
      conf.row = 0
      return conf
    end,
  },
}
```

</details>

## Known issues
There have been reports of `inc-rename` not working with certain plugins and language servers:
- `traces.vim` (see [issue #35](https://github.com/smjonas/inc-rename.nvim/issues/35))
- `custom-elements-languageserver` (see [issue #44](https://github.com/smjonas/inc-rename.nvim/issues/44))

Make sure to uninstall these if you are experiencing issues.

## Customization
You can override the default settings by passing a Lua table to the `setup` function.
The default options are:
```lua
require("inc_rename").setup {
 -- the name of the command
  cmd_name = "IncRename",
   -- the highlight group used for highlighting the identifier's new name
  hl_group = "Substitute",
   -- whether an empty new name should be previewed; if false the command preview will be cancelled instead
  preview_empty_name = false,
   -- whether to display a `Renamed m instances in n files` message after a rename operation
  show_message = true,
   -- whether to save the "IncRename" command in the commandline history (set to false to prevent issues with
   -- navigating to older entries that may arise due to the behavior of command preview)
  save_in_cmdline_history = true,
   -- the type of the external input buffer to use (the only supported value is currently "dressing")
  input_buffer_type = nil,
   -- callback to run after renaming, receives the result table (from LSP handler) as an argument
  post_hook = nil,
}
```

<details>
    <summary>💡 Renaming across multiple files</summary>

</br>When renaming across multiple files, make sure to save all affected buffers with
`:wa`. If the Nvim option `inccommand` is set to `split` (`:set inccommand=split`),
a buffer with information about all identifiers to be renamed will be shown as you type.

Here is an example of how this could look like:
<div align="center">
<img src="https://github.com/smjonas/inc-rename.nvim/assets/40792180/36cf0324-09a1-4b3b-8561-ffe3626d52b1">
</div>

> 💡 Tip - Use `:set cmdwinheight=20` to change the height of the preview window.

</details>
