# This file is a part of Julia. License is MIT: https://julialang.org/license

## dummy stub for https://github.com/JuliaBinaryWrappers/MozillaCACerts_jll.jl

baremodule MozillaCACerts_jll
using Base
Base.Experimental.@compiler_options compile=min optimize=0 infer=false

const PATH_list = String[]
const LIBPATH_list = String[]

# These get calculated in __init__()
const PATH = Ref("")
const LIBPATH = Ref("")
global artifact_dir::String = ""
global cacert::String = ""

function __init__()
    # These are `const` arrays serialized into the sysimage, and `__init__` has
    # already run once during the image build — so repopulate them from scratch
    # instead of appending the build machine's paths again at every startup.
    empty!(PATH_list)
    empty!(LIBPATH_list)
    global artifact_dir = dirname(Sys.BINDIR)
    global cacert = normpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "cert.pem")
end

# JLLWrappers API compatibility shims.  Note that not all of these will really make sense.
# For instance, `find_artifact_dir()` won't actually be the artifact directory, because
# there isn't one.  It instead returns the overall Julia prefix.
is_available() = true
find_artifact_dir() = artifact_dir
dev_jll() = error("stdlib JLLs cannot be dev'ed")
best_wrapper = nothing

end # module
