struct Product{A,B}
    a::A
    b::B
end
@inline function Base.size(p::Product)
    M = size(p.a, 1)
    (M, Base.tail(size(p.b))...)
end
@inline function Base.size(p::Product, i::Integer)
    i == 1 && return size(p.a, 1)
    size(p.b, i)
end
@inline Base.length(p::Product) = prod(size(p))
@inline Base.broadcastable(p::Product) = p
@inline Base.ndims(p::Type{Product{A,B}}) where {A,B} = ndims(B)

Base.Broadcast._broadcast_getindex_eltype(::Product{A,B}) where {T, A <: AbstractVecOrMat{T}, B <: AbstractVecOrMat{T}} = T
function Base.Broadcast._broadcast_getindex_eltype(p::Product)
    promote_type(
        Base.Broadcast._broadcast_getindex_eltype(p.a),
        Base.Broadcast._broadcast_getindex_eltype(p.b)
    )
end

# recursive_eltype(::Type{A}) where {T, A <: AbstractArray{T}} = T
# recursive_eltype(::Type{NTuple{N,T}}) where {N,T<:Union{Float32,Float64}} = T
# recursive_eltype(::Type{Float32}) = Float32
# recursive_eltype(::Type{Float64}) = Float64
# recursive_eltype(::Type{Tuple{T}}) where {T} = T
# recursive_eltype(::Type{Tuple{T1,T2}}) where {T1,T2} = promote_type(recursive_eltype(T1), recursive_eltype(T2))
# recursive_eltype(::Type{Tuple{T1,T2,T3}}) where {T1,T2,T3} = promote_type(recursive_eltype(T1), recursive_eltype(T2), recursive_eltype(T3))
# recursive_eltype(::Type{Tuple{T1,T2,T3,T4}}) where {T1,T2,T3,T4} = promote_type(recursive_eltype(T1), recursive_eltype(T2), recursive_eltype(T3), recursive_eltype(T4))
# recursive_eltype(::Type{Tuple{T1,T2,T3,T4,T5}}) where {T1,T2,T3,T4,T5} = promote_type(recursive_eltype(T1), recursive_eltype(T2), recursive_eltype(T3), recursive_eltype(T4), recursive_eltype(T5))

# function recursive_eltype(::Type{Broadcasted{S,A,F,ARGS}}) where {S,A,F,ARGS}
#     recursive_eltype(ARGS)
# end

@inline *ˡ(a::A, b::B) where {A,B} = Product{A,B}(a, b)
@inline Base.Broadcast.broadcasted(::typeof(*ˡ), a::A, b::B) where {A, B} = Product{A,B}(a, b)
const ∗ = *ˡ
# TODO: Need to make this handle A or B being (1 or 2)-D broadcast objects.
function add_broadcast!(
    ls::LoopSet, mC::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{Product{A,B}}, elementbytes::Int = 8
) where {A, B}
    K = gensym(:K)
    mA = gensym(:Aₘₖ)
    mB = gensym(:Bₖₙ)
    pushprepreamble!(ls, Expr(:(=), mA, Expr(:(.), bcname, QuoteNode(:a))))
    pushprepreamble!(ls, Expr(:(=), mB, Expr(:(.), bcname, QuoteNode(:b))))
    pushprepreamble!(ls, Expr(:(=), K, Expr(:call, :size, mB, 1)))

    k = gensym(:k)
    ls.loops[k] = Loop(k, 0, K)
    m = loopsyms[1];
    if ndims(B) == 1
        bloopsyms = Symbol[k]
        cloopsyms = Symbol[m]
        reductdeps = Symbol[m, k]
    elseif ndims(B) == 2
        n = loopsyms[2];
        bloopsyms = Symbol[k,n]
        cloopsyms = Symbol[m,n]
        reductdeps = Symbol[m, k, n]
    else
        throw("B must be a vector or matrix.")
    end
    # load A
    # loadA = add_load!(ls, gensym(:A), productref(A, mA, m, k), elementbytes)
    loadA = add_broadcast!(ls, gensym(:A), mA, Symbol[m,k], A, elementbytes)
    # load B
    loadB = add_broadcast!(ls, gensym(:B), mB, bloopsyms, B, elementbytes)
    # set Cₘₙ = 0
    # setC = add_constant!(ls, zero(promote_type(recursive_eltype(A), recursive_eltype(B))), cloopsyms, mC, elementbytes)
    setC = if elementbytes == 4
        add_constant!(ls, 0f0, cloopsyms, mC, Symbol(""), elementbytes)
    else#if elementbytes == 4
        add_constant!(ls, 0.0, cloopsyms, mC, Symbol(""), elementbytes)
    end       
    # compute Cₘₙ += Aₘₖ * Bₖₙ
    reductop = Operation(
        ls, mC, elementbytes, :vmuladd, compute, reductdeps, Symbol[k], Operation[loadA, loadB, setC]
    )
    pushop!(ls, reductop, mC)    
end

struct LowDimArray{D,T,N,A<:DenseArray{T,N}} <: DenseArray{T,N}
    data::A
end
@inline Base.pointer(A::LowDimArray) = pointer(A.data)
Base.size(A::LowDimArray) = Base.size(A.data)
@generated function VectorizationBase.stridedpointer(A::LowDimArray{D,T,N}) where {D,T,N}
    s = Expr(:tuple, [Expr(:ref, :strideA, n) for n ∈ 1+D[1]:N if D[n]]...)
    f = D[1] ? :PackedStridedPointer : :SparseStridedPointer
    Expr(:block, Expr(:meta,:inline), Expr(:(=), :strideA, Expr(:call, :strides, Expr(:(.), :A, QuoteNode(:data)))),
         Expr(:call, Expr(:(.), :VectorizationBase, QuoteNode(f)), Expr(:call, :pointer, Expr(:(.), :A, QuoteNode(:data))), s))
end
function LowDimArray{D}(data::A) where {D,T,N,A <: AbstractArray{T,N}}
    LowDimArray{D,T,N,A}(data)
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{<:LowDimArray{D,T,N}}, elementbytes::Int = 8
) where {D,T,N}
    fulldims = Union{Symbol,Int}[loopsyms[n] for n ∈ 1:N if D[n]]
    ref = ArrayReference(bcname, fulldims)
    add_simple_load!(ls, destname, ref, elementbytes )::Operation
end
function add_broadcast_adjoint_array!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol}, ::Type{A}, elementbytes::Int = 8
) where {T,N,A<:AbstractArray{T,N}}
    parent = gensym(:parent)
    pushprepreamble!(ls, Expr(:(=), parent, Expr(:call, :parent, bcname)))
    ref = ArrayReference(parent, Union{Symbol,Int}[loopsyms[N + 1 - n] for n ∈ 1:N])
    add_simple_load!( ls, destname, ref, elementbytes )::Operation    
end
function add_broadcast_adjoint_array!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol}, ::Type{<:AbstractVector}, elementbytes::Int = 8
)
    ref = ArrayReference(bcname, Union{Symbol,Int}[loopsyms[2]])
    add_simple_load!( ls, destname, ref, elementbytes )
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{Adjoint{T,A}}, elementbytes::Int = 8
) where {T, A <: AbstractArray{T}}
    add_broadcast_adjoint_array!( ls, destname, bcname, loopsyms, A, elementbytes )
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{Transpose{T,A}}, elementbytes::Int = 8
) where {T, A <: AbstractArray{T}}
    add_broadcast_adjoint_array!( ls, destname, bcname, loopsyms, A, elementbytes )
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{<:AbstractArray{T,N}}, elementbytes::Int = 8
) where {T,N}
    add_simple_load!(ls, destname, ArrayReference(bcname, @view(loopsyms[1:N])), elementbytes)
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol}, ::Type{T}, elementbytes::Int = 8
) where {T<:Union{Integer,Float32,Float64}}
    op = add_constant!(ls, destname, elementbytes) # or replace elementbytes with sizeof(T) ? u
    pushprepreamble!(ls, Expr(:(=), mangledvar(op), bcname))
    op
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{SubArray{T,N,A,S,B}}, elementbytes::Int = 8
) where {T,N,N2,A<:AbstractArray{T,N2},B,N3,S <: Tuple{Int,Vararg{Any,N3}}}
    inds = Vector{Union{Int,Symbol}}(undef, N+1)
    inds[1] = Symbol("##DISCONTIGUOUSSUBARRAY##")
    inds[2:end] .= @view(loopsyms[1:N])
    add_simple_load!(ls, destname, ArrayReference(bcname, inds), elementbytes)
end
function add_broadcast!(
    ls::LoopSet, destname::Symbol, bcname::Symbol, loopsyms::Vector{Symbol},
    ::Type{Broadcasted{S,Nothing,F,A}},
    elementbytes::Int = 8
) where {N,S<:Base.Broadcast.AbstractArrayStyle{N},F,A}
    instr = get(FUNCTIONSYMBOLS, F) do
        Instruction(bcname, :f)
    end
    args = A.parameters
    Nargs = length(args)
    bcargs = Expr(:(.), bcname, QuoteNode(:args))
    # this is the var name in the loop
    parents = Operation[]
    deps = Symbol[]
    reduceddeps = Symbol[]
    for (i,arg) ∈ enumerate(args)
        argname = gensym(:arg)
        pushprepreamble!(ls, Expr(:macrocall, Symbol("@inbounds"), LineNumberNode(@__LINE__,@__FILE__), Expr(:(=), argname, Expr(:ref, bcargs, i))))
        # dynamic dispatch
        parent = add_broadcast!(ls, gensym(:temp), argname, loopsyms, arg, elementbytes)::Operation
        pushparent!(parents, deps, reduceddeps, parent)
    end
    op = Operation(
        length(operations(ls)), destname, elementbytes, instr, compute, deps, reduceddeps, parents
    )
    pushop!(ls, op, destname)
end

# size of dest determines loops
# function vmaterialize!(
@generated function vmaterialize!(
    dest::AbstractArray{T,N}, bc::BC
) where {T <: Union{Float32,Float64}, N, BC <: Broadcasted}
    # we have an N dimensional loop.
    # need to construct the LoopSet
    loopsyms = [gensym(:n) for n ∈ 1:N]
    ls = LoopSet()
    sizes = Expr(:tuple)
    for (n,itersym) ∈ enumerate(loopsyms)
        Nsym = gensym(:N)
        ls.loops[itersym] = Loop(itersym, 0, Nsym)
        push!(sizes.args, Nsym)
    end
    pushprepreamble!(ls, Expr(:(=), sizes, Expr(:call, :size, :dest)))
    elementbytes = sizeof(T)
    add_broadcast!(ls, :dest, :bc, loopsyms, BC, elementbytes)
    add_simple_store!(ls, :dest, ArrayReference(:dest, loopsyms), elementbytes)
    resize!(ls.loop_order, num_loops(ls)) # num_loops may be greater than N, eg Product
    q = lower(ls)
    push!(q.args, :dest)
    pushfirst!(q.args, Expr(:meta,:inline))
    q
    # ls
end
@generated function vmaterialize!(
    dest′::Union{Adjoint{T,A},Transpose{T,A}}, bc::BC
) where {T <: Union{Float32,Float64}, N, A <: AbstractArray{T,N}, BC <: Broadcasted}
    # we have an N dimensional loop.
    # need to construct the LoopSet
    loopsyms = [gensym(:n) for n ∈ 1:N]
    ls = LoopSet()
    pushprepreamble!(ls, Expr(:(=), :dest, Expr(:call, :parent, :dest′)))
    sizes = Expr(:tuple)
    for (n,itersym) ∈ enumerate(loopsyms)
        Nsym = gensym(:N)
        ls.loops[itersym] = Loop(itersym, 0, Nsym)
        push!(sizes.args, Nsym)
    end
    pushprepreamble!(ls, Expr(:(=), sizes, Expr(:call, :size, :dest′)))
    elementbytes = sizeof(T)
    add_broadcast!(ls, :dest, :bc, loopsyms, BC, elementbytes)
    add_simple_store!(ls, :dest, ArrayReference(:dest, reverse(loopsyms)), elementbytes)
    resize!(ls.loop_order, num_loops(ls)) # num_loops may be greater than N, eg Product
    q = lower(ls)
    push!(q.args, :dest′)
    pushfirst!(q.args, Expr(:meta,:inline))
    q
    # ls
end

@inline function vmaterialize(bc::Broadcasted)
    ElType = Base.Broadcast.combine_eltypes(bc.f, bc.args)
    vmaterialize!(similar(bc, ElType), bc)
end
