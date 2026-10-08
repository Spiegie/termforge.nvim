-- termforge.nvim — small extensions for Neovim's built-in terminal.
--
-- Module layout:
--   termforge         = Kern: Setup, Terminal-Kontext, Picker-Dispatch, chansend
--   termforge.launch  = Command-Launcher: Picker -> Edit -> Send
--   termforge.buffers = Terminal-Buffer-Selector
--
-- Setup:
--   require("termforge").setup({
--     keymaps = {
--       launch = "<leader>j",      -- Befehl ins aktuelle Terminal feuern
--       buffers = "<leader>tb",   -- Terminal-Buffer auswaehlen
--       terminal_esc = "<Esc>",   -- Terminal-Modus mit Esc verlassen
--     },
--   })

local M = {}

M.config = {
  keymaps = {
    launch = "<leader>j",
    buffers = "<leader>tb",
    -- Esc verlaesst den Terminal-Modus wie den Insert-Modus; false = aus.
    -- Achtung: Esc erreicht dann nie mehr das Programm im Terminal.
    terminal_esc = "<Esc>",
  },
  -- Befehle fuer termforge.launch
  commands = {
    local_commands_file = ".nvim/commands.lua",
    global_commands_file = vim.fn.stdpath("config") .. "/termforge-commands.lua",
    edit_before_run = true, -- optionaler Edit-Schritt, default an
  },
}

---@param opts table
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local launch = require("termforge.launch")
  local buffers = require("termforge.buffers")

  local km = M.config.keymaps
  if km.launch then
    vim.keymap.set("t", km.launch, launch.launch, { desc = "termforge: Befehl auswaehlen" })
    vim.keymap.set("n", km.launch, launch.launch, { desc = "termforge: Befehl auswaehlen" })
  end
  if km.buffers then
    vim.keymap.set("t", km.buffers, buffers.select, { desc = "termforge: Terminal-Buffer" })
    vim.keymap.set("n", km.buffers, buffers.select, { desc = "termforge: Terminal-Buffer" })
  end
  if km.terminal_esc then
    vim.keymap.set("t", km.terminal_esc, [[<C-\><C-n>]], { desc = "termforge: Terminal-Modus verlassen" })
  end
end

--- CWD des Terminal-Prozesses ermitteln.
--- Neovim bietet dafuer keine Funktion: unter Linux zeigt /proc/<pid>/cwd
--- das Live-Verzeichnis des Shells (folgt cd); sonst bleibt das
--- Anlege-Verzeichnis aus dem term://-Buffernamen.
---@param bufnr number
---@param job_id number
---@return string? cwd
M.terminal_cwd = function(bufnr, job_id)
  local ok_pid, pid = pcall(vim.fn.jobpid, job_id)
  if ok_pid and type(pid) == "number" and pid > 0 then
    local ok, cwd = pcall(vim.fn.resolve, ("/proc/%d/cwd"):format(pid))
    if ok and cwd ~= "" and not cwd:match("^/proc/%d+/cwd$") then
      return cwd
    end
  end
  local dir = vim.api.nvim_buf_get_name(bufnr):match("^term://(.-)//")
  if dir and dir ~= "" then
    return (dir:sub(1, 1) == "~") and vim.fn.expand(dir) or dir
  end
  return nil
end

--- Terminal-Kontext des aktuellen Buffers ermitteln.
--- Strikt: nur das Terminal des aktuellen Buffers, kein Fallback.
---@return number? bufnr
---@return number? job_id
---@return string? cwd
M.terminal_context = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local job_id = vim.b[bufnr].terminal_job_id
  if not job_id then
    return nil, nil, nil
  end
  return bufnr, job_id, M.terminal_cwd(bufnr, job_id)
end

--- Nach einer Picker-/Input-Interaktion in den Terminal-Modus des Buffers
--- zurueckkehren, sofern der Fokus noch dort liegt. Ohne diesen Schritt
--- landet man nach Abbruch im Normal-Modus des nomodifiable Terminals.
---@param bufnr number
M.enter_terminal_mode = function(bufnr)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
      vim.cmd("startinsert")
    end
  end, 10)
end

--- Befehl an einen Terminal-Job senden und Fokus zurueckholen.
M.send = function(bufnr, job_id, cmd)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("termforge: Terminal-Buffer existiert nicht mehr.", vim.log.levels.ERROR)
    return
  end
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  end
  vim.fn.chansend(job_id, cmd .. "\r")
  M.enter_terminal_mode(bufnr)
end

--- Alle Terminal-Buffer sammeln.
---@return table[] terminals {bufnr, job_id, cwd, title}
M.terminals = function()
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local job_id = vim.b[bufnr].terminal_job_id
    if job_id then
      out[#out + 1] = {
        bufnr = bufnr,
        job_id = job_id,
        cwd = M.terminal_cwd(bufnr, job_id),
        title = vim.api.nvim_buf_get_name(bufnr),
      }
    end
  end
  return out
end

return M
