# This file is a part of Julia. License is MIT: https://julialang.org/license

# Check Pkg's spawn-free archive path against the `7z` path it replaces.
#
# stdlib/patches/Pkg-spawn-free-gzip.patch teaches Pkg.PlatformEngines to
# decompress gzip in this process (zlib via Zlib_jll) instead of piping a
# tarball through the bundled `7z` executable, because iOS forbids fork/exec
# for third-party apps.  On iOS that path is the only one there is; everywhere
# else `JULIA_PKG_NO_SUBPROCESS=1` selects it, which is what this script uses
# to compare the two implementations on a machine that can run both.
#
# Run it with the build's own julia, e.g.
#
#     usr/bin/julia contrib/ios/test-gzip-inflate.jl
#
# It exercises the *installed* Pkg (`Base.IOS` and the patch state included),
# so a failure here is a failure of what the iOS sysimage would bake.

using Test, Pkg, Tar, SHA

const PE = Pkg.PlatformEngines

isdefined(PE, :GzipInflateStream) || error("""
    Pkg.PlatformEngines has no GzipInflateStream, so
    stdlib/patches/Pkg-spawn-free-gzip.patch was not applied to this build's
    Pkg checkout.  Run `make distclean-Pkg && make` (patches are applied at
    extraction time; see deps/tools/stdlib-external.mk).""")

println("Base.IOS              = ", Base.IOS)
println("PE.can_spawn_7z()     = ", PE.can_spawn_7z())
println("Zlib_jll.libz_path    = ", PE.Zlib_jll.libz_path)
println("sizeof(PE.ZStream)    = ", sizeof(PE.ZStream))
println()

nospawn(f) = withenv(f, "JULIA_PKG_NO_SUBPROCESS" => "1")

function make_tree(root; nfiles::Int, filesize::Int)
    mkpath(root)
    for i in 1:nfiles
        d = joinpath(root, "d$(i % 5)")
        mkpath(d)
        write(joinpath(d, "f$i.bin"), rand(UInt8, filesize))
    end
    mkpath(joinpath(root, "empty_dir"))
    write(joinpath(root, "text.txt"), repeat("the quick brown fox\n", 500))
    return root
end

relfiles(root) = sort!(String[relpath(joinpath(d, f), root)
                             for (d, _, fs) in walkdir(root) for f in fs])

function same_tree(a, b)
    fa, fb = relfiles(a), relfiles(b)
    fa == fb || return false
    all(read(joinpath(a, f)) == read(joinpath(b, f)) for f in fa)
end

# Raw decompressed bytes, via each of the two implementations.
inflate_bytes(tarball) = nospawn() do
    PE.open_gzip_tarball(read, tarball)
end
sevenzip_bytes(tarball) = open(read, `$(PE.exe7z()) x $tarball -so`)

@testset "Pkg spawn-free gzip" begin
    tmp = mktempdir()

    @testset "predicate" begin
        @test PE.can_spawn_7z() == !Base.IOS
        nospawn() do
            @test PE.can_spawn_7z() == false
        end
    end

    # `package` compresses, which only the 7z path can do — so it also gives
    # us archives that were definitely produced by the reference tool.
    small = make_tree(joinpath(tmp, "small"); nfiles = 4, filesize = 200)
    big   = make_tree(joinpath(tmp, "big");   nfiles = 40, filesize = 200_000)
    small_gz = joinpath(tmp, "small.tar.gz")
    big_gz   = joinpath(tmp, "big.tar.gz")

    PE.can_spawn_7z() || error("""
        This script compares the two implementations, so it has to run
        somewhere both work — a machine that can spawn `7z`.  On a device
        there is nothing to compare against.""")
    PE.package(small, small_gz)
    PE.package(big, big_gz)

    # The reference tree hashes, taken through the path being replaced.
    small_hash = Base.SHA1(open(Tar.tree_hash, `$(PE.exe7z()) x $small_gz -so`))
    big_hash   = Base.SHA1(open(Tar.tree_hash, `$(PE.exe7z()) x $big_gz -so`))

    @testset "decompressed bytes are identical" begin
        @test inflate_bytes(small_gz) == sevenzip_bytes(small_gz)
        @test inflate_bytes(big_gz) == sevenzip_bytes(big_gz)
        # The big fixture must actually cross the stream's buffer boundaries,
        # or the multi-fill path never runs.
        @test length(inflate_bytes(big_gz)) > 8 * PE.Z_BUFSIZE
    end

    @testset "unpack" begin
        for (name, gzf, src) in (("small", small_gz, small), ("big", big_gz, big))
            with7z = joinpath(tmp, "7z-$name")
            without = joinpath(tmp, "nospawn-$name")
            PE.unpack(gzf, with7z)
            nospawn() do
                PE.unpack(gzf, without)
            end
            @test same_tree(with7z, without)
            @test same_tree(with7z, src)
            @test !isempty(relfiles(without))
        end
    end

    @testset "verify_archive_tree_hash" begin
        wrong = Base.SHA1("0" ^ 40)
        for (gzf, hash) in ((small_gz, small_hash), (big_gz, big_hash))
            @test PE.verify_archive_tree_hash(gzf, hash)
            @test PE.verify_archive_tree_hash(gzf, wrong) == false
            nospawn() do
                @test PE.verify_archive_tree_hash(gzf, hash)
                # A wrong hash must be rejected on its merits, not because
                # decompression fell over.
                @test PE.verify_archive_tree_hash(gzf, wrong) == false
            end
        end
    end

    @testset "corrupt archive is reported, not crashed on" begin
        bad = joinpath(tmp, "bad.tar.gz")
        bytes = read(big_gz)
        bytes[5000:5200] .= 0xff
        write(bad, bytes)
        nospawn() do
            # Catches the failure and warns, exactly as the 7z path does when
            # 7z exits nonzero.  (The warning below is expected output.)
            @test PE.verify_archive_tree_hash(bad, big_hash) == false
            # unpack lets it through, as a domain error rather than a spawn one.
            @test_throws Exception PE.unpack(bad, joinpath(tmp, "bad-out"))
        end
    end

    @testset "truncated archive is an EOFError" begin
        cut = joinpath(tmp, "cut.tar.gz")
        write(cut, read(big_gz)[1:5000])
        nospawn() do
            @test_throws EOFError PE.open_gzip_tarball(read, cut)
        end
    end

    @testset "package refuses to compress without a subprocess" begin
        err = nospawn() do
            try
                PE.package(small, joinpath(tmp, "nope.tar.gz"))
                nothing
            catch e
                e
            end
        end
        @test err isa ErrorException
        @test occursin("cannot create compressed archives", err.msg)
        # Specifically NOT a spawn failure.
        @test !occursin("could not spawn", err.msg)
    end
end
