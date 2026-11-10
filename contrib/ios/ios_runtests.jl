# This file is a part of Julia. License is MIT: https://julialang.org/license

# A single-process, Distributed-free driver for Julia's own test suite, meant
# to run inside an iOS process.  contrib/ios/build-xcframework.sh copies it
# next to test/runtests.jl in the staged runtime resources (IOS_STAGE_TESTS=1),
# so `@__DIR__` is the test tree and the relative includes below resolve.
#
# Why not just use test/runtests.jl:
#
#   * runtests.jl distributes work with Distributed.  With a single test name
#     it stays on worker 1 and never calls `addprocs`, so it does run — but
#     only because the selection happened to be one test.  Any selection that
#     expands to more than one test reaches `addprocs_with_testenv`, which
#     spawns `Base.julia_cmd()`.  There is no julia executable on iOS, and a
#     device forbids `fork`/`exec` outright.
#   * It also assumes a writable working directory (`buildkitetestjson.jl`
#     writes result files next to the test tree when CI is set), which the app
#     bundle is not on a device.
#
# So the two are complementary rather than redundant, and the workflow runs
# both: test/runtests.jl one test name at a time proves the staged tree is
# the tree upstream's own runner expects, and this driver runs a selection
# the way a device would have to — one process, no subprocesses, no forking.
#
# Selection is exactly `choosetests` (so "--skip", "-name", "--seed=", and
# the collection names all behave as documented in test/choosetests.jl), read
# from `Main.IOS_TEST_ARGS` when the embedder set it and from `ARGS`
# otherwise.
#
# Results are reported two ways: the per-test lines and the final summary go
# to stdout, and the failure count is left in `Main.IOS_TEST_FAILURES` for an
# embedder to read (an embedded process has no exit code to inspect until it
# exits, and calling `exit` from inside the runtime would skip the host's own
# teardown).

using Test, Random, Printf

include("choosetests.jl")

# Suppresses precompilation chatter; upstream's runtests.jl sets it too.
ENV["JULIA_TESTS"] = "true"

# Looking in "." confuses package resolution during the tests themselves.
filter!(x -> x != ".", LOAD_PATH)

const IOS_TEST_CHOICES = isdefined(Main, :IOS_TEST_ARGS) ?
    convert(Vector{String}, Main.IOS_TEST_ARGS) : copy(ARGS)

# Restore the process-global state a test is allowed to touch.  Upstream
# checks these and errors, because each test set owns a worker process that is
# thrown away afterwards.  Here every test shares one process, so leaked state
# would corrupt the *next* test rather than only its own — restore it, and
# report the leak without failing the run over it.
function ios_restore_env!(orig::Dict{String,String})
    for k in collect(keys(ENV))
        haskey(orig, k) || delete!(ENV, k)
    end
    for (k, v) in orig
        get(ENV, k, nothing) == v || (ENV[k] = v)
    end
    return
end

function ios_runtest(name::AbstractString, seed::UInt128)
    path = test_path(name) * ".jl"
    if !isfile(path)
        @printf("%-28s  MISSING (%s)\n", name, path)
        return (; ok = false, elapsed = 0.0)
    end

    # A fresh module per test, named as upstream names it, so a test that
    # inspects its own module name (several print `curmod_str`) sees the same
    # shape it would under runtests.jl.
    mod_name = Symbol("Test", rand(1:100), "Main_", replace(name, '/' => '_'))
    m = @eval(Main, module $mod_name end)
    @eval(m, using Test, Random)

    # Error hints accumulate across loads and change what `errorshow` tests
    # see; upstream clears them per test for the same reason.
    empty!(Base.Experimental._hint_handlers)

    depot_path = copy(Base.DEPOT_PATH)
    load_path = copy(Base.LOAD_PATH)
    env = Dict{String,String}(k => v for (k, v) in ENV)
    project = Base.active_project()

    t0 = time_ns()
    res = try
        @testset "$name" begin
            Random.seed!(seed)
            Base.include(m, path)
        end
    catch ex
        ex isa InterruptException && rethrow()
        # Keep the backtrace: when a test file fails to LOAD rather than to
        # pass, the stack is the only thing that says where.
        (ex, catch_backtrace())
    end
    elapsed = (time_ns() - t0) / 1e9

    leaked = String[]
    Base.DEPOT_PATH == depot_path || push!(leaked, "DEPOT_PATH")
    Base.LOAD_PATH == load_path || push!(leaked, "LOAD_PATH")
    Dict{String,String}(k => v for (k, v) in ENV) == env || push!(leaked, "ENV")
    Base.active_project() == project || push!(leaked, "active project")
    if !isempty(leaked)
        @warn "$name did not restore $(join(leaked, ", ")); restoring for the next test"
        copy!(Base.DEPOT_PATH, depot_path)
        copy!(Base.LOAD_PATH, load_path)
        ios_restore_env!(env)
        Base.set_active_project(project)
    end

    if res isa Test.AbstractTestSet
        @printf("%-28s  ok      %8.2fs\n", name, elapsed)
        return (; ok = true, elapsed)
    end
    # `@testset` throws once its body has finished and something did not pass;
    # anything else escaping is the test file failing to load at all.
    ex, bt = res
    if ex isa Test.TestSetException
        @printf("%-28s  FAIL    %8.2fs  (%d fail, %d error, %d broken of %d)\n",
                name, elapsed, ex.fail, ex.error, ex.broken,
                ex.pass + ex.fail + ex.error + ex.broken)
    else
        @printf("%-28s  ERROR   %8.2fs\n", name, elapsed)
        showerror(stdout, ex, bt)
        println(stdout)
    end
    return (; ok = false, elapsed)
end

const IOS_TEST_FAILURES = cd(@__DIR__) do
    (; tests, exit_on_error, seed) = choosetests(IOS_TEST_CHOICES)
    tests = unique(tests)

    # One process running every test set in sequence: a multithreaded BLAS
    # would be competing with nothing, and on a phone the extra threads are
    # pure memory.  Guarded because a sysimage baked without LinearAlgebra
    # would not have it.
    try
        @eval Main using LinearAlgebra
        @eval Main LinearAlgebra.BLAS.set_num_threads(1)
    catch ex
        @warn "could not pin BLAS to one thread" exception = ex
    end

    @printf("ios_runtests: %d test set(s), seed 0x%s\n", length(tests), string(seed, base = 16))
    @printf("ios_runtests: compile_enabled=%d (3 = min, interpreter fallback), check_bounds=%d\n",
            Base.JLOptions().compile_enabled, Base.JLOptions().check_bounds)
    flush(stdout)

    failures = String[]
    total = 0.0
    for t in tests
        r = ios_runtest(t, seed)
        total += r.elapsed
        flush(stdout)
        r.ok && continue
        push!(failures, t)
        exit_on_error && break
    end

    @printf("\nios_runtests: %d/%d test set(s) passed in %.1fs\n",
            length(tests) - length(failures), length(tests), total)
    isempty(failures) || println("ios_runtests: failed: ", join(failures, ", "))
    flush(stdout)

    length(failures)
end
