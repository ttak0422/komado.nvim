# komado.nvim

A Lua-configured sidebar for Neovim. Compose text, highlights, and interactive rows
with a declarative component tree, and refresh them on Neovim events. Use it to
build a small dashboard or a view of your own data.

Komado provides the sidebar and rendering tools; you supply its content and actions.
It uses one sidebar shared across tabs, reattaching it when you switch tabs.

## Installation

Install `ttak0422/komado.nvim` with your plugin manager. For example, add this spec
to [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "ttak0422/komado.nvim" }
```

No other plugins are required. The example below is tested with Neovim 0.12.5;
compatibility with older versions has not been verified.

## Setup

Run this after the plugin is loaded:

```lua
local komado = require("komado")
local Line = require("komado.dsl").Line

komado.setup({
  window = { position = "left", size = 40, padding = 1 },
  mappings = {
    q = function()
      komado.close()
    end,
  },
  root = {
    Line({ provider = "komado", hl = "Title" }),
    Line({
      update = { "BufEnter", "BufFilePost" },
      provider = function()
        local name = vim.fn.expand("%:t")
        return name ~= "" and name or "[No Name]"
      end,
    }),
  },
})

vim.keymap.set("n", "<leader>k", function()
  komado.toggle({ focus = true })
end, { desc = "Toggle komado" })
```

Press `<leader>k` to open and focus the sidebar, move with `j` / `k`, and press `q`
to close it. Use normal window commands such as `<C-w>p` to return to editing.
These mappings are defined by the example, not installed by default.

`root` stacks components vertically. `Line` renders its children side by side;
`provider` supplies a string or a function returning text, and `hl` sets its
highlight. `update` lists the events that refresh a component. Providers run in
the current tab's editing-window context, so the filename above refers to your
file rather than the sidebar.

## Usage and customization

- `require("komado").open()` opens the sidebar without taking focus. Pass
  `{ focus = true }` to focus it.
- `close()` closes it; `toggle()` switches between open and closed; `redraw()`
  renders it again. Components with `update` reuse cached content until their
  configured event invalidates it.
- Set `window.position = "right"` to change sides. `window.size` accepts a column
  count or a table such as `{ ratio = 0.3, min = 30, max = 60 }`.
- Add `mappings` to a `Line` for row actions. Mouse actions require an explicit
  `<LeftMouse>` mapping and Neovim mouse support to be enabled.

See [the sample configuration](examples/sample.lua) for buffer, Git, mark, and
clock sections, including row actions and automatic updates. These are examples
to copy and adapt, not built-in panels. The sample also defines `:KomadoOpen` and
related commands; the core plugin exposes a [Lua API](lua/komado/init.lua).

## Development

Run the sidebar window regression tests with the local Neovim installation:

```sh
nvim --headless -u NONE -i NONE -l tests/window_width.lua
```

Run `nix flake check` for the configured lint and format checks.
