# Inline output benchmark

Windows, Neovim 0.12.5 headless. Rails, full width, `max_height = 12`, `max_lines = 1000`. Each sample opens a fresh pane; the full pane starts with 999 completed lines and the empty tail line. Each burst delivers 640 lines, including a distinct final line to detect when the whole burst has landed.

| Initial pane | Input | Time before (`f2fba92`) | Time after | Output commits before → after | Buffer writes before → after |
| --- | --- | ---: | ---: | ---: | ---: |
| Empty | 640 chunks | 161.98 ms | 1.56 ms | 640 → 1 | 640 → 1 |
| Empty | 1 chunk | 1.77 ms | 1.17 ms | 1 → 1 | 1 → 1 |
| Full | 640 chunks | 713.41 ms | 1.65 ms | 640 → 1 | 1280 → 2 |
| Full | 1 chunk | 3.32 ms | 1.85 ms | 1 → 1 | 2 → 2 |

Times are medians of seven samples, from the first `append` until the last line is in the pane and Neovim has processed `:redraw`. Output commits count tail-follow passes in the visible pane, not physical terminal frames. Buffer writes count `on_lines` notifications; trimming the head is a separate write in the same commit. Julia and terminal rendering are outside this benchmark.

Run `nvim -u NONE -i NONE --headless -l tests/inline_bench.lua`. To measure an older revision, set `REPLISE_BENCH_RTP` to the path of a checkout of that revision and run the same script.

A separate headless smoke check with Julia 1.13.4 streamed 10,240 lines through the real backend. A movement key in the source and a scroll key in the pane were processed while the request was running. The pane kept its browsing position on the next update and retained the final output within the 1,000-line limit.
