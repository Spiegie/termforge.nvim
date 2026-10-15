-- Test suite for termforge.nvim.
--
-- Run from the repository root:
--   nvim --headless -l tests/test.lua
--
-- Exits with status 1 if any test fails.

local root = (arg and arg[0] or ''):match('^(.*)tests[/\\]test%.lua$')
if not root or root == '' then root = vim.fn.getcwd() .. '/' end

-- Neovim resolves modules from the runtimepath before package.path, so an
-- installed copy of this plugin would shadow the repository. Put the
-- repository first so the code under test is the one in this checkout.
vim.opt.runtimepath:prepend(root)

package.path = root .. 'lua/?.lua;' .. root .. 'tests/?.lua;' .. package.path

local inspect = require('lib.inspect')
local core = require('termforge')
local launch = require('termforge.launch')
local pickers = require('termforge.pickers')

local api = vim.api
local failures = 0

local function eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then return end
  failures = failures + 1
  print('FAIL: ' .. msg)
  print('  expected: ' .. inspect(expected))
  print('  actual:   ' .. inspect(actual))
end

-- Scratch directory for command files written by the tests.
local tmpdir = vim.fn.tempname() .. '-termforge-tests'
vim.fn.mkdir(tmpdir, 'p')

local function write(path, lines) vim.fn.writefile(lines, path) end

local function buf_contains(bufnr, needle)
  for _, line in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then return true end
  end
  return false
end

-- Open a terminal in the current window; returns bufnr, job_id.
local function open_terminal()
  vim.cmd('terminal')
  local bufnr = api.nvim_get_current_buf()
  return bufnr, vim.b[bufnr].terminal_job_id
end

-- The terminals() entry for bufnr, or nil.
local function find_terminal(bufnr)
  for _, t in ipairs(core.terminals()) do
    if t.bufnr == bufnr then return t end
  end
  return nil
end

-- True when lhs is mapped in mode.
local function mapped(lhs, mode)
  local d = vim.fn.maparg(lhs, mode, false, true)
  return type(d) == 'table' and next(d) ~= nil
end

-- ---------------------------------------------------------- command files --

do
  eq(launch._load_file(tmpdir .. '/missing.lua'), {}, '_load_file: missing file yields no commands')
end

do
  local f = tmpdir .. '/commands.lua'
  write(f, {
    'return {',
    '  { name = "build", cmd = "cargo build --release" },',
    '  { cmd = "ls -la" },',
    '  { name = "no-cmd" },',
    '  "not a table",',
    '}',
  })
  eq(launch._load_file(f), {
    { name = 'build', cmd = 'cargo build --release' },
    { name = 'ls -la', cmd = 'ls -la' },
  }, '_load_file: valid entries, name defaults to cmd, invalid entries dropped')
end

do
  local f = tmpdir .. '/broken.lua'
  write(f, { 'return {' })
  eq(launch._load_file(f), {}, '_load_file: broken file yields no commands')
end

do
  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/global.lua',
  }
  write(tmpdir .. '/commands.lua', {
    'return { { name = "build", cmd = "local build" }, { name = "only-local", cmd = "ll" } }',
  })
  write(tmpdir .. '/global.lua', {
    'return { { name = "build", cmd = "global build" }, { name = "global-only", cmd = "gg" } }',
  })
  eq(launch._collect(tmpdir), {
    { name = 'build', cmd = 'local build' },
    { name = 'only-local', cmd = 'll' },
    { name = 'global-only', cmd = 'gg' },
  }, '_collect: local commands win on name collision, global appended')
  eq(launch._collect(nil), {
    { name = 'build', cmd = 'global build' },
    { name = 'global-only', cmd = 'gg' },
  }, '_collect: without cwd only global commands')
  core.config.commands = saved
end

-- ----------------------------------------------------------- terminal cwd --

do
  local bufnr, job_id = open_terminal()
  local cwd = core.terminal_cwd(bufnr, job_id)
  eq(type(cwd), 'string', 'terminal_cwd: live terminal yields a cwd')
  if cwd then
    eq(vim.fn.isdirectory(cwd), 1, 'terminal_cwd: live cwd is a directory')
    eq(cwd:match('^/proc/%d+/cwd$') ~= nil, false, 'terminal_cwd: /proc symlink is resolved')
  end
end

do
  local bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(bufnr, 'term://~/termforge-cwd-test//7:' .. vim.o.shell)
  eq(
    core.terminal_cwd(bufnr, 999999),
    vim.fn.expand('~/termforge-cwd-test'),
    'terminal_cwd: fallback expands ~ from buffer name'
  )
  api.nvim_buf_delete(bufnr, { force = true })
end

do
  local bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(bufnr, 'term:///tmp/termforge-abs//7:' .. vim.o.shell)
  eq(
    core.terminal_cwd(bufnr, 999999),
    '/tmp/termforge-abs',
    'terminal_cwd: fallback keeps absolute paths'
  )
  api.nvim_buf_delete(bufnr, { force = true })
end

do
  local bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(bufnr, '/tmp/not-a-terminal.txt')
  eq(core.terminal_cwd(bufnr, 999999), nil, 'terminal_cwd: non-terminal buffer name yields nil')
  api.nvim_buf_delete(bufnr, { force = true })
end

-- -------------------------------------------------------------- terminals --

do
  local bufnr, job_id = open_terminal()
  local t = find_terminal(bufnr)
  eq(t ~= nil, true, 'terminals: live terminal is listed')
  if t then
    eq(t.job_id, job_id, 'terminals: entry carries the job id')
    eq(t.title, api.nvim_buf_get_name(bufnr), 'terminals: entry carries the buffer name')
  end

  vim.fn.jobstop(job_id)
  vim.wait(500, function() return find_terminal(bufnr) == nil end)
  eq(find_terminal(bufnr) == nil, true, 'terminals: dead terminal is not listed')
end

do
  local bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'plain buffer' })
  eq(find_terminal(bufnr) == nil, true, 'terminals: non-terminal buffer is not listed')
  api.nvim_buf_delete(bufnr, { force = true })
end

-- ------------------------------------------------------------------- send --

do
  local bufnr, job_id = open_terminal()
  core.send(bufnr, job_id, 'echo TERMFORGE_SEND_MARKER')
  local ok = vim.wait(2000, function() return buf_contains(bufnr, 'TERMFORGE_SEND_MARKER') end)
  eq(ok, true, 'send: command runs in the terminal and output lands in the buffer')
end

do
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
  core.send(999999, 1, 'x')
  vim.notify = orig_notify
  eq(#notified, 1, 'send: invalid buffer notifies once')
  if notified[1] then
    eq(notified[1].level, vim.log.levels.ERROR, 'send: invalid buffer notifies at ERROR level')
  end
end

-- ------------------------------------------------------------------ setup --

do
  local saved_config = core.config
  core.setup({})
  eq(mapped('<leader>ll', 'n'), true, 'setup: launch keymap defaults to <leader>ll (normal mode)')
  eq(mapped('<leader>ll', 't'), true, 'setup: launch keymap defaults to <leader>ll (terminal mode)')
  eq(mapped('<leader>lb', 'n'), true, 'setup: buffers keymap defaults to <leader>lb (normal mode)')
  eq(
    mapped('<leader>lb', 't'),
    true,
    'setup: buffers keymap defaults to <leader>lb (terminal mode)'
  )
  eq(vim.fn.maparg('<Esc>', 't', false, true).rhs, '<C-\\><C-n>', 'setup: Esc leaves Terminal mode')
  eq(mapped('<leader>ls', 'n'), true, 'setup: send keymap defaults to <leader>ls (normal mode)')
  eq(mapped('<leader>ls', 'x'), true, 'setup: send keymap defaults to <leader>ls (visual mode)')
  eq(mapped('<leader>lr', 'n'), true, 'setup: repeat keymap defaults to <leader>lr (normal mode)')
  eq(mapped('<leader>lr', 't'), true, 'setup: repeat keymap defaults to <leader>lr (terminal mode)')
  eq(mapped('<leader>lc', 'n'), true, 'setup: cd keymap defaults to <leader>lc (normal mode)')
  eq(mapped('<leader>lc', 't'), true, 'setup: cd keymap defaults to <leader>lc (terminal mode)')
  eq(mapped('<leader>lt', 'n'), true, 'setup: last keymap defaults to <leader>lt (normal mode)')
  eq(mapped('<leader>lt', 't'), true, 'setup: last keymap defaults to <leader>lt (terminal mode)')

  pcall(vim.keymap.del, 'n', '<leader>ll')
  pcall(vim.keymap.del, 't', '<leader>ll')
  core.setup({ keymaps = { launch = false, buffers = '<leader>xb' } })
  eq(mapped('<leader>ll', 'n'), false, 'setup: launch = false leaves the keymap unset')
  eq(mapped('<leader>xb', 'n'), true, 'setup: custom buffers keymap is set')

  for _, mode in ipairs({ 'n', 't', 'x' }) do
    for _, key in ipairs({
      '<leader>ll',
      '<leader>lb',
      '<leader>xb',
      '<leader>ls',
      '<leader>lr',
      '<leader>lc',
      '<leader>lt',
      '<Esc>',
    }) do
      pcall(vim.keymap.del, mode, key)
    end
  end
  core.config = saved_config
end

-- ---------------------------------------------------------------- pickers --

do
  local has_telescope = pcall(require, 'telescope.pickers')
  local has_snacks = pcall(require, 'snacks.picker')
  if not has_telescope then
    eq(
      pickers._telescope({}, {}, function() end),
      false,
      'pickers: _telescope reports unhandled without telescope'
    )
  end
  if not has_snacks then
    eq(
      pickers._snacks({}, {}, function() end),
      false,
      'pickers: _snacks reports unhandled without snacks'
    )
  end

  local captured, chosen
  local orig_select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts }
    on_choice(items[2])
  end
  pickers.select({ 'a', 'b' }, {
    prompt = 'test',
    format = function(s) return '>' .. s end,
  }, function(item) chosen = item end)
  vim.ui.select = orig_select

  if not has_telescope and not has_snacks then
    eq(chosen, 'b', 'pickers: falls back to vim.ui.select and delivers the choice')
    eq(captured.opts.prompt, 'test: ', 'pickers: prompt is passed to vim.ui.select')
    eq(captured.opts.format_item('b'), '>b', 'pickers: format becomes format_item')
  end
end

-- ----------------------------------------------------------------- launch --

do
  local bufnr, job_id = open_terminal()
  -- The launcher reads commands from the terminal process' live cwd, so the
  -- test command file has to be written there (not into the test tmpdir).
  local cwd = core.terminal_cwd(bufnr, job_id)
  local cmdfile = cwd .. '/commands.lua'
  write(cmdfile, { 'return { { name = "marker", cmd = "echo TERMFORGE_LAUNCH_MARKER" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
    edit_before_run = true,
  }

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
  vim.ui.input = function(opts, on_confirm) on_confirm(opts.default) end

  launch.launch()

  vim.ui.select, vim.ui.input = orig_select, orig_input
  core.config.commands = saved

  local ok = vim.wait(2000, function() return buf_contains(bufnr, 'TERMFORGE_LAUNCH_MARKER') end)
  eq(ok, true, 'launch: picked command runs in the current terminal')
  vim.fn.delete(cmdfile)
end

-- ------------------------------------------------------------ send lines --

local send = require('termforge.send')

do
  send.setup()
  local tbuf = open_terminal()
  eq(send.target() ~= nil, true, 'send: opened terminal becomes the target')

  local src = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(src, 0, -1, false, { 'echo SEL_A', 'echo SEL_B', 'echo SEL_C' })
  send.range(src, 1, 1)
  eq(
    vim.wait(2000, function() return buf_contains(tbuf, 'SEL_A') end),
    true,
    'send: range lands in the target terminal'
  )

  api.nvim_set_current_buf(src)
  api.nvim_win_set_cursor(0, { 2, 0 })
  send.line()
  eq(
    vim.wait(2000, function() return buf_contains(tbuf, 'SEL_B') end),
    true,
    'send: line() sends the cursor line'
  )

  send.line(2)
  eq(
    vim.wait(2000, function() return buf_contains(tbuf, 'SEL_C') end),
    true,
    'send: line(count) sends count lines'
  )

  api.nvim_buf_set_lines(src, 0, -1, false, { 'echo SEL_D', 'echo SEL_E', 'echo SEL_F' })
  -- '< '> cannot be set through :normal in headless mode; set them directly.
  api.nvim_buf_set_mark(src, '<', 1, 0, {})
  api.nvim_buf_set_mark(src, '>', 3, 0, {})
  send.selection()
  eq(
    vim.wait(
      2000,
      function() return buf_contains(tbuf, 'SEL_D') and buf_contains(tbuf, 'SEL_F') end
    ),
    true,
    'send: selection() sends the selected lines'
  )
end

do
  send.setup()
  local _, tjob = open_terminal()
  vim.fn.jobstop(tjob)
  vim.wait(500, function() return vim.fn.jobwait({ tjob }, 0)[1] ~= -1 end)
  eq(send.target() == nil, true, 'send: dead target terminal is rejected')

  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
  local src = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(src, 0, -1, false, { 'x' })
  send.range(src, 1, 1)
  vim.notify = orig_notify
  eq(#notified, 1, 'send: without a live target it notifies once')
  if notified[1] then
    eq(notified[1].level, vim.log.levels.WARN, 'send: missing target notifies at WARN level')
  end
end

-- --------------------------------------------------------------- session --

local session = require('termforge.session')

do
  eq(
    session.sidecar('/tmp/sess.vim'),
    '/tmp/sess.vim.termforge.json',
    'session: sidecar path is derived from the session file'
  )
end

do
  session.setup()
  local flags = vim.split(vim.o.sessionoptions, ',', { plain = true })
  eq(vim.tbl_contains(flags, 'terminal'), true, 'session: setup adds terminal to sessionoptions')
  local events = {}
  for _, c in ipairs(api.nvim_get_autocmds({ group = 'termforge-session' })) do
    events[#events + 1] = c.event
  end
  table.sort(events)
  eq(events, { 'SessionLoadPost', 'SessionWritePost' }, 'session: setup registers both autocmds')
end

do
  local sess = tmpdir .. '/save-session.vim'
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'cd ' .. vim.fn.fnameescape(tmpdir) .. '\r')
  eq(
    vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end),
    true,
    'session: shell follows cd into the test directory'
  )
  local aname = api.nvim_buf_get_name(bufnr)
  session.save(sess)
  local data = vim.json.decode(table.concat(vim.fn.readfile(session.sidecar(sess)), '\n'))
  local entry = nil
  for _, e in ipairs(data.terminals) do
    if e.name == aname then entry = e end
  end
  eq(entry ~= nil, true, 'session: save records the terminal by buffer name')
  if entry then eq(entry.cwd, tmpdir, 'session: save records the live cwd') end
end

do
  local sess = tmpdir .. '/restore-session.vim'
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'cd ' .. vim.fn.fnameescape(tmpdir) .. '\r')
  vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end)
  local aname = api.nvim_buf_get_name(bufnr)
  session.save(sess)

  -- Simulate a restored session: the original terminal is gone, a fresh one
  -- carries the old buffer name (Nvim recreates terminal buffers by name).
  vim.fn.jobstop(job_id)
  vim.wait(500, function() return vim.fn.jobwait({ job_id }, 0)[1] ~= -1 end)
  api.nvim_buf_delete(bufnr, { force = true })
  local rbuf, rjob = open_terminal()
  api.nvim_buf_set_name(rbuf, aname)

  session.restore(sess)
  eq(
    vim.wait(2000, function() return core.terminal_cwd(rbuf, rjob) == tmpdir end),
    true,
    'session: restore navigates the restored shell back to the recorded cwd'
  )
end

do
  local sess = tmpdir .. '/nocwd-session.vim'
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'cd ' .. vim.fn.fnameescape(tmpdir) .. '\r')
  vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end)
  local aname = api.nvim_buf_get_name(bufnr)
  session.save(sess)

  vim.fn.jobstop(job_id)
  vim.wait(500, function() return vim.fn.jobwait({ job_id }, 0)[1] ~= -1 end)
  api.nvim_buf_delete(bufnr, { force = true })
  local rbuf, rjob = open_terminal()
  api.nvim_buf_set_name(rbuf, aname)

  local saved = core.config.session
  core.config.session = { enabled = true, restore_cwd = false }
  session.restore(sess)
  core.config.session = saved

  -- Give a wrongly deferred `cd` time to land before checking.
  vim.wait(300, function() return false end)
  eq(
    core.terminal_cwd(rbuf, rjob) ~= tmpdir,
    true,
    'session: restore_cwd = false leaves the restored shell alone'
  )
end

do
  local sess = tmpdir .. '/missing-session.vim'
  local bufnr, job_id = open_terminal()
  local aname = api.nvim_buf_get_name(bufnr)
  write(session.sidecar(sess), {
    vim.json.encode({ terminals = { { name = aname, cwd = '/nonexistent-termforge-dir' } } }),
  })
  session.restore(sess)
  vim.wait(300, function() return false end)
  eq(
    buf_contains(bufnr, 'nonexistent-termforge-dir'),
    false,
    'session: entries with a missing cwd are skipped'
  )
  vim.fn.jobstop(job_id)
  vim.wait(500, function() return vim.fn.jobwait({ job_id }, 0)[1] ~= -1 end)
  api.nvim_buf_delete(bufnr, { force = true })
end

do
  local sess = tmpdir .. '/wiring-session.vim'
  vim.cmd('mksession! ' .. vim.fn.fnameescape(sess))
  eq(vim.fn.filereadable(sess), 1, 'session: mksession writes the session file')
  eq(
    vim.fn.filereadable(session.sidecar(sess)),
    1,
    'session: SessionWritePost writes the sidecar next to the session file'
  )
end

-- ------------------------------------------------------------------ watch --

local watch = require('termforge.watch')

do
  eq(
    watch.marker(123),
    '/tmp/termforge-cmd-123',
    'watch: marker path is derived from the shell pid'
  )
end

do
  eq(vim.fn.filereadable(watch.snippet('zsh')), 1, 'watch: snippet path points into the plugin')
end

do
  watch.setup()
  local bufnr, job_id = open_terminal()
  local pid = vim.fn.jobpid(job_id)
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, opts)
    notified[#notified + 1] = { msg = msg, level = level, opts = opts }
  end
  write(watch.marker(pid), { '0 5 sleep 5' })
  local ok = vim.wait(2000, function() return #notified > 0 end)
  vim.notify = orig_notify
  eq(ok, true, 'watch: marker file turns into a notification')
  if notified[1] then
    eq(notified[1].level, vim.log.levels.INFO, 'watch: exit 0 notifies at INFO level')
    eq(notified[1].opts.title, 'termforge', 'watch: notification carries the termforge title')
    eq(
      notified[1].msg:find('sleep 5', 1, true) ~= nil,
      true,
      'watch: notification names the command'
    )
    eq(
      notified[1].msg:find('5s', 1, true) ~= nil,
      true,
      'watch: notification includes the duration'
    )
  end
  eq(vim.fn.filereadable(watch.marker(pid)), 0, 'watch: marker file is deleted after reading')
end

do
  watch.setup()
  local bufnr, job_id = open_terminal()
  local pid = vim.fn.jobpid(job_id)
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, opts) notified[#notified + 1] = { msg = msg, level = level } end
  write(watch.marker(pid), { '1 3 cargo build' })
  local ok = vim.wait(2000, function() return #notified > 0 end)
  vim.notify = orig_notify
  eq(ok, true, 'watch: nonzero exit notifies')
  if notified[1] then
    eq(notified[1].level, vim.log.levels.ERROR, 'watch: nonzero exit notifies at ERROR level')
    eq(
      notified[1].msg:find('exit 1', 1, true) ~= nil,
      true,
      'watch: failure message includes the exit code'
    )
  end
end

do
  watch.setup()
  local bufnr, job_id = open_terminal()
  local pid = vim.fn.jobpid(job_id)
  local saved = core.config.notify
  core.config.notify = { enabled = true, min_duration = 10 }
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, opts) notified[#notified + 1] = msg end
  write(watch.marker(pid), { '0 5 quick' })
  vim.wait(1000, function() return false end)
  vim.notify = orig_notify
  eq(#notified, 0, 'watch: commands below min_duration stay silent')
  eq(vim.fn.filereadable(watch.marker(pid)), 0, 'watch: suppressed marker file is still consumed')
  core.config.notify = saved
end

do
  watch.setup()
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, opts) notified[#notified + 1] = msg end
  write(watch.marker(999999), { '0 5 ghost' })
  vim.wait(1000, function() return false end)
  vim.notify = orig_notify
  eq(#notified, 0, 'watch: markers for unknown pids are ignored')
  vim.fn.delete(watch.marker(999999))
end

-- Real shell integration: source the snippet in an interactive shell inside
-- :terminal and expect a notification through the whole pipeline.
local function shell_end_to_end(shell)
  local saved = core.config.notify
  core.config.notify = { enabled = true, min_duration = 0 }
  local saved_shell = vim.o.shell
  vim.o.shell = shell
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, opts) notified[#notified + 1] = msg end
  local ok = pcall(function()
    vim.cmd('terminal')
    local bufnr = api.nvim_get_current_buf()
    local job_id = vim.b[bufnr].terminal_job_id
    vim.fn.chansend(job_id, 'source ' .. vim.fn.fnameescape(watch.snippet(shell)) .. '\n')
    vim.fn.chansend(job_id, 'sleep 0.3\n')
    vim.wait(5000, function() return #notified > 0 end)
  end)
  vim.notify = orig_notify
  vim.o.shell = saved_shell
  core.config.notify = saved
  return ok and #notified > 0 and notified[1]:find('sleep 0.3', 1, true) ~= nil
end

do
  if vim.fn.executable('zsh') == 1 then
    eq(
      shell_end_to_end('zsh'),
      true,
      'watch: zsh integration reports a finished command end to end'
    )
  end
  if vim.fn.executable('bash') == 1 then
    eq(
      shell_end_to_end('bash'),
      true,
      'watch: bash integration reports a finished command end to end'
    )
  end
  if vim.fn.executable('fish') == 1 then
    eq(
      shell_end_to_end('fish'),
      true,
      'watch: fish integration reports a finished command end to end'
    )
  end
end

-- ------------------------------------------------------------------ label --

do
  local bufnr, job_id = open_terminal()
  local original = api.nvim_buf_get_name(bufnr)
  eq(core.label(bufnr, 'build'), true, 'label: labeling a terminal succeeds')
  eq(api.nvim_buf_get_name(bufnr), 'term://build', 'label: buffer is renamed to term://<label>')
  eq(vim.b[bufnr].termforge_label, 'build', 'label: label is stored in a buffer variable')
  eq(vim.b[bufnr].termforge_original_name, original, 'label: original name is kept')
  eq(
    type(core.terminal_cwd(bufnr, job_id)),
    'string',
    'label: live cwd still resolves with a label'
  )
  local t = find_terminal(bufnr)
  eq(t ~= nil, true, 'label: labeled terminal is still listed')
  if t then eq(t.title, 'term://build', 'label: terminals() carries the labeled name') end
  eq(core.label(bufnr, nil), true, 'label: clearing succeeds')
  eq(api.nvim_buf_get_name(bufnr), original, 'label: clearing restores the original name')
  eq(vim.b[bufnr].termforge_label, nil, 'label: clearing removes the label variable')
  eq(
    vim.b[bufnr].termforge_original_name,
    nil,
    'label: clearing removes the original name variable'
  )
end

do
  local bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'plain buffer' })
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
  eq(core.label(bufnr, 'x'), false, 'label: non-terminal buffer is rejected')
  vim.notify = orig_notify
  eq(#notified, 1, 'label: non-terminal buffer notifies once')
  if notified[1] then
    eq(notified[1].level, vim.log.levels.WARN, 'label: non-terminal buffer notifies at WARN level')
  end
  api.nvim_buf_delete(bufnr, { force = true })
end

do
  local a = open_terminal()
  local b = open_terminal()
  eq(core.label(a, 'same'), true, 'label: first buffer takes the name')
  eq(core.label(b, 'same'), false, 'label: duplicate names are rejected')
  eq(
    api.nvim_buf_get_name(b) ~= 'term://same',
    true,
    'label: rejected label leaves the name unchanged'
  )
  core.label(a, nil)
end

do
  -- cwd fallback: a labeled buffer keeps resolving via the original name
  local bufnr = api.nvim_create_buf(false, false)
  api.nvim_buf_set_name(bufnr, 'term://build')
  vim.b[bufnr].termforge_original_name = 'term:///tmp/termforge-label-orig//7:sh'
  eq(
    core.terminal_cwd(bufnr, 999999),
    '/tmp/termforge-label-orig',
    'label: cwd fallback uses the original name'
  )
  api.nvim_buf_delete(bufnr, { force = true })
end

-- --------------------------------------------------------------- commands --

do
  core.setup({})
  eq(vim.fn.exists(':TermforgeLaunch') == 2, true, 'commands: TermforgeLaunch is registered')
  eq(vim.fn.exists(':TermforgeBuffers') == 2, true, 'commands: TermforgeBuffers is registered')
  eq(vim.fn.exists(':TermforgeSend') == 2, true, 'commands: TermforgeSend is registered')
  eq(vim.fn.exists(':TermforgeLabel') == 2, true, 'commands: TermforgeLabel is registered')
  eq(vim.fn.exists(':TermforgeRepeat') == 2, true, 'commands: TermforgeRepeat is registered')
  eq(vim.fn.exists(':TermforgeCd') == 2, true, 'commands: TermforgeCd is registered')
  eq(vim.fn.exists(':TermforgeCommands') == 2, true, 'commands: TermforgeCommands is registered')
  eq(vim.fn.exists(':TermforgeLast') == 2, true, 'commands: TermforgeLast is registered')
end

do
  send.setup()
  local tbuf = open_terminal()
  local src = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(src, 0, -1, false, { 'echo CMD_A', 'echo CMD_B', 'echo CMD_C' })
  api.nvim_set_current_buf(src)
  api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd('TermforgeSend')
  eq(
    vim.wait(2000, function() return buf_contains(tbuf, 'CMD_A') end),
    true,
    'commands: TermforgeSend sends the cursor line'
  )
  vim.cmd('2TermforgeSend')
  eq(
    vim.wait(2000, function() return buf_contains(tbuf, 'CMD_B') end),
    true,
    'commands: :NTermforgeSend sends line N'
  )
  api.nvim_buf_set_mark(src, '<', 1, 0, {})
  api.nvim_buf_set_mark(src, '>', 3, 0, {})
  vim.cmd("'<,'>TermforgeSend")
  eq(
    vim.wait(2000, function() return buf_contains(tbuf, 'CMD_C') end),
    true,
    "commands: :'<,'>TermforgeSend sends the range"
  )
end

do
  local bufnr = open_terminal()
  local original = api.nvim_buf_get_name(bufnr)
  vim.cmd('TermforgeLabel build')
  eq(api.nvim_buf_get_name(bufnr), 'term://build', 'commands: TermforgeLabel renames the buffer')
  vim.cmd('TermforgeLabel')
  eq(
    api.nvim_buf_get_name(bufnr),
    original,
    'commands: TermforgeLabel without argument clears the label'
  )
end

-- ----------------------------------------------------------------- health --

do
  local health = require('termforge.health')
  local log = {}
  local orig = {}
  for _, fn in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
    orig[fn] = vim.health[fn]
    vim.health[fn] = function(...) log[#log + 1] = { fn = fn, args = { ... } } end
  end
  local ok = pcall(health.check)
  for fn, _ in pairs(orig) do
    vim.health[fn] = orig[fn]
  end
  eq(ok, true, 'health: check() runs without errors')
  eq(#log > 0, true, 'health: check() reports something')
  local mentions_integration = false
  for _, entry in ipairs(log) do
    for _, v in ipairs(entry.args) do
      if type(v) == 'string' and v:lower():find('integration', 1, true) then
        mentions_integration = true
      end
    end
  end
  eq(mentions_integration, true, 'health: check() covers the shell integration')
end

-- --------------------------------------------------------- session + label --

do
  local sess = tmpdir .. '/label-session.vim'
  local bufnr, job_id = open_terminal()
  local original = api.nvim_buf_get_name(bufnr)
  core.label(bufnr, 'build')
  session.save(sess)
  local data = vim.json.decode(table.concat(vim.fn.readfile(session.sidecar(sess)), '\n'))
  local entry = nil
  for _, e in ipairs(data.terminals) do
    if e.label == 'build' then entry = e end
  end
  eq(entry ~= nil, true, 'session: save records the label')
  if entry then
    eq(entry.name, original, 'session: save records the original name for labeled terminals')
  end

  vim.fn.jobstop(job_id)
  vim.wait(500, function() return vim.fn.jobwait({ job_id }, 0)[1] ~= -1 end)
  api.nvim_buf_delete(bufnr, { force = true })
  local rbuf = open_terminal()
  api.nvim_buf_set_name(rbuf, original)
  session.restore(sess)
  eq(api.nvim_buf_get_name(rbuf), 'term://build', 'session: restore re-applies the label')
  eq(vim.b[rbuf].termforge_label, 'build', 'session: restore sets the label variable')
  core.label(rbuf, nil)
end

do
  local sess = tmpdir .. '/label-mksession.vim'
  local bufnr = open_terminal()
  local original = api.nvim_buf_get_name(bufnr)
  core.label(bufnr, 'build')
  vim.cmd('mksession! ' .. vim.fn.fnameescape(sess))
  eq(api.nvim_buf_get_name(bufnr), 'term://build', 'session: label is back after mksession')
  local content = table.concat(vim.fn.readfile(sess), '\n')
  eq(
    content:find('term://build', 1, true) ~= nil,
    false,
    'session: mksession does not record the label name'
  )
  eq(content:find(original, 1, true) ~= nil, true, 'session: mksession records the original name')
  eq(
    vim.fn.filereadable(session.sidecar(sess)),
    1,
    'session: sidecar is written for a labeled terminal'
  )
  core.label(bufnr, nil)
end

-- -------------------------------------------------------------- templates --

do
  eq(launch.expand('plain command', nil), 'plain command', 'expand: plain command stays unchanged')
  eq(launch.expand('{cwd}', '/tmp/termforge-cwd'), '/tmp/termforge-cwd', 'expand: {cwd} expands')
  eq(
    launch.expand('{file}', nil):find('{file}', 1, true) == nil,
    true,
    'expand: {file} is consumed even without a value'
  )
  eq(launch.expand('echo ${HOME}', nil), 'echo ${HOME}', 'expand: shell variables stay untouched')
  eq(launch.expand('{unknown}', nil), '{unknown}', 'expand: unknown placeholders stay untouched')
end

do
  local file = tmpdir .. '/main.py'
  write(file, { 'print("hi")' })
  launch.setup()
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  eq(launch.expand('{file}', '/cwd'), file, 'expand: {file} is the last visited file')
  eq(launch.expand('{file_basename}', '/cwd'), 'main.py', 'expand: {file_basename} is its name')
  eq(launch.expand('{file_dirname}', '/cwd'), tmpdir, 'expand: {file_dirname} is its directory')
  eq(launch.expand('{cwd}', '/cwd'), '/cwd', 'expand: {cwd} is the terminal cwd')
end

do
  local file = tmpdir .. '/main.py'
  write(file, { 'print("hi")' })
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  local bufnr, job_id = open_terminal()
  local cwd = core.terminal_cwd(bufnr, job_id)
  local cmdfile = cwd .. '/commands.lua'
  write(cmdfile, { 'return { { name = "tmpl", cmd = "echo TMPL_{file_basename}" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
    edit_before_run = true,
  }

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
  vim.ui.input = function(opts, on_confirm) on_confirm(opts.default) end

  launch.launch()

  vim.ui.select, vim.ui.input = orig_select, orig_input
  core.config.commands = saved

  local ok = vim.wait(2000, function() return buf_contains(bufnr, 'TMPL_main.py') end)
  eq(ok, true, 'launch: {file_basename} template expands at launch time')
  vim.fn.delete(cmdfile)
end

do
  local expanded, cursor = launch.expand('git checkout {cursor} main', nil)
  eq(expanded, 'git checkout  main', 'expand: {cursor} is removed from the command')
  eq(cursor, 14, 'expand: {cursor} reports its position')
  local _, none = launch.expand('plain command', nil)
  eq(none, nil, 'expand: no {cursor} yields no position')
  local _, first = launch.expand('a {cursor} b {cursor}', nil)
  eq(first, 3, 'expand: the first {cursor} wins')
  local _, at_end = launch.expand('pytest {cursor}', nil)
  eq(at_end, 8, 'expand: {cursor} at the end points past the last character')
end

do
  local bufnr, job_id = open_terminal()
  local armed = function()
    local ok, autocs = pcall(vim.api.nvim_get_autocmds, { group = 'termforge-launch-cursor' })
    return ok and #autocs > 0
  end
  local seen_armed = false
  local orig_input = vim.ui.input
  vim.ui.input = function(opts, on_confirm)
    seen_armed = armed()
    on_confirm(opts.default)
  end
  launch._run(bufnr, job_id, 'echo AB', false, 7)
  vim.ui.input = orig_input
  eq(seen_armed, true, 'cursor: placement is armed while the prompt is open')
  eq(armed(), false, 'cursor: placement is removed after the prompt')
  eq(launch._place_cursor(2, 'x'), false, 'cursor: placement ignores a foreign command line')
end

do
  -- End to end through the real vim.ui.input: the X typed into the edit
  -- prompt must land at the {cursor} position. feedkeys('xt') drives the
  -- input() prompt headlessly.
  local bufnr = open_terminal()
  local cwd = core.terminal_cwd(bufnr, vim.b[bufnr].terminal_job_id)
  local cmdfile = cwd .. '/commands.lua'
  write(cmdfile, { 'return { { name = "cur", cmd = "echo FORGECURSOR{cursor}END" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
    edit_before_run = true,
  }

  local orig_select = vim.ui.select
  vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
  _G.termforge_cursor_launch = function() launch.launch() end
  vim.fn.feedkeys(':lua termforge_cursor_launch()\rX\r', 'xt')
  vim.ui.select = orig_select
  core.config.commands = saved
  _G.termforge_cursor_launch = nil

  local ok = vim.wait(2000, function() return buf_contains(bufnr, 'FORGECURSORXEND') end)
  eq(ok, true, 'launch: typed text lands at the {cursor} position')
  vim.fn.delete(cmdfile)
end

do
  local buf = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'local foo = bar', 'second line', 'third' })
  eq(launch._selection(buf), nil, 'selection: a buffer without a selection yields nil')
  api.nvim_buf_set_mark(buf, '<', 1, 6, {})
  api.nvim_buf_set_mark(buf, '>', 1, 8, {})
  eq(launch._selection(buf), 'foo', 'selection: single-line selection')
  api.nvim_buf_set_mark(buf, '<', 1, 0, {})
  api.nvim_buf_set_mark(buf, '>', 3, 4, {})
  eq(
    launch._selection(buf),
    'local foo = bar second line third',
    'selection: multi-line selection joins the lines with a space'
  )
  api.nvim_buf_delete(buf, { force = true })
end

do
  local file = tmpdir .. '/sel.py'
  write(file, { 'value = 42' })
  launch.setup()
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  api.nvim_buf_set_mark(0, '<', 1, 0, {})
  api.nvim_buf_set_mark(0, '>', 1, 4, {})
  eq(
    launch.expand('rg -n {selection}', '/cwd'),
    'rg -n value',
    'expand: {selection} is the last selection in the last visited file'
  )
end

do
  local file = tmpdir .. '/sel.py'
  write(file, { 'value = 42' })
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  api.nvim_buf_set_mark(0, '<', 1, 0, {})
  api.nvim_buf_set_mark(0, '>', 1, 4, {})
  local bufnr, job_id = open_terminal()
  local cwd = core.terminal_cwd(bufnr, job_id)
  local cmdfile = cwd .. '/commands.lua'
  write(cmdfile, { 'return { { name = "sel", cmd = "echo SEL_{selection}" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
    edit_before_run = true,
  }

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
  vim.ui.input = function(opts, on_confirm) on_confirm(opts.default) end

  launch.launch()

  vim.ui.select, vim.ui.input = orig_select, orig_input
  core.config.commands = saved

  local ok = vim.wait(2000, function() return buf_contains(bufnr, 'SEL_value') end)
  eq(ok, true, 'launch: {selection} template expands at launch time')
  vim.fn.delete(cmdfile)
end

-- ------------------------------------------------------------------- root --

do
  local repo = root:gsub('/$', '')
  eq(launch._root(repo), repo, 'root: a repository root resolves to itself')
  eq(launch._root(tmpdir), tmpdir, 'root: outside a git repository the cwd is the root')
  eq(launch.expand('{root}', tmpdir), tmpdir, 'expand: {root} is the project root of the cwd')
  eq(launch.expand('{root}', nil), '', 'expand: {root} without a cwd is empty')
end

do
  if vim.fn.executable('git') == 1 then
    local repo = tmpdir .. '/gitrepo'
    vim.fn.mkdir(repo .. '/sub', 'p')
    vim.fn.system({ 'git', '-C', repo, 'init', '--quiet' })
    if vim.v.shell_error == 0 then
      eq(
        launch._root(repo .. '/sub'),
        vim.fn.resolve(repo),
        'root: _root finds the worktree root from a subdirectory'
      )
    end
  end
end

do
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'cd ' .. vim.fn.fnameescape(tmpdir) .. '\r')
  eq(
    vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end),
    true,
    'root: shell follows cd into the test directory'
  )
  local cmdfile = tmpdir .. '/commands.lua'
  write(cmdfile, { 'return { { name = "root", cmd = "echo ROOT_{root}" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
    edit_before_run = true,
  }

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
  vim.ui.input = function(opts, on_confirm) on_confirm(opts.default) end

  launch.launch()

  vim.ui.select, vim.ui.input = orig_select, orig_input
  core.config.commands = saved

  local ok = vim.wait(2000, function() return buf_contains(bufnr, 'ROOT_' .. tmpdir) end)
  eq(ok, true, 'launch: {root} template expands at launch time')
  vim.fn.delete(cmdfile)
end

-- ----------------------------------------------------------------- branch --

do
  eq(launch._branch(tmpdir), '', 'branch: outside a git repository the branch is empty')
  eq(launch.expand('{git_branch}', tmpdir), '', 'expand: {git_branch} outside git is empty')
  eq(
    launch.expand('git push origin {git_branch}', nil),
    'git push origin ',
    'expand: {git_branch} without a cwd is empty'
  )
end

do
  if vim.fn.executable('git') == 1 then
    local repo = tmpdir .. '/branchrepo'
    vim.fn.mkdir(repo, 'p')
    vim.fn.system({ 'git', '-C', repo, 'init', '--quiet' })
    if vim.v.shell_error == 0 then
      vim.fn.system({ 'git', '-C', repo, 'checkout', '-q', '-b', 'termforge-test' })
      eq(launch._branch(repo), 'termforge-test', 'branch: _branch reads the checked out branch')
      eq(
        launch.expand('git push origin {git_branch}', repo),
        'git push origin termforge-test',
        'expand: {git_branch} expands to the branch of the cwd'
      )
    end
  end
end

-- ---------------------------------------------------------------- repeat --

do
  -- Fire a command in one terminal, then repeat it in another: repeat
  -- goes to the terminal the cursor is in now.
  local abuf, ajob = open_terminal()
  local cwd = core.terminal_cwd(abuf, ajob)
  local cmdfile = cwd .. '/commands.lua'
  write(cmdfile, { 'return { { name = "rep", cmd = "echo TERMFORGE_REPEAT_MARKER" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
    edit_before_run = true,
  }

  local orig_select, orig_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
  vim.ui.input = function(opts, on_confirm) on_confirm(opts.default) end

  launch.launch()

  vim.ui.select, vim.ui.input = orig_select, orig_input
  core.config.commands = saved

  eq(
    vim.wait(2000, function() return buf_contains(abuf, 'TERMFORGE_REPEAT_MARKER') end),
    true,
    'repeat: launch fires the command'
  )
  vim.fn.delete(cmdfile)

  local bbuf = open_terminal()
  launch.repeat_last()
  eq(
    vim.wait(2000, function() return buf_contains(bbuf, 'TERMFORGE_REPEAT_MARKER') end),
    true,
    'repeat: repeat_last sends the last command to the current terminal'
  )
end

do
  local src = api.nvim_create_buf(false, false)
  api.nvim_set_current_buf(src)
  local notified = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
  launch.repeat_last()
  launch.cd()
  vim.notify = orig_notify
  eq(#notified, 2, 'repeat/cd: outside a terminal both notify once')
  for _, n in ipairs(notified) do
    eq(n.level, vim.log.levels.WARN, 'repeat/cd: missing terminal notifies at WARN level')
  end
  api.nvim_buf_delete(src, { force = true })
end

-- --------------------------------------------------------------------- cd --

do
  launch.setup()
  local bufnr, job_id = open_terminal()
  local file = tmpdir .. '/cd-target.lua'
  write(file, { 'return 1' })
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  eq(launch.last_file(), file, 'cd: editing a file records it as the last file')
  api.nvim_set_current_buf(bufnr)
  launch.cd()
  eq(
    vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end),
    true,
    "cd: the shell navigates to the last file's directory"
  )
end

-- ---------------------------------------------------------- edit commands --

do
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'cd ' .. vim.fn.fnameescape(tmpdir) .. '\r')
  eq(
    vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end),
    true,
    'edit_commands: shell follows cd into the test directory'
  )

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = '.nvim/commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
  }
  eq(
    launch._commands_path(tmpdir),
    tmpdir .. '/.nvim/commands.lua',
    'edit_commands: _commands_path joins cwd and the local commands file'
  )
  eq(
    launch._commands_path(nil),
    tmpdir .. '/no-global-commands.lua',
    'edit_commands: without a cwd the global file is used'
  )

  launch.edit_commands()
  local path = tmpdir .. '/.nvim/commands.lua'
  eq(vim.fn.filereadable(path), 1, 'edit_commands: a missing file is created')
  eq(
    vim.wait(500, function() return api.nvim_buf_get_name(0) == path end),
    true,
    'edit_commands: the file opens in a split'
  )
  eq(buf_contains(0, 'return {'), true, 'edit_commands: the stub shows the file format')
  core.config.commands = saved

  vim.cmd('close')
  vim.fn.delete(path)
end

do
  -- An empty picker offers to open the commands file instead.
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'cd ' .. vim.fn.fnameescape(tmpdir) .. '\r')
  vim.wait(2000, function() return core.terminal_cwd(bufnr, job_id) == tmpdir end)

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
  }

  local captured
  local orig_select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts }
    on_choice(items[1])
  end
  launch.launch()
  vim.ui.select = orig_select
  core.config.commands = saved

  eq(captured ~= nil, true, 'offer: an empty picker asks what to do')
  if captured then
    eq(captured.items[1], 'Edit', 'offer: the first choice is Edit')
    eq(
      captured.opts.prompt:find('commands.lua', 1, true) ~= nil,
      true,
      'offer: the prompt names the commands file'
    )
  end
  eq(vim.fn.filereadable(tmpdir .. '/commands.lua'), 1, 'offer: choosing Edit creates the file')
  eq(
    vim.wait(500, function() return api.nvim_buf_get_name(0) == tmpdir .. '/commands.lua' end),
    true,
    'offer: choosing Edit opens the file in a split'
  )
  vim.cmd('close')
  vim.fn.delete(tmpdir .. '/commands.lua')
end

do
  -- The picker carries an edit action (wired to <C-e> by Telescope/snacks).
  local bufnr, job_id = open_terminal()
  local cwd = core.terminal_cwd(bufnr, job_id)
  local cmdfile = cwd .. '/commands.lua'
  write(cmdfile, { 'return { { name = "x", cmd = "echo TERMFORGE_EDIT_OPT" } }' })

  local saved = core.config.commands
  core.config.commands = {
    local_commands_file = 'commands.lua',
    global_commands_file = tmpdir .. '/no-global-commands.lua',
  }

  local captured
  local orig_select = pickers.select
  pickers.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts }
    on_choice(nil)
  end
  launch.launch()
  pickers.select = orig_select
  core.config.commands = saved

  eq(captured ~= nil, true, 'picker edit: launch goes through pickers.select')
  local edit
  if captured then
    for _, act in ipairs(captured.opts.actions or {}) do
      if act.key == '<C-e>' then edit = act.fn end
    end
  end
  eq(type(edit), 'function', 'picker edit: picker opts carry a <C-e> edit action')
  vim.fn.delete(cmdfile)
end

-- ---------------------------------------------------------------- preview --

do
  local buffers = require('termforge.buffers')
  local bufnr, job_id = open_terminal()
  vim.fn.chansend(job_id, 'echo TERMFORGE_PREVIEW_MARKER\r')
  eq(
    vim.wait(2000, function() return buf_contains(bufnr, 'TERMFORGE_PREVIEW_MARKER') end),
    true,
    'preview: marker echoed into the terminal'
  )

  local captured = nil
  local orig_select = pickers.select
  pickers.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts }
    on_choice(nil)
  end
  buffers.select()
  pickers.select = orig_select

  eq(captured ~= nil, true, 'preview: buffers.select goes through pickers.select')
  if captured then
    eq(type(captured.opts.preview), 'function', 'preview: picker opts carry a preview function')
    eq(captured.opts.preview({ bufnr = -1 }), {}, 'preview: invalid buffer yields no lines')
    local t = find_terminal(bufnr)
    eq(t ~= nil, true, 'preview: the terminal is listed')
    if t then
      local lines = captured.opts.preview(t)
      eq(type(lines), 'table', 'preview: preview returns a list of lines')
      eq(
        table.concat(lines, '\n'):find('TERMFORGE_PREVIEW_MARKER', 1, true) ~= nil,
        true,
        'preview: preview shows the terminal tail'
      )
    end
  end
end

-- ------------------------------------------------------------------- kill --

do
  local buffers = require('termforge.buffers')
  local bufnr, job_id = open_terminal()
  local captured
  local orig_select = pickers.select
  pickers.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts }
    on_choice(nil)
  end
  buffers.select()
  pickers.select = orig_select

  local kill
  if captured then
    for _, act in ipairs(captured.opts.actions or {}) do
      if act.key == '<C-k>' then kill = act.fn end
    end
  end
  eq(type(kill), 'function', 'kill: the terminal picker carries a <C-k> action')

  if kill then
    local entry = find_terminal(bufnr)
    eq(entry ~= nil, true, 'kill: the terminal is listed')
    kill(entry)
    eq(
      vim.wait(500, function() return vim.fn.jobwait({ job_id }, 0)[1] ~= -1 end),
      true,
      'kill: the job is stopped'
    )
    eq(vim.api.nvim_buf_is_valid(bufnr), false, 'kill: the buffer is deleted')
  end
  eq(buffers._kill(nil), nil, 'kill: a missing entry is ignored')
end

-- ----------------------------------------------------------------- rename --

do
  local buffers = require('termforge.buffers')
  local bufnr, job_id = open_terminal()
  local original = api.nvim_buf_get_name(bufnr)
  local captured
  local orig_select = pickers.select
  pickers.select = function(items, opts, on_choice)
    captured = { items = items, opts = opts }
    on_choice(nil)
  end
  buffers.select()
  pickers.select = orig_select

  local rename
  if captured then
    for _, act in ipairs(captured.opts.actions or {}) do
      if act.key == '<C-e>' then rename = act.fn end
    end
  end
  eq(type(rename), 'function', 'rename: the terminal picker carries a <C-e> action')

  if rename then
    local entry = find_terminal(bufnr)
    eq(entry ~= nil, true, 'rename: the terminal is listed')
    local prompts = {}
    local orig_input = vim.ui.input
    local stub = function(reply)
      return function(opts, on_confirm)
        prompts[#prompts + 1] = opts
        on_confirm(reply)
      end
    end

    vim.ui.input = stub('build')
    rename(entry)
    eq(prompts[1] ~= nil, true, 'rename: renaming prompts for a label')
    if prompts[1] then eq(prompts[1].default, '', 'rename: the prompt defaults to no label') end
    eq(api.nvim_buf_get_name(bufnr), 'term://build', 'rename: a confirmed label renames the buffer')
    eq(vim.b[bufnr].termforge_label, 'build', 'rename: the label variable is set')

    vim.ui.input = stub('')
    rename(entry)
    eq(api.nvim_buf_get_name(bufnr), original, 'rename: an empty input clears the label')
    eq(vim.b[bufnr].termforge_label, nil, 'rename: clearing removes the label variable')

    core.label(bufnr, 'build')
    vim.ui.input = stub(nil)
    rename(entry)
    eq(api.nvim_buf_get_name(bufnr), 'term://build', 'rename: canceling leaves the name unchanged')
    eq(prompts[#prompts].default, 'build', 'rename: the prompt pre-fills the current label')

    vim.ui.input = orig_input
    core.label(bufnr, nil)
    vim.fn.jobstop(job_id)
    vim.wait(500, function() return vim.fn.jobwait({ job_id }, 0)[1] ~= -1 end)
    api.nvim_buf_delete(bufnr, { force = true })
  end
  eq(buffers._rename(nil), nil, 'rename: a missing entry is ignored')
end

-- ------------------------------------------------------------------- last --

do
  -- A hidden last-used terminal opens in a split; a displayed one is focused.
  local tbuf = open_terminal()
  local src = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(src, 0, -1, false, { 'x' })
  api.nvim_set_current_buf(src)
  send.last()
  eq(api.nvim_get_current_buf(), tbuf, 'last: a hidden terminal opens in a split')
  vim.cmd('close')

  local tbuf2 = open_terminal()
  vim.cmd('sbuffer ' .. src)
  eq(api.nvim_get_current_buf(), src, 'last: the source buffer is current')
  send.last()
  eq(api.nvim_get_current_buf(), tbuf2, 'last: a displayed terminal is focused')
  vim.cmd('only')
end

-- ---------------------------------------------------------------- chosen --

do
  -- :TermforgeSend! picks the terminal: the lines land in the chosen one,
  -- not in the last-used one.
  local abuf = open_terminal()
  local bbuf = open_terminal()
  local src = api.nvim_create_buf(false, false)
  api.nvim_buf_set_lines(src, 0, -1, false, { 'echo CHOSEN_A', 'echo CHOSEN_B' })
  api.nvim_set_current_buf(src)
  api.nvim_win_set_cursor(0, { 1, 0 })

  local picked = nil
  local orig_select = pickers.select
  pickers.select = function(items, _, on_choice)
    for _, t in ipairs(items) do
      if t.bufnr == abuf then
        picked = t
        on_choice(t)
        return
      end
    end
    on_choice(nil)
  end
  vim.cmd('TermforgeSend!')
  eq(picked ~= nil, true, 'chosen: TermforgeSend! opens the terminal picker')
  eq(
    vim.wait(2000, function() return buf_contains(abuf, 'CHOSEN_A') end),
    true,
    'chosen: the picked terminal receives the lines'
  )
  eq(buf_contains(bbuf, 'CHOSEN_A'), false, 'chosen: the last-used terminal is not touched')

  -- A count/range goes to the picked terminal as well.
  vim.cmd('2TermforgeSend!')
  pickers.select = orig_select
  eq(
    vim.wait(2000, function() return buf_contains(abuf, 'CHOSEN_B') end),
    true,
    'chosen: a count/range is sent to the picked terminal'
  )
end

-- ------------------------------------------------------------------- done --

vim.fn.delete(tmpdir, 'rf')

if failures > 0 then
  print(('%d test(s) FAILED'):format(failures))
  os.exit(1)
end
print('all tests passed')
