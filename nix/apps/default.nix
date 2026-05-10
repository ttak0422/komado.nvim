{
  self',
  pkgs,
  ...
}:

{
  # Self-contained nvim launcher for the sample sidebar. We unset $VIMINIT
  # (some users export `lua dofile(...)` from their shell, which would run
  # before any of our setup) and isolate XDG state so the demo can't pollute
  # — or be polluted by — the user's real config. Stock runtime (filetype
  # detection, syntax, etc.) is left intact.
  demo = {
    type = "app";
    program = "${pkgs.writeShellScript "komado-demo" ''
      unset VIMINIT MYVIMRC NVIM_LOG_FILE NVIM_SYSTEM_RPLUGIN_MANIFEST
      export XDG_CONFIG_HOME=/dev/null
      export XDG_DATA_HOME=$(${pkgs.coreutils}/bin/mktemp -d)
      export XDG_STATE_HOME=$(${pkgs.coreutils}/bin/mktemp -d)
      exec ${pkgs.neovim-unwrapped}/bin/nvim \
        --cmd "set termguicolors" \
        --cmd "set rtp+=${self'.packages.komado-nvim}" \
        -c "luafile ${self'.packages.komado-nvim}/examples/sample.lua" \
        -c "KomadoOpen" "$@"
    ''}";
    meta.description = "komado.nvim sample sidebar (header + file info + buffers + marks + clock)";
  };
}
