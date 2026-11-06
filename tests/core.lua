-- nvim -u NONE -i NONE --headless -l tests/core.lua   (fake backend + recording inline; no processes)
local api = vim.api
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2)))))

local function check(cond, msg)
  if not cond then error('FAIL: ' .. msg, 2) end
end

local notes = {}
vim.notify = function(m) notes[#notes + 1] = m end
local function noted(pat)
  for _, m in ipairs(notes) do if m:find(pat) then return true end end
end

local tmp = vim.fs.normalize(vim.fn.tempname())
local function file(rel, text)
  local p = tmp .. '/' .. rel
  vim.fn.mkdir(vim.fs.dirname(p), 'p')
  vim.fn.writefile({ text or '' }, p)
  return p
end
file('a/fake.toml'); file('b/fake.toml')
local function real(rel) return vim.fs.normalize(vim.uv.fs_realpath(tmp .. '/' .. rel)) end

local function keymaps()
  local n = 0
  for _, m in ipairs({ 'n', 'x', 'i', 't', 'o' }) do n = n + #api.nvim_get_keymap(m) + #api.nvim_buf_get_keymap(0, m) end
  return n
end
api.nvim_create_autocmd('User', { group = api.nvim_create_augroup('replise', {}), command = '' }) -- a user's group
local before = { maps = keymaps(), cmds = vim.tbl_count(api.nvim_get_commands({})), au = #api.nvim_get_autocmds({}),
  cwd = vim.fn.getcwd(), bufs = #api.nvim_list_bufs() }

-- fake backend: records everything, never emits on its own
local log = { starts = 0, calls = {}, interrupts = 0 }
local fake = { root_markers = { 'fake.toml' } }
function fake.start(ctx, emit)
  log.starts = log.starts + 1
  log.last = { ctx = ctx, emit = emit, repl_bufnr = 1000 + log.starts }
  return log.last
end
function fake.run_buffer(h, req) log.calls[#log.calls + 1] = { h = h, req = req } end
fake.send = fake.run_buffer
function fake.interrupt() log.interrupts = log.interrupts + 1 end
function fake.stop(h) log.stopped = h end

-- 1. require + setup({}) are inert
local replise = require('replise')
replise.setup({})
check(keymaps() == before.maps, 'setup({}) added keymaps')
check(vim.tbl_count(api.nvim_get_commands({})) == before.cmds, 'setup({}) added commands')
check(#api.nvim_get_autocmds({}) == before.au, 'setup({}) added autocmds')
check(#api.nvim_list_bufs() == before.bufs, 'setup({}) created buffers')
check(package.loaded['replise.inline'] == nil, 'inline loaded without opt-in')
check(#api.nvim_get_autocmds({ group = 'replise' }) == 1, "setup deleted the user's 'replise' augroup")

-- recording inline stub (the real UI is tested in tests/inline.lua)
local ui = {}
package.loaded['replise.inline'] = setmetatable({}, { __index = function(_, fn)
  return function(...) ui[#ui + 1] = { fn, ... } end
end })
local function ui_count(fn, bufnr)
  local n = 0
  for _, c in ipairs(ui) do if c[1] == fn and (not bufnr or c[2] == bufnr) then n = n + 1 end end
  return n
end
local function last_state(bufnr)
  for i = #ui, 1, -1 do if ui[i][1] == 'set_state' and ui[i][2] == bufnr then return ui[i][3] end end
end

-- cwd points at an unrelated project: roots must come from the buffers' own markers
vim.cmd.cd(tmp .. '/b')
local cwd = vim.fn.getcwd()
local function open(rel, ft)
  vim.cmd.edit(vim.fn.fnameescape(file(rel, 'line of ' .. rel)))
  vim.bo.filetype = ft or 'fake'
  return api.nvim_get_current_buf()
end
local A1, A2, N = open('a/sub/x.fake'), open('a/y.fake'), open('none/w.fake')
local scratch = api.nvim_create_buf(false, true)
vim.bo[scratch].filetype = 'fake'

replise.setup({ backends = { fake = fake } })
check(log.starts == 0, 'backend registration started a process')
check(#api.nvim_get_autocmds({}) == before.au, 'setup without autostart added autocmds')
check(replise.get_context(A1).root == real('a'), 'root not resolved from markers')
check(replise.get_context(N) == nil, 'context without marker')
api.nvim_set_current_buf(N)
check(replise.run_buffer() == nil and noted('no project root') and log.starts == 0, 'explicit run without marker')
check(replise.get_context(scratch) == nil, 'scratch buffer accepted as source')

-- 2. autostart: existing buffers, one process per root, no root / non-file buffers ignored
replise.setup({ backends = { fake = fake }, autostart = { 'fake' }, inline = { enabled = true, max_height = 8 }, commands = true })
check(log.starts == 1, 'existing buffers: expected 1 start, got ' .. log.starts)
check(replise.get_session(A1) == replise.get_session(A2), 'same root did not share session')
check(replise.get_session(N) == nil, 'no-root buffer autostarted')
local B = open('b/z.fake')
vim.wait(1000, function() return log.starts == 2 end)
check(log.starts == 2, 'FileType autostart for new root')
check(replise.get_repl_buffer(A2) == 1001 and replise.get_repl_buffer(B) == 1002, 'get_repl_buffer')
check(api.nvim_get_commands({}).RepliseRun, 'commands=true did not define RepliseRun')
replise.get_session(B).handle.emit({ kind = 'stdout', chunk = 'bootstrap' })
check(#ui == 0, 'bootstrap output without a request touched inline')
check(keymaps() == before.maps, 'full setup added keymaps')
check(log.last.ctx.root == real('b'), 'ctx.root for new root')

-- 3. dirty-file safety, pending while starting, busy rejection
local sA = replise.get_session(A1)
local emitA = sA.handle.emit
api.nvim_set_current_buf(A1)
api.nvim_buf_set_lines(A1, 0, -1, false, { 'edited' })
check(replise.run_buffer() == nil and noted('unsaved'), 'dirty buffer run not rejected')
check(ui_count('open') == 0, 'rejected run opened inline')
local id1 = replise.run_buffer({ save = true })
check(id1 and not vim.bo[A1].modified, 'run_buffer({save=true}) did not save/run')
check(vim.fn.readfile(api.nvim_buf_get_name(A1))[1] == 'edited', 'save wrote wrong content')
check(#log.calls == 0 and sA.pending and sA.pending.id == id1, 'request dispatched before ready')
check(last_state(A1) == 'starting', 'pending request not shown as starting')
api.nvim_set_current_buf(A2)
check(replise.send_line() == nil and noted('busy'), 'second request while pending not rejected')
emitA({ kind = 'stdout', chunk = 'Precompiling' })
check(ui_count('append', A1) == 1, 'bootstrap output not routed to pending view')
emitA({ kind = 'ready' })
check(#log.calls == 1 and log.calls[1].req.id == id1 and log.calls[1].req.kind == 'run', 'pending not dispatched on ready')
check(log.calls[1].req.path == api.nvim_buf_get_name(A1), 'run_buffer redirected to another file')
check(sA.state == 'busy', 'state not busy')
api.nvim_set_current_buf(A1)
check(replise.run_buffer() == nil, 'busy session accepted another run')
emitA({ kind = 'stdout', request_id = id1, chunk = '50%\r' })
emitA({ kind = 'stdout', request_id = id1 + 99, chunk = 'stale' })
check(ui_count('append', A1) == 2, 'stale request chunk not filtered')
emitA({ kind = 'done', request_id = id1 })
check(sA.state == 'idle' and last_state(A1) == 'done', 'done not applied')

-- send_line uses unsaved content; results go to the request's buffer, not the current one
api.nvim_set_current_buf(A2)
api.nvim_buf_set_lines(A2, 0, -1, false, { 'unsaved code' })
local id2 = replise.send_line()
check(id2 and log.calls[2].req.code == 'unsaved code' and vim.bo[A2].modified, 'send_line content/save')
api.nvim_set_current_buf(A1)
emitA({ kind = 'stderr', request_id = id2, chunk = 'warn' })
check(ui_count('append', A2) == 1 and ui_count('append', A1) == 2, 'chunk routed to wrong buffer')

-- 4. restart: old session's callbacks are stale
local old = sA.handle
check(replise.restart(A2), 'restart')
check(log.stopped == old and last_state(A2) == 'interrupted', 'restart did not stop old handle/fail request')
local sA2 = replise.get_session(A1)
check(sA2 ~= sA and log.starts == 3, 'restart did not create a new session')
local nnotes = #notes
old.emit({ kind = 'ready' })
old.emit({ kind = 'stdout', request_id = id2, chunk = 'late' })
old.emit({ kind = 'exit' })
check(sA2.state == 'starting' and replise.get_session(A1) == sA2, 'old session events affected new session')
check(ui_count('append', A2) == 1, 'stale-generation chunk delivered')
check(#notes == nnotes, 'stopped session still reports: ' .. tostring(notes[#notes]))

-- interrupt while pending cancels locally; nothing is dispatched later
check(replise.run_buffer(), 'run while starting')
check(replise.interrupt(A1) and sA2.pending == nil and last_state(A1) == 'interrupted', 'pending interrupt')
sA2.handle.emit({ kind = 'ready' })
check(#log.calls == 2, 'cancelled pending request was dispatched')

-- real visual-mode mapping: charwise inclusive/exclusive and linewise use the live selection, then leave visual
local function sel(keys)
  api.nvim_win_set_cursor(0, { 1, 1 })
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys .. '<F2>', true, false, true), 'mx', false)
  local c = log.calls[#log.calls]
  sA2.handle.emit({ kind = 'done', request_id = c.req.id })
  check(api.nvim_get_mode().mode == 'n', 'send_selection left visual mode active')
  return c.req.code, c.req.row
end
api.nvim_set_current_buf(A2)
api.nvim_buf_set_lines(A2, 0, -1, false, { 'abcdef', 'ghij' })
vim.keymap.set('x', '<F2>', replise.send_selection, { buffer = A2 })
check(sel('vl') == 'bc', 'charwise selection')
vim.o.selection = 'exclusive'
check(sel('vl') == 'b', "selection=exclusive not honored")
vim.o.selection = 'inclusive'
local code, row = sel('Vj')
check(code == 'abcdef\nghij' and row == 1, 'linewise selection')
vim.cmd('normal! gg')
api.nvim_set_current_buf(A1)

-- backend.interrupt failure must not relabel a later unrelated error
local idf = replise.run_buffer()
local real_interrupt = fake.interrupt
fake.interrupt = function() error('no job') end
check(replise.interrupt(A1) == nil and noted('interrupt failed'), 'interrupt failure not reported')
fake.interrupt = real_interrupt
sA2.handle.emit({ kind = 'error', request_id = idf, message = 'boom' })
check(last_state(A1) == 'error', 'failed interrupt mislabeled the error as interrupted')

-- 5. clear removes only the view; late chunks never reopen it
local opens = ui_count('open')
local id4 = replise.run_buffer()
check(ui_count('open') == opens + 1, 'explicit run did not open inline')
vim.cmd('RepliseInlineClear')
check(ui_count('clear') == 1, 'RepliseInlineClear did not clear')
check(replise.get_session(A1) == sA2 and sA2.state == 'busy' and log.stopped == old, 'clear touched the process')
sA2.handle.emit({ kind = 'stdout', request_id = id4, chunk = 'late' })
sA2.handle.emit({ kind = 'running', request_id = id4 })
check(ui_count('open') == opens + 1, 'late event reopened inline')

-- interrupt while busy: backend error after interrupt is reported as interrupted
check(replise.interrupt(A1) and log.interrupts == 1, 'interrupt not forwarded')
sA2.handle.emit({ kind = 'error', request_id = id4, message = 'InterruptException' })
check(sA2.state == 'idle' and last_state(A1) == 'interrupted', 'interrupt state')

-- 6. process exit drops the session; init error while starting stops the handle
check(replise.run_buffer(), 'run before exit')
sA2.handle.emit({ kind = 'exit', message = 'julia exited' })
check(replise.get_session(A1) == nil and last_state(A1) == 'error', 'exit not handled')
local id6 = replise.run_buffer() -- starts again, pending
local h = log.last
check(id6 and log.starts == 4, 'run after exit did not start a new session')
h.emit({ kind = 'error', message = 'Revise not installed' })
check(replise.get_session(A1) == nil and log.stopped == h and last_state(A1) == 'error', 'init error')
check(noted('Revise not installed'), 'init error not reported')

-- 7. a FileType autostart queued before setup() without autostart must not start
file('c/fake.toml')
replise.setup({ backends = { fake = fake }, autostart = { 'fake' } })
local starts = log.starts
open('c/q.fake') -- FileType queues a scheduled autostart
replise.setup({ backends = { fake = fake } })
vim.wait(50)
check(log.starts == starts, 'queued autostart ran after autostart was disabled')
check(#api.nvim_get_autocmds({ group = 'replise' }) == 1, "user's 'replise' augroup lost")

check(vim.fn.getcwd() == cwd, 'plugin changed cwd')
vim.fn.delete(tmp, 'rf')
print('core: OK')
