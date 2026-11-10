# This file is a part of Julia. License is MIT: https://julialang.org/license

# Check the Accelerate-over-OpenBLAS forwarding that LinearAlgebra performs on
# iOS (see BLAS.forward_accelerate! in stdlib/LinearAlgebra/src/blas.jl).
#
# The layering is a performance choice.  Make.inc sets `FC := false` for iOS so
# OpenBLAS builds NOFORTRAN, but that selects its C_LAPACK sources rather than
# dropping LAPACK — the factorizations work on device without Accelerate too.
# What the layering decides is which library backs each symbol, since
# libblastrampoline resolves to the last one forwarded that has it.
#
# Run with the build's own julia on a Mac, where the same Accelerate is
# present and both libraries can be compared:
#
#     usr/bin/julia contrib/ios/test-accelerate.jl
#
# macOS 13.3+ is required for Accelerate's ILP64 interface (iOS 16.4+ on
# device, which is why Make.inc floors IOS_VERSION_MIN there).

using Test, LinearAlgebra, OpenBLAS_jll
using Base.Libc: Libdl

const B = LinearAlgebra.BLAS

isdefined(B, :forward_accelerate!) || error("""
    LinearAlgebra.BLAS has no forward_accelerate!, so this build predates the
    Accelerate support.  Rebuild after updating stdlib/LinearAlgebra.""")

# LinearAlgebra is baked into the sysimage (pkgimage.mk builds it with
# sysimg_builder), so editing stdlib/LinearAlgebra/src/blas.jl changes nothing
# at runtime until `make` re-bakes usr/lib/julia/sys.dylib.  Testing a stale
# copy against a current script produces failures that look like Accelerate
# problems and are not, so refuse to run rather than mislead.
isdefined(B, :ACCELERATE_ILP64_PROBE) &&
        startswith(B.ACCELERATE_ILP64_SUFFIX, '\x1a') || error("""
    The LinearAlgebra in this sysimage is older than
    stdlib/LinearAlgebra/src/blas.jl on disk: its Accelerate suffix is
    $(repr(isdefined(B, :ACCELERATE_ILP64_SUFFIX) ? B.ACCELERATE_ILP64_SUFFIX : nothing)),
    which does not begin with the \\x1a that tells libblastrampoline to strip
    the F77 trailing underscore.  Run `make` first.""")

B.report(stdout)
println()

const OPENBLAS = OpenBLAS_jll.libopenblas_path
backing(sym, iface = (Base.USE_BLAS64 ? :ilp64 : :lp64)) =
    (l = B.lbt_find_backing_library(sym, iface); l === nothing ? nothing : l.libname)

# Restore whatever the process started with, whatever this script does.
const ORIGINAL = [l.libname for l in B.get_config().loaded_libs]
restore!() = (B.lbt_forward(OPENBLAS; clear = true);
              Sys.isapple() && B.forward_accelerate!(); nothing)

# Which decorated names Accelerate actually exports.  libblastrampoline builds
# the name it looks up as <symbol><suffix>, stripping one trailing `_` from the
# symbol when the suffix starts with \x1a; both spellings are listed so the
# output says which one this OS uses rather than assuming.
function probe_accelerate_symbols(io = stdout)
    handle = Libdl.dlopen(B.ACCELERATE_PATH; throw_error = false)
    handle === nothing && return println(io, "Accelerate did not dlopen")
    println(io, "dlsym probe of ", B.ACCELERATE_PATH, ":")
    for stem in ("dgemm", "isamax", "dpotrf", "dgetrf")
        for name in (stem * "_", stem * "\$NEWLAPACK\$ILP64",
                     stem * "_\$NEWLAPACK\$ILP64", stem * "\$NEWLAPACK",
                     stem * "_\$NEWLAPACK")
            found = Libdl.dlsym(handle, name; throw_error = false) !== nothing
            println(io, "    ", rpad(name, 34), found ? "present" : "missing")
        end
    end
    println(io)
end

# What libblastrampoline made of it, once forwarded: a library can be accepted
# as ILP64 and still back nothing, so the forwarded-symbol list is the fact
# that matters, not the count.
function describe_accelerate(io = stdout)
    config = B.get_config()
    idx = findfirst(l -> l.libname == B.ACCELERATE_PATH, config.loaded_libs)
    idx === nothing && return println(io, "Accelerate is not in the LBT config")
    lib = config.loaded_libs[idx]
    println(io, "Accelerate: interface=", lib.interface, " suffix=", repr(lib.suffix),
                " f2c=", lib.f2c, " complex_retstyle=", lib.complex_retstyle)
    funcs = B.lbt_forwarded_funcs(config, lib)
    println(io, "  forwards ", length(funcs), " symbols",
                isempty(funcs) ? "" : "; first 20: " * join(first(funcs, 20), ", "))
    println(io)
end

@testset "Accelerate forwarding" begin

    @testset "environment" begin
        @test Base.USE_BLAS64          # BLAS.check() exits the process without ILP64
        @test !isempty(ORIGINAL)
        Sys.isapple() || @warn "not macOS: only the failure paths are exercised"
    end

    @testset "failure paths never disturb the configuration" begin
        B.lbt_forward(OPENBLAS; clear = true)
        before = backing("dgemm_")
        n, why = withenv(() -> B.forward_accelerate!(), "JULIA_NO_ACCELERATE" => "1")
        @test n == 0
        @test occursin("JULIA_NO_ACCELERATE", why)
        @test backing("dgemm_") == before
    end

    if Sys.isapple()
        probe_accelerate_symbols()

        # Independent of forward_accelerate!, and of whatever LinearAlgebra is
        # in the sysimage: does the libblastrampoline this build ships honour
        # the trimming marker at all?  It only compiles the `\x1a` handling
        # under -DSYMBOL_TRIMMING (src/Make.inc, `ifeq ($(OS), Darwin)`), and
        # without it the hint matches nothing, the search falls through to the
        # undecorated symbols, and Accelerate is forwarded as legacy LP64.
        @testset "libblastrampoline honours the trimming marker" begin
            B.lbt_forward(OPENBLAS; clear = true)
            n = B.lbt_forward(B.ACCELERATE_PATH; clear = false,
                              suffix_hint = B.ACCELERATE_ILP64_SUFFIX)
            config = B.get_config()
            idx = findfirst(l -> l.libname == B.ACCELERATE_PATH, config.loaded_libs)
            @test idx !== nothing
            if idx !== nothing
                lib = config.loaded_libs[idx]
                println("direct lbt_forward with ", repr(B.ACCELERATE_ILP64_SUFFIX),
                        ": n=", n, " interface=", lib.interface,
                        " suffix=", repr(lib.suffix))
                # An LP64 result here means the marker was ignored, i.e. this
                # libblastrampoline was built without SYMBOL_TRIMMING.
                @test lib.interface === :ilp64
            end
        end

        @testset "forwards, and takes precedence where it has the symbol" begin
            B.lbt_forward(OPENBLAS; clear = true)
            @test backing("dgemm_") == OPENBLAS
            n, why = B.forward_accelerate!()
            if why !== nothing
                error("""Accelerate did not forward: $why
                      On macOS < 13.3 the ILP64 interface does not exist; the
                      iOS floor of 16.4 in Make.inc is the same requirement.""")
            end
            println("forward_accelerate! reported ", n, " symbols")
            describe_accelerate()
            @test n > 0
            libs = [l.libname for l in B.get_config().loaded_libs]
            @test OPENBLAS in libs           # the base stays loaded, as a fallback
            @test B.ACCELERATE_PATH in libs
            @test backing("dgemm_") == B.ACCELERATE_PATH
        end

        # The point of layering rather than clearing: report what Accelerate
        # does NOT cover, so a gap is visible here instead of aborting the
        # process on a device.  Nothing may be UNBOUND either way.
        @testset "coverage, with OpenBLAS filling the gaps" begin
            # Accelerate shadows OpenBLAS for every symbol it exports, so which
            # LAPACK each one implements is the substance of that trade.
            B.lbt_forward(OPENBLAS; clear = true)
            openblas_lapack = LinearAlgebra.LAPACK.version()
            restore!()
            accelerate_lapack = LinearAlgebra.LAPACK.version()
            println("\nLAPACK version: OpenBLAS ", openblas_lapack,
                    " -> forwarded ", accelerate_lapack)

            covered, fellback = String[], String[]
            for sym in B.REPORT_SYMBOLS
                lib = backing(sym)
                @test lib !== nothing        # UNBOUND aborts on call
                push!(lib == B.ACCELERATE_PATH ? covered : fellback, sym)
            end
            println("\nAccelerate covers: ", join(covered, ", "))
            println("Falls back to OpenBLAS: ",
                    isempty(fellback) ? "(nothing)" : join(fellback, ", "))
            println("""
                Symbols in the fallback list stay on OpenBLAS on device too;
                the ones Accelerate covers are the ones it shadows.\n""")
            @test !isempty(covered)
        end

        @testset "numerics agree with OpenBLAS" begin
            rng_a = randn(120, 120)
            spd = rng_a * rng_a' + 120I
            b = randn(120)

            results = map((:openblas, :accelerate)) do which
                B.lbt_forward(OPENBLAS; clear = true)
                which === :accelerate && B.forward_accelerate!()
                (mul  = rng_a * rng_a,
                 chol = cholesky(spd).U,
                 lu   = rng_a \ b,
                 eig  = sort(eigvals(Symmetric(spd))),
                 sv   = svdvals(rng_a))
            end
            ob, acc = results
            @test acc.mul  ≈ ob.mul
            @test acc.chol ≈ ob.chol
            @test acc.lu   ≈ ob.lu
            @test acc.eig  ≈ ob.eig
            @test acc.sv   ≈ ob.sv
        end
    end

    restore!()
    @testset "configuration restored" begin
        @test backing("dgemm_") !== nothing
    end
end
