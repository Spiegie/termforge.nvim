-- termforge.pickers — vereinheitlichter Picker-Dispatch.
--
-- Reihenfolge: Telescope -> snacks.picker -> vim.ui.select.
-- Alle Pfade bekommen identische items/format/ordinal/on_choice-Interfaces,
-- damit Module den Picker frei tauschen koennen.

local M = {}

---@param items table
---@param opts table {prompt, format, ordinal}
---@param on_choice function(item|nil)
M.select = function(items, opts, on_choice)
  if M._telescope(items, opts, on_choice) then
    return
  end
  if M._snacks(items, opts, on_choice) then
    return
  end
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

  pickers
    .new({}, {
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
        return true
      end,
    })
    :find()
  return true
end

---@return boolean handled
M._snacks = function(items, opts, on_choice)
  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    return false
  end
  snacks.pick({
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
  })
  return true
end

M._ui_select = function(items, opts, on_choice)
  vim.ui.select(items, {
    prompt = (opts.prompt or "termforge") .. ": ",
    format_item = opts.format,
  }, on_choice)
end

return M
