-- termforge.nvim — small extensions for Neovim's built-in terminal.
--
-- Module layout:
--   termforge         = core: setup, terminal context, picker dispatch, chansend
--   termforge.launch  = command launcher: picker -> edit -> send
--   termforge.buffers = terminal buffer selector
--   termforge.send    = send lines/selection from a buffer to a terminal
--   termforge.session = persist terminals across :mksession
--   termforge.watch   = notify when commands in terminal shells finish
--   termforge.health  = checks for :checkhealth termforge
--
-- Setup:
--   require("termforge").setup({
--     keymaps = {
--       launch = "<leader>ll",      -- fire a command into the current terminal
--       buffers = "<leader>lb",   -- pick a terminal buffer
--       send = "<leader>ls",       -- send line/selection to a terminal
--       repeat_last = "<leader>lr", -- repeat the last fired command
--       cd = "<leader>lc",         -- cd the terminal to the last file's dir
--       last = "<leader>lt",      -- focus the last-used terminal
--       terminal_esc = "<Esc>",   -- leave Terminal mode with Esc
--     },
--   })

local M = {}

M.config = {
  keymaps = {
    launch = "<leader>ll",
    buffers = "<leader>lb",
    -- Send the cursor line (Normal mode) or the selection (Visual mode)
    -- to the most recently visited terminal.
    send = "<leader>ls",
    -- Repeat the last command fired through the launcher.
    repeat_last = "<leader>lr",
    -- cd the current terminal to the directory of the last visited file.
    cd = "<leader>lc",
    -- Focus the last-used terminal.
    last = "<leader>lt",
    -- Esc leaves Terminal mode like Insert mode; false = off.
    -- Note: Esc then never reaches the program in the terminal.
    terminal_esc = "<Esc>",
  },
  -- Commands for termforge.launch
  commands = {
    local_commands_file = ".nvim/commands.lua",
    global_commands_file = vim.fn.stdpath("config") .. "/termforge-commands.lua",
    edit_before_run = true, -- optional edit step, on by default
  },
  -- Persist terminals across :mksession. Neovim recreates the terminal
  -- buffers itself; termforge writes each shell's live directory to a
  -- sidecar file and restores it after loading.
  session = {
    enabled = true,
    restore_cwd = true, -- navigate restored shells back with `cd`
  },
  -- Notify when commands in terminal shells finish. Requires the shell
  -- integration to be sourced from the shell rc; see README
  -- "Command notifications".
  notify = {
    enabled = true,
    min_duration = 1, -- seconds; shorter commands stay silent
  },
}

---@param opts table
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local launch = require("termforge.launch")
  local buffers = require("termforge.buffers")
  local send = require("termforge.send")

  send.setup()
  launch.setup()

  if M.config.session and M.config.session.enabled then
    require("termforge.session").setup()
  end
  if M.config.notify and M.config.notify.enabled then
    require("termforge.watch").setup()
  end

  local km = M.config.keymaps
  if km.launch then
    vim.keymap.set("t", km.launch, launch.launch, { desc = "termforge: pick a command" })
    vim.keymap.set("n", km.launch, launch.launch, { desc = "termforge: pick a command" })
  end
  if km.buffers then
    vim.keymap.set("t", km.buffers, buffers.select, { desc = "termforge: terminal buffer" })
    vim.keymap.set("n", km.buffers, buffers.select, { desc = "termforge: terminal buffer" })
  end
  if km.send then
    vim.keymap.set("n", km.send, function()
      send.line()
    end, { desc = "termforge: send line to terminal" })
    vim.keymap.set("x", km.send, function()
      send.selection()
    end, { desc = "termforge: send selection to terminal" })
  end
  if km.repeat_last then
    vim.keymap.set("t", km.repeat_last, launch.repeat_last, { desc = "termforge: repeat the last command" })
    vim.keymap.set("n", km.repeat_last, launch.repeat_last, { desc = "termforge: repeat the last command" })
  end
  if km.cd then
    vim.keymap.set("t", km.cd, launch.cd, { desc = "termforge: cd the terminal to the last file's directory" })
    vim.keymap.set("n", km.cd, launch.cd, { desc = "termforge: cd the terminal to the last file's directory" })
  end
  if km.last then
    vim.keymap.set("t", km.last, send.last, { desc = "termforge: focus the last-used terminal" })
    vim.keymap.set("n", km.last, send.last, { desc = "termforge: focus the last-used terminal" })
  end
  if km.terminal_esc then
    vim.keymap.set("t", km.terminal_esc, [[<C-\><C-n>]], { desc = "termforge: leave Terminal mode" })
  end

  -- User commands, independent of the keymaps: same actions for people
  -- who disable the keymaps or prefer commands.
  local user_command = function(name, fn, opts)
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, fn, opts)
  end
  user_command("TermforgeLaunch", launch.launch, {
    desc = "termforge: pick a command and fire it into the current terminal",
  })
  user_command("TermforgeBuffers", buffers.select, {
    desc = "termforge: pick a terminal buffer",
  })
  user_command("TermforgeSend", function(opts)
    if opts.bang then
      send.chosen(opts.line1, opts.line2)
      return
    end
    if opts.range and opts.range > 0 then
      send.range(vim.api.nvim_get_current_buf(), opts.line1, opts.line2)
    else
      send.line()
    end
  end, {
    range = true,
    bang = true,
    desc = "termforge: send [range] or the cursor line to the last-used terminal (!: pick the terminal)",
  })
  user_command("TermforgeLabel", function(opts)
    M.label(nil, opts.args ~= "" and opts.args or nil)
  end, {
    nargs = "?",
    desc = "termforge: label the current terminal buffer (no argument clears it)",
  })
  user_command("TermforgeRepeat", launch.repeat_last, {
    desc = "termforge: repeat the last fired command in the current terminal",
  })
  user_command("TermforgeCd", launch.cd, {
    desc = "termforge: cd the current terminal to the directory of the last visited file",
  })
  user_command("TermforgeCommands", launch.edit_commands, {
    desc = "termforge: open the commands file for editing",
  })
  user_command("TermforgeLast", send.last, {
    desc = "termforge: focus the last-used terminal",
  })
end

--- CWD of the terminal process.
--- Neovim offers no function for this: on Linux, /proc/<pid>/cwd shows the
--- shell's live directory (it follows cd); otherwise the directory the
--- terminal was opened in (from the term:// buffer name) is used.
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
  -- A labeled terminal is renamed to term://<label>; the original name
  -- (which carries the directory) is kept in b:termforge_original_name.
  local name = vim.b[bufnr].termforge_original_name or vim.api.nvim_buf_get_name(bufnr)
  local dir = name:match("^term://(.-)//")
  if dir and dir ~= "" then
    return (dir:sub(1, 1) == "~") and vim.fn.expand(dir) or dir
  end
  return nil
end

--- Terminal context of the current buffer.
--- Strict: only the current buffer's terminal, no fallback.
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

--- Return to Terminal mode of the buffer after a picker/input interaction,
--- as long as the focus is still there. Without this step, canceling lands
--- you in Normal mode of the nomodifiable terminal.
---@param bufnr number
M.enter_terminal_mode = function(bufnr)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr then
      vim.cmd("startinsert")
    end
  end, 10)
end

--- Send a command to a terminal job and move focus back there.
M.send = function(bufnr, job_id, cmd)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("termforge: terminal buffer no longer exists.", vim.log.levels.ERROR)
    return
  end
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  end
  vim.fn.chansend(job_id, cmd .. "\r")
  M.enter_terminal_mode(bufnr)
end

--- Collect all terminal buffers with a running job.
--- b:terminal_job_id stays set after the shell has exited; therefore also
--- check that the job is still alive.
---@return table[] terminals {bufnr, job_id, cwd, title}
M.terminals = function()
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local job_id = vim.b[bufnr].terminal_job_id
    if job_id then
      local ok, running = pcall(function()
        return vim.fn.jobwait({ job_id }, 0)[1] == -1
      end)
      if ok and running then
        out[#out + 1] = {
          bufnr = bufnr,
          job_id = job_id,
          cwd = M.terminal_cwd(bufnr, job_id),
          title = vim.api.nvim_buf_get_name(bufnr),
        }
      end
    end
  end
  return out
end

--- Label a terminal buffer: it is renamed to "term://<label>", so every
--- buffer listing (:ls, Telescope, snacks, bufferline) shows the label.
--- The original name is kept in b:termforge_original_name; pass nil (or
--- "") to clear the label and restore the original name. With session
--- persistence enabled, termforge keeps the session file free of label
--- names and re-applies labels after restoring (see termforge.session).
---@param bufnr number? terminal buffer (default: current buffer)
---@param label string? new label; nil clears it
---@return boolean ok
M.label = function(bufnr, label)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.b[bufnr].terminal_job_id then
    vim.notify("termforge: not a terminal buffer.", vim.log.levels.WARN)
    return false
  end
  if label == "" then
    label = nil
  end
  if label then
    if vim.b[bufnr].termforge_original_name == nil then
      vim.b[bufnr].termforge_original_name = vim.api.nvim_buf_get_name(bufnr)
    end
    local ok = pcall(vim.api.nvim_buf_set_name, bufnr, "term://" .. label)
    if not ok then
      vim.notify("termforge: another buffer already uses this name.", vim.log.levels.ERROR)
      return false
    end
    vim.b[bufnr].termforge_label = label
  else
    local original = vim.b[bufnr].termforge_original_name
    if original then
      pcall(vim.api.nvim_buf_set_name, bufnr, original)
    end
    vim.b[bufnr].termforge_label = nil
    vim.b[bufnr].termforge_original_name = nil
  end
  return true
end

return M
