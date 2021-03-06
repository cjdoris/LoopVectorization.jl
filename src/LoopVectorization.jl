module LoopVectorization

using VectorizationBase, SIMDPirates, SLEEFPirates, MacroTools, Parameters
using VectorizationBase: REGISTER_SIZE, REGISTER_COUNT, extract_data, num_vector_load_expr,
    mask, masktable, pick_vector_width_val, valmul, valrem, valmuladd, valadd, valsub, _MM
using SIMDPirates: VECTOR_SYMBOLS, evadd, evmul, vrange, reduced_add, reduced_prod, reduce_to_add, reduce_to_prod
using Base.Broadcast: Broadcasted, DefaultArrayStyle
using LinearAlgebra: Adjoint, Transpose
using MacroTools: prewalk, postwalk


export LowDimArray, stridedpointer, vectorizable,
    @avx, *ˡ, ∗,
    vmap, vmap!


include("costs.jl")
include("operations.jl")
include("graphs.jl")
include("broadcast.jl")
include("determinestrategy.jl")
include("lowering.jl")
include("constructors.jl")
include("map.jl")
include("_avx.jl")

export @_avx, _avx

# include("precompile.jl")
# _precompile_()

end # module
