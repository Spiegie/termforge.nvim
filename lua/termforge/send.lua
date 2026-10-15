-- termforge.send — send lines/selection from a buffer to a terminal.
--
-- The target is the most recently visited terminal (tracked via autocmd).
-- Focus stays in the source buffer: the terminal only receives the lines.
-- Each line is sent individually with Enter, so it executes right away.

local M = {}

local core = require("termforge")

-- most recently visited terminal: { bufnr = number, job_id = number }
local target = nil

--- Enable target tracking: TermOpen/BufEnter remember the last visited
--- terminal.
M.setup = function()
  local group = vim.api.nvim_create_augroup("termforge-send", { clear = true })
  vim.api.nvim_create_autocmd({ "TermOpen", "BufEnter" }, {
    group = group,
    callback = function(args)
      local job_id = vim.b[args.buf].terminal_job_id
      if job_id then
        target = { bufnr = args.buf, job_id = job_id }
      end
    end,
  })
end

--- The most recently visited terminal that is still alive — or nil.
---@return table? target {bufnr, job_id}
M.target = function()
  if not target or not vim.api.nvim_buf_is_valid(target.bufnr) then
    return nil
  end
  local ok, running = pcall(function()
    return vim.fn.jobwait({ target.job_id }, 0)[1] == -1
  end)
  if not ok or not running then
    return nil
  end
  return target
end

--- Send {lines} to the terminal {t} ({bufnr, job_id}), one line per Enter.
--- Focus stays in the source buffer.
---@param t table {bufnr, job_id}
---@param lines string[]
M.lines_to = function(t, lines)
  for _, line in ipairs(lines) do
    vim.fn.chansend(t.job_id, line .. "\r")
  end
end

--- Send lines [start, finish] (1-based, inclusive) of bufnr to the target
--- terminal. Without a live target, a warning is shown.
---@param bufnr number source buffer
---@param start number
---@param finish number
M.range = function(bufnr, start, finish)
  local t = M.target()
  if not t then
    vim.notify("termforge: no live terminal to send to.", vim.log.levels.WARN)
    return
  end
  M.lines_to(t, vim.api.nvim_buf_get_lines(bufnr, start - 1, finish, false))
end

--- Send lines [start, finish] (default: the cursor line) of the current
--- buffer to a terminal chosen in the terminal picker — the picker shows
--- labels and previews, so this composes with |termforge-label()|.
---@param start number?
---@param finish number?
M.chosen = function(start, finish)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  start = start or row
  finish = finish or start
  local lines =
    vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), start - 1, finish, false)
  require("termforge.buffers").pick(function(t)
    M.lines_to(t, lines)
  end)
end

--- Focus the last-used terminal: its window when it is displayed,
--- otherwise a new split. Warns when no live terminal was used yet.
M.last = function()
  local t = M.target()
  if not t then
    vim.notify("termforge: no live terminal used yet.", vim.log.levels.WARN)
    return
  end
  local win = vim.fn.bufwinid(t.bufnr)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("sbuffer " .. t.bufnr)
  end
  core.enter_terminal_mode(t.bufnr)
end

--- Send the cursor line (Normal mode); with v:count or count, that many
--- lines.
---@param count number? number of lines (default 1, or v:count)
M.line = function(count)
  count = count or (vim.v.count > 0 and vim.v.count or 1)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  M.range(bufnr, row, row + count - 1)
end

--- Send the lines of the last visual selection (Visual mode).
M.selection = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local start = vim.api.nvim_buf_get_mark(bufnr, "<")[1]
  local finish = vim.api.nvim_buf_get_mark(bufnr, ">")[1]
  if start > finish then
    start, finish = finish, start
  end
  M.range(bufnr, start, finish)
end

return M
