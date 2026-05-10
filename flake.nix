{
  description = "komado.nvim - heirline-style declarative sidebars for Neovim";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/default";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (_: {
      systems = import inputs.systems;
      perSystem =
        {
          self',
          system,
          pkgs,
          lib,
          ...
        }:
        {
          packages.komado-nvim = pkgs.vimUtils.buildVimPlugin {
            name = "komado-nvim";
            src = lib.cleanSource ./.;
          };

          checks = {
            pre-commit-check = inputs.git-hooks.lib.${system}.run {
              src = ./.;
              hooks = {
                nixfmt.enable = true;
                statix.enable = true;
                deadnix.enable = true;
                luacheck.enable = true;
                stylua.enable = true;
                selene.enable = true;
              };
            };
          };

          apps = import ./nix/apps {
            inherit inputs self' pkgs;
          };

          devShells.default = pkgs.mkShell {
            inherit (self'.checks.pre-commit-check) shellHook;
            packages = [ ];
          };
        };
    });
}
