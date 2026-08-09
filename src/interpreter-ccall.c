// This file is a part of Julia. License is MIT: https://julialang.org/license

/*
  interpreted foreign calls

  `ccall` normally requires codegen: the compiler emits a call in the target's
  C calling convention directly.  Platforms that forbid mapping executable
  memory — iOS being the case this exists for — run everything outside the
  sysimage in the interpreter, where that is not available, and every `ccall`
  reached from interpreted code would otherwise fail outright.

  The call is made with libffi's `ffi_call`, which assembles the arguments and
  branches to the callee without writing any code: only `ffi_prep_closure_loc`
  needs executable memory, and that is the reverse direction (`@cfunction`,
  handing C a pointer to a Julia function), which stays unsupported.

  This is deliberately limited to iOS.  Elsewhere the compiler is available,
  `--compile=min` is a diagnostic mode rather than the only way to run, and
  changing what it accepts would alter behaviour on platforms that have no need
  of it.  Non-iOS builds keep the original error, and raise it before
  evaluating any argument, exactly as before.  libffi is only built for iOS
  (deps/libffi.mk), so nothing else links it either.

  What is supported follows from what libffi can describe: void, integers and
  floats up to 64 bits, pointers, boxed Julia values, and isbits structs and
  tuples of those — passed and returned by value, in registers or on the stack
  or through a hidden return pointer, whichever the platform ABI says.
  Variadic callees work through `ffi_prep_cif_var`.  What is left out is named
  where it is rejected: `Int128`/`UInt128` and `Float16`, for which libffi has
  no type, and `VecElement` vectors, likewise.
*/

#include "julia.h"
#include "julia_internal.h"

// Only iOS routes foreign calls through the interpreter; see the note above.
#if defined(_OS_IOS_)
#  define JL_CCALL_FFI 1
#  include <ffi.h>
#else
#  define JL_CCALL_FFI 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

int jl_foreigncall_interpretable(void) JL_NOTSAFEPOINT
{
    return JL_CCALL_FFI;
}


// Report why a call could not be made, naming the callee so the message points
// at something actionable.
static JL_NORETURN void ccall_unsupported(const char *what)
{
    jl_errorf("ccall: %s is not supported by the interpreter; "
              "this method must be compiled into the system image to call it", what);
}

#if JL_CCALL_FFI

// Signatures are described in fixed storage rather than allocated: a Julia
// exception unwinds straight past this frame, so anything malloc'd on the way
// in would leak.  These bounds are far above any real C signature, and the
// message says which one was hit.
#define JL_FFI_MAX_ARGS       64
#define JL_FFI_MAX_AGGREGATES 64
#define JL_FFI_MAX_ELEMENTS   512
#define JL_FFI_MAX_RETURN     512

// `ffi_type` nodes for the aggregates in one signature, plus the element
// pointer arrays they refer to.  Scalars use libffi's own static types and
// take no space here, so a signature without structs fills none of it.
typedef struct {
    ffi_type  types[JL_FFI_MAX_AGGREGATES];
    ffi_type *elements[JL_FFI_MAX_ELEMENTS];
    int ntypes;
    int nelements;
} jl_ffi_arena_t;

// Whether codegen would hand this type to C as a `jl_value_t*`.  The rule is
// `_julia_type_to_llvm` in cgutils.cpp: everything that is not a concrete
// immutable becomes `T_prjlvalue`, and `_julia_struct_to_llvm` adds the
// opaque-layout case (`String`) on top.  `Vector{T}`, `Array`, `Any`, `String`
// and every mutable struct land here — the pointer is the value, needing no
// conversion in either direction.
static int ccall_boxed(jl_value_t *ty) JL_NOTSAFEPOINT
{
    if (!jl_is_datatype(ty))
        return 1;                       // Union, UnionAll, abstract: always boxed
    jl_datatype_t *dt = (jl_datatype_t*)ty;
    if (!jl_is_immutable(ty) || !dt->isconcretetype)
        return 1;
    return dt->layout != NULL && jl_is_layout_opaque(dt->layout);
}

static ffi_type *ffi_type_for(jl_value_t *ty, jl_ffi_arena_t *arena);

// `Ref{T}` names no type C can see, and codegen substitutes before describing
// the signature (`jl_is_abstract_ref_type` in ccall.cpp): an argument becomes
// `Ptr{Cvoid}` — by then the `ccall` lowering has already run
// `unsafe_convert(Ref{T}, ...)`, so the value in hand is a `Ptr` — and a
// return becomes `Any`, a bare `jl_value_t*` with no check against `T`.
// Substituting here likewise is what keeps `Ref` behaving as it does compiled;
// describing `Ref{T}` itself would pass the address of the argument's box, and
// would reject a returned object for not being a `Ref`.
static jl_value_t *ccall_deref_return(jl_value_t *rt)
{
    if (!jl_is_abstract_ref_type(rt))
        return rt;
    jl_value_t *param = jl_tparam0(rt);
    if (param == (jl_value_t*)jl_any_type)
        jl_error("ccall: return type Ref{Any} is invalid. Use Any or Ptr{Any} instead.");
    if (jl_is_typevar(param))
        jl_error("ccall: return type Ref should have an element type, not Ref{<:T}");
    return (jl_value_t*)jl_any_type;
}

// Build the `ffi_type` for an isbits struct or tuple from Julia's own field
// list, then check that libffi lays it out the way Julia does.  They agree for
// every type `ccall` accepts — that is what makes such a type C-compatible in
// the first place — but a silent disagreement would misplace fields, so it is
// worth one comparison per aggregate rather than a comment asserting it.
static ffi_type *ffi_type_for_aggregate(jl_value_t *ty, jl_ffi_arena_t *arena)
{
    jl_datatype_t *dt = (jl_datatype_t*)ty;
    size_t nf = jl_datatype_nfields(dt);
    if (nf == 0 || jl_datatype_size(dt) == 0)
        ccall_unsupported("an empty struct, which C has no representation for");
    if (arena->ntypes >= JL_FFI_MAX_AGGREGATES)
        ccall_unsupported("a signature with more aggregate types than this build handles");
    if (arena->nelements + (int)nf + 1 > JL_FFI_MAX_ELEMENTS)
        ccall_unsupported("a signature with more aggregate fields than this build handles");

    ffi_type *out = &arena->types[arena->ntypes++];
    ffi_type **elems = &arena->elements[arena->nelements];
    arena->nelements += (int)nf + 1;

    for (size_t i = 0; i < nf; i++)
        elems[i] = ffi_type_for(jl_field_type(dt, i), arena);
    elems[nf] = NULL;

    out->size = 0;              // libffi fills these in
    out->alignment = 0;
    out->type = FFI_TYPE_STRUCT;
    out->elements = elems;

    if (ffi_get_struct_offsets(FFI_DEFAULT_ABI, out, NULL) != FFI_OK)
        ccall_unsupported("a struct libffi could not lay out");
    if (out->size != jl_datatype_size(dt) ||
            out->alignment != jl_datatype_align(dt))
        ccall_unsupported("a struct whose C layout differs from its Julia layout");
    return out;
}

// Map a Julia type to the way it travels to or from C.  Mirrors what codegen
// would emit for the same declaration.
static ffi_type *ffi_type_for(jl_value_t *ty, jl_ffi_arena_t *arena)
{
    if (ty == (jl_value_t*)jl_nothing_type || ty == (jl_value_t*)jl_void_type)
        return &ffi_type_void;
    if (jl_is_cpointer_type(ty))
        return &ffi_type_pointer;
    if (ccall_boxed(ty))
        return &ffi_type_pointer;
    if (ty == (jl_value_t*)jl_float32_type)
        return &ffi_type_float;
    if (ty == (jl_value_t*)jl_float64_type)
        return &ffi_type_double;
    if (jl_is_primitivetype(ty)) {
        // libffi has no half-precision type, and passing the bits as a 16-bit
        // integer would put them in the wrong register class on AArch64.
        if (ty == (jl_value_t*)jl_float16_type)
            ccall_unsupported("Float16, which libffi has no type for");
        int is_signed = jl_signed_type != NULL && jl_subtype(ty, (jl_value_t*)jl_signed_type);
        switch (jl_datatype_size(ty)) {
            case 1: return is_signed ? &ffi_type_sint8  : &ffi_type_uint8;
            case 2: return is_signed ? &ffi_type_sint16 : &ffi_type_uint16;
            case 4: return is_signed ? &ffi_type_sint32 : &ffi_type_uint32;
            case 8: return is_signed ? &ffi_type_sint64 : &ffi_type_uint64;
            default: break;
        }
        // 128-bit integers cannot be expressed: libffi has no type for them,
        // and a two-word struct is not equivalent — AArch64 gives a 16-byte
        // *integer* an even-aligned register pair, which libffi's aarch64 port
        // does not do for composites.
        ccall_unsupported("a 128-bit primitive type, which libffi has no type for");
    }
    if (jl_is_datatype(ty) && ((jl_datatype_t*)ty)->isconcretetype)
        return ffi_type_for_aggregate(ty, arena);
    ccall_unsupported("this type");
}

// Resolve the callee address from the first argument of the `:foreigncall`.
// Accepts a literal symbol, a (symbol, library) pair, or any expression that
// evaluates to a `Ptr`.
static void *ccall_resolve(jl_value_t *fexpr, jl_value_t *evaluated)
{
    const char *f_name = NULL;
    const char *f_lib = NULL;
    if (jl_is_quotenode(fexpr)) {
        jl_value_t *q = jl_quotenode_value(fexpr);
        if (jl_is_symbol(q))
            f_name = jl_symbol_name((jl_sym_t*)q);
    }
    if (f_name == NULL && evaluated != NULL) {
        if (jl_is_symbol(evaluated)) {
            f_name = jl_symbol_name((jl_sym_t*)evaluated);
        }
        else if (jl_is_cpointer(evaluated)) {
            return jl_unbox_voidpointer(evaluated);
        }
        else if (jl_is_tuple(evaluated) && jl_nfields(evaluated) == 2) {
            jl_value_t *n = jl_get_nth_field_noalloc(evaluated, 0);
            jl_value_t *l = jl_get_nth_field_noalloc(evaluated, 1);
            if (jl_is_symbol(n))
                f_name = jl_symbol_name((jl_sym_t*)n);
            else if (jl_is_string(n))
                f_name = jl_string_data(n);
            if (jl_is_symbol(l))
                f_lib = jl_symbol_name((jl_sym_t*)l);
            else if (jl_is_string(l))
                f_lib = jl_string_data(l);
        }
    }
    if (f_name == NULL)
        jl_error("ccall: first argument is not a symbol, (symbol, library) pair, or pointer");
    if (f_lib == NULL)
        f_lib = jl_dlfind(f_name);
    // Not `jl_load_and_lookup`: that caches the resolved library in a
    // caller-supplied slot, which codegen allocates per call site.  There is no
    // per-call-site storage here, and one shared slot would resolve every later
    // symbol in whichever library happened to be opened first.  `jl_get_library`
    // keeps its own table of open handles, so nothing is reopened per call.
    void *handle = jl_get_library(f_lib);
    void *ptr = NULL;
    jl_dlsym(handle, f_name, &ptr, 1);
    return ptr;
}

#endif // JL_CCALL_FFI

jl_value_t *jl_interpret_foreigncall(jl_value_t *fexpr, jl_value_t *evaluated_fexpr,
                                     jl_value_t *rt, jl_svec_t *at, size_t nreq,
                                     jl_sym_t *cc, jl_value_t **argv, size_t nargs)
{
#if !JL_CCALL_FFI
    (void)fexpr; (void)evaluated_fexpr; (void)rt; (void)at;
    (void)nreq; (void)cc; (void)argv; (void)nargs;
    ccall_unsupported("this build");
#else
    if (cc != jl_symbol("ccall"))
        ccall_unsupported("a non-C calling convention");
    // `at` is an expression until `jl_resolve_globals_in_ir` turns it into an
    // svec; being handed the expression means some path reached the interpreter
    // without that pass, which is a bug here rather than a limit of the call.
    if (!jl_is_svec((jl_value_t*)at))
        ccall_unsupported("an unresolved argument-type list (jl_resolve_globals_in_ir did not run on this code)");
    if (nargs != jl_svec_len(at))
        ccall_unsupported("an argument count that disagrees with the type list");
    if (nargs > JL_FFI_MAX_ARGS)
        ccall_unsupported("more arguments than this build handles");

    jl_ffi_arena_t arena;
    arena.ntypes = 0;
    arena.nelements = 0;

    rt = ccall_deref_return(rt);
    ffi_type *rtype = ffi_type_for(rt, &arena);
    if (rtype->size > JL_FFI_MAX_RETURN)
        ccall_unsupported("a return value larger than this build handles");

    ffi_type *atypes[JL_FFI_MAX_ARGS];
    void     *avalues[JL_FFI_MAX_ARGS];
    // Storage for the arguments that travel as a pointer to a Julia object;
    // `avalues` must point at the pointer, not at the object.
    void     *boxed[JL_FFI_MAX_ARGS];

    for (size_t i = 0; i < nargs; i++) {
        jl_value_t *ty = jl_svecref(at, i);
        jl_value_t *v = argv[i];
        if (ty == (jl_value_t*)jl_nothing_type || ty == (jl_value_t*)jl_void_type)
            ccall_unsupported("a void argument");
        if (!jl_isa(v, ty))
            jl_type_error("ccall argument", ty, v);
        if (jl_is_abstract_ref_type(ty)) {
            // The same check codegen emits here (`emit_cpointercheck`): after
            // `unsafe_convert` this must be a pointer, and passing anything
            // else would hand C the address of a Julia box.
            if (!jl_is_cpointer(v))
                jl_error("ccall: argument to Ref{T} is not a pointer");
            ty = (jl_value_t*)jl_voidpointer_type;
        }
        atypes[i] = ffi_type_for(ty, &arena);
        if (atypes[i] == &ffi_type_pointer && ccall_boxed(ty)) {
            boxed[i] = v;
            avalues[i] = &boxed[i];
        }
        else {
            // Every other class is stored inline in the box, and `argv` is
            // rooted by the caller for the duration of the call.
            avalues[i] = jl_data_ptr(v);
        }
    }

    // `nreq > 0` is exactly how codegen decides a call is variadic
    // (`isVa` in emit_ccall); it counts the arguments before the `...`.
    ffi_cif cif;
    ffi_status status = (nreq > 0)
        ? ffi_prep_cif_var(&cif, FFI_DEFAULT_ABI, (unsigned)nreq, (unsigned)nargs, rtype, atypes)
        : ffi_prep_cif(&cif, FFI_DEFAULT_ABI, (unsigned)nargs, rtype, atypes);
    if (status != FFI_OK)
        ccall_unsupported("a signature libffi rejected");

    void *fptr = ccall_resolve(fexpr, evaluated_fexpr);
    if (fptr == NULL)
        jl_error("ccall: null function pointer");

    // libffi widens an integer return to `ffi_arg`, so the buffer is at least
    // that big however narrow the declared type is.  `long double` in the union
    // is there for its alignment, which is the strictest any member needs.
    union {
        ffi_arg     i;
        double      d;
        long double ld;
        void       *p;
        char        bytes[JL_FFI_MAX_RETURN];
    } rbuf;
    ffi_call(&cif, FFI_FN(fptr), &rbuf, avalues);

    if (rtype == &ffi_type_void)
        return jl_nothing;
    if (rtype == &ffi_type_pointer && ccall_boxed(rt)) {
        // The callee returned the object itself; nothing is converted or
        // copied.  Root it before `jl_isa`, which may allocate — until then
        // the only reference is in this frame, invisible to the GC.
        jl_value_t *v = (jl_value_t*)rbuf.p;
        if (v == NULL)
            jl_error("ccall: returned NULL where a Julia value was declared; "
                     "declare the return type as a `Ptr` if the callee can return NULL");
        JL_GC_PUSH1(&v);
        // Codegen does not check this, but a device has no debugger and a
        // mis-declared return type otherwise corrupts the heap silently.
        if (!jl_isa(v, rt))
            jl_type_error("ccall return value", rt, v);
        JL_GC_POP();
        return v;
    }
    // `jl_new_bits` copies exactly `jl_datatype_size(rt)` bytes from the start
    // of the buffer, which on these little-endian targets is where a value
    // narrower than `ffi_arg` sits.
    return jl_new_bits(rt, &rbuf);
#endif
}

#ifdef __cplusplus
}
#endif
