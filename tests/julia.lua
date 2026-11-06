-- Real-Julia check for the julia backend (needs Revise in the default env, iron in .deps).
-- nvim -u NONE -i NONE --headless -l tests/julia.lua
-- REPLISE_TEST_JULIA = julia binary to run (default `julia`). With mise on Windows, use the real binary
-- (`mise which julia`): the mise shim exits on console Ctrl-C and the rapid-interrupt checks fail.
local script = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p')
local root = vim.fn.fnamemodify(script, ':h:h')

-- Windows: a headless nvim whose stdio is redirected leaks ConPTY child output to its own stdout (terminal
-- buffers stay empty). Re-run this script in a fresh hidden console and relay its log.
if vim.fn.has('win32') == 1 and not vim.env.REPLISE_TEST_LOG then
  vim.env.REPLISE_TEST_LOG = vim.fn.tempname()
  local r = vim.system({ 'powershell', '-NoProfile', '-Command', ("$p = Start-Process '%s' -ArgumentList "
    .. "'-u','NONE','-i','NONE','--headless','-l','\"%s\"' -WindowStyle Hidden -PassThru -Wait; exit $p.ExitCode")
    :format(vim.v.progpath, script) }):wait()
  io.stdout:write(table.concat(vim.fn.readfile(vim.env.REPLISE_TEST_LOG), '\n') .. '\n')
  vim.fn.delete(vim.env.REPLISE_TEST_LOG)
  os.exit(r.code)
end
local function say(s)
  if vim.env.REPLISE_TEST_LOG then vim.fn.writefile(vim.split(s, '\n'), vim.env.REPLISE_TEST_LOG, 'a') else print(s) end
end

local JULIA = vim.env.REPLISE_TEST_JULIA or 'julia'
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. '/.deps/iron.nvim')
local julia = require('replise.backends.julia')

-- everything the test owns is released on success and on failure; deletes only inside nvim's own temp dir
local tmp = vim.fs.normalize(vim.fs.dirname(vim.fn.tempname()))
local cleanups = {}
local function defer(fn) cleanups[#cleanups + 1] = fn end
local function cleanup()
  for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
  cleanups = {}
end
local function rm(p)
  p = vim.fs.normalize(p)
  assert(vim.startswith(p, tmp .. '/') and #p > #tmp + 1, 'refusing to delete ' .. p)
  vim.fn.delete(p, 'rf')
end
local function check(cond, msg, ...)
  if not cond then
    say('FAIL: ' .. msg .. '\n' .. vim.inspect({ ... }))
    cleanup()
    os.exit(1)
  end
end

-- fixture project in a path with spaces, unicode, quotes and $
local dir = vim.fs.normalize(vim.fn.tempname() .. [[ sp ü日本 '$x]])
vim.fn.mkdir(dir .. '/src', 'p')
defer(function() rm(dir) end)
local function write(name, s) vim.fn.writefile(vim.split(s, '\n'), dir .. '/' .. name) end
write('Project.toml', '')
write('src/lib.jl', 'f() = 1')
local outside = dir .. '-outside.jl' -- shares the root's name prefix but is outside its directory
vim.fn.writefile({ 'g() = 1' }, outside)
defer(function() rm(outside) end)
write('main.jl', 'include("src/lib.jl")\ninclude(raw"' .. outside .. '")\nmain() = println("v", f(), g())\nprintln("loaded main")')
write('value.jl', 'x = 6 * 7')
write('answer.jl', 'answer() = 6 * 7')
write('quiet.jl', 'answer2() = 6 * 7')
write('script.jl', 'println("script ", 40 + 2, " ", @__FILE__)')

-- process tree helpers (owned processes only)
local function procs()
  local out = vim.system(vim.fn.has('win32') == 1 and { 'powershell', '-NoProfile', '-Command',
    'Get-CimInstance Win32_Process | % { "$($_.ProcessId) $($_.ParentProcessId)" }' }
    or { 'ps', '-eo', 'pid=,ppid=' }, { text = true }):wait().stdout
  local t = {}
  for pid, ppid in out:gmatch('(%d+)%s+(%d+)') do t[tonumber(pid)] = tonumber(ppid) end
  return t
end
local function tree(pid)
  local t, set, grew = procs(), { [pid] = true }, true
  while grew do
    grew = false
    for p, pp in pairs(t) do
      if set[pp] and not set[p] then set[p], grew = true, true end
    end
  end
  return set
end
local function alive(set)
  local t, n = procs(), 0
  for p in pairs(set) do if t[p] then n = n + 1 end end
  return n
end

local events = {}
local function emit(ev) events[#events + 1] = ev end -- may run in a luv callback
local function wait_for(pred, ms, what)
  local found
  vim.wait(ms or 60000, function()
    for _, ev in ipairs(events) do if pred(ev) then found = ev return true end end
  end, 20)
  check(found, 'timeout waiting for ' .. what, events)
  return found
end

local B = julia.new({
  cmd = { JULIA, '--startup-file=no' }, -- isolate from the user's startup.jl
  revise = true,
  prescript = 'PRE = 41',
  before_run = 'global NRUN = (isdefined(Main, :NRUN) ? NRUN : 0) + 1',
  files = {
    ['main.jl'] = { run = 'main()', first_run = 'include' },
    ['answer.jl'] = { run = 'answer()' },
    ['quiet.jl'] = { run = 'answer2();' },
  },
})
check(not pcall(julia.new, { instantiate = true }), 'instantiate must be false|startup|on_change')
check(not pcall(julia.new, { revize = true }), 'unknown option rejected')
check(vim.deep_equal(B.root_markers, { 'Project.toml', 'JuliaProject.toml' }), 'root markers')

local src = vim.api.nvim_create_buf(true, false)
local wins, cwd = #vim.api.nvim_list_wins(), vim.fn.getcwd()
local function start()
  events = {}
  local h = B.start({ bufnr = src, root = dir, ft = 'julia' }, emit)
  defer(function() B.stop(h) end)
  check(#vim.api.nvim_list_wins() == wins, 'start opened a window')
  wait_for(function(ev) return ev.kind == 'ready' end, 180000, 'ready')
  check(vim.fn.getcwd() == cwd, 'nvim cwd changed')
  check(vim.bo[h.repl_bufnr].buftype == 'terminal', 'replise buffer is a terminal')
  return h
end

local id = 0
local function req(h, kind, r)
  id = id + 1
  events = {}
  r.id, r.bufnr = id, src
  B[kind](h, r)
  local term = wait_for(function(ev) return ev.request_id == id and (ev.kind == 'done' or ev.kind == 'error') end, 60000,
    kind .. ' ' .. vim.inspect(r))
  local res = { term = term, stdout = {}, stderr = {}, running = false }
  for _, ev in ipairs(events) do
    check(ev.request_id == id, 'event for other request', ev)
    if ev.kind == 'stdout' or ev.kind == 'stderr' then table.insert(res[ev.kind], ev.chunk) end
    if ev.kind == 'running' then res.running = true end
    if ev ~= term then check(ev.kind ~= 'done' and ev.kind ~= 'error', 'two terminal events', events) end
  end
  res.out, res.err = table.concat(res.stdout), table.concat(res.stderr)
  return res
end

local ok, err = xpcall(function() -- body: Lua errors also reach cleanup()
local h = start()
local pids = tree(vim.fn.jobpid(h.job_id))

-- CPU work does not yield to the helper's pipe reader. A fixture file proves the body started
-- before we interrupt, independent of stdout pumps and compilation time.
id = id + 1
events = {}
local marker = dir .. '/cpu-started'
B.send(h, { id = id, bufnr = src,
  code = 'write(raw"' .. marker .. '", "started"); while true; global cpu_scratch = zeros(4096); end', path = '' })
check(vim.wait(30000, function() return vim.uv.fs_stat(marker) ~= nil end, 10), 'CPU work started', events)
B.interrupt(h)
local t = wait_for(function(ev) return ev.request_id == id and (ev.kind == 'done' or ev.kind == 'error') end, 15000,
  'CPU-bound interrupt')
check(t.kind == 'error' and t.message == 'interrupted', 'CPU-bound interrupted', t)
check(req(h, 'send', { code = '"after cpu"', path = '' }).out == '"after cpu"\n', 'usable after CPU interrupt')

-- send: stdout, stderr, displayed value, unsaved code text with unicode/quotes
local r = req(h, 'send', { code = 'print("a\\"ü\\$"); print(stderr, "b"); PRE + 1', path = dir .. '/x.jl' })
check(r.term.kind == 'done' and r.running, 'send done', r)
check(r.out:find('a"ü$', 1, true) and r.out:find('42', 1, true) and r.err == 'b', 'send streams', r)
check(req(h, 'send', { code = 'PRE;' }).out == '', 'trailing ; suppresses value')
r = req(h, 'send', { code = 'include("../value.jl")', path = dir .. '/src/unsaved.jl' })
check(r.out == '42\n', 'sent text resolves relative includes from its source file', r)
r = req(h, 'send', { code = 'basename(@__FILE__) == "unsaved.jl" && basename(@__DIR__) == "src"', path = dir .. '/src/unsaved.jl' })
check(r.out == 'true\n', 'sent text retains its source location', r)

-- a UTF-8 char split across writes: complete chunks to nvim, every byte exactly once to the terminal
r = req(h, 'send', { code = 'print("Q"); write(stdout, UInt8[0xe6, 0x97]); flush(stdout); sleep(0.4); write(stdout, UInt8[0xa5]); println("Z")' })
check(r.out == 'Q日Z\n', 'split utf8 joined', r.stdout)
for _, c in ipairs(r.stdout) do
  check(not c:find('^[\128-\191]') and (not c:find('\230', 1, true) or c:find('日', 1, true)), 'chunk splits a char', r.stdout)
end
local function term_text(b) return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') end
vim.wait(3000, function() return term_text(h.repl_bufnr):find('Q日Z', 1, true) end)
check(select(2, term_text(h.repl_bufnr):gsub('Q日Z', '')) == 1, 'terminal shows the split char once', term_text(h.repl_bufnr))

-- realtime partial-line / CR streaming
r = req(h, 'send', { code = 'for i in 1:3; print("\\rp$i"); sleep(0.4); end; println(" end")', path = '' })
check(#r.stdout >= 3 and r.stdout[1] == '\rp1' and r.out == '\rp1\rp2\rp3 end\n', 'CR chunks streamed separately', r.stdout)

-- exception: error event, message + stderr, session still usable
r = req(h, 'send', { code = 'error("boom")', path = '' })
check(r.term.kind == 'error' and r.term.message:find('boom') and r.err:find('boom'), 'exception', r)
check(req(h, 'send', { code = '1 + 1', path = '' }).out == '2\n', 'usable after error')

-- run_buffer with per-file rule: first include only, later revise + call; revise tracks src/lib.jl
r = req(h, 'run_buffer', { path = dir .. '/main.jl' })
check(r.term.kind == 'done' and r.out == 'loaded main\n', 'first run includes only', r)
r = req(h, 'run_buffer', { path = dir .. '/main.jl' })
check(r.out == 'v11\n', 'second run calls runner', r)
write('src/lib.jl', 'f() = 2')
vim.fn.writefile({ 'g() = 2' }, outside)
vim.wait(1500) -- let the file mtime/watch settle (Revise compares contents on revise())
r = req(h, 'run_buffer', { path = dir .. '/main.jl' })
check(r.out == 'v21\n', 'revised project include only (file outside root not tracked)', r)
write('src/lib.jl', 'f() = ')
vim.wait(1500)
r = req(h, 'run_buffer', { path = dir .. '/main.jl' })
check(r.term.kind == 'error', 'revise error surfaces', r)
write('src/lib.jl', 'f() = 3')
vim.wait(1500)
check(req(h, 'run_buffer', { path = dir .. '/main.jl' }).out == 'v31\n', 'recovers after fix')

-- REPL-style values: plain file shows its last value, runner value shown unless it ends with ;
check(req(h, 'run_buffer', { path = dir .. '/value.jl' }).out == '42\n', 'plain file value')
check(req(h, 'run_buffer', { path = dir .. '/answer.jl' }).out == '42\n', 'runner value')
check(req(h, 'run_buffer', { path = dir .. '/quiet.jl' }).out == '', 'runner ; suppresses value')

-- run_buffer without rule: plain script include every time, actual current file
for _ = 1, 2 do
  r = req(h, 'run_buffer', { path = dir .. '/script.jl' })
  check(r.out == 'script 42 ' .. vim.fn.fnamemodify(dir .. '/script.jl', ':p'):gsub('/', '\\') .. '\n'
    or r.out:find('script 42', 1, true), 'script run', r)
end
check(req(h, 'send', { code = 'NRUN', path = '' }).out == tostring(id) .. '\n', 'before_run per request')

-- interrupt while busy (Windows Ctrl-C through the pty)
id = id + 1
events = {}
B.send(h, { id = id, bufnr = src, code = 'while true; print("."); sleep(0.2); end', path = '' })
wait_for(function(ev) return ev.kind == 'stdout' and ev.request_id == id end, 30000, 'busy output')
B.interrupt(h)
t = wait_for(function(ev) return ev.request_id == id and (ev.kind == 'done' or ev.kind == 'error') end, 15000, 'interrupt')
check(t.kind == 'error' and t.message == 'interrupted', 'interrupted', t)
check(req(h, 'send', { code = '"after"', path = '' }).out == '"after"\n', 'usable after interrupt')

-- interrupt right after dispatch (before any output), and a request queued behind hand-typed REPL work
-- (sleep(5), left alone): one acknowledged `interrupted` each, it never runs later, the next is not blocked
for _, typed in ipairs({ false, true }) do
  id = id + 1
  events = {}
  if typed then
    vim.api.nvim_chan_send(h.job_id, 'sleep(5)\r')
    vim.wait(500)
  end
  B.send(h, { id = id, bufnr = src, code = 'sleep(20); println("late")', path = '' })
  B.interrupt(h)
  t = wait_for(function(ev) return ev.request_id == id and (ev.kind == 'done' or ev.kind == 'error') end, 15000, 'rapid interrupt')
  check(t.kind == 'error' and t.message == 'interrupted', 'rapid interrupt acknowledged', typed, t)
  local t0 = vim.uv.hrtime()
  check(req(h, 'send', { code = '"next"', path = '' }).out == '"next"\n', 'usable after rapid interrupt', typed)
  check(vim.uv.hrtime() - t0 < 8e9, 'next request was blocked by the interrupted one', typed)
end

-- process exit is reported
events = {}
B.send(h, { id = id + 1, bufnr = src, code = 'exit(3)', path = '' })
ex = wait_for(function(ev) return ev.kind == 'exit' end, 30000, 'exit')
check(ex.message:find('3'), 'exit code', ex)
vim.wait(5000, function() return alive(pids) == 0 end, 200)
check(alive(pids) == 0, 'processes after exit()', pids)
B.stop(h)

-- broken control channel with julia still alive: reported as exit, owned process stopped (core not left busy)
h = start()
pids = tree(vim.fn.jobpid(h.job_id))
events = {}
B.send(h, { id = id + 1, bufnr = src, code = 'close(Replise.sock[])', path = '' })
ex = wait_for(function(ev) return ev.kind == 'exit' end, 30000, 'exit after channel close')
check(ex.message:find('control channel closed', 1, true), 'channel close message', ex)
vim.wait(10000, function() return alive(pids) == 0 end, 200)
check(alive(pids) == 0, 'processes after channel close', pids)

-- start failure leaves nothing behind
local nbufs = #vim.api.nvim_list_bufs()
local ok, err = pcall(julia.new({ cmd = { 'no-such-julia-xyz' } }).start, { bufnr = src, root = dir }, emit)
check(not ok and tostring(err):find('julia start failed', 1, true), 'start failure error', err)
check(#vim.api.nvim_list_bufs() == nbufs, 'start failure left a buffer')

-- restart = new process; stop cleans up the whole owned process tree and terminal buffer
h = start()
pids = tree(vim.fn.jobpid(h.job_id))
check(req(h, 'send', { code = 'isdefined(Main, :NRUN) ? NRUN : 0', path = '' }).out == '1\n', 'fresh process')
local tb = h.repl_bufnr
B.stop(h)
vim.wait(10000, function() return alive(pids) == 0 end, 200)
check(alive(pids) == 0, 'processes after stop', pids)
check(not vim.api.nvim_buf_is_valid(tb), 'terminal buffer wiped')
vim.wait(500)
check(not vim.iter(events):find(function(ev) return ev.kind == 'exit' end), 'no exit event after explicit stop', events)

-- missing optional tooling: actionable init error, no install attempt
local load_path = vim.env.JULIA_LOAD_PATH
vim.env.JULIA_LOAD_PATH = '@;@stdlib'
events = {}
h = B.start({ bufnr = src, root = dir, ft = 'julia' }, emit)
defer(function() B.stop(h) end)
vim.env.JULIA_LOAD_PATH = load_path
local e = wait_for(function(ev) return ev.kind == 'error' or ev.kind == 'ready' end, 120000, 'init error')
check(e.kind == 'error' and e.message:find('Revise.jl is not installed', 1, true), 'missing Revise error', e)
B.stop(h)

-- instantiate = 'on_change': instantiate only when Project/Manifest (or cmd) changed since last success
vim.env.XDG_STATE_HOME = vim.fn.tempname()
defer(function() rm(vim.env.XDG_STATE_HOME) end)
local BI = julia.new({ cmd = { JULIA, '--startup-file=no' }, instantiate = 'on_change' })
local function cycle()
  events = {}
  local hi = BI.start({ bufnr = src, root = dir, ft = 'julia' }, emit)
  defer(function() BI.stop(hi) end)
  wait_for(function(ev) return ev.kind == 'ready' end, 180000, 'ready (instantiate)')
  check(not vim.iter(events):any(function(ev) return (ev.chunk or ''):find('WARNING') end), 'bootstrap warning', events)
  vim.wait(200)
  BI.stop(hi)
  local stamp = vim.fn.glob(vim.env.XDG_STATE_HOME .. '/**/julia-instantiate-*', true, true)
  check(#stamp == 1, 'one stamp in isolated state dir', stamp)
  local st = vim.uv.fs_stat(stamp[1])
  return st.mtime.sec * 1e9 + st.mtime.nsec, vim.fn.readfile(stamp[1])[1]
end
local m1, s1 = cycle()
local m2, s2 = cycle()
check(m1 == m2 and s1 == s2, 'unchanged env: no instantiate', m1, m2)
write('Project.toml', '# changed')
local _, s3 = cycle()
check(s3 ~= s1, 'changed Project.toml: instantiated and re-stamped')

-- end-to-end through the public core API with the real inline pane: one process for terminal and inline
local replise = require('replise')
replise.setup({ backends = { julia = julia.new({ cmd = { JULIA, '--startup-file=no' } }) },
  inline = { enabled = true, max_height = 8, max_width = 72 } })
write('e2e.jl', 'for i in 1:3; println("tick", i); sleep(0.5); end\nprintln("pid ", getpid())')
vim.cmd.edit(vim.fn.fnameescape(dir .. '/e2e.jl'))
vim.bo.filetype = 'julia'
local sb = vim.api.nvim_get_current_buf()
defer(function() replise.stop(sb) end)
local function pane()
  local win, newest = nil, 0
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].filetype == 'replise_inline' and b > newest then win, newest = w, b end
  end
  if win then
    local t = vim.api.nvim_win_get_config(win).title
    return table.concat(vim.api.nvim_buf_get_lines(newest, 0, -1, false), '\n'),
      type(t) == 'table' and table.concat(vim.tbl_map(function(c) return c[1] end, t)) or tostring(t)
  end
  return '', ''
end
local function settle(what)
  vim.wait(120000, function() local s = replise.get_session(sb) return s and s.state == 'idle' end, 20)
  local s = replise.get_session(sb)
  check(s and s.state == 'idle', 'e2e idle after ' .. what, s and s.state)
  return s
end
check(replise.run_buffer(), 'e2e run_buffer accepted')
local streamed = false
vim.wait(120000, function()
  local s, text = replise.get_session(sb), pane()
  if s and s.state == 'busy' and text:find('tick1') and not text:find('pid') then streamed = true end
  return s and s.state == 'idle'
end, 10)
local s = settle('run')
local text, title = pane()
check(streamed and text:find('tick3') and title:find('done'), 'e2e stream before done', text, title)
local jpid = tonumber(text:match('pid (%d+)'))
local rb = replise.get_repl_buffer(sb)
check(rb == s.handle.repl_bufnr and tree(vim.fn.jobpid(s.handle.job_id))[jpid], 'inline output from the REPL terminal process', jpid)
vim.wait(5000, function() return term_text(rb):find('pid ' .. jpid, 1, true) end)
check(term_text(rb):find('pid ' .. jpid, 1, true), 'terminal shows the same run', term_text(rb))

vim.api.nvim_buf_set_lines(sb, -1, -1, false, { 'error("e2e boom")', 'while true; sleep(0.1); end' })
vim.api.nvim_win_set_cursor(0, { 3, 0 })
replise.send_line()
settle('error')
check(require('replise.inline').focus_here(), 'enter error output at its anchor')
require('replise.inline').leave()
text, title = pane()
check(text:find('e2e boom') and title:find('error'), 'e2e error', text, title)
local preserved = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local b = vim.api.nvim_win_get_buf(w)
  if vim.bo[b].filetype == 'replise_inline' then
    preserved = preserved + 1
  end
end
check(preserved == 2, 'file output remains alongside line output', preserved)

vim.api.nvim_win_set_cursor(0, { 4, 0 })
replise.send_line()
vim.wait(1500) -- julia is really inside the loop now
check(replise.get_session(sb).state == 'busy', 'e2e busy')
replise.interrupt(sb)
settle('interrupt')
check(require('replise.inline').focus_here(), 'enter interrupted output at its anchor')
require('replise.inline').leave()
text, title = pane()
check(title:find('interrupted'), 'e2e interrupt acknowledged', title)

local old = tree(vim.fn.jobpid(s.handle.job_id))
replise.restart(sb)
vim.wait(180000, function() local n = replise.get_session(sb) return n and n.state == 'idle' end, 20)
local n = replise.get_session(sb)
check(n and n.handle ~= s.handle and n.state == 'idle', 'e2e restarted', n)
vim.wait(10000, function() return alive(old) == 0 end, 200)
check(alive(old) == 0, 'old process gone after restart', old)
local cur = tree(vim.fn.jobpid(n.handle.job_id))
replise.stop(sb)
vim.wait(10000, function() return alive(cur) == 0 end, 200)
check(alive(cur) == 0 and replise.get_session(sb) == nil, 'e2e stop cleanup', cur)
vim.cmd('bwipe!')

end, debug.traceback)
check(ok, 'error', err)
cleanup()
say('julia: OK')
