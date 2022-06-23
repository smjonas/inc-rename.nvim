# inc-rename.nvim

A small Neovim plugin that provides a command for LSP renaming with immediate visual
feedback thanks to Neovim's command preview feature. Requires Neovim nightly (0.8).

<div align="center">
<video src="https://user-images.githubusercontent.com/40792180/171936247-9a4af4f8-fcc6-4c0c-a230-5d65339cd29c.mp4" width="85%">
</div>

## Installation
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


## Customization
You can override the default settings by passing a Lua table to the `setup` function.
The default options are:
```lua
require("inc_rename.nvim").setup {
  cmd_name = "IncRename", -- the name of the command
  hl_group = "Substitute", -- the highlight group used for highlighting the identifier's new name
  multifile_preview = true, -- whether to enable the command preview across multiple buffers
  show_message = true, -- whether to display a `Renamed m instances in n files` message after a rename operation
}
```
