-- Julia backend: a hidden iron.nvim terminal REPL plus a small pipe control channel (see julia/bootstrap.jl).
local M = {}

local uv = vim.uv
local win = vim.fn.has('win32') == 1
local bootstrap = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h:h') .. '/julia/bootstrap.jl'
local npipes = 0

local OPTS = {
  cmd = 'table', -- default iron's julia command ({ 'julia' })
  root_markers = 'table',
  revise = 'boolean',
  instantiate = function(v) return v == false or v == 'startup' or v == 'on_change' end,
  prescript = 'string',
  before_run = 'string',
  files = { 'table', 'function' },
}

local function pipe_name()
  npipes = npipes + 1
  local id = ('replise-nvim-%d-%d-%d'):format(uv.os_getpid(), npipes, uv.hrtime() % 1e9)
  return win and [[\\.\pipe\]] .. id or vim.fn.tempname() .. '.sock'
end

-- instantiate='on_change': signature of the julia command + Project/Manifest, stamped after a successful bootstrap.
local function env_sig(root, cmdline)
  local parts = { cmdline }
  for _, f in ipairs({ 'Project.toml', 'JuliaProject.toml', 'Manifest.toml', 'JuliaManifest.toml' }) do
    local fd = io.open(root .. '/' .. f, 'rb')
    parts[#parts + 1] = fd and fd:read('a') or ''
    if fd then fd:close() end
  end
  return vim.fn.sha256(table.concat(parts, '\0'))
end
local function stamp_path(root)
  return vim.fn.stdpath('state') .. '/replise.nvim/julia-instantiate-' .. vim.fn.sha256(root):sub(1, 16)
end

local function interrupt_running(h, sid)
  if not h.stopped and h.cancel == sid and h.running == sid and h.ids[sid] then
    h.cancel = nil
    vim.api.nvim_chan_send(h.job_id, '\3')
  end
end

local function on_line(h, line)
  local ev, sid, b64 = line:match('^(%S+) (%d+) (%S*)$')
  if not ev then return end
  sid = tonumber(sid)
  local data = vim.base64.decode(b64)
  if ev == 'ready' then
    if h.stamp then vim.schedule(h.stamp) end
    return h.emit({ kind = 'ready' })
  end
  if sid == 0 then -- bootstrap output / init failure
    return h.emit(ev == 'error' and { kind = 'error', message = 'julia init failed: ' .. data } or { kind = ev, chunk = data })
  end
  local id = h.ids[sid]
  if id == nil then return end -- canceled / stale
  if ev == 'running' then
    h.running = sid
    h.emit({ kind = 'running', request_id = id })
    if h.cancel == sid then vim.schedule(function() interrupt_running(h, sid) end) end
  elseif ev == 'stdout' or ev == 'stderr' then
    h.emit({ kind = ev, request_id = id, chunk = data })
  elseif ev == 'done' or ev == 'error' then
    h.ids[sid], h.running, h.cancel = nil, nil, nil
    h.emit({ kind = ev, request_id = id, message = ev == 'error' and data or nil })
  end
end

local function stop(h)
  h.stopped = true
  for _, p in ipairs({ h.client, h.server }) do
    if not p:is_closing() then p:close() end
  end
  if not win and h.pipe then os.remove(h.pipe) end
  if h.job_id then pcall(vim.fn.jobstop, h.job_id) end
  if h.repl_bufnr and vim.api.nvim_buf_is_valid(h.repl_bufnr) then
    pcall(vim.api.nvim_buf_delete, h.repl_bufnr, { force = true })
  end
end

-- The process (or its control channel) is gone: report once and release everything we own.
local function fail(h, msg)
  if h.stopped then return end
  h.emit({ kind = 'exit', message = msg })
  stop(h)
end

--- opts: see OPTS. files = { ['rel/path.jl'] = { run = 'main()', first_run = 'include'|'include_and_call' } }
--- (keys relative to the project root, or absolute) or function(path, root) -> rule|nil.
function M.new(opts)
  opts = opts or {}
  for k, v in pairs(opts) do
    if not OPTS[k] then error('replise.nvim julia: unknown option ' .. vim.inspect(k), 2) end
    vim.validate(k, v, OPTS[k], 'see replise.nvim README (Julia)')
  end
  local B = { root_markers = opts.root_markers or { 'Project.toml', 'JuliaProject.toml' } }

  local function spawn(h, ctx)
    local cmd = vim.deepcopy(opts.cmd or require('iron.fts').julia.julia.command) -- used exactly as configured
    local instantiate = opts.instantiate == 'startup'
    if opts.instantiate == 'on_change' then
      local path, cmdline = stamp_path(ctx.root), table.concat(cmd, ' ')
      instantiate = vim.fn.filereadable(path) == 0 or vim.fn.readfile(path)[1] ~= env_sig(ctx.root, cmdline)
      h.stamp = instantiate and function() -- after bootstrap, which may have written the Manifest
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        vim.fn.writefile({ env_sig(ctx.root, cmdline) }, path)
      end or nil
    end
    h.pipe = pipe_name()
    assert(h.server:bind(h.pipe))
    assert(h.server:listen(1, function()
      h.server:accept(h.client)
      h.connected = true
      vim.schedule(function() -- ready is reported by the REPL evaluating this, after bootstrap succeeded
        if not h.stopped then vim.api.nvim_chan_send(h.job_id, 'Replise.ready()\r') end
      end)
      local buf = ''
      h.client:read_start(function(err, chunk)
        if not chunk then -- EOF/error with julia still alive: broken channel, stop it rather than hang core
          return vim.defer_fn(function() -- grace period so a real exit is reported by TermClose with its code
            fail(h, 'julia control channel closed' .. (err and (': ' .. err) or ''))
          end, 1000)
        end
        buf = buf .. chunk
        for line in buf:gmatch('([^\n]*)\n') do on_line(h, line) end
        buf = buf:match('[^\n]*$')
      end)
    end))
    vim.list_extend(cmd, { '--project=' .. ctx.root, '-i', '-L', bootstrap })
    local env = {
      REPLISE_PIPE = h.pipe,
      REPLISE_ROOT = ctx.root,
      REPLISE_REVISE = opts.revise and '1' or '',
      REPLISE_INSTANTIATE = instantiate and '1' or '',
      REPLISE_PRESCRIPT = opts.prescript or '',
      REPLISE_BEFORE_RUN = opts.before_run or '',
    }
    h.repl_bufnr = vim.api.nvim_create_buf(false, true)
    local meta = vim.api.nvim_buf_call(h.repl_bufnr, function() -- hidden: no window is opened
      return require('iron.lowlevel').create_repl_on_current_window('julia', { command = cmd, env = env },
        h.repl_bufnr, ctx.bufnr, { cwd = ctx.root })
    end)
    if meta.job <= 0 then error('cannot run ' .. table.concat(cmd, ' ')) end
    h.job_id = meta.job
    vim.api.nvim_create_autocmd('TermClose', {
      buffer = h.repl_bufnr,
      once = true,
      callback = function()
        local code = vim.v.event.status
        vim.schedule(function() fail(h, 'julia exited with code ' .. tostring(code)) end)
      end,
    })
  end

  function B.start(ctx, emit)
    local h = { emit = emit, ids = {}, sid = 0, root = ctx.root, server = uv.new_pipe(false), client = uv.new_pipe(false) }
    local ok, err = pcall(spawn, h, ctx)
    if not ok then
      stop(h)
      error('replise.nvim: julia start failed: ' .. tostring(err), 0)
    end
    return h
  end

  local function dispatch(h, req, kind, first, code)
    assert(h.connected and not h.stopped and not h.client:is_closing(), 'replise.nvim: julia control channel is not connected')
    h.sid = h.sid + 1
    h.ids[h.sid] = req.id
    local path = req.path or ''
    h.client:write(('%d %s %s %d %d\n'):format(h.sid, kind, first, #path, #code) .. path .. code)
    vim.api.nvim_chan_send(h.job_id, ('Replise.run(%d)\r'):format(h.sid))
  end

  function B.run_buffer(h, req)
    local rule = opts.files
    if type(rule) == 'function' then
      rule = rule(req.path, h.root)
    elseif rule then
      local rel = vim.fs.relpath(h.root, req.path)
      rule = rel and rule[rel] or rule[vim.fs.normalize(req.path)]
    end
    rule = rule or {}
    assert(rule.run == nil or type(rule.run) == 'string', 'replise.nvim julia: files rule `run` must be a string')
    assert(({ include = 1, include_and_call = 1 })[rule.first_run or 'include_and_call'],
      "replise.nvim julia: files rule `first_run` must be 'include' or 'include_and_call'")
    dispatch(h, req, 'run', rule.first_run == 'include' and 'include' or 'call', rule.run or '')
  end

  function B.send(h, req)
    dispatch(h, req, 'send', '-', req.code)
  end

  function B.interrupt(h)
    local sid = h.sid
    if h.ids[sid] == nil or h.client:is_closing() then return end
    -- Queued work is canceled by the helper. Running work needs Ctrl-C, including CPU-bound work
    -- whose running event is still in flight. Never signal the idle REPL just to cancel queued work.
    h.cancel = sid
    h.client:write(('%d cancel - 0 0\n'):format(sid))
    interrupt_running(h, sid)
  end

  B.stop = stop
  return B
end

return M
