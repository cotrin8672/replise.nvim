local M = {}
local api = vim.api
local config, backends, sessions, last_id, group = {}, {}, {}, 0, nil

local function fail(msg, level)
  vim.notify('replise: ' .. msg, level or vim.log.levels.WARN)
  return nil, msg
end

-- Inline is loaded lazily and only when enabled; every call is a no-op otherwise.
local function ui(fn, ...)
  if config.inline and config.inline.enabled then require('replise.inline')[fn](...) end
end

function M.register_backend(ft, backend) backends[ft] = backend end

function M.get_context(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  if not api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= '' then return nil, 'not a source buffer' end
  local ft, name = vim.bo[bufnr].filetype, api.nvim_buf_get_name(bufnr)
  local backend = backends[ft]
  if not backend then return nil, 'no backend for filetype "' .. ft .. '"' end
  if name == '' then return nil, 'buffer has no file name' end
  local root = backend.root_markers and vim.fs.root(bufnr, backend.root_markers)
  if not root then return nil, 'no project root (' .. table.concat(backend.root_markers or {}, ', ') .. ')' end
  root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)
  return { bufnr = bufnr, ft = ft, root = root, backend = backend, key = ft .. '\0' .. root }
end

function M.get_session(bufnr)
  local ctx = M.get_context(bufnr)
  return ctx and sessions[ctx.key]
end

function M.get_repl_buffer(bufnr)
  local s = M.get_session(bufnr)
  return s and s.handle and s.handle.repl_bufnr
end

local function finish(s, state, msg)
  local req = s.current
  if state == 'error' and s.interrupting then state = 'interrupted' end
  s.current, s.state, s.interrupting = nil, 'idle', nil
  ui('set_state', req.bufnr, state, msg)
end

-- Forget the session (its emit becomes stale) and fail whatever it held.
local function drop(s, state, msg, stop)
  if sessions[s.key] == s then sessions[s.key] = nil end
  s.dead = true
  for _, req in pairs({ s.current, s.pending }) do ui('set_state', req.bufnr, state, msg) end
  s.current, s.pending = nil, nil
  if stop and s.handle then pcall(s.backend.stop, s.handle) end
end

local function dispatch(s, req)
  s.current, s.state = req, 'busy'
  ui('set_state', req.bufnr, 'running')
  local ok, err = pcall(s.backend[req.kind == 'run' and 'run_buffer' or 'send'], s.handle, req)
  if not ok and s.current == req then finish(s, 'error', tostring(err)) end
end

local function on_event(s, ev)
  if vim.in_fast_event() then return vim.schedule(function() on_event(s, ev) end) end
  if sessions[s.key] ~= s then return end -- stopped/restarted session
  local k, req = ev.kind, s.current
  if k == 'ready' then
    if s.state ~= 'starting' then return end
    s.state = 'idle'
    local p = s.pending
    s.pending = nil
    if p then dispatch(s, p) end
  elseif k == 'exit' then
    drop(s, 'error', ev.message or 'process exited')
    fail((ev.message or 'process exited') .. ' (' .. s.root .. ')')
  elseif not ev.request_id then
    if (k == 'stdout' or k == 'stderr') and s.pending then ui('append', s.pending.bufnr, ev.chunk, k) end -- bootstrap log
    if k ~= 'error' then return end
    if s.state == 'starting' then drop(s, 'error', ev.message, true) end
    fail(tostring(ev.message), vim.log.levels.ERROR)
  elseif not req or ev.request_id ~= req.id then
    return -- stale request
  elseif k == 'stdout' or k == 'stderr' then
    ui('append', req.bufnr, ev.chunk, k)
  elseif k == 'running' then
    ui('set_state', req.bufnr, 'running')
  elseif k == 'done' or k == 'error' then
    finish(s, k, ev.message)
  end
end

local function start(ctx)
  if sessions[ctx.key] then return sessions[ctx.key] end
  local s = { key = ctx.key, ft = ctx.ft, root = ctx.root, backend = ctx.backend, state = 'starting' }
  sessions[ctx.key] = s
  local ok, h = pcall(ctx.backend.start, { bufnr = ctx.bufnr, root = ctx.root, ft = ctx.ft },
    function(ev) on_event(s, ev) end)
  if not ok then
    drop(s, 'error', tostring(h))
    return fail('start failed: ' .. tostring(h), vim.log.levels.ERROR)
  end
  s.handle = h
  if s.dead then -- failed synchronously through emit
    pcall(s.backend.stop, h)
    return nil, 'start failed'
  end
  return s
end

local function submit(ctx, req)
  local s = sessions[ctx.key]
  if s and (s.current or s.pending) then return fail('busy') end
  local err
  if not s then
    s, err = start(ctx)
    if not s then return nil, err end
  end
  last_id = last_id + 1
  req.id = last_id
  ui('open', req.bufnr, req.row, config.inline, req)
  if s.state == 'starting' then
    s.pending = req
    ui('set_state', req.bufnr, 'starting')
  else
    dispatch(s, req)
  end
  return req.id
end

local function send(bufnr, code, row, range)
  local ctx, err = M.get_context(bufnr)
  if not ctx then return fail(err) end
  range = range or { row, 0, row, #api.nvim_buf_get_lines(ctx.bufnr, row, row + 1, false)[1] }
  return submit(ctx, { kind = 'send', bufnr = ctx.bufnr, path = api.nvim_buf_get_name(ctx.bufnr), code = code, row = row, range = range })
end

function M.start(bufnr)
  local ctx, err = M.get_context(bufnr)
  if not ctx then return fail(err) end
  return start(ctx)
end

function M.stop(bufnr)
  local s = M.get_session(bufnr)
  if not s then return false end
  drop(s, 'interrupted', 'stopped', true)
  return true
end

function M.restart(bufnr)
  M.stop(bufnr)
  return M.start(bufnr)
end

-- opts.save = true writes a modified buffer first; otherwise modified buffers are rejected.
function M.run_buffer(opts)
  opts = opts or {}
  local ctx, err = M.get_context(opts.bufnr)
  if not ctx then return fail(err) end
  local b = ctx.bufnr
  if vim.bo[b].modified then
    if not opts.save then return fail('buffer has unsaved changes; save it or use run_buffer({ save = true })') end
    api.nvim_buf_call(b, function() vim.cmd('silent write') end)
  end
  local path = api.nvim_buf_get_name(b)
  if not vim.uv.fs_stat(path) then return fail('file does not exist on disk: ' .. path) end
  return submit(ctx, { kind = 'run', bufnr = b, path = path, row = api.nvim_buf_line_count(b) - 1 })
end

function M.send_line()
  local row = api.nvim_win_get_cursor(0)[1] - 1
  return send(0, api.nvim_buf_get_lines(0, row, row + 1, false)[1], row)
end

-- Works from a visual-mode mapping (live selection) or after it (last '< '> marks).
function M.send_selection()
  local mode, p1, p2 = vim.fn.mode(), nil, nil
  if mode:match('^[vV\22]') then
    p1, p2 = vim.fn.getpos('v'), vim.fn.getpos('.')
    api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
  else
    mode, p1, p2 = vim.fn.visualmode(), vim.fn.getpos("'<"), vim.fn.getpos("'>")
  end
  if mode == '' or p1[2] == 0 then return fail('no selection') end
  local lines = vim.fn.getregion(p1, p2, { type = mode })
  if p1[2] > p2[2] or (p1[2] == p2[2] and p1[3] > p2[3]) then p1, p2 = p2, p1 end
  local first, last = p1[2] - 1, p2[2] - 1
  local a = api.nvim_buf_get_lines(0, first, first + 1, false)[1]
  local b = api.nvim_buf_get_lines(0, last, last + 1, false)[1]
  local c1, c2 = math.min(p1[3] - 1, #a), math.min(p2[3] - 1, #b)
  if mode == 'V' then c1, c2 = 0, #b end
  return send(0, table.concat(lines, '\n'), last, { first, c1, last, c2 })
end

function M.interrupt(bufnr)
  local s = M.get_session(bufnr)
  if not s then return fail('no session') end
  if s.pending then -- not dispatched yet: cancel locally
    ui('set_state', s.pending.bufnr, 'interrupted')
    s.pending = nil
    return true
  end
  if s.state == 'starting' then return false end
  if s.current then s.interrupting = true end
  local ok, err = pcall(s.backend.interrupt, s.handle)
  if not ok then
    s.interrupting = nil
    return fail('interrupt failed: ' .. tostring(err))
  end
  return true
end

local function commands()
  local cmd = api.nvim_create_user_command
  for name, fn in pairs({ RepliseStart = M.start, RepliseStop = M.stop, RepliseRestart = M.restart, RepliseInterrupt = M.interrupt,
    RepliseInlineClear = function() require('replise.inline').clear() end,
    RepliseInlineClearAll = function() require('replise.inline').clear_all() end }) do
    cmd(name, function() fn() end, {})
  end
  cmd('RepliseRun', function(a) M.run_buffer({ save = a.bang }) end, { bang = true })
  cmd('RepliseSend', function(a)
    local lines = api.nvim_buf_get_lines(0, a.line1 - 1, a.line2, false)
    send(0, table.concat(lines, '\n'), a.line2 - 1, { a.line1 - 1, 0, a.line2 - 1, #lines[#lines] })
  end, { range = true })
end

function M.setup(opts)
  config = opts or {}
  for ft, b in pairs(config.backends or {}) do backends[ft] = b end
  if config.commands then commands() end
  if group then api.nvim_del_augroup_by_id(group) group = nil end
  local fts = config.autostart or {}
  if #fts == 0 then return end
  local function auto(b) -- re-checks config: a later setup() may have disabled autostart
    local ok = api.nvim_buf_is_valid(b) and vim.tbl_contains(config.autostart or {}, vim.bo[b].filetype)
    local ctx = ok and M.get_context(b)
    if ctx then start(ctx) end
  end
  group = api.nvim_create_augroup('replise.nvim.autostart', {})
  api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = fts,
    callback = function(a) vim.schedule(function() auto(a.buf) end) end,
  })
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(b) and vim.tbl_contains(fts, vim.bo[b].filetype) then auto(b) end
  end
end

return M
