# termforge.nvim

Small extensions for Neovim's built-in terminal. Fire predefined commands into
the terminal you are already in, and jump between your terminal buffers.

Unlike task runners, termforge does not spawn terminals or background jobs. It
serves **the terminal you navigated to**: navigate your shell where you want,
pick a command, edit it, fire it.

## Modules

| Module | What it does | Default keymap |
|---|---|---|
| `termforge.launch` | Command launcher: pick → edit → send into the current terminal | `<leader>j` |
| `termforge.buffers` | Picker listing only terminal buffers | `<leader>tb` |

Both keymaps work in Normal mode and Terminal mode. Additionally, `<Esc>`
leaves Terminal mode back to Normal mode (like leaving Insert mode); set
`keymaps.terminal_esc = false` if you want Esc to reach the program in the
terminal instead.

## Installation

```lua
-- lazy.nvim
{
  "Spiegie/termforge.nvim",
  -- Telescope or snacks.nvim are optional pickers; without either,
  -- vim.ui.select is used.
  dependencies = {
    { "nvim-telescope/telescope.nvim", optional = true },
    { "folke/snacks.nvim", optional = true },
  },
  config = function()
    require("termforge").setup({})
  end,
}
```

## Usage

1. Open a terminal (`:terminal`) and `cd` where you want the command to run.
2. Press `<leader>j`: a picker lists your commands.
3. Pick one; an input prompt opens with the command pre-filled — edit or just
   confirm.
4. The command is sent to the terminal and Terminal mode is restored.

Canceling the picker or the prompt also returns you to Terminal mode, so you
never get stuck in Normal mode inside the (non-modifiable) terminal buffer.

### Defining commands

Two sources, project-local wins on name collision:

- `<terminal-cwd>/.nvim/commands.lua`
- `~/.config/nvim/termforge-commands.lua`

```lua
return {
  { name = "build", cmd = "cargo build --release" },
  { name = "test", cmd = "cargo nextest run" },
  { name = "push", cmd = "git push" },
}
```

The CWD is read live from the terminal process (`/proc/<pid>/cwd` via
`jobpid()`), not from Neovim — it follows `cd` in your shell. On systems
without `/proc`, the directory the terminal was opened in (from the `term://`
buffer name) is used as fallback.

## Configuration

```lua
require("termforge").setup({
  keymaps = {
    launch = "<leader>j",   -- set to false to disable
    buffers = "<leader>tb",
    terminal_esc = "<Esc>", -- Esc exits Terminal mode; false to disable
  },
  commands = {
    local_commands_file = ".nvim/commands.lua",
    global_commands_file = vim.fn.stdpath("config") .. "/termforge-commands.lua",
    edit_before_run = true, -- skip the edit step with false
  },
})
```

## Picker support

termforge checks, in order: Telescope → snacks.picker → `vim.ui.select`.
Install one of the first two for fuzzy matching; `vim.ui.select` is the
dependency-free fallback.

## Nix

Test drive in an isolated Neovim (no user config, only termforge loaded):

```sh
nix run .
```

Dev shell:

```sh
nix develop
```

Package as a Neovim plugin (home-manager / NixOS):

```nix
inputs.termforge.url = "github:Spiegie/termforge.nvim";
# …
programs.neovim.plugins = [
  (pkgs.vimUtils.buildVimPlugin {
    pname = "termforge.nvim";
    version = "unstable";
    src = inputs.termforge;
  })
];
```

## Roadmap

- [ ] Session persistence for terminals
- [ ] Send lines/selection from a buffer to a terminal
- [ ] Per-terminal labels

## License

MIT
