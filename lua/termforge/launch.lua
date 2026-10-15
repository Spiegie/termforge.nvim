-- termforge.launch — command launcher.
--
-- Flow: cursor in a :terminal buffer -> launch() -> picker shows commands
-- (project-local + global) -> edit step (optional, on by default) -> send.
--
-- Command files (both optional, project wins on name collision):
--   <terminal-cwd>/.nvim/commands.lua
--   ~/.config/nvim/termforge-commands.lua
-- Format:
--   return {
--     { name = "build", cmd = "cargo build --release" },
--   }
-- cmd strings support placeholders ({file}, {file_basename}, {file_dirname},
-- {cwd}, {root}, {git_branch}, {selection}, {cursor}); see M.expand.

local M = {}

local core = require("termforge")
local pickers = require("termforge.pickers")

-- Prompt of the edit step; also identifies our command line for the
-- {cursor} placement.
local PROMPT = "termforge > "

-- Most recently visited file buffer, tracked via BufEnter; feeds the
-- {file} placeholders in command templates.
local last_file = nil

-- Last command fired through the launcher (after the edit step), for
-- M.repeat_last.
local last_cmd = nil

--- Track the most recently visited file buffer for {file} placeholders.
--- Called from termforge.setup().
M.setup = function()
  if vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" then
    last_file = vim.api.nvim_buf_get_name(0)
  end
  vim.api.nvim_create_augroup("termforge-launch", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = "termforge-launch",
    callback = function(args)
      if vim.bo[args.buf].buftype ~= "" then
        return
      end
      local name = vim.api.nvim_buf_get_name(args.buf)
      if name ~= "" then
        last_file = name
      end
    end,
  })
end

--- Path of the most recently visited file buffer (or nil); feeds the
--- {file} placeholders and M.cd.
---@return string? file
M.last_file = function()
  return last_file
end

--- Text of the last visual selection in {bufnr}, read from the '< / '>
--- marks (they persist after leaving Visual mode). Interpreted
--- characterwise: a linewise selection covers the whole lines, a
--- multi-line selection is joined with a space. Returns nil when the
--- buffer has no selection yet.
---@param bufnr number
---@return string?
M._selection = function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local start = vim.api.nvim_buf_get_mark(bufnr, "<")
  local finish = vim.api.nvim_buf_get_mark(bufnr, ">")
  if not start or not finish or start[1] == 0 or finish[1] == 0 then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start[1] - 1, finish[1], false)
  if #lines == 0 then
    return nil
  end
  if #lines == 1 then
    return lines[1]:sub(start[2] + 1, finish[2] + 1)
  end
  lines[1] = lines[1]:sub(start[2] + 1)
  lines[#lines] = lines[#lines]:sub(1, finish[2] + 1)
  return table.concat(lines, " ")
end

--- Project root of {cwd}: the git worktree root of the directory, or
--- {cwd} itself outside a git repository (or without git installed).
---@param cwd string
---@return string root
M._root = function(cwd)
  local ok, out = pcall(vim.fn.system, { "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if ok and vim.v.shell_error == 0 then
    local root = out:gsub("%s+$", "")
    if root ~= "" then
      return root
    end
  end
  return cwd
end

--- Git branch checked out in {cwd}: "" outside a git repository, on a
--- detached HEAD, or without git installed.
---@param cwd string
---@return string branch
M._branch = function(cwd)
  local ok, out = pcall(vim.fn.system, { "git", "-C", cwd, "branch", "--show-current" })
  if ok and vim.v.shell_error == 0 then
    return out:gsub("%s+$", "")
  end
  return ""
end

--- Expand command template placeholders:
---   {file}           absolute path of the most recently visited file buffer
---   {file_basename}  its name without the directory
---   {file_dirname}   its directory
---   {cwd}            the terminal's live working directory
---   {root}           git worktree root of {cwd} (or {cwd} outside git)
---   {git_branch}     the git branch checked out in {cwd} ("" outside git)
---   {selection}     the last visual selection in that file buffer
---   {cursor}         removed; reports the position for the edit prompt
--- A placeholder whose value is unknown (no file visited yet, no cwd, no
--- selection) expands to an empty string; anything else, like ${HOME}, is
--- untouched.
---@param cmd string
---@param cwd string?
---@return string expanded
---@return number? cursor 1-based byte position of the first {cursor}
M.expand = function(cmd, cwd)
  local file = last_file
  local values = {
    file_basename = file and vim.fn.fnamemodify(file, ":t") or "",
    file_dirname = file and vim.fn.fnamemodify(file, ":h") or "",
    file = file or "",
    cwd = cwd or "",
    root = cwd and M._root(cwd) or "",
    git_branch = cwd and M._branch(cwd) or "",
    -- last_file holds the buffer name; resolve it (a wiped buffer gives -1,
    -- which _selection rejects).
    selection = file and M._selection(vim.fn.bufnr(file)) or "",
  }
  local out, cursor, pos = {}, nil, 1
  while true do
    local s, e, key = cmd:find("{([%w_]+)}", pos)
    if not s then
      out[#out + 1] = cmd:sub(pos)
      break
    end
    out[#out + 1] = cmd:sub(pos, s - 1)
    if key == "cursor" then
      cursor = cursor or #table.concat(out) + 1
    else
      out[#out + 1] = values[key] or cmd:sub(s, e)
    end
    pos = e + 1
  end
  return table.concat(out), cursor
end

---@param path string
---@return table
M._load_file = function(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, mod = pcall(dofile, path)
  if not ok or type(mod) ~= "table" then
    vim.notify(("termforge: %s could not be loaded"):format(path), vim.log.levels.WARN)
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

--- Path of the commands file for {cwd}: the project-local file, or the
--- global file without a cwd.
---@param cwd string?
---@return string path
M._commands_path = function(cwd)
  local cfg = core.config.commands
  if cwd then
    return cwd .. "/" .. cfg.local_commands_file
  end
  return cfg.global_commands_file
end

--- Open the commands file in a split, creating it (and its directory)
--- with a commented stub when it does not exist yet. The split is
--- scheduled and guarded: from a picker callback a synchronous split
--- would surface the swap-file ATTENTION dialog (E325) as a raw error
--- when the file is open in another session; scheduled, the dialog
--- works, and a real failure becomes a notification.
---@param path string
M._open_commands = function(path)
  if vim.fn.filereadable(path) ~= 1 then
    pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({
      "-- Commands for termforge.launch (<leader>ll).",
      '-- Format: return { { name = "build", cmd = "cargo build" } }',
      "-- Placeholders: {file}, {file_basename}, {file_dirname}, {cwd},",
      "-- {root}, {git_branch}, {selection}, {cursor}; see :h termforge-commands.",
      "return {",
      "}",
    }, path)
  end
  vim.schedule(function()
    local ok, err = pcall(vim.cmd, "split " .. vim.fn.fnameescape(path))
    if not ok then
      vim.notify(("termforge: could not open %s (%s)"):format(path, err), vim.log.levels.ERROR)
    end
  end)
end

--- Open the commands file for editing: the project-local file of the
--- current terminal; outside a terminal, the one at the project root of
--- the last visited file; without either, the global file. Missing
--- files and directories are created.
M.edit_commands = function()
  local _, _, cwd = core.terminal_context()
  if not cwd and last_file then
    cwd = M._root(vim.fn.fnamemodify(last_file, ":h"))
  end
  M._open_commands(M._commands_path(cwd))
end

--- Offer to open the commands file when the picker would be empty.
---@param bufnr number
---@param restore boolean true when launched from Terminal mode
---@param cwd string?
M._offer_edit = function(bufnr, restore, cwd)
  local path = M._commands_path(cwd)
  vim.ui.select({ "Edit", "Cancel" }, {
    prompt = "termforge: no commands found. Edit " .. path .. "?",
  }, function(choice)
    if choice == "Edit" then
      M._open_commands(path)
    elseif restore then
      core.enter_terminal_mode(bufnr)
    end
  end)
end

--- Move the cursor in the edit prompt to {cursor} (1-based byte position
--- in {default}). Called from a CmdlineChanged autocmd while the prompt is
--- open: the default vim.ui.input is a synchronous input() wrapper, so the
--- prompt is a command line (type "@"). input() inserts the default
--- character by character, so wait for the line to be complete.
--- Returns true when the cursor was placed.
---@param cursor number
---@param default string
---@return boolean placed
M._place_cursor = function(cursor, default)
  if vim.fn.getcmdtype() ~= "@" or vim.fn.getcmdprompt() ~= PROMPT then
    return false
  end
  if vim.fn.getcmdline() ~= default then
    return false
  end
  pcall(vim.fn.setcmdline, default, cursor)
  return true
end

--- Arm cursor placement for the next edit prompt. Pickers or other
--- vim.ui.input implementations never open a command line; the autocmd
--- is removed when the input finishes (see M._run).
---@param cursor number
---@param default string
M._arm_cursor = function(cursor, default)
  vim.api.nvim_create_augroup("termforge-launch-cursor", { clear = true })
  vim.api.nvim_create_autocmd("CmdlineChanged", {
    group = "termforge-launch-cursor",
    callback = function()
      if M._place_cursor(cursor, default) then
        pcall(vim.api.nvim_del_augroup_by_name, "termforge-launch-cursor")
      end
    end,
  })
end

local disarm_cursor = function()
  pcall(vim.api.nvim_del_augroup_by_name, "termforge-launch-cursor")
end

--- Send the command (possibly edited).
---@param bufnr number
---@param job_id number
---@param cmd string
---@param restore boolean true when launched from Terminal mode
---@param cursor number? position for the edit prompt, from {cursor}
M._run = function(bufnr, job_id, cmd, restore, cursor)
  if not core.config.commands.edit_before_run then
    last_cmd = cmd
    core.send(bufnr, job_id, cmd)
    return
  end
  if cursor then
    M._arm_cursor(cursor, cmd)
  end
  vim.ui.input({ prompt = PROMPT, default = cmd }, function(edited)
    disarm_cursor()
    if not edited then
      if restore then
        core.enter_terminal_mode(bufnr)
      end
      return -- canceled
    end
    last_cmd = edited == "" and cmd or edited
    core.send(bufnr, job_id, last_cmd)
  end)
end

--- Repeat the last command fired through the launcher, in the terminal
--- the cursor is in now (which may be a different one than back then).
M.repeat_last = function()
  if not last_cmd then
    vim.notify("termforge: no command fired yet.", vim.log.levels.WARN)
    return
  end
  local bufnr, job_id = core.terminal_context()
  if not job_id then
    vim.notify("termforge: cursor is not in a terminal.", vim.log.levels.WARN)
    return
  end
  core.send(bufnr, job_id, last_cmd)
end

--- Send `cd <directory of the last visited file>` to the current
--- terminal: the shell navigates to where the edited file lives.
M.cd = function()
  local bufnr, job_id = core.terminal_context()
  if not job_id then
    vim.notify("termforge: cursor is not in a terminal.", vim.log.levels.WARN)
    return
  end
  if not last_file then
    vim.notify("termforge: no file visited yet.", vim.log.levels.WARN)
    return
  end
  core.send(bufnr, job_id, "cd " .. vim.fn.shellescape(vim.fn.fnamemodify(last_file, ":h")))
end

--- Main entry point: open the picker and fire a command into the current
--- terminal.
M.launch = function()
  local bufnr, job_id, cwd = core.terminal_context()
  if not job_id then
    vim.notify("termforge: cursor is not in a terminal.", vim.log.levels.WARN)
    return
  end

  local commands = M._collect(cwd)

  -- When the picker was opened from Terminal mode, restore it after every
  -- cancel (the terminal buffer is nomodifiable; keys would otherwise be
  -- lost in Normal mode).
  local restore = vim.api.nvim_get_mode().mode == "t"

  if #commands == 0 then
    M._offer_edit(bufnr, restore, cwd)
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
    -- <C-e> in the picker (Telescope and snacks) opens the commands
    -- file for editing.
    actions = {
      {
        key = "<C-e>",
        fn = function()
          M.edit_commands()
        end,
      },
    },
  }, function(choice)
    if not choice then
      if restore then
        core.enter_terminal_mode(bufnr)
      end
      return
    end
    -- Expand templates at pick time: the edit prompt shows the expanded
    -- command, the picker display stays raw.
    local expanded, cursor = M.expand(choice.cmd, cwd)
    M._run(bufnr, job_id, expanded, restore, cursor)
  end)
end

return M
