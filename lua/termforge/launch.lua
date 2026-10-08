-- termforge.launch — Command-Launcher.
--
-- Ablauf: Cursor im :terminal-Buffer -> launch() -> Picker zeigt Befehle
-- (projektlokal + global) -> Edit-Schritt (optional, default an) -> send.
--
-- Befehlsdateien (beide optional, Projekt gewinnt bei Namensgleichheit):
--   <terminal-cwd>/.nvim/commands.lua
--   ~/.config/nvim/termforge-commands.lua
-- Format:
--   return {
--     { name = "build", cmd = "cargo build --release" },
--   }

local M = {}

local core = require("termforge")
local pickers = require("termforge.pickers")

---@param path string
---@return table
M._load_file = function(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, mod = pcall(dofile, path)
  if not ok or type(mod) ~= "table" then
    vim.notify(("termforge: %s konnte nicht geladen werden"):format(path), vim.log.levels.WARN)
    return {}
  end
  local out = {}
  for _, e in ipairs(mod) do
    if type(e) == "table" and type(e.cmd) == "string" then
      out[#out + 1] = {
        name = type(e.name) == "string" and e.name or e.cmd,
        cmd = e.cmd,
      }
    end
  end
  return out
end

---@param cwd string?
---@return table commands
M._collect = function(cwd)
  local cfg = core.config.commands
  local commands, seen = {}, {}
  local add = function(list)
    for _, c in ipairs(list) do
      if not seen[c.name] then
        seen[c.name] = true
        commands[#commands + 1] = c
      end
    end
  end
  if cwd then
    add(M._load_file(cwd .. "/" .. cfg.local_commands_file))
  end
  add(M._load_file(cfg.global_commands_file))
  return commands
end

--- Befehl (ggf. editiert) absenden.
M._run = function(bufnr, job_id, cmd)
  if not core.config.commands.edit_before_run then
    core.send(bufnr, job_id, cmd)
    return
  end
  vim.ui.input({ prompt = "termforge > ", default = cmd }, function(edited)
    if not edited then
      return -- abgebrochen
    end
    core.send(bufnr, job_id, edited == "" and cmd or edited)
  end)
end

--- Haupteinstieg: Picker oeffnen und Befehl ins aktuelle Terminal feuern.
M.launch = function()
  local bufnr, job_id, cwd = core.terminal_context()
  if not job_id then
    vim.notify("termforge: Cursor steht nicht in einem Terminal.", vim.log.levels.WARN)
    return
  end

  local commands = M._collect(cwd)
  if #commands == 0 then
    vim.notify("termforge: keine Befehle gefunden.", vim.log.levels.WARN)
    return
  end

  pickers.select(commands, {
    prompt = "termforge",
    format = function(c)
      return ("%s  ->  %s"):format(c.name, c.cmd)
    end,
    ordinal = function(c)
      return c.name .. " " .. c.cmd
    end,
  }, function(choice)
    if choice then
      M._run(bufnr, job_id, choice.cmd)
    end
  end)
end

return M
