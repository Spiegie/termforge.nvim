-- termforge.session — persist terminals across :mksession.
--
-- Neovim restores terminal buffers itself with `sessionoptions += terminal`:
-- same command, same window — but in the directory they were opened in.
-- This module additionally records each terminal's live directory (it
-- follows cd, see termforge.terminal_cwd) in a sidecar file next to the
-- session and navigates the restored shells back there after loading.

local M = {}

local core = require("termforge")

--- Sidecar file for a session file.
---@param session_file string
---@return string
M.sidecar = function(session_file)
  return session_file .. ".termforge.json"
end

--- Write the live CWD of all running terminals to the sidecar file.
--- Called automatically on SessionWritePost; without {session_file},
--- v:this_session is used (only set from SessionWritePost on).
---@param session_file string? path of the session file
M.save = function(session_file)
  session_file = session_file or vim.v.this_session
  if not session_file or session_file == "" then
    return
  end
  local terminals = {}
  for _, t in ipairs(core.terminals()) do
    local cwd = core.terminal_cwd(t.bufnr, t.job_id)
    if cwd then
      terminals[#terminals + 1] = {
        -- The original name, not term://<label>: restored buffers carry
        -- the original name, so matching must not see the label.
        name = vim.b[t.bufnr].termforge_original_name or t.title,
        cwd = cwd,
        label = vim.b[t.bufnr].termforge_label,
      }
    end
  end
  local ok = pcall(vim.fn.writefile, { vim.json.encode({ terminals = terminals }) }, M.sidecar(session_file))
  if not ok then
    vim.notify("termforge: terminal sidecar could not be written.", vim.log.levels.WARN)
  end
end

--- Navigate restored shells back to their recorded directories with `cd`.
--- Called automatically on SessionLoadPost.
---@param session_file string? path of the session file
M.restore = function(session_file)
  session_file = session_file or vim.v.this_session
  if not session_file or session_file == "" then
    return
  end
  local path = M.sidecar(session_file)
  if vim.fn.filereadable(path) ~= 1 then
    return
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" or type(data.terminals) ~= "table" then
    vim.notify("termforge: terminal sidecar could not be read.", vim.log.levels.WARN)
    return
  end

  local restore_cwd = type(core.config.session) == "table" and core.config.session.restore_cwd
  local by_name = {}
  for _, t in ipairs(core.terminals()) do
    by_name[t.title] = t
  end

  for _, entry in ipairs(data.terminals) do
    if type(entry) == "table" and type(entry.name) == "string" and type(entry.cwd) == "string" then
      local t = by_name[entry.name]
      if t then
        if type(entry.label) == "string" then
          core.label(t.bufnr, entry.label)
        end
        if restore_cwd and vim.fn.isdirectory(entry.cwd) == 1 then
          local live = core.terminal_cwd(t.bufnr, t.job_id)
          if live ~= entry.cwd then
            -- wait briefly for the shell to finish its rc files; the pty
            -- input buffers in the meantime
            vim.defer_fn(function()
              if vim.fn.jobwait({ t.job_id }, 0)[1] == -1 then
                vim.fn.chansend(t.job_id, "cd " .. vim.fn.fnameescape(entry.cwd) .. "\r")
              end
            end, 100)
          end
        end
      end
    end
  end
end

--- Replace label names (term://<label>) in a freshly written session file
--- with the buffers' original names: on restore, Neovim would otherwise
--- try to run the label as the terminal command. The labels themselves
--- stay on the buffers and are re-applied after restoring (M.restore).
---@param session_file string
M._rewrite_labels = function(session_file)
  if not session_file or session_file == "" or vim.fn.filereadable(session_file) ~= 1 then
    return
  end
  local replacements = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local label = vim.b[bufnr].termforge_label
      local original = vim.b[bufnr].termforge_original_name
      if label and original then
        replacements[#replacements + 1] = { from = "term://" .. label, to = original }
      end
    end
  end
  if #replacements == 0 then
    return
  end
  local lines = vim.fn.readfile(session_file)
  local changed = false
  for i, _ in ipairs(lines) do
    for _, r in ipairs(replacements) do
      local pos = lines[i]:find(r.from, 1, true)
      while pos do
        lines[i] = lines[i]:sub(1, pos - 1) .. r.to .. lines[i]:sub(pos + #r.from)
        changed = true
        pos = lines[i]:find(r.from, pos + #r.to, true)
      end
    end
  end
  if changed then
    vim.fn.writefile(lines, session_file)
  end
end

--- Register autocmds and enable Neovim's terminal restoration.
M.setup = function()
  local flags = vim.split(vim.o.sessionoptions, ",", { plain = true })
  if not vim.tbl_contains(flags, "terminal") then
    vim.opt.sessionoptions:append("terminal")
  end
  local group = vim.api.nvim_create_augroup("termforge-session", { clear = true })
  vim.api.nvim_create_autocmd("SessionWritePost", {
    group = group,
    callback = function()
      M._rewrite_labels(vim.v.this_session)
      M.save()
    end,
  })
  vim.api.nvim_create_autocmd("SessionLoadPost", {
    group = group,
    callback = function()
      M.restore()
    end,
  })
end

return M
