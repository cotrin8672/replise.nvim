# replise.nvim helper, loaded by `julia -i -L bootstrap.jl` (after the user's startup.jl).
# Control channel: one local pipe to Neovim.
#   nvim -> julia: "<sid> <kind> <first> <#path> <#code>\n" path code   (kind = run|send|cancel)
#   julia -> nvim: "<event> <sid> <base64 data>\n"
# The REPL itself only ever sees `Replise.run(<sid>)`, so Ctrl-C and the terminal view behave normally.
module Replise

using Sockets: connect
using Base64: base64encode

popenv(k) = (v = get(ENV, k, ""); delete!(ENV, k); v)
const REVISE = popenv("REPLISE_REVISE") == "1"
const BEFORE_RUN = popenv("REPLISE_BEFORE_RUN")
const ROOT = rstrip(normpath(popenv("REPLISE_ROOT")), ['/', '\\']) * Base.Filesystem.path_separator  # dir boundary
normcase(p) = Sys.iswindows() ? lowercase(p) : p

const sock = Ref{IO}(devnull)
const cond = Threads.Condition()
const reqs = Dict{Int,Any}()      # sid => (kind, first, path, code) or :cancel
const loaded = Set{String}()      # files whose first run succeeded (per process)
const begun = Ref(0)              # highest started sid (sids grow, one request at a time): later cancel is a no-op
const busy = Ref{Any}(nothing)    # task running the current request

# Ctrl-C (SIGINT) is thrown into whichever task runs on the main thread, possibly a helper task here.
# Helpers hand it to the request task instead of dying (a dead pump would stall the request forever).
function forward_interrupts(f)
    while true
        try
            return f()
        catch e
            e isa InterruptException || rethrow()
            t = busy[]
            t === nothing || t === current_task() || @async Base.throwto(t, e)
        end
    end
end

emit(ev, sid=0, data="") =
    try write(sock[], string(ev, ' ', sid, ' ', base64encode(data), '\n')) catch end

function reader(s)
    while !eof(s)
        h = split(readline(s))
        length(h) == 5 || continue
        sid = parse(Int, h[1])
        path = String(read(s, parse(Int, h[4])))
        code = String(read(s, parse(Int, h[5])))
        @lock cond begin
            if h[2] != "cancel"
                reqs[sid] = (h[2], h[3], path, code)
            elseif sid > begun[]      # not started yet: acknowledge here, run(sid) will skip it
                reqs[sid] = :cancel
                emit("error", sid, "interrupted")
            end                       # started: nvim's Ctrl-C interrupts it after observing `running`
            notify(cond)
        end
    end
end

# Number of leading bytes of `b` that end on a complete UTF-8 sequence.
function utf8_cut(b)
    n = length(b)
    for i in n:-1:max(1, n - 2)
        c = b[i]
        c & 0xc0 == 0x80 && continue
        need = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1
        return n - i + 1 >= need ? n : i - 1
    end
    return n
end

# Copy the pipe to the real terminal stream and to nvim, chunk by chunk (partial lines / \r kept).
pump(p, term, ev, sid) = @async begin
    held = UInt8[]
    try
        forward_interrupts() do
            while !eof(p)
                data = readavailable(p)
                write(term, data)             # terminal gets every byte exactly once, immediately
                b = append!(held, data)
                k = utf8_cut(b)
                emit(ev, sid, view(b, 1:k))
                held = b[k+1:end]
            end
        end
    catch
    end
    isempty(held) || emit(ev, sid, held)
end

eval_main(code, name) =
    task_local_storage(() -> include_string(Main, code, name), :SOURCE_PATH, abspath(name))

# REPL-style value display; `;` at the end of an explicit expression suppresses it.
function show_value(v, code="")
    (v === nothing || endswith(rstrip(code), ';')) && return
    show(IOContext(stdout, :limit => true), MIME"text/plain"(), v)
    println()
end

function track_include(path)
    files = Tuple{Module,String}[]
    cb = (m, f) -> push!(files, (m, f))
    push!(Base.include_callbacks, cb)
    v = try
        Base.include(Main, path)
    finally
        filter!(x -> x !== cb, Base.include_callbacks)
    end
    for (m, f) in files   # only project files; Revise already tracks packages loaded with using/import
        startswith(normcase(f), normcase(ROOT)) && Base.invokelatest(Main.Revise.track, m, f)
    end
    return v
end

# Revise logs (does not throw) parse errors, and its REPL hook may already have revised before us.
function revise()
    R = Main.Revise
    Base.invokelatest(R.revise; throw=true)
    isempty(R.queue_errors) || error("Revise could not apply changes:
" *
        join((string(f, ": ", sprint(showerror, e)) for ((_, f), (e, _)) in R.queue_errors), "
"))
end

function execute(kind, first, path, code)
    isempty(BEFORE_RUN) || eval_main(BEFORE_RUN, "before_run")
    if kind == "send"
        show_value(eval_main(code, isempty(path) ? "replise.nvim" : path), code)
    elseif isempty(code)                      # no runner rule: plain script, include every time
        show_value(Base.include(Main, path))
    elseif path in loaded                     # later runs: revise (or re-include), then call
        REVISE ? revise() : Base.include(Main, path)
        show_value(eval_main(code, "runner"), code)
    else                                      # first run: load (tracking actual project includes)
        v = REVISE ? track_include(path) : Base.include(Main, path)
        push!(loaded, path)
        first == "call" ? show_value(eval_main(code, "runner"), code) : show_value(v)
    end
    return nothing
end

# Run `f` with stdout/stderr streamed to nvim as `sid` chunks. Once `started[]`, ends with exactly
# one terminal event: done or error (sid 0 = bootstrap: only errors; `ready` comes from the REPL itself).
function capture(f, sid, started=Ref(true))
    term_out, term_err = stdout, stderr
    pipes, tasks = (), ()
    failure = nothing
    try
        pipes = (redirect_stdout(), redirect_stderr())
        tasks = (pump(pipes[1], term_out, "stdout", sid), pump(pipes[2], term_err, "stderr", sid))
        f()
    catch e
        failure = (e isa LoadError ? e.error : e) isa InterruptException ? "interrupted" : sprint(showerror, e)
        if started[]
            st = stacktrace(catch_backtrace())
            k = something(findfirst(sf -> String(sf.file) == @__FILE__, st), length(st) + 1)
            Base.invokelatest(Base.display_error, stderr, e, st[1:k-1])  # user frames only
        end
    finally
        Base.disable_sigint() do
            redirect_stdout(term_out)
            redirect_stderr(term_err)
            foreach(p -> close(p.in), pipes)
            foreach(wait, tasks)
            started[] || return
            failure === nothing ? (sid == 0 || emit("done", sid)) : emit("error", sid, failure)
        end
    end
    return nothing
end

function run(sid::Int)
    started = Ref(false)
    capture(sid, started) do
        req = @lock cond begin
            while !haskey(reqs, sid)
                wait(cond)            # Ctrl-C here: not started; nvim's cancel resolves the request
            end
            r = pop!(reqs, sid)
            r === :cancel || (started[] = true; begun[] = sid)
            r
        end
        started[] || return
        busy[] = current_task()
        emit("running", sid)
        execute(req...)
    end
    busy[] = nothing
    return nothing
end

# nvim types `Replise.ready()` once connected; the REPL evaluating it proves it is reading input
# (no prompt scraping, no sleeps; a Ctrl-C can no longer land in Julia's own startup).
const init_ok = Ref(false)
ready() = (init_ok[] && emit("ready"); nothing)

function init()
    sock[] = connect(popenv("REPLISE_PIPE"))
    errormonitor(@async forward_interrupts(() -> reader(sock[])))
    instantiate = popenv("REPLISE_INSTANTIATE") == "1"   # nvim decides startup/on_change
    pre = popenv("REPLISE_PRESCRIPT")
    capture(0) do
        if instantiate && isfile(something(Base.active_project(), ""))
            Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
            Base.invokelatest(Pkg.instantiate)
        end
        if REVISE
            Base.find_package("Revise") === nothing && error(
                "revise=true but Revise.jl is not installed in any environment on LOAD_PATH " *
                "($(join(LOAD_PATH, ", "))). Install it yourself, e.g. " *
                "`julia -e 'using Pkg; Pkg.add(\"Revise\")'`, or set revise=false.")
            Core.eval(Main, :(using Revise))
        end
        isempty(pre) || Base.invokelatest(eval_main, pre, "prescript")
        init_ok[] = true
    end
end

end # module

Replise.init()
