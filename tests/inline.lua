-- nvim --headless -u NONE -i NONE -l tests/inline.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local api, uv = vim.api, vim.uv
vim.o.columns, vim.o.lines = 80, 24
vim.opt.winblend = 17
local inline = require('replise.inline')
local ns = api.nvim_get_namespaces()['replise.inline']

local function settle(ms)
  vim.cmd('redraw')
  vim.wait(ms or 30)
  vim.cmd('redraw')
end
local function panes()
  local r = {}
  for _, w in ipairs(api.nvim_list_wins()) do
    if vim.bo[api.nvim_win_get_buf(w)].filetype == 'replise_inline' then r[#r + 1] = w end
  end
  return r
end
local function timers()
  local n = 0
  uv.walk(function(h) if h:get_type() == 'timer' and h:is_active() then n = n + 1 end end)
  return n
end
local function gap(buf)
  local m = api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  return m[1] and #(m[1][4].virt_lines or {}), m[1] and m[1][2]
end

local src = {}
for i = 1, 40 do src[i] = 'line ' .. i end
src[3] = '日本語の行'
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, -1, false, src)
vim.bo[buf].modified = false
local win = api.nvim_get_current_win()
local keys, base_timers = #api.nvim_get_keymap('n'), timers()

inline.open(buf, 4, { max_height = 8, max_width = 30 })
inline.set_state(buf, 'running')
for _, c in ipairs({ 'hello ', 'world\n', 'progress 10%\r', 'progress 50%\r', 'progress 100%\n',
  ('あ'):rep(40) .. '\n', 'a\r', '\nb\n' }) do
  inline.append(buf, c, 'stdout')
end
inline.append(buf, '\27[31mbo', 'stderr')
inline.append(buf, 'om\27', 'stderr') -- escape split across chunks
inline.append(buf, '[0', 'stderr')
inline.append(buf, 'm\n', 'stderr')
settle()

local p = panes()
assert(#p == 1, 'one pane')
local pw = p[1]
local lb = api.nvim_win_get_buf(pw)
assert(vim.deep_equal(api.nvim_buf_get_lines(lb, 0, -1, false),
  { 'hello world', 'progress 100%', ('あ'):rep(40), 'a', 'b', 'boom', '' }), 'partial/CR/CRLF/ANSI streaming')
assert(#api.nvim_buf_get_extmarks(lb, ns, { 5, 0 }, { 5, -1 }, { overlap = true }) > 0, 'stderr highlighted')
local cfg = api.nvim_win_get_config(pw)
assert(cfg.width + 2 == 30 and cfg.height + 2 == 8, ('cap incl. border %dx%d'):format(cfg.width, cfg.height))
assert(cfg.focusable and not cfg.hide)
assert(vim.wo[pw].winblend == 17, 'inherits winblend')
assert(gap(buf) == 8, 'virtual gap = float height incl. border')
assert(vim.deep_equal(api.nvim_win_get_position(pw), { 5, 0 }), 'float sits right under anchor')
assert(api.nvim_win_get_cursor(pw)[1] == 7, 'tail follow')
assert(not vim.bo[lb].modifiable and not pcall(api.nvim_buf_set_lines, lb, 0, 1, false, { 'x' }), 'log read-only')
assert(vim.iter(api.nvim_win_get_config(pw).footer):any(function(c) return c[1]:find('━') end), 'busy bar in footer')
assert(vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), src) and not vim.bo[buf].modified, 'source untouched')
assert(#api.nvim_get_keymap('n') == keys and #api.nvim_buf_get_keymap(lb, 'n') == 0, 'no keymaps')

-- spinner: animates while visible, pauses on another tabpage, stops when done
local t1 = api.nvim_win_get_config(pw).title[1][1]
settle(250)
assert(api.nvim_win_get_config(pw).title[1][1] ~= t1 and timers() == base_timers + 1, 'spinner runs')
vim.cmd('tabnew')
settle(250)
assert(timers() == base_timers, 'spinner paused when not visible')
vim.cmd('tabclose')
settle(250)
assert(timers() == base_timers + 1, 'spinner resumes')

-- narrow viewport clamps width; window wrap gives taller content but still capped
vim.cmd('vsplit')
api.nvim_win_set_width(win, 20)
settle()
cfg = api.nvim_win_get_config(pw)
assert(cfg.win == win and cfg.width + 2 == 20 and cfg.height + 2 == 8, 'clamped to window width ' .. cfg.width)
vim.cmd('close')
api.nvim_set_current_win(win)
settle()
assert(api.nvim_win_get_config(pw).width == 28, 'grows back')

-- edits above move the anchor and mark the shown result stale; scrolling/folding the anchor away hides the pane
local function stale() return vim.iter(api.nvim_win_get_config(pw).title):any(function(c) return c[1]:find('stale') end) end
assert(not stale(), 'fresh before edit')
api.nvim_buf_set_lines(buf, 0, 0, false, { 'x', 'y', 'z' })
settle()
assert(select(2, gap(buf)) == 7 and vim.deep_equal(api.nvim_win_get_position(pw), { 8, 0 }), 'anchor follows edit')
assert(stale(), 'stale after source edit')
vim.fn.winrestview({ topline = 20, lnum = 25 })
settle()
assert(api.nvim_win_get_config(pw).hide, 'hidden when scrolled away')
vim.fn.winrestview({ topline = 3, lnum = 5 })
settle()
assert(not api.nvim_win_get_config(pw).hide and vim.deep_equal(api.nvim_win_get_position(pw), { 6, 0 }), 'back on scroll')
vim.fn.winrestview({ topline = 1, lnum = 1 })
vim.cmd('6,10fold')
settle()
assert(api.nvim_win_get_config(pw).hide, 'hidden in closed fold')
vim.cmd('normal! zR')
settle()
assert(not api.nvim_win_get_config(pw).hide, 'shown after unfold')
vim.wo.wrap = false
api.nvim_buf_set_lines(buf, 0, 1, false, { ('w'):rep(200) })
vim.fn.winrestview({ leftcol = 50, topline = 1, lnum = 1, col = 100 })
settle()
assert(vim.deep_equal(api.nvim_win_get_position(pw), { 8, 0 }), 'horizontal scroll keeps pane in gap')
assert(api.nvim_win_get_config(pw).bufpos == nil)
vim.fn.winrestview({ leftcol = 0, topline = 1, lnum = 1, col = 0 })
api.nvim_buf_set_lines(buf, 0, 1, false, { 'x' })
vim.wo.wrap = true
-- anchor near window bottom: float shrinks to the visible part of the gap, then hides
vim.cmd('split')
api.nvim_win_set_height(win, 12) -- anchor ends at window row 8 -> 4 rows left
api.nvim_set_current_win(win)
settle()
cfg = api.nvim_win_get_config(pw)
assert(not cfg.hide and cfg.height + 2 == 4 and gap(buf) == 8, 'clamped to visible rows')
assert(api.nvim_win_get_position(pw)[1] + 4 == api.nvim_win_get_position(win)[1] + 12, 'ends at window bottom')
api.nvim_win_set_height(win, 10)
settle()
assert(api.nvim_win_get_config(pw).hide, 'hidden when no room')
vim.cmd('only') -- closes floats too; the pane comes back with its log
settle()
assert(not api.nvim_win_is_valid(pw) and #panes() == 1 and api.nvim_win_get_buf(panes()[1]) == lb, 'recreated')
pw = panes()[1]
assert(api.nvim_win_get_config(pw).height + 2 == 8)

-- focus/browse/leave
assert(inline.focus(buf) and api.nvim_get_current_win() == pw)
api.nvim_win_set_cursor(pw, { 1, 0 })
inline.append(buf, 'more\n')
assert(api.nvim_win_get_cursor(pw)[1] == 1, 'browsing position kept')
vim.cmd('normal! G')
inline.append(buf, 'tail\n')
assert(api.nvim_win_get_cursor(pw)[1] == api.nvim_buf_line_count(lb), 'follow resumes at tail')
assert(inline.leave() and api.nvim_get_current_win() == win, 'leave restores source')
vim.cmd('wincmd w')
assert(api.nvim_get_current_win() == pw, 'wincmd w reaches the focusable pane')
vim.cmd('wincmd p')
assert(api.nvim_get_current_win() == win, 'wincmd p returns')

inline.set_state(buf, 'done')
settle(250)
cfg = api.nvim_win_get_config(pw)
assert(cfg.title[1][1]:find('done') and not vim.iter(cfg.title):any(function(c) return c[1]:find('▰') end) and (cfg.footer or '') == '' and timers() == base_timers,
  'done stops spinner and busy bar')
-- idle pane: redraws must not keep reconfiguring the float (no redraw/resync loop)
local set_config, calls = api.nvim_win_set_config, 0
api.nvim_win_set_config = function(...) calls = calls + 1 return set_config(...) end
for _ = 1, 5 do vim.cmd('redraw!') vim.wait(40) end -- full redraw fires the on_win hook
api.nvim_win_set_config = set_config
assert(calls == 0, 'no resync loop: ' .. calls)

-- clear removes view only; late output must not recreate it
inline.focus(buf)
inline.clear()
settle()
assert(#panes() == 0 and not api.nvim_buf_is_valid(lb) and gap(buf) == nil, 'cleared')
assert(api.nvim_get_current_win() == win, 'clear from viewer returns to source')
inline.append(buf, 'late\n')
inline.set_state(buf, 'error', 'late')
settle()
assert(#panes() == 0, 'late chunks ignored')

-- bounded retention, reopen, clear_all
inline.open(buf, 0, { max_lines = 5 })
local function width() return api.nvim_win_get_config(panes()[1]).width end
inline.append(buf, ('w'):rep(60))
assert(width() == 60, 'width fits long progress line')
inline.append(buf, '\rshort\n') -- CR replaces the widest line
assert(width() < 40, 'width shrinks after CR replacement: ' .. width())
inline.append(buf, ('w'):rep(60) .. '\n')
assert(width() == 60)
for i = 1, 20 do inline.append(buf, i .. '\n') end
lb = api.nvim_win_get_buf(panes()[1])
assert(api.nvim_buf_line_count(lb) == 5 and api.nvim_buf_get_lines(lb, 0, 1, false)[1] == '17', 'retention')
assert(width() < 40, 'width shrinks after retention drops the widest line: ' .. width())
local b2 = api.nvim_create_buf(true, false)
api.nvim_buf_set_lines(b2, 0, -1, false, { 'other' })
inline.open(b2, 0)
assert(#panes() == 2)
inline.append(b2, 'other buffer')
local other
for _, w in ipairs(panes()) do if api.nvim_win_get_buf(w) ~= lb then other = w end end
inline.open(buf, 2)
inline.append(buf, 'second result in source')
assert(#panes() == 3)
inline.set_state(buf, 'running')
inline.clear_all(0)
assert(#panes() == 1 and panes()[1] == other and gap(buf) == nil, 'buffer clear preserves other buffers')
inline.append(buf, 'late')
assert(#panes() == 1, 'late output after buffer clear stays hidden')
inline.open(buf, 0)
inline.open(buf, 2)
assert(inline.focus(buf))
inline.clear_all(0)
assert(#panes() == 1 and panes()[1] == other and api.nvim_get_current_win() == win,
  'buffer clear from a log resolves its source buffer')
inline.clear_all()
assert(#panes() == 0 and timers() == base_timers, 'clear_all stops timer immediately')

-- Whole-file output at EOF can be focused from elsewhere without moving the cursor on run.
api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd('normal! ggzt')
inline.open(buf, api.nvim_buf_line_count(buf) - 1, { max_height = 12, max_width = 120 })
inline.append(buf, ((('w'):rep(200)) .. '\n'):rep(20))
settle()
pw = panes()[1]
assert(api.nvim_win_get_config(pw).hide and api.nvim_win_get_cursor(win)[1] == 1, 'EOF output stays off-screen')
assert(inline.focus(buf) and api.nvim_get_current_win() == pw, 'focus reveals off-screen EOF output')
settle()
cfg = api.nvim_win_get_config(pw)
assert(not cfg.hide and cfg.width + 2 == math.min(120, api.nvim_win_get_width(win)) and cfg.height + 2 == 12,
  'larger configured size, clamped to source window')
assert(vim.wo[pw].winblend == 17, 'recreated float inherits winblend')
assert(inline.leave() and api.nvim_get_current_win() == win)
inline.clear_all()

-- Several results survive in one buffer; Enter targets the exact anchor, not the latest request.
api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two', 'three', 'four', 'five', 'six' })
api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd('normal! ggzt')
local opts = { max_height = 4, max_width = 40, col_offset = 4 }
local function text(w) return table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, -1, false), '\n') end
local function at(row)
  for _, w in ipairs(panes()) do
    if api.nvim_win_get_config(w).bufpos[1] == row then return w end
  end
end
inline.open(buf, 0, opts)
inline.append(buf, 'first')
inline.set_state(buf, 'done')
local first = panes()[1]
inline.open(buf, 2, opts)
inline.append(buf, 'second')
inline.set_state(buf, 'running')
settle()
local second = at(2)
assert(#panes() == 2 and text(first) == 'first' and text(second) == 'second', 'retains both results')
assert(api.nvim_win_get_position(first)[2] == 4 and api.nvim_win_get_position(second)[2] == 4, 'right inset')
assert(inline.focus_here() and api.nvim_get_current_win() == first, 'Enter enters the pane below the cursor')
inline.append(buf, ' streamed')
assert(text(first) == 'first' and text(second) == 'second streamed', 'stream stays with its request while browsing old output')
assert(inline.leave())
api.nvim_win_set_cursor(win, { 2, 0 })
assert(not inline.focus_here() and api.nvim_get_current_win() == win, 'no pane below: Enter may fall back normally')
api.nvim_win_set_cursor(win, { 3, 0 })
assert(inline.focus_here() and api.nvim_get_current_win() == second)
assert(inline.leave())
inline.set_state(buf, 'done')
inline.open(buf, 0, opts)
inline.append(buf, 'replaced')
inline.set_state(buf, 'done')
assert(#panes() == 2 and at(0) == first and text(first) == 'replaced', 'same range reuses only its pane')
assert(text(second) == 'second streamed', 'rerun keeps other results')

-- Distinct ranges ending on the same line, including a whole-file run, stack without overlap.
inline.open(buf, 2, opts, { kind = 'send', range = { 0, 0, 2, 0 } })
inline.append(buf, 'range')
inline.set_state(buf, 'done')
inline.open(buf, 5, opts, { kind = 'run' })
inline.append(buf, 'file')
inline.set_state(buf, 'done')
inline.open(buf, 5, opts)
inline.append(buf, 'last line')
inline.set_state(buf, 'done')
settle()
assert(#panes() == 5, 'whole-file and last-line results coexist')
local same_row = {}
for _, w in ipairs(panes()) do
  local c = api.nvim_win_get_config(w)
  if c.bufpos[1] == 2 then same_row[#same_row + 1] = w end
end
assert(#same_row == 2)
table.sort(same_row, function(a, b) return api.nvim_win_get_position(a)[1] < api.nvim_win_get_position(b)[1] end)
assert(api.nvim_win_get_position(same_row[1])[1] + api.nvim_win_get_height(same_row[1]) + 2
  <= api.nvim_win_get_position(same_row[2])[1], 'same-line panes do not overlap')
inline.open(buf, 5, opts, { kind = 'run' })
inline.append(buf, 'file again')
inline.set_state(buf, 'done')
assert(#panes() == 5, 'repeated whole-file run updates its own pane')
api.nvim_buf_set_lines(buf, 0, 0, false, { 'inserted above' })
inline.open(buf, 1, opts)
inline.append(buf, 'tracked')
inline.set_state(buf, 'done')
assert(#panes() == 5 and text(first) == 'tracked', 'ranges follow edits above them')
api.nvim_win_set_cursor(win, { 2, 0 })
assert(inline.focus_here() and api.nvim_get_current_win() == first)
inline.clear()
assert(#panes() == 4 and not api.nvim_win_is_valid(first), 'clear removes only the chosen pane')
inline.append(buf, 'late')
assert(#panes() == 4 and text(second) == 'second streamed', 'clear active pane does not redirect late output')
inline.clear_all()
assert(#panes() == 0 and timers() == base_timers)

-- A relative width is shared by short/long results and follows the source window's usable width.
api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd('normal! ggzt')
local fixed = { width = 0.8, max_height = 12, col_offset = 4 }
inline.open(buf, 0, fixed)
inline.append(buf, 'short')
inline.set_state(buf, 'done')
first = panes()[1]
inline.open(buf, 2, fixed)
inline.append(buf, ('long '):rep(120))
inline.set_state(buf, 'done')
second = at(2)
settle()
local expected = math.floor((api.nvim_win_get_width(win) - 4) * 0.8)
assert(api.nvim_win_get_width(first) + 2 == expected and api.nvim_win_get_width(second) + 2 == expected,
  'short and long results have equal relative width')
assert(api.nvim_win_get_height(first) < api.nvim_win_get_height(second), 'height still fits content')
vim.cmd('vsplit')
api.nvim_win_set_width(win, 30)
settle()
expected = math.floor((api.nvim_win_get_width(win) - 4) * 0.8)
assert(api.nvim_win_get_width(first) + 2 == expected, 'relative width follows split resize')
vim.cmd('close')
api.nvim_set_current_win(win)
settle()
api.nvim_win_set_cursor(win, { 2, 0 })
assert(not inline.clear_here() and #panes() == 2, 'Backspace away from an anchor does not close another result')
api.nvim_win_set_cursor(win, { 1, 0 })
assert(inline.clear_here() and #panes() == 1 and text(second):find('long', 1, true), 'Backspace clears only the result below')
inline.clear_all()
inline.open(buf, 0, { width = 45 })
inline.append(buf, 'short')
assert(api.nvim_win_get_width(panes()[1]) + 2 == 45, 'fixed width in columns')
inline.clear_all()

-- bad options are rejected before any gap/float/log is created
local notified, notify = nil, vim.notify
vim.notify = function(m) notified = m end
local nbufs = #api.nvim_list_bufs()
for _, o in ipairs({ { max_height = 2 }, { max_width = 0 }, { max_lines = 0 }, { max_height = 5.5 }, { max_width = '72' },
  { col_offset = -1 }, { width = 0 }, { width = -1 }, { width = 1.5 }, { width = '80%' } }) do
  notified = nil
  inline.open(buf, 0, o)
  assert(notified and #panes() == 0 and gap(buf) == nil and #api.nvim_list_bufs() == nbufs, 'invalid ' .. vim.inspect(o))
  inline.append(buf, 'x\n')
end
vim.notify = notify
print('inline ok')
