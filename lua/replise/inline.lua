-- One live log pane per source buffer: an extmark reserves blank virtual lines
-- under the anchor row and a focusable bordered float is drawn over that gap.
local api, fn, uv = vim.api, vim.fn, vim.uv
local M = {}

local ns = api.nvim_create_namespace('replise.inline')
local defaults = { max_height = 8, max_width = 72, max_lines = 1000 }
local SPIN = { starting = true, running = true }
local HL = { done = 'DiagnosticOk', error = 'DiagnosticError', interrupted = 'DiagnosticWarn' }
local FRAMES = {}
for i = 0, 6 do
  FRAMES[#FRAMES + 1] = ('▱'):rep(i) .. '▰▰▰' .. ('▱'):rep(6 - i)
end

local views = {} -- [source bufnr] = view
local logbufs = {} -- [log bufnr] = source bufnr
local timer, pending, watching, sync

local function resolve(b)
  b = (b == nil or b == 0) and api.nvim_get_current_buf() or b
  return logbufs[b] or b
end

local function title(v)
  local s = ('%s %.1fs'):format(v.state, ((v.t1 or uv.hrtime()) - v.t0) / 1e9)
  if v.msg and v.msg ~= '' then s = s .. ': ' .. v.msg end
  local t = { { ' ' .. s .. ' ', HL[v.state] or 'FloatTitle' } }
  if SPIN[v.state] then table.insert(t, 1, { ' ' .. FRAMES[v.frame % #FRAMES + 1], 'DiagnosticInfo' }) end
  -- source edited since this run was opened: the shown output may no longer match the code
  if api.nvim_buf_get_changedtick(v.buf) ~= v.tick then t[#t + 1] = { ' stale ', 'DiagnosticWarn' } end
  return t
end

-- busy: a bright bar sweeps the whole bottom border, so the pane is framed top and bottom while it runs
local function footer(v, iw)
  if not SPIN[v.state] then return '' end
  local k = math.min(8, iw)
  local span = iw - k
  local p = span > 0 and math.abs((v.frame * 3) % (2 * span) - span) or 0
  local f = {}
  for _, c in ipairs({ { ('─'):rep(p), 'FloatBorder' }, { ('━'):rep(k), 'DiagnosticInfo' }, { ('─'):rep(span - p), 'FloatBorder' } }) do
    if c[1] ~= '' then f[#f + 1] = c end
  end
  return f
end

-- the log is read-only for the user; only these internal writes may change it
local function write(buf, f, ...)
  vim.bo[buf].modifiable = true
  f(buf, ...)
  vim.bo[buf].modifiable = false
end

local function valid(o)
  local function int(x, min) return type(x) == 'number' and x % 1 == 0 and x >= min end
  return int(o.max_height, 3) and int(o.max_width, 3) and int(o.max_lines, 1)
end

local function hide(v)
  if v.cfg then api.nvim_win_set_config(v.float, { hide = true }) end
  v.cfg = nil
end

local function tick()
  local any = false
  for _, v in pairs(views) do
    local w = v.float
    if v.cfg and SPIN[v.state] and api.nvim_win_is_valid(w) and api.nvim_win_get_tabpage(w) == api.nvim_get_current_tabpage() then
      v.frame, any = v.frame + 1, true
      sync(v)
    end
  end
  if not any then timer:stop() end -- nothing visible is spinning: sleep until a sync restarts it
end

local function new_float(log)
  local w = api.nvim_open_win(log, false, {
    relative = 'editor', row = 0, col = 0, width = 1, height = 1, hide = true,
    focusable = true, border = 'rounded', style = 'minimal', noautocmd = true,
  })
  vim.wo[w].wrap, vim.wo[w].winfixbuf, vim.wo[w].scrolloff = true, true, 0
  return w
end

-- Place/size the float for the current viewport; hide it whenever the gap is not on screen.
function sync(v)
  if fn.getcmdwintype() ~= '' then return end -- windows cannot be changed from the cmdline window
  if not api.nvim_buf_is_valid(v.buf) or not api.nvim_buf_is_valid(v.log) then return M.clear(v.buf) end
  if not api.nvim_win_is_valid(v.float) then -- closed by :only/:q etc.; the log survives, only clear() drops it
    v.float, v.cfg = new_float(v.log), nil
    api.nvim_win_set_cursor(v.float, { api.nvim_buf_line_count(v.log), 0 })
  end
  local pos = api.nvim_buf_get_extmark_by_id(v.buf, ns, v.mark, {})
  if not pos[1] then return M.clear(v.buf) end
  local row = pos[1]

  local win = v.win
  if not (win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == v.buf) then
    win = nil
    for _, w in ipairs(fn.win_findbuf(v.buf)) do
      if api.nvim_win_get_tabpage(w) == api.nvim_get_current_tabpage() and api.nvim_win_get_config(w).relative == '' then
        win = w
        break
      end
    end
  end
  if not win then return hide(v) end
  v.win = win

  local info = fn.getwininfo(win)[1]
  local sv = api.nvim_win_call(win, function()
    local s = fn.winsaveview()
    s.folded = fn.foldclosed(row + 1) ~= -1
    return s
  end)
  if sv.folded or row + 1 < info.topline or row + 1 > info.botline then return hide(v) end

  local th = api.nvim_win_text_height
  local anchor = th(win, { start_row = row, end_row = row })
  local text_rows = anchor.all - anchor.fill
  local above = th(win, { start_row = info.topline - 1, end_row = row }).all -- rows from window top to end of anchor
    - th(win, { start_row = info.topline - 1, end_row = info.topline - 1 }).fill
    + sv.topfill

  local o, t, tw = v.opts, title(v), 0
  for _, c in ipairs(t) do tw = tw + fn.strdisplaywidth(c[1]) end
  local iw = math.min(math.max(v.width, tw), o.max_width - 2, info.width - info.textoff - 2)
  local cap = math.min(o.max_height, info.height) - 2
  if iw < 1 or cap < 1 then return hide(v) end
  if api.nvim_win_get_width(v.float) ~= iw then api.nvim_win_set_config(v.float, { width = iw }) end
  local n = api.nvim_buf_line_count(v.log)
  local ih = math.max(1, math.min(cap, th(v.float, { start_row = math.max(0, n - cap) }).all))
  if v.gap ~= ih + 2 then
    v.gap = ih + 2
    local lines = {}
    for i = 1, v.gap do lines[i] = { { '' } } end
    api.nvim_buf_set_extmark(v.buf, ns, row, 0, { id = v.mark, virt_lines = lines })
  end
  local h = math.min(v.gap, info.height - above) - 2 -- only the part of the gap inside the window
  if h < 1 then return hide(v) end

  local cfg = { relative = 'win', win = win, width = iw, height = h, hide = false, title = t, footer = footer(v, iw) }
  if sv.leftcol == 0 then -- native anchoring: follows scrolling without waiting for a resync
    cfg.bufpos, cfg.row, cfg.col = { row, 0 }, text_rows, 0
  else -- bufpos misplaces floats when column 0 is scrolled off horizontally
    cfg.row, cfg.col = above, info.textoff
  end
  if not vim.deep_equal(cfg, v.cfg) then
    api.nvim_win_set_config(v.float, cfg)
    v.cfg = cfg
  end
  if SPIN[v.state] then
    timer = timer or uv.new_timer()
    if not timer:is_active() then timer:start(100, 100, vim.schedule_wrap(tick)) end
  end
end

-- view for a public call, after repairing a float closed behind our back
local function live(b)
  local v = views[resolve(b)]
  if v and not (api.nvim_buf_is_valid(v.log) and api.nvim_win_is_valid(v.float)) then sync(v) end
  return v and views[v.buf] == v and api.nvim_win_is_valid(v.float) and v or nil
end

function M.open(bufnr, row, opts)
  bufnr = resolve(bufnr)
  local o = vim.tbl_extend('force', defaults, opts or {})
  if not valid(o) then -- reject before any gap/float/log exists; the run itself continues without a pane
    M.clear(bufnr)
    vim.notify('replise.inline: max_height/max_width must be integers >= 3 (border included), max_lines an integer >= 1',
      vim.log.levels.ERROR)
    return
  end
  local v = live(bufnr)
  if not v then
    M.clear(bufnr)
    local log = api.nvim_create_buf(false, true)
    v = { buf = bufnr, log = log, float = new_float(log) }
    views[bufnr], logbufs[log] = v, bufnr
    vim.bo[log].filetype = 'replise_inline' -- lets users map viewer keys (e.g. <Esc> -> leave) via FileType
  end
  if api.nvim_get_current_buf() == bufnr then v.win = api.nvim_get_current_win() end
  row = math.max(0, math.min(row or 0, api.nvim_buf_line_count(bufnr) - 1))
  v.mark = api.nvim_buf_set_extmark(bufnr, ns, row, 0, { id = v.mark })
  v.opts, v.esc, v.tick = o, nil, api.nvim_buf_get_changedtick(bufnr)
  v.gap, v.width, v.cr, v.state, v.msg, v.t0, v.t1, v.frame = nil, 1, false, 'starting', nil, uv.hrtime(), nil, 0
  api.nvim_buf_clear_namespace(v.log, ns, 0, -1)
  write(v.log, api.nvim_buf_set_lines, 0, -1, false, {})
  api.nvim_win_set_cursor(v.float, { 1, 0 })
  if not watching then -- every redraw (scroll, resize, edit, fold, buffer switch) re-validates the panes
    watching = true
    api.nvim_set_decoration_provider(ns, {
      on_win = function(_, _, buf)
        if next(views) and not logbufs[buf] and not pending then
          pending = true
          vim.schedule(function()
            pending = false
            for _, x in pairs(views) do sync(x) end
          end)
        end
        return false
      end,
    })
  end
  sync(v)
end

function M.append(bufnr, chunk, stream)
  local v = live(bufnr)
  if not v or not chunk then return end
  -- drop ANSI CSI codes (colors/cursor); an escape cut at the chunk end waits for the next chunk
  chunk = (v.esc or '') .. chunk
  v.esc = chunk:match('\27%[[0-?]*[ -/]*$') or chunk:match('\27$')
  if v.esc then chunk = chunk:sub(1, -#v.esc - 1) end
  chunk = chunk:gsub('\27%[[0-?]*[ -/]*[@-~]', ''):gsub('\27', '')
  if chunk == '' then return end
  local n = api.nvim_buf_line_count(v.log)
  local follow = api.nvim_win_get_cursor(v.float)[1] >= n
  local old = api.nvim_buf_get_lines(v.log, n - 1, n, false)[1]
  local lines, keep, shrink = { old }, #old, false
  for text, sep in chunk:gmatch('([^\r\n]*)([\r\n]?)') do
    if text ~= '' then
      if v.cr then -- carriage return: the next text rewrites the current line (progress bars)
        lines[#lines] = text
        if #lines == 1 then keep, shrink = 0, #old > 0 end
      else
        lines[#lines] = lines[#lines] .. text
      end
      v.cr = false
    end
    if sep == '\n' then
      lines[#lines + 1], v.cr = '', false
    elseif sep == '\r' then
      v.cr = true
    end
  end
  for _, l in ipairs(lines) do v.width = math.max(v.width, fn.strdisplaywidth(l)) end
  lines[1] = lines[1]:sub(keep + 1)
  write(v.log, api.nvim_buf_set_text, n - 1, keep, n - 1, #old, lines)
  if stream == 'stderr' then
    local er = n - 2 + #lines
    api.nvim_buf_set_extmark(v.log, ns, n - 1, keep, {
      end_row = er, end_col = #lines[#lines] + (#lines == 1 and keep or 0), hl_group = 'DiagnosticError',
    })
  end
  local over = api.nvim_buf_line_count(v.log) - v.opts.max_lines
  if over > 0 then write(v.log, api.nvim_buf_set_lines, 0, over, false, {}) end
  if shrink or over > 0 then -- the widest line may be gone: rescan the retained log (at most max_lines)
    v.width = 1
    for _, l in ipairs(api.nvim_buf_get_lines(v.log, 0, -1, false)) do v.width = math.max(v.width, fn.strdisplaywidth(l)) end
  end
  sync(v)
  if follow and views[v.buf] == v then -- tail-follow unless the user moved up to browse
    api.nvim_win_set_cursor(v.float, { api.nvim_buf_line_count(v.log), 0 })
    api.nvim_win_call(v.float, function() vim.cmd('normal! zb') end)
  end
end

function M.set_state(bufnr, state, message)
  local v = views[resolve(bufnr)]
  if not v then return end
  v.state, v.msg = state, message and message:match('[^\r\n]*')
  v.t1 = not SPIN[state] and uv.hrtime() or nil
  sync(v)
end

function M.focus(bufnr)
  local v = live(bufnr)
  if not v then return false end
  sync(v)
  if views[v.buf] ~= v then return false end
  if not v.cfg and v.win and api.nvim_win_is_valid(v.win) and api.nvim_win_get_buf(v.win) == v.buf then
    local row = api.nvim_buf_get_extmark_by_id(v.buf, ns, v.mark, {})[1]
    api.nvim_win_call(v.win, function()
      api.nvim_win_set_cursor(0, { row + 1, 0 })
      vim.cmd('normal! zvzt')
    end)
    sync(v)
  end
  if not v.cfg then return false end
  api.nvim_set_current_win(v.float)
  return true
end

function M.leave()
  local v = views[logbufs[api.nvim_get_current_buf()]]
  if not v then return false end
  if not (v.win and api.nvim_win_is_valid(v.win)) then return false end
  api.nvim_set_current_win(v.win)
  return true
end

function M.clear(bufnr)
  bufnr = resolve(bufnr)
  local v = views[bufnr]
  if not v then return end
  if api.nvim_get_current_win() == v.float then M.leave() end
  views[bufnr], logbufs[v.log] = nil, nil
  if api.nvim_buf_is_valid(bufnr) then api.nvim_buf_del_extmark(bufnr, ns, v.mark) end
  if api.nvim_win_is_valid(v.float) then api.nvim_win_close(v.float, true) end
  if api.nvim_buf_is_valid(v.log) then api.nvim_buf_delete(v.log, { force = true }) end
  if not next(views) then -- nothing left to watch: stop the spinner and detach the redraw hook now
    if timer then timer:stop() end
    api.nvim_set_decoration_provider(ns, {})
    watching = false
  end
end

function M.clear_all()
  for b in pairs(views) do M.clear(b) end
end

return M
