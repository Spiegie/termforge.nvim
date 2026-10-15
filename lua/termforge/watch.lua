-- termforge.watch — notify when commands in terminal shells finish.
--
-- Neovim cannot see command boundaries inside a terminal shell, so the
-- shell integration (shell/termforge.{zsh,bash,fish}, sourced from the
-- user's rc) writes a marker file after every command:
-- /tmp/termforge-cmd-<shell-pid> containing "<exit> <duration> <command>".
-- This module polls those files for every live terminal and turns them
-- into vim.notify() calls.

local M = {}

local core = require("termforge")

local uv = vim.uv or vim.loop
local timer = nil
local INTERVAL_MS = 250

--- Marker file the shell integration writes after each command.
---@param pid number shell process id
---@return string
M.marker = function(pid)
  return "/tmp/termforge-cmd-" .. pid
end

--- Absolute path of the shell integration snippet ("zsh", "bash" or
--- "fish"), for sourcing from the shell rc.
---@param shell string
---@return string
M.snippet = function(shell)
  local here = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(here) .. "/../../shell/termforge." .. shell
end

local function format_duration(seconds)
  if seconds >= 60 then
    return ("%dm %ds"):format(math.floor(seconds / 60), seconds % 60)
  end
  return ("%ds"):format(seconds)
end

local function notify(cmd, exit_code, duration)
  if cmd == "" then
    cmd = "command"
  end
  if #cmd > 60 then
    cmd = cmd:sub(1, 57) .. "..."
  end
  local duration_s = format_duration(duration)
  if exit_code == 0 then
    vim.notify(("%s finished (%s)"):format(cmd, duration_s), vim.log.levels.INFO, { title = "termforge" })
  else
    vim.notify(
      ("%s failed (exit %d, %s)"):format(cmd, exit_code, duration_s),
      vim.log.levels.ERROR,
      { title = "termforge" }
    )
  end
end

local function tick()
  local min_duration = (core.config.notify or {}).min_duration or 1
  for _, t in ipairs(core.terminals()) do
    local ok, pid = pcall(vim.fn.jobpid, t.job_id)
    if ok and type(pid) == "number" and pid > 0 then
      local marker = M.marker(pid)
      if vim.fn.filereadable(marker) == 1 then
        local content = vim.fn.readfile(marker)[1]
        -- A partially written file is left alone and retried next tick.
        if content then
          local exit_code, duration, cmd = content:match("^(%d+) (%d+) (.*)$")
          if exit_code then
            vim.fn.delete(marker)
            if tonumber(duration) >= min_duration then
              notify(cmd, tonumber(exit_code), tonumber(duration))
            end
          end
        end
      end
    end
  end
end

--- Start polling for finished commands. Called by termforge.setup().
M.setup = function()
  if timer then
    return
  end
  timer = uv.new_timer()
  timer:start(INTERVAL_MS, INTERVAL_MS, vim.schedule_wrap(tick))
end

return M
