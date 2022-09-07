# inc-rename.nvim

A small Neovim plugin that provides a command for LSP renaming with immediate visual
feedback thanks to Neovim's command preview feature.

<div align="center">
<video src="https://user-images.githubusercontent.com/40792180/171936247-9a4af4f8-fcc6-4c0c-a230-5d65339cd29c.mp4" width="85%">
</div>

## Installation
**This plugin requires Neovim's nightly version (0.8).**

Install using your favorite package manager and call the `setup` function.
Here is an example using packer.nvim:
```lua
use {
  "smjonas/inc-rename.nvim",
  config = function()
    require("inc_rename").setup()
  end,
}
```

## Usage
Simply type `:IncRename <new_name>` while your cursor is on an LSP identifier.
You could also create a keymap that types out the command name for you so you only have to
enter the new name:
```lua
vim.keymap.set("n", "<leader>rn", ":IncRename ")
```
If you want to prefill the word under the cursor you can use the following:
```lua
vim.keymap.set("n", "<leader>rn", function()
  return ":IncRename " .. vim.fn.expand("<cword>")
end, { expr = true })
```

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

> :bulb: Tip - try these `dressing.nvim` settings to position the input box above the
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

## Customization
You can override the default settings by passing a Lua table to the `setup` function.
The default options are:
```lua
require("inc_rename").setup {
  cmd_name = "IncRename", -- the name of the command
  hl_group = "Substitute", -- the highlight group used for highlighting the identifier's new name
  preview_empty_name = false, -- whether an empty new name should be previewed; if false the command preview will be cancelled instead
  show_message = true, -- whether to display a `Renamed m instances in n files` message after a rename operation
  input_buffer_type = nil, -- the type of the external input buffer to use (the only supported value is currently "dressing")
  post_hook = nil, -- callback to run after renaming, receives the result table (from LSP handler) as an argument
}
```
