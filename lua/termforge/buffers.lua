-- termforge.buffers — terminal buffer selector.
--
-- Lists all terminal buffers (job still running); picking one jumps to it.
-- Hidden buffers (no window) are opened in the current window.

local M = {}

local core = require("termforge")
local pickers = require("termforge.pickers")

--- Kill a terminal entry from the picker: stop its job and delete its
--- buffer. Guarded: the entry may be gone by the time the key fires.
---@param t table? {bufnr, job_id, ...} from core.terminals()
M._kill = function(t)
  if not t then
    return
  end
  pcall(vim.fn.jobstop, t.job_id)
  pcall(vim.api.nvim_buf_delete, t.bufnr, { force = true })
end

--- Rename a terminal entry from the picker: prompt for a label and
--- apply it (see core.label). An empty input clears the label,
--- canceling changes nothing. Guarded: the entry may be gone by the
--- time the key fires.
---@param t table? {bufnr, job_id, ...} from core.terminals()
M._rename = function(t)
  if not t or not vim.api.nvim_buf_is_valid(t.bufnr) then
    return
  end
  local current = vim.b[t.bufnr].termforge_label or ""
  vim.ui.input({ prompt = "termforge label: ", default = current }, function(input)
    if input == nil then
      return
    end
    core.label(t.bufnr, input ~= "" and input or nil)
  end)
end

--- Open the terminal picker; {on_choice} receives the picked terminal
--- ({bufnr, job_id, cwd, title}). Not called when the picker is canceled.
---@param on_choice function(terminal)
M.pick = function(on_choice)
  local terminals = core.terminals()
  if #terminals == 0 then
    vim.notify("termforge: no terminal buffers open.", vim.log.levels.WARN)
    return
  end

  local current = vim.api.nvim_get_current_buf()
  local restore = vim.api.nvim_get_mode().mode == "t"

  pickers.select(terminals, {
    prompt = "terminals",
    format = function(t)
      local short = t.title
      for _, pat in ipairs({ "term://", "//", "%d+:" }) do
        short = short:gsub(pat, "")
      end
      local cwd = t.cwd and ("  [" .. vim.fn.fnamemodify(t.cwd, ":t") .. "]") or ""
      local marker = (t.bufnr == current) and " * " or "   "
      return ("%s#%d %s%s"):format(marker, t.bufnr, short, cwd)
    end,
    ordinal = function(t)
      return t.title .. " " .. (t.cwd or "")
    end,
    -- Shown by pickers that support previews (Telescope, snacks): the
    -- last lines of the terminal, so you can tell terminals apart.
    -- Terminal buffers pad with blank lines below the content (the
    -- buffer is as tall as its window), so trim the blank tail first
    -- and only then keep the last lines.
    preview = function(t)
      if not vim.api.nvim_buf_is_valid(t.bufnr) then
        return {}
      end
      local count = vim.api.nvim_buf_line_count(t.bufnr)
      local lines = vim.api.nvim_buf_get_lines(t.bufnr, math.max(0, count - 500), -1, false)
      while #lines > 0 and lines[#lines]:match("^%s*$") do
        lines[#lines] = nil
      end
      if #lines > 15 then
        local tail = {}
        for i = #lines - 14, #lines do
          tail[#tail + 1] = lines[i]
        end
        return tail
      end
      return lines
    end,
    -- <C-k> kills the terminal under the cursor, <C-e> renames it
    -- (label); Telescope and snacks.
    actions = {
      { key = "<C-k>", fn = M._kill },
      { key = "<C-e>", fn = M._rename },
    },
  }, function(choice)
    if not choice then
      if restore then
        core.enter_terminal_mode(current)
      end
      return
    end
    on_choice(choice)
  end)
end

--- Open the terminal picker and jump to the chosen terminal.
M.select = function()
  M.pick(function(choice)
    local win = vim.fn.bufwinid(choice.bufnr)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      vim.api.nvim_set_current_buf(choice.bufnr)
    end
    if vim.api.nvim_get_current_buf() == choice.bufnr then
      core.enter_terminal_mode(choice.bufnr)
    end
  end)
end

return M
