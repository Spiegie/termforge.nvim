-- termforge.pickers — unified picker dispatch.
--
-- Order: Telescope -> snacks.picker -> vim.ui.select.
-- All paths get identical items/format/ordinal/on_choice interfaces, so
-- modules can swap the picker freely.

local M = {}

---@param items table
---@param opts table {prompt, format, ordinal, preview, actions}
---@param on_choice function(item|nil)
-- opts.actions: list of { key = "<C-k>", fn = function(item) end } —
-- extra keys inside the picker (Telescope and snacks; vim.ui.select has
-- no extra keys). fn receives the entry under the cursor, if any.
M.select = function(items, opts, on_choice)
  if M._telescope(items, opts, on_choice) then
    return
  end
  if M._snacks(items, opts, on_choice) then
    return
  end
  -- vim.ui.select has no preview support; opts.preview is ignored there.
  M._ui_select(items, opts, on_choice)
end

---@return boolean handled
M._telescope = function(items, opts, on_choice)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return false
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local picker_opts = {
    prompt_title = opts.prompt or "termforge",
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        return {
          value = item,
          display = opts.format(item),
          ordinal = opts.ordinal and opts.ordinal(item) or opts.format(item),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          on_choice(entry.value)
        end
      end)
      for _, act in ipairs(opts.actions or {}) do
        vim.keymap.set({ "i", "n" }, act.key, function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          act.fn(entry and entry.value or nil)
        end, { buffer = prompt_bufnr })
      end
      return true
    end,
  }
  if opts.preview then
    local previewers = require("telescope.previewers")
    picker_opts.previewer = previewers.new_buffer_previewer({
      title = opts.prompt or "termforge",
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, opts.preview(entry.value))
      end,
    })
  end

  pickers.new({}, picker_opts):find()
  return true
end

---@return boolean handled
M._snacks = function(items, opts, on_choice)
  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    return false
  end
  local snacks_opts = {
    title = opts.prompt or "termforge",
    items = items,
    format = function(item)
      return { { text = opts.format(item) } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        on_choice(item.item)
      end
    end,
  }
  if opts.preview then
    snacks_opts.preview = function(ctx)
      return { text = table.concat(opts.preview(ctx.item.item), "\n"), ft = "" }
    end
  end
  local keys = {}
  for _, act in ipairs(opts.actions or {}) do
    keys[act.key] = function(picker, item)
      picker:close()
      act.fn(item and item.item or nil)
    end
  end
  if next(keys) then
    snacks_opts.keys = keys
  end
  snacks.pick(snacks_opts)
  return true
end

M._ui_select = function(items, opts, on_choice)
  vim.ui.select(items, {
    prompt = (opts.prompt or "termforge") .. ": ",
    format_item = opts.format,
  }, on_choice)
end

return M
