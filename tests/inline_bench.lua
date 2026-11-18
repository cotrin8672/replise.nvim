-- nvim -u NONE -i NONE --headless -l tests/inline_bench.lua
-- To benchmark another revision, point REPLISE_BENCH_RTP at its checkout.
vim.opt.rtp:prepend(vim.env.REPLISE_BENCH_RTP or vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local api, uv = vim.api, vim.uv
local inline = require('replise.inline')
local source = api.nvim_get_current_buf()
local line = 'julia stdout line 12345678\n'
local last = 'final stdout line\n'
vim.o.columns, vim.o.lines = 80, 24

local function run(prefill, split)
  inline.open(source, 0, { style = 'rails', width = 'full', max_height = 12, max_lines = 1000 })
  inline.set_state(source, 'done') -- exclude spinner updates
  local pane = api.nvim_list_wins()[2]
  local log = api.nvim_win_get_buf(pane)
  if prefill then inline.append(source, line:rep(999), 'stdout') end
  assert(vim.wait(1000, function() return api.nvim_buf_line_count(log) == (prefill and 1000 or 1) end, 1))
  vim.cmd('redraw')

  local writes, commits = 0, 0
  api.nvim_buf_attach(log, false, { on_lines = function() writes = writes + 1 end })
  local set_cursor = api.nvim_win_set_cursor
  api.nvim_win_set_cursor = function(w, pos)
    if w == pane then commits = commits + 1 end -- one tail-follow per visible output commit
    return set_cursor(w, pos)
  end
  local function rendered()
    local n = api.nvim_buf_line_count(log)
    return api.nvim_buf_get_lines(log, n - 2, n - 1, false)[1] == last:sub(1, -2)
  end
  local start = uv.hrtime()
  if split then
    for _ = 1, 639 do inline.append(source, line, 'stdout') end
    inline.append(source, last, 'stdout')
  else
    inline.append(source, line:rep(639) .. last, 'stdout')
  end
  assert(vim.wait(1000, rendered, 1), 'last output not applied')
  vim.cmd('redraw')
  local ms = (uv.hrtime() - start) / 1e6
  api.nvim_win_set_cursor = set_cursor
  inline.clear_all()
  return ms, commits, writes
end

for _, prefill in ipairs({ false, true }) do
  for _, split in ipairs({ true, false }) do
    local times, commits, writes = {}
    for i = 1, 7 do times[i], commits, writes = run(prefill, split) end
    table.sort(times)
    io.stdout:write(('%s, %s: %.2f ms (median), %d output commits, %d buffer writes\n')
      :format(prefill and 'full' or 'empty', split and 'split' or 'combined', times[4], commits, writes))
  end
end
