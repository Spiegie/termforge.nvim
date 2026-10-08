{
  description = "termforge.nvim - small extensions for Neovim's built-in terminal";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          termforge-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "termforge.nvim";
            version = "unstable";
            src = self;
          };
          default = self.packages.${system}.termforge-nvim;
        });

      apps = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          # Test drive: `nix run .#` opens an isolated Neovim with only
          # termforge loaded (no user config, no other plugins).
          default = {
            type = "app";
            program = "${pkgs.writeShellScript "termforge-nvim" ''
              exec ${pkgs.lib.getExe pkgs.neovim} --noplugin \
                -u ${pkgs.writeText "termforge-init.lua" ''
                  vim.opt.rtp:prepend("${self.packages.${system}.termforge-nvim}")
                  require("termforge").setup({})
                ''} "$@"
            ''}";
          };
        });

      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              lua-language-server
              stylua
            ];
          };
        });
    };
}
