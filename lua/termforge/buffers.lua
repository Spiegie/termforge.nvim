-- termforge.buffers — Terminal-Buffer-Selector.
--
-- Listet alle Terminal-Buffer (job laeuft noch), Auswahl springt hin.
-- Versteckte Buffer (kein Fenster) werden im aktuellen Fenster geoeffnet.

local M = {}

local core = require("termforge")
local pickers = require("termforge.pickers")

M.select = function()
  local terminals = core.terminals()
  if #terminals == 0 then
    vim.notify("termforge: keine Terminal-Buffer offen.", vim.log.levels.WARN)
    return
  end

  local current = vim.api.nvim_get_current_buf()

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
  }, function(choice)
    if not choice then
      return
    end
    local win = vim.fn.bufwinid(choice.bufnr)
    if win ~= -1 then
      vim.api.nvim_set_current_win(win)
    else
      vim.api.nvim_set_current_buf(choice.bufnr)
    end
    if vim.api.nvim_get_current_buf() == choice.bufnr then
      vim.cmd("startinsert")
    end
  end)
end

return M
