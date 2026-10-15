-- termforge.health — checks for `:checkhealth termforge`.
--
-- Verifies the plugin's environment: Neovim version, picker backend,
-- shell integration for command notifications, session settings and the
-- command files. Everything is read-only; nothing here modifies config.

local M = {}

local core = require("termforge")

-- rc file that would source the shell integration, per supported shell.
local rc_file = {
  zsh = function()
    local zdotdir = vim.env.ZDOTDIR
    if zdotdir and zdotdir ~= "" then
      return zdotdir .. "/.zshrc"
    end
    return vim.env.HOME .. "/.zshrc"
  end,
  bash = function()
    return vim.env.HOME .. "/.bashrc"
  end,
  fish = function()
    return vim.env.HOME .. "/.config/fish/config.fish"
  end,
}

--- True when {path} contains a line that sources a termforge snippet.
---@param path string
---@return boolean
local function sources_integration(path)
  for _, line in ipairs(vim.fn.readfile(path)) do
    if line:find("termforge.", 1, true) then
      return true
    end
  end
  return false
end

M.check = function()
  vim.health.start("termforge.nvim")

  if vim.fn.has("nvim-0.8") == 1 then
    local v = vim.version()
    vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
  else
    vim.health.error("termforge requires Neovim 0.8 or newer.")
  end

  if pcall(require, "telescope") then
    vim.health.ok("Picker: Telescope.")
  elseif pcall(require, "snacks.picker") then
    vim.health.ok("Picker: snacks.picker.")
  else
    vim.health.info("Picker: vim.ui.select fallback. Install Telescope or snacks.nvim for fuzzy matching.")
  end

  local notify = type(core.config.notify) == "table" and core.config.notify or {}
  if notify.enabled == false then
    vim.health.info("Command notifications are disabled (notify.enabled = false).")
  else
    local shell = vim.env.SHELL or ""
    local name = vim.fn.fnamemodify(shell, ":t")
    local rc = rc_file[name] and rc_file[name]()
    if not rc then
      vim.health.info(("Shell `%s` has no integration; notifications need zsh, bash or fish."):format(name))
    else
      local snippet = require("termforge.watch").snippet(name)
      if vim.fn.filereadable(snippet) == 1 then
        vim.health.ok(("Integration snippet: `%s`"):format(snippet))
      else
        vim.health.error(("Integration snippet missing: `%s`"):format(snippet))
      end
      if vim.fn.filereadable(rc) == 1 then
        if sources_integration(rc) then
          vim.health.ok(("Integration is sourced from `%s`"):format(rc))
        else
          vim.health.warn(
            ("No `source .../termforge.%s` found in `%s`. Add it to get notifications (see README)."):format(name, rc)
          )
        end
      else
        vim.health.warn(("`%s` not found; source the integration from your shell rc to get notifications."):format(rc))
      end
    end
  end

  if type(core.config.session) == "table" and core.config.session.enabled then
    local flags = vim.split(vim.o.sessionoptions, ",", { plain = true })
    if vim.tbl_contains(flags, "terminal") then
      vim.health.ok("Session persistence: 'sessionoptions' includes terminal.")
    else
      vim.health.warn("Session persistence: 'sessionoptions' lacks terminal (setup() adds it; call setup() first).")
    end
  end

  local commands = type(core.config.commands) == "table" and core.config.commands or {}
  local global = commands.global_commands_file
  if global and vim.fn.filereadable(global) == 1 then
    local ok, mod = pcall(dofile, global)
    local count = ok and type(mod) == "table" and #mod or "?"
    vim.health.ok(("Global command file: `%s` (%s commands)"):format(global, tostring(count)))
  else
    vim.health.info(("Global command file: none at `%s` (optional)."):format(tostring(global)))
  end
  local local_file = commands.local_commands_file
  if local_file then
    local path = vim.fn.getcwd() .. "/" .. local_file
    if vim.fn.filereadable(path) == 1 then
      local ok, mod = pcall(dofile, path)
      local count = ok and type(mod) == "table" and #mod or "?"
      vim.health.ok(("Project command file: `%s` (%s commands)"):format(path, tostring(count)))
    else
      vim.health.info(("Project command file: none at `%s` (optional, checked against the cwd)."):format(path))
    end
  end
end

return M
