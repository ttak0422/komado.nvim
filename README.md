<h1 align="center">
    komado.nvim
</h1>

> [!CAUTION]
>  Please note that this is currently in an experimental phase. Destructive changes may be apply.

## Development

Run the sidebar window regression tests with the local Neovim installation:

```sh
nvim --headless -u NONE -i NONE -l tests/window_width.lua
```

The tests cover equalization, explicit resizing, and window recreation on both sides
with fixed and ratio-based widths. Run `nix flake check` for the configured lint and
format checks.
