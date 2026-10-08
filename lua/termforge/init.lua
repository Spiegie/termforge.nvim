-- termforge.nvim — small extensions for Neovim's built-in terminal.
--
-- Module layout:
--   termforge        = Kern: Setup, Terminal-Kontext, Picker-Dispatch, chansend
--   termforge.just   = Command-Launcher (just-artig): Picker -> Edit -> Send
--   termforge.buffers= Terminal-Buffer-Selector
--
-- Setup:
--   require("termforge").setup({
--     keymaps = {
--       launch = "<leader>j",   -- Befehl ins aktuelle Terminal feuern
--       buffers = "<leader>tb", -- Terminal-Buffer auswaehlen
--     },
--   })

local M = {}

M.config = {
  keymaps = {
    launch = "<leader>j",
    buffers = "<leader>tb",
  },
  -- Befehle fuer termforge.just
  just = {
    local_commands_file = ".nvim/commands.lua",
    global_commands_file = vim.fn.stdpath("config") .. "/termforge-commands.lua",
    edit_before_run = true, -- optionaler Edit-Schritt, default an
  },
}

---@param opts table
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local just = require("termforge.just")
  local buffers = require("termforge.buffers")

  local km = M.config.keymaps
  if km.launch then
    vim.keymap.set("t", km.launch, just.launch, { desc = "termforge: Befehl auswaehlen" })
    vim.keymap.set("n", km.launch, just.launch, { desc = "termforge: Befehl auswaehlen" })
  end
  if km.buffers then
    vim.keymap.set("t", km.buffers, buffers.select, { desc = "termforge: Terminal-Buffer" })
    vim.keymap.set("n", km.buffers, buffers.select, { desc = "termforge: Terminal-Buffer" })
  end
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
  local ok, cwd = pcall(vim.fn.term_getcwd, bufnr)
  if not ok or cwd == "" then
    cwd = nil
  end
  return bufnr, job_id, cwd
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
  vim.defer_fn(function()
    if vim.api.nvim_get_current_buf() == bufnr then
      vim.cmd("startinsert")
    end
  end, 10)
end

--- Alle Terminal-Buffer sammeln.
---@return table[] terminals {bufnr, job_id, cwd, title}
M.terminals = function()
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local job_id = vim.b[bufnr].terminal_job_id
    if job_id then
      local ok, cwd = pcall(vim.fn.term_getcwd, bufnr)
      out[#out + 1] = {
        bufnr = bufnr,
        job_id = job_id,
        cwd = (ok and cwd ~= "") and cwd or nil,
        title = vim.api.nvim_buf_get_name(bufnr),
      }
    end
  end
  return out
end

return M
