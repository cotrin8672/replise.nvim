# replise.nvim

A small REPL library for Neovim with one process per language and project root. It includes a Julia backend built on
[iron.nvim](https://github.com/Vigemus/iron.nvim) and an optional inline log pane. Other languages plug in as a small
callback table.

`require('replise')` and `setup({})` do nothing: no processes, autocmds, keymaps, commands or UI. Each of those is opt-in.

## Requirements

- Neovim 0.12+ (tested on 0.12.5, Windows).
- Julia backend: `julia` on `PATH` and [iron.nvim](https://github.com/Vigemus/iron.nvim) on `runtimepath`. replise.nvim
  only uses iron's low-level API and never calls `iron.setup()`, so it doesn't need your iron configuration.
- Optional: Revise.jl, installed by you in an environment on Julia's `LOAD_PATH`, if you use `revise = true`.

## Install

For example, with lazy.nvim:

```lua
{ 'cotrin8672/replise.nvim', dependencies = { 'Vigemus/iron.nvim' } }
```

To try a checkout without touching your config:

```sh
git clone https://github.com/Vigemus/iron.nvim .deps/iron.nvim   # inside the checkout; .deps/ is gitignored
nvim --clean --cmd "set rtp^=.,./.deps/iron.nvim" -c "lua require('replise').setup({ backends = { julia = require('replise.backends.julia').new() }, inline = { enabled = true }, commands = true })" path/to/project/file.jl
```

Then `:RepliseRun` (`RepliseRun!` to save first).

## Setup

```lua
local replise = require('replise')
replise.setup({
  backends = { julia = require('replise.backends.julia').new({ --[[ see Julia ]] }) }, -- key = filetype
  autostart = { 'julia' },                              -- start on FileType when a project root is found
  inline = { enabled = true, max_height = 8, max_width = 72 }, -- inline log pane
  commands = true,                                      -- :Replise* commands
})
-- or: replise.register_backend('julia', backend)          -- registration only
```

Every option left out is off.

### Sessions

- The project root is `vim.fs.root(source_buffer, backend.root_markers)`. It never comes from Neovim's cwd or from
  another active session, and replise.nvim never changes your cwd. With no root, nothing starts and every action reports
  `no project root`.
- One process per `filetype + root`. The terminal REPL and the inline pane share it.
- Only normal file buffers count (`buftype == ''`). Terminal, log and scratch buffers are ignored. When autostart is
  enabled, buffers that are already open are handled too.
- One request at a time. While a process starts up, one request waits as pending. Any other request is rejected with
  `busy`.
- `stop`/`restart` drop the session. Late output from the old process is ignored, and results always go to the buffer
  that made the request.

## API

| function | |
|---|---|
| `run_buffer({ bufnr?, save? })` | Run the current source file. Modified buffers are rejected unless `save = true` (then it writes first). |
| `send_line()` / `send_selection()` | Send buffer text, including unsaved edits. `send_selection` works from an `x` mapping and follows `'selection'`. |
| `interrupt(bufnr?)` | Interrupt the running request, or cancel a pending one. |
| `start(bufnr?)` / `stop(bufnr?)` / `restart(bufnr?)` | Explicit lifecycle. |
| `get_context(bufnr?)` | `{ bufnr, ft, root, key, backend }` or `nil, err`. |
| `get_session(bufnr?)` | `{ state = 'starting'|'idle'|'busy', root, ft, handle, current?, pending? }` or `nil`. |
| `get_repl_buffer(bufnr?)` | Terminal buffer of the session, for your own view. |
| `require('replise.inline').focus(bufnr?)` / `.focus_here()` / `.leave()` | Enter the nearest result, enter only a result directly below the cursor, or return to source. |
| `require('replise.inline').clear(bufnr?)` / `.clear_all()` | Remove the nearest result (or the one being browsed), or all results. Never stops the process. |

Request functions return a request id, or `nil, err` (also shown with `vim.notify`).

Commands (`commands = true`): `RepliseStart`, `RepliseStop`, `RepliseRestart`, `RepliseInterrupt`, `RepliseRun` (`RepliseRun!` saves
first), `:[range]RepliseSend`, `RepliseInlineClear`, `RepliseInlineClearAll`.

### Suggested bindings (not installed)

```lua
-- e.g. in after/ftplugin/julia.lua
local replise, inline = require('replise'), require('replise.inline')
local map = function(m, lhs, rhs) vim.keymap.set(m, lhs, rhs, { buffer = true }) end
map('n', '<leader>ee', replise.run_buffer)
map('n', '<leader>ei', replise.interrupt)
map('n', '<leader>er', replise.restart)
map('n', '<leader>is', replise.send_line)
map('x', '<leader>is', replise.send_selection)
map('n', '<leader>ii', inline.focus)
map('n', '<leader>ic', inline.clear)
map('n', '<leader>it', function() -- toggle your own view of the shared REPL (starts it if needed)
  local b = replise.get_repl_buffer() or (replise.start() and replise.get_repl_buffer())
  if not b then return end
  local w = vim.fn.bufwinid(b)
  if w ~= -1 then return vim.api.nvim_win_close(w, false) end
  local src = vim.api.nvim_get_current_win()
  vim.cmd('botright 12split')
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_set_current_win(src) -- stay in the source so the next toggle closes it
end)
```

## Inline pane

`inline = { enabled = true, max_height = 8, max_width = 72, max_lines = 1000, col_offset = 0 }`

- Each executed range keeps its own log pane. Running the same range again replaces just that result; other results stay.
  Ranges follow source edits with extmarks. Whole-file runs have a separate pane below the last line of the file; sends
  anchor their panes below the sent line or the last selected line. Blank virtual lines reserve space, with focusable
  bordered floats drawn over them, so source text is never changed or covered. Panes ending on the same line stack.
- `max_width`/`max_height` include the border. The width is the widest line, then the height is the wrapped height
  (correct for CJK). Both are clamped to the window. `max_lines` is the retained log and does not depend on the pane's
  size. `col_offset` moves the border right by that many columns from the source text's left edge (try `4`), clamped to
  leave room in narrow windows. Invalid values (`max_*` must be integers >= 3, `max_lines` >= 1, `col_offset` >= 0) are
  reported, and that run gets no pane; existing results and the process are unaffected.
- Streams in real time, including partial lines and `\r` progress. ANSI color (CSI) codes are stripped, even when split
  across chunks, and stderr is highlighted. The log buffer is read-only.
  While the pane's cursor is on the last line it follows new output; scroll up to browse, `G` to follow again.
- While starting or running, the title shows a spinner band, the state and the elapsed time, and a bright bar sweeps
  along the bottom border. Afterwards the title shows `done`, `error` or `interrupted`. One shared timer drives the
  animation; it pauses while no running pane is visible and stops when the last pane is cleared.
- The title adds `stale` once the source buffer has changed since the run (any edit, even one undone).
- The pane hides when its anchor scrolls off-screen or into a closed fold, or when its buffer isn't shown, and comes
  back on redraw.
- `focus()` chooses the nearest result and reveals its anchor if off-screen; `focus_here()` only enters a result directly
  below the cursor's line and returns `false` if there is none. From a log buffer, actions target that result. `leave()`
  returns to the source (`wincmd w`/`p` work too).
  Running a file never moves the source cursor. `clear()` removes only the view; later output from the same request does
  not reopen it, a new run does. Closing the float with `:q` does not clear it.
- The log buffer has `filetype=replise_inline`, so you can add viewer keys yourself:

```lua
vim.api.nvim_create_autocmd('FileType', { pattern = 'replise_inline', callback = function(a)
  vim.keymap.set('n', '<Esc>', require('replise.inline').leave, { buffer = a.buf })
end })
```

To enter a result with `Enter` from the line just above it, while keeping normal `Enter` elsewhere:

```lua
vim.keymap.set('n', '<CR>', function()
  if not require('replise.inline').focus_here() then
    vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'n', false)
  end
end, { buffer = true }) -- e.g. in after/ftplugin/julia.lua
```

## Julia

```lua
require('replise.backends.julia').new({
  root_markers = { 'Project.toml', 'JuliaProject.toml' }, -- default
  cmd = nil,          -- default: iron.nvim's julia command
  revise = false,     -- `using Revise` at startup; errors if Revise.jl is not installed (never installs it)
  instantiate = false,-- false | 'startup' | 'on_change' (see below)
  prescript = nil,    -- Julia code run once after startup
  before_run = nil,   -- Julia code run before every request
  files = {           -- per-file runner rules; keys relative to the root (or a function(path, root) -> rule)
    ['src/sim.jl'] = { run = 'Sim.main()', first_run = 'include_and_call' }, -- or 'include'
  },
})
```

- Startup runs `julia --project=<root> -i -L julia/bootstrap.jl` in `<root>` through iron.nvim, in a hidden terminal
  buffer. Your `startup.jl` is respected. Then it runs instantiate (if enabled), Revise (if enabled) and `prescript`,
  and waits for an acknowledgement evaluated by the interactive REPL before reporting ready. Readiness comes from a
  local control pipe, not from prompt scraping or delays. The plugin never calls `Pkg.add` or `Pkg.update`.
- `instantiate = 'startup'` calls `Pkg.instantiate()` on every new process. `'on_change'` does so at startup only when
  the configured command or Project/Manifest contents differ from the last successful startup; a stamp is stored under
  `stdpath('state')/replise.nvim`. It does not refresh packages during a running session. Use `'startup'` if you remove
  installed packages or change Julia depots. `false` (the default) skips it. Instantiation may create/update a Manifest.
- `cmd` is used as configured. On Windows with mise, pass the real executable path from `mise which julia`, e.g.
  `cmd = { 'C:/Users/you/AppData/Local/mise/installs/julia/latest/bin/julia.exe' }`. The mise shim can exit on console
  Ctrl-C; the plugin does not probe for or silently substitute another executable.
- `run_buffer` always runs the current file:
  - No rule: `include(file)` on every run.
  - With a rule, the first run includes the file. With Revise, the project files it actually includes are tracked. The first run
    then calls `run` (`include_and_call`, the default) or does nothing more (`include`).
  - Later runs call `Revise.revise()` (or re-include without Revise) and then evaluate `run`. `main()` is never guessed.
- `send_line`/`send_selection` evaluate the text in `Main`, with the source file's location so relative `include` and
  `@__DIR__` resolve from that file. They print the value REPL-style. A trailing `;` suppresses it.
- File and runner return values are displayed too. Keeping this process alive preserves compiled methods; initial JIT
  compilation still happens. Use `restart` for edits that Revise cannot apply.
- Output goes to both the terminal and the inline pane. `interrupt` cancels queued work or sends Ctrl-C to running work,
  and completion is acknowledged by Julia. The terminal
  (`get_repl_buffer()`) is the same process, so you can also type in it.

## Other languages

A backend is a plain table:

```lua
replise.register_backend('r', {
  root_markers = { 'DESCRIPTION', '.git' },
  start = function(ctx, emit) --[[ ctx = { bufnr, root, ft } ]] return handle end, -- handle.repl_bufnr optional
  run_buffer = function(handle, req) end, -- req = { id, kind = 'run', bufnr, path, row }
  send = function(handle, req) end,       -- req.code
  interrupt = function(handle) end,
  stop = function(handle) end,
})
```

`emit` takes:

- `{ kind = 'ready' }` once startup finishes. Nothing is dispatched before it.
- `{ kind = 'stdout'|'stderr', request_id?, chunk }` with raw chunks. Chunks without an id during startup go to the
  pending request's pane.
- `{ kind = 'running', request_id }`.
- Exactly one `{ kind = 'done', request_id }` or `{ kind = 'error', request_id, message }` per request, including after an
  interrupt.
- `{ kind = 'error', message }` for a startup failure.
- `{ kind = 'exit' }` when the process is gone.

## Tests

```sh
nvim -u NONE -i NONE --headless -l tests/core.lua   # fake backend, no processes
nvim -u NONE -i NONE --headless -l tests/inline.lua # real UI, headless
nvim -u NONE -i NONE --headless -l tests/julia.lua  # real Julia; needs iron.nvim cloned to .deps/iron.nvim
```

The Julia check also needs Revise.jl. On Windows with mise, set `$env:REPLISE_TEST_JULIA = (mise which julia)` in PowerShell
before running it so the interrupt checks use the actual executable.

## Limits

- Neovim 0.12+ only (developed and tested on 0.12.5, Windows).
- One request at a time per session; no queue beyond the one startup-pending request.
- Each inline pane belongs to one source window (the one that ran or focused it). Other windows on that buffer show only
  the blank gap. When the anchor scrolls into or out of view, repositioning happens after redraw, so the old placement can show
  for one frame.
- The busy indicator uses the title and bottom border (two rows), not a large block inside the log.
- Only CSI escape sequences are parsed. Other escapes (e.g. OSC) lose just their ESC byte.
- An anchor whose gap is only partly visible at the top of the window hides the pane.
- The inline UI is checked headless only; check focus and `wincmd w`/`p` on your own UI.
