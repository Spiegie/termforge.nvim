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
            version = self.shortRev or "dev";
            src = self;
            # makes the build fail if the plugin cannot be required
            nvimRequireCheck = "termforge";
          };
          # Shell integration snippets for command notifications, for
          # sourcing from the shell rc:
          #   source ${termforge-shell}/share/termforge/termforge.zsh
          termforge-shell = pkgs.runCommand "termforge-shell" { } ''
            install -Dm644 ${self}/shell/termforge.zsh $out/share/termforge/termforge.zsh
            install -Dm644 ${self}/shell/termforge.bash $out/share/termforge/termforge.bash
            install -Dm644 ${self}/shell/termforge.fish $out/share/termforge/termforge.fish
          '';
          default = self.packages.${system}.termforge-nvim;
        });

      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          snippetDir = "${self.packages.${system}.termforge-shell}/share/termforge";
          # Bare zshrc that only loads the shell integration, so
          # test-drive terminals start with command notifications
          # preloaded.
          zdotdir = pkgs.runCommand "termforge-zdotdir" { } ''
            mkdir -p "$out"
            printf '%s\n' 'source ${snippetDir}/termforge.zsh' > "$out/.zshrc"
          '';
          bashrc = pkgs.writeText "termforge-bashrc" ''
            source ${snippetDir}/termforge.bash
          '';
          # Interactive terminals in the test drive run this wrapper: it
          # starts the user's shell with the integration sourced (a bare
          # shell, without the user's rc). Invocations with arguments
          # (":!cmd", ":terminal {cmd}") pass through untouched.
          testShell = pkgs.writeShellScript "termforge-test-shell" ''
            if [ "$#" -ne 0 ]; then
              exec "''${SHELL:-/bin/sh}" "$@"
            fi
            case "''${SHELL:-/bin/sh}" in
              *zsh)
                export ZDOTDIR="${zdotdir}"
                exec "''${SHELL}" -i
                ;;
              *bash)
                exec "''${SHELL}" --rcfile "${bashrc}" -i
                ;;
              *fish)
                exec "''${SHELL}" --no-config -C "source ${snippetDir}/termforge.fish"
                ;;
              *)
                exec "''${SHELL:-/bin/sh}"
                ;;
            esac
          '';
          # Isolated Neovim for the test drives: only termforge (plus the
          # given extra plugins) is loaded, no user config, no plugin
          # manager. Terminal shells preload the shell integration.
          nvimApp = name: extra: extraInit:
            let
              rtp = extra ++ [ self.packages.${system}.termforge-nvim ];
              prepends = pkgs.lib.concatMapStrings (p: "vim.opt.rtp:prepend(\"${p}\")\n") rtp;
            in
            {
              type = "app";
              program = "${pkgs.writeShellScript name ''
                exec ${pkgs.lib.getExe pkgs.neovim} --noplugin \
                  -u ${pkgs.writeText "termforge-init.lua" ''
                    ${prepends}
                    ${extraInit}
                    require("termforge").setup({})
                    -- Test drive only: route terminals through the wrapper
                    -- that preloads the shell integration.
                    vim.o.shell = "${testShell}"
                  ''} "$@"
              ''}";
            };
        in
        {
          # Test drive: `nix run .#` opens an isolated Neovim with only
          # termforge loaded (no user config, no other plugins). Terminal
          # shells preload the shell integration, so command notifications
          # work there without touching the user's rc files.
          default = nvimApp "termforge-nvim" [ ] "";

          # Same test drive with Telescope installed: the launch and
          # terminal pickers run through Telescope, with previews and the
          # <C-e>/<C-k> picker keys.
          telescope = nvimApp "termforge-telescope"
            [ pkgs.vimPlugins.telescope-nvim pkgs.vimPlugins.plenary-nvim ]
            ''require("telescope").setup({})'';

          # Same test drive with snacks.nvim installed: the pickers run
          # through snacks.picker.
          snacks = nvimApp "termforge-snacks"
            [ pkgs.vimPlugins.snacks-nvim ]
            ''require("snacks").setup({})'';

          # Run the headless test suite against the flake source.
          test = {
            type = "app";
            program = "${pkgs.writeShellScript "termforge-test" ''
              exec ${pkgs.lib.getExe pkgs.neovim} --headless -l ${self}/tests/test.lua
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
              neovim # run tests: nvim --headless -l tests/test.lua
            ];
          };
        });
    };
}
