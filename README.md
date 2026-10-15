# termforge.nvim

Small extensions for Neovim's built-in terminal. Fire predefined commands into
the terminal you are already in, and jump between your terminal buffers.

Unlike task runners, termforge does not spawn terminals or background jobs. It
serves **the terminal you navigated to**: navigate your shell where you want,
pick a command, edit it, fire it.

Full reference after installation: `:h termforge`.

## Modules

| Module | What it does | Default keymap |
|---|---|---|
| `termforge.launch` | Command launcher: pick → edit → send into the current terminal | `<leader>ll` |
| `termforge.buffers` | Picker listing only terminal buffers, with a preview of each | `<leader>lb` |
| `termforge.send` | Send the cursor line or a selection to the last-used terminal | `<leader>ls` |
| `termforge.session` | Persist terminals across `:mksession` / `:source` | automatic |
| `termforge.watch` | Notify when commands in terminal shells finish | automatic |
| `termforge.label()` | Label terminal buffers, shown in every picker and `:ls` | `:TermforgeLabel` |
| `termforge.health` | Health checks | `:checkhealth termforge` |

The launch, buffers, repeat, cd and last keymaps work in Normal mode and
Terminal mode; the send keymap works in Normal mode (cursor line) and Visual
mode (selection). Additionally, `<Esc>` leaves Terminal mode back to Normal
mode (like leaving Insert mode); set `keymaps.terminal_esc = false` if you
want Esc to reach the program in the terminal instead.

Every action is also available as a user command, independent of the
keymaps: `:TermforgeLaunch`, `:TermforgeBuffers`, `:[range]TermforgeSend`
(with `!`: pick the terminal first), `:TermforgeLabel [label]`,
`:TermforgeRepeat`, `:TermforgeCd`, `:TermforgeCommands` and
`:TermforgeLast`.

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
2. Press `<leader>ll`: a picker lists your commands.
3. Pick one; an input prompt opens with the command pre-filled — edit or just
   confirm.
4. The command is sent to the terminal and Terminal mode is restored.

Canceling the picker or the prompt also returns you to Terminal mode, so you
never get stuck in Normal mode inside the (non-modifiable) terminal buffer.

### Repeat, cd and editing commands

- `<leader>lr` / `:TermforgeRepeat` fires the last launched command again,
  in the terminal the cursor is in now — repeat a build without reopening
  the picker.
- `<leader>lc` / `:TermforgeCd` sends `cd <directory of the last visited
  file>` to the current terminal: the shell navigates to where the file you
  are editing lives.
- `<leader>lt` / `:TermforgeLast` focuses the last-used terminal — its
  window when it is still open, a new split otherwise.
- `<C-e>` in the launch picker opens the commands file for editing
  (Telescope and snacks; with the `vim.ui.select` fallback use
  `:TermforgeCommands`). Missing files and directories are created with a
  commented stub. When the picker finds no commands at all, termforge
  offers to open the file right away.

### Defining commands

Two sources, project-local wins on name collision:

- `<terminal-cwd>/.nvim/commands.lua`
- `~/.config/nvim/termforge-commands.lua`

```lua
return {
  { name = "build", cmd = "cargo build --release" },
  { name = "test", cmd = "cargo nextest run" },
  { name = "test-file", cmd = "pytest {file_basename}" },
  { name = "push", cmd = "git push" },
}
```

The CWD is read live from the terminal process (`/proc/<pid>/cwd` via
`jobpid()`), not from Neovim — it follows `cd` in your shell. On systems
without `/proc`, the directory the terminal was opened in (from the `term://`
buffer name) is used as fallback.

#### Command templates

A `cmd` string can contain placeholders that termforge expands when you pick
the command — the edit prompt then shows the expanded result:

| Placeholder | Expands to |
|---|---|
| `{file}` | absolute path of the file buffer you visited last |
| `{file_basename}` | its name without the directory |
| `{file_dirname}` | its directory |
| `{cwd}` | the terminal's live working directory |
| `{root}` | the project root of `{cwd}`: the git worktree root, or `{cwd}` itself outside a git repository |
| `{git_branch}` | the git branch checked out in `{cwd}` (empty outside a git repository or on a detached HEAD) |
| `{selection}` | the last visual selection in that file buffer |
| `{cursor}` | removed; the edit prompt opens with the cursor at this spot |

```lua
return {
  { name = "test-file", cmd = "pytest {file_basename}" },
  { name = "run-here", cmd = "cargo run --manifest-path {file_dirname}/Cargo.toml" },
  { name = "search", cmd = "rg -n {selection}" },
  { name = "checkout", cmd = "git checkout {cursor}" },
}
```

A placeholder whose value is unknown (no file visited yet, no CWD) expands to
an empty string; anything else, like `${HOME}`, is left untouched.

`{selection}` is read from the `'<`/`'>` marks, so it survives leaving Visual
mode and switching to the terminal. It is interpreted characterwise: a
linewise selection covers the whole lines, and a multi-line selection is
joined with a space. Without a selection it expands to an empty string.

`{cursor}` inserts nothing: it is removed, and the edit prompt opens with the
cursor at its position, so you can type an argument right there —
`git checkout {cursor}` becomes `git checkout |` with the cursor ready for
the branch name. It needs the edit step (`commands.edit_before_run`, on by
default) and works with the built-in input prompt; other `vim.ui.input`
implementations may not support cursor placement, but the placeholder is
still removed.

### Sending lines or a selection

From any buffer, `<leader>ls` sends lines to the terminal you visited last:

- Normal mode: the cursor line — with a count (`3<leader>ls`) that many lines.
- Visual mode: the selected lines.

Each line is sent with Enter, so the terminal executes it right away. Focus
stays in your buffer; the terminal only receives the lines. The target is
the most recently opened or visited terminal — if it has exited, you get a
warning and nothing is sent.

To send to a specific terminal instead of the last-used one, use
`:[range]TermforgeSend!`: the terminal picker opens first (labels and
previews included), and the lines go to the terminal you pick.

### Persistent terminals

With `session.enabled = true` (default), termforge composes with Neovim's
built-in session support:

- `sessionoptions` gets `terminal` added, so `:mksession` records your
  terminal buffers and `:source` recreates them.
- On `:mksession`, termforge writes a sidecar file (`<session>.termforge.json`)
  next to the session file, recording the live CWD of every running terminal.
- After `:source`, the restored shells are sent a `cd` back to their recorded
  directories — Neovim recreates terminal buffers, but in the directory the
  session was saved from, not where your shell had navigated.

The sidecar is written on `SessionWritePost`, when `v:this_session` already
points at the saved session. Restore runs on `SessionLoadPost` and only sends
`cd` to shells whose live CWD differs from the recorded one; entries whose
directory no longer exists are skipped. Set `session.restore_cwd = false` to
keep the automatic buffer restore but skip the `cd` navigation.

Session plugins compose with this out of the box: persistence.nvim (saves
the session on exit, restores on demand) and auto-session (auto-saves and
auto-restores, with a session picker) both use `:mksession` and `:source`
under the hood, so the sidecar hooks fire with no extra configuration.

### Command notifications

termforge notifies you when a command finishes in any of your terminal
shells — builds, tests, anything that runs longer than a second, including
commands you type by hand. Neovim cannot see command boundaries inside a
shell, so this needs a tiny shell integration: the shell writes a marker
file after each command, and termforge turns it into a `vim.notify()` call.
With nvim-notify, noice.nvim or snacks.nvim installed you get a popup;
otherwise the message lands in the message area (`:messages`).

Enable it by sourcing the integration for your shell — a no-op outside
Neovim terminals:

```zsh
# .zshrc
source <termforge>/shell/termforge.zsh
```

```bash
# .bashrc
source <termforge>/shell/termforge.bash
```

```fish
# config.fish
source <termforge>/shell/termforge.fish
```

`<termforge>` is the plugin's installation directory:

| Installation | Directory |
|---|---|
| lazy.nvim | `~/.local/share/nvim/lazy/termforge.nvim` |
| vim-plug | `~/.local/share/nvim/plugged/termforge.nvim` |
| packer.nvim | `~/.local/share/nvim/site/pack/packer/start/termforge.nvim` |
| manual clone | wherever you cloned it |

Not sure? Ask the plugin: `:lua print(require("termforge.watch").snippet("zsh"))`
prints the exact path for your installation.

#### NixOS and home-manager

The flake exposes the snippets as a separate package, so the sourced path
always matches your flake input:

```nix
# flake.nix
inputs.termforge.url = "github:Spiegie/termforge.nvim";
```

```nix
# home-manager: zsh
programs.zsh.initExtra = ''
  source ${inputs.termforge.packages.${system}.termforge-shell}/share/termforge/termforge.zsh
'';
```

```nix
# home-manager: bash
programs.bash.initExtra = ''
  source ${inputs.termforge.packages.${system}.termforge-shell}/share/termforge/termforge.bash
'';
```

```nix
# home-manager: fish
programs.fish.interactiveShellInit = ''
  source ${inputs.termforge.packages.${system}.termforge-shell}/share/termforge/termforge.fish
'';
```

Without home-manager, on NixOS directly:

```nix
programs.zsh.enable = true;
programs.zsh.interactiveShellInit = ''
  source ${inputs.termforge.packages.${system}.termforge-shell}/share/termforge/termforge.zsh
'';
```

#### Other operating systems

The integration is plain shell script: Linux, macOS and BSD work the same
way, and only the plugin directory differs (macOS uses the same
`~/.local/share/nvim/...` paths as Linux). Windows shells (cmd,
PowerShell) are not supported.

#### Notes and limits

- Notifications fire for commands in terminals Neovim owns (`:terminal`),
  not in external terminal emulators.
- zsh uses `preexec`/`precmd`, fish its `fish_preexec`/`fish_postexec`
  events. bash uses a DEBUG trap — if bash-preexec is loaded, termforge
  hooks into it instead. Durations are whole seconds.
- If a terminal dies before its marker is read, the file stays in `/tmp`
  until the OS cleans it up.
- `nix run .#` preloads the integration: terminals in the isolated Neovim
  start with the snippet sourced (a bare shell, without your rc files).

### Terminal labels

`:TermforgeLabel build` renames the current terminal buffer to
`term://build`. The label shows up everywhere buffer names are shown:
`:ls`, Telescope's and snacks' buffer pickers, bufferline plugins — no
picker or statusline plugin required. `:TermforgeLabel` without an argument
removes the label and restores the original name. From the terminal buffer
picker, `<C-e>` renames the terminal under the cursor (Telescope and
snacks), with the current label pre-filled; an empty input clears it.

Labels compose with session persistence: after `:mksession`, termforge
rewrites the label names out of the session file (Neovim would otherwise try
to run the label as the terminal command when restoring), records the label
in the sidecar file, and re-applies it after `:source`. With
`session.enabled = false`, clear labels before saving a session.

## Configuration

```lua
require("termforge").setup({
  keymaps = {
    launch = "<leader>ll",   -- set to false to disable
    buffers = "<leader>lb",
    send = "<leader>ls",     -- send cursor line/selection to the last terminal
    repeat_last = "<leader>lr", -- repeat the last fired command
    cd = "<leader>lc",       -- cd the terminal to the last file's directory
    last = "<leader>lt",     -- focus the last-used terminal
    terminal_esc = "<Esc>", -- Esc exits Terminal mode; false to disable
  },
  commands = {
    local_commands_file = ".nvim/commands.lua",
    global_commands_file = vim.fn.stdpath("config") .. "/termforge-commands.lua",
    edit_before_run = true, -- skip the edit step with false
  },
  session = {
    enabled = true,     -- persist terminals with :mksession
    restore_cwd = true, -- cd restored shells back to their recorded CWD
  },
  notify = {
    enabled = true,   -- notify when commands finish
    min_duration = 1, -- seconds; shorter commands stay silent
  },
})
```

## Picker support

termforge checks, in order: Telescope → snacks.picker → `vim.ui.select`.
Install one of the first two for fuzzy matching; `vim.ui.select` is the
dependency-free fallback.

The terminal buffer picker (`<leader>lb`) shows a preview of each terminal's
last lines when the backend supports previews — Telescope and snacks.picker
do, `vim.ui.select` does not. With Telescope or snacks, `<C-k>` in the
picker kills the terminal under the cursor: its job is stopped and its
buffer deleted. `<C-e>` renames it: a prompt opens with the current label
pre-filled, an empty input clears the label (see Terminal labels).

## Testing

The test suite runs headlessly with neovim:

```sh
nvim --headless -l tests/test.lua
```

It exits with a non-zero status when a test fails. With the flake:

```sh
nix run .#test
```

Health checks verify the setup (picker backend, shell integration, session
settings, command files):

```sh
:checkhealth termforge
```

## Nix

Test drive in an isolated Neovim (no user config, only termforge loaded).
Terminal shells preload the shell integration, so command notifications
work there out of the box:

```sh
nix run .
```

To try the pickers with a real backend installed (same isolated Neovim,
plus Telescope or snacks.nvim — previews and the `<C-e>`/`<C-k>` picker
keys included):

```sh
nix run .#telescope
nix run .#snacks
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

- [x] Session persistence for terminals
- [x] Send lines/selection from a buffer to a terminal
- [x] Notifications when commands finish
- [x] Per-terminal labels
- [x] Repeat last command, cd to the last file's directory
- [x] `{root}` placeholder, edit commands from the picker
- [x] `{git_branch}` placeholder, kill terminals from the picker
- [x] `:TermforgeLast`, send to a chosen terminal
- [x] Rename terminals from the picker

## License

MIT
