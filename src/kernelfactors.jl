module KernelFactors

using StaticArrays, OffsetArrays
using ..ImageFiltering: centered, dummyind
import ..ImageFiltering: _reshape, _vec, nextendeddims
using Base: tail, Indices, @pure, checkbounds_indices, throw_boundserror

using Compat

abstract type IIRFilter{T} end

Base.eltype(kernel::IIRFilter{T}) where {T} = T

"""
    ReshapedOneD{N,Npre}(data)

Return an object of dimensionality `N`, where `data` must have
dimensionality 1. The indices are `0:0` for the first `Npre`
dimensions, have the indices of `data` for dimension `Npre+1`, and are
`0:0` for the remaining dimensions.

`data` must support `eltype` and `ndims`, but does not have to be an
AbstractArray.

ReshapedOneDs allow one to specify a "filtering dimension" for a
1-dimensional filter.
"""
struct ReshapedOneD{T,N,Npre,V}  # not <: AbstractArray{T,N} (more general, incl. IIR)
    data::V

    function ReshapedOneD{T,N,Npre,V}(data::V) where {T,N,Npre,V}
        ndims(V) == 1 || throw(DimensionMismatch("must be one dimensional, got $(ndims(V))"))
        new{T,N,Npre,V}(data)
    end
end

ReshapedOneD{N,Npre}(data::V) where {N,Npre,V} = ReshapedOneD{eltype(data),N,Npre,V}(data)
# Convenient loop constructor that uses dummy NTuple{N,Bool} to keep
# track of dimensions for type-stability
@inline function ReshapedOneD(pre::NTuple{Npre,Bool}, data, post::NTuple{Npost,Bool}) where {Npre,Npost}
    total = (pre..., true, post...)
    _reshapedvector(total, pre, data)
end
_reshapedvector(::NTuple{N,Bool}, ::NTuple{Npre,Bool}, data) where {N,Npre} = ReshapedOneD{eltype(data),N,Npre,typeof(data)}(data)

# Give ReshapedOneD many of the characteristics of AbstractArray
Base.eltype(A::ReshapedOneD{T}) where {T} = T
Base.ndims(A::ReshapedOneD{_,N}) where {_,N} = N
Base.isempty(A::ReshapedOneD) = isempty(A.data)

@inline Base.indices(A::ReshapedOneD{_,N,Npre}) where {_,N,Npre} = Base.fill_to_length((Base.ntuple(d->0:0, Val{Npre})..., UnitRange(Base.indices1(A.data))), 0:0, Val{N})

Base.start(A::ReshapedOneD) = start(A.data)
Base.next(A::ReshapedOneD, state) = next(A.data, state)
Base.done(A::ReshapedOneD, state) = done(A.data, state)

@inline function Base.getindex(A::ReshapedOneD, i::Int)
    @boundscheck checkbounds(A.data, i)
    @inbounds ret = A.data[i]
    ret
end
@inline function Base.getindex(A::ReshapedOneD{T,N,Npre}, I::Vararg{Int,N}) where {T,N,Npre}
    @boundscheck checkbounds_indices(Bool, indices(A), I) || throw_boundserror(A, I)
    @inbounds ret = A.data[I[Npre+1]]
    ret
end
@inline function Base.getindex(A::ReshapedOneD, I::Union{CartesianIndex,Int}...)
    A[Base.IteratorsMD.flatten(I)...]
end

Base.convert(::Type{AA}, A::ReshapedOneD) where {AA<:AbstractArray} = convert(AA, reshape(A.data, indices(A)))

import Base: ==
==(A::ReshapedOneD, B::ReshapedOneD) = convert(AbstractArray, A) == convert(AbstractArray, B)
==(A::ReshapedOneD, B::AbstractArray) = convert(AbstractArray, A) == B
==(A::AbstractArray, B::ReshapedOneD) = A == convert(AbstractArray, B)

import Base: +, -, *, /
for op in (:+, :-, :*, :/)
    @eval begin
        ($op)(A::ReshapedOneD, B::ReshapedOneD) =
            broadcast($op, convert(AbstractArray, A), convert(AbstractArray, B))
        @inline ($op)(As::ReshapedOneD...) =
            broadcast($op, map(A->convert(AbstractArray, A), As)...)
    end
end
Base.Broadcast.containertype(::Type{T}) where {T<:ReshapedOneD} = Array

_reshape(A::ReshapedOneD{T,N}, ::Type{Val{N}}) where {T,N} = A
_vec(A::ReshapedOneD) = A.data
Base.vec(A::ReshapedOneD) = A.data  # is this OK? (note indices won't nec. start with 1)
nextendeddims(a::ReshapedOneD) = 1

"""
    iterdims(inds, v::ReshapedOneD{T,N,Npre}) -> Rpre, ind, Rpost

Return a pair `Rpre`, `Rpost` of CartesianRanges that correspond to
pre- and post- dimensions for iterating over an array with indices
`inds`. `Rpre` corresponds to the `Npre` "pre" dimensions, and `Rpost`
to the trailing dimensions (not including the vector object wrapped in
`v`).  Concretely,

    Rpre  = CartesianRange(inds[1:Npre])
    ind   = inds[Npre+1]
    Rpost = CartesianRange(inds[Npre+2:end])

although the implementation differs for reason of type-stability.
"""
function iterdims(inds::Indices{N}, v::ReshapedOneD{_,N,Npre}) where {_,N,Npre}
    indspre, ind, indspost = _iterdims((), (), inds, v)
    CartesianRange(indspre), ind, CartesianRange(indspost)
end
@inline function _iterdims(indspre, ::Tuple{}, inds, v)
    _iterdims((indspre..., inds[1]), (), tail(inds), v)  # consume inds and push to indspre
end
@inline function _iterdims(indspre::NTuple{Npre}, ::Tuple{}, inds, v::ReshapedOneD{_,N,Npre}) where {_,N,Npre}
    indspre, inds[1], tail(inds)   # return the "central" and trailing dimensions
end

function indexsplit(I::CartesianIndex{N}, v::ReshapedOneD{_,N}) where {_,N}
    ipre, i, ipost = _iterdims((), (), I.I, v)
    CartesianIndex(ipre), i, CartesianIndex(ipost)
end

#### FIR filters

## gradients

"""
    kern1, kern2 = sobel()

Factored Sobel filters for dimensions 1 and 2 of a two-dimensional
image. Each is a 2-tuple of one-dimensional filters.
"""
function sobel()
    f1 = centered(SVector( 1.0, 2.0, 1.0)/4)
    f2 = centered(SVector(-1.0, 0.0, 1.0)/2)
    return kernelfactors((f2, f1)), kernelfactors((f1, f2))
end

"""
    kern = sobel(extended::NTuple{N,Bool}, d)

Return a factored Sobel filter for computing the gradient in `N` dimensions along axis `d`.
If `extended[dim]` is false, `kern` will have size 1 along that dimension.
"""
function sobel(extended::NTuple{N,Bool}, d) where N
    gradfactors(extended, d, [-1, 0, 1]/2, [1, 2, 1]/4)
end

"`kern1, kern2 = prewitt()` returns factored Prewitt filters for dimensions 1 and 2 of your image"
function prewitt()
    f1 = centered(SVector( 1.0, 1.0, 1.0)/3)
    f2 = centered(SVector(-1.0, 0.0, 1.0)/2)
    return kernelfactors((f2, f1)), kernelfactors((f1, f2))
end

"""
    kern = prewitt(extended::NTuple{N,Bool}, d)

Return a factored Prewitt filter for computing the gradient in `N` dimensions along axis `d`.
If `extended[dim]` is false, `kern` will have size 1 along that dimension.
"""
function prewitt(extended::NTuple{N,Bool}, d) where N
    gradfactors(extended, d, [-1, 0, 1]/2, [1, 1, 1]/3)
end

# Consistent Gradient Operators
# Ando Shigeru
# IEEE Trans. Pat. Anal. Mach. Int., vol. 22 no 3, March 2000
#
# TODO: These coefficients were taken from the paper. It would be nice
#       to resolve the optimization problem and use higher precision
#       versions, which might allow better separable approximations of
#       ando4 and ando5.

"""
`kern1, kern2 = ando3()` returns optimal 3x3 gradient filters for dimensions 1 and 2 of your image, as defined in
Ando Shigeru, IEEE Trans. Pat. Anal. Mach. Int., vol. 22 no 3, March 2000.

See also: [`Kernel.ando3`](@ref), [`KernelFactors.ando4`](@ref), [`KernelFactors.ando5`](@ref).
"""
function ando3()
    f1 = centered(2*SVector(0.112737, 0.274526, 0.112737))
    f2 = centered(SVector(-1.0, 0.0, 1.0)/2)
    return kernelfactors((f2, f1)), kernelfactors((f1, f2))
end

"""
    kern = ando3(extended::NTuple{N,Bool}, d)

Return a factored Ando filter (size 3) for computing the gradient in
`N` dimensions along axis `d`.  If `extended[dim]` is false, `kern`
will have size 1 along that dimension.
"""
function ando3(extended::NTuple{N,Bool}, d) where N
    gradfactors(extended, d, [-1.0, 0.0, 1.0]/2, 2*[0.112737, 0.274526, 0.112737])
end

"""
`kern1, kern2 = ando4()` returns separable approximations of the
optimal 4x4 filters for dimensions 1 and 2 of your image, as defined
in Ando Shigeru, IEEE Trans. Pat. Anal. Mach. Int., vol. 22 no 3,
March 2000.

See also: [`Kernel.ando4`](@ref).
"""
function ando4()
    f1 = centered(SVector( 0.0919833,  0.408017, 0.408017, 0.0919833))
    f2 = centered(1.46205884*SVector(-0.0919833, -0.408017, 0.408017, 0.0919833))
    return kernelfactors((f2, f1)), kernelfactors((f1, f2))
end

"""
    kern = ando4(extended::NTuple{N,Bool}, d)

Return a factored Ando filter (size 4) for computing the gradient in
`N` dimensions along axis `d`.  If `extended[dim]` is false, `kern`
will have size 1 along that dimension.
"""
function ando4(extended::NTuple{N,Bool}, d) where N
    if N == 2 && all(extended)
        return ando4()[d]
    else
        error("dimensions other than 2 are not yet supported")
    end
end

"""
`kern1, kern2 = ando5_sep()` returns separable approximations of the
optimal 5x5 gradient filters for dimensions 1 and 2 of your image, as defined
in Ando Shigeru, IEEE Trans. Pat. Anal. Mach. Int., vol. 22 no 3,
March 2000.

See also: [`Kernel.ando5`](@ref).
"""
function ando5()
    f1 = centered(SVector( 0.0357338, 0.248861, 0.43081, 0.248861, 0.0357338))
    f2 = centered(0.784406*SVector(-0.137424, -0.362576, 0.0,     0.362576, 0.137424))
    return kernelfactors((f2, f1)), kernelfactors((f1, f2))
end

"""
    kern = ando5(extended::NTuple{N,Bool}, d)

Return a factored Ando filter (size 5) for computing the gradient in
`N` dimensions along axis `d`.  If `extended[dim]` is false, `kern`
will have size 1 along that dimension.
"""
function ando5(extended::NTuple{N,Bool}, d) where N
    if N == 2 && all(extended)
        return ando5()[d]
    else
        error("dimensions other than 2 are not yet supported")
    end
end

## Gaussian

"""
    gaussian(σ::Real, [l]) -> g

Construct a 1d gaussian kernel `g` with standard deviation `σ`, optionally
providing the kernel length `l`. The default is to extend by two `σ`
in each direction from the center. `l` must be odd.
"""
function gaussian(σ::Real, l = 4*ceil(Int,σ)+1)
    isodd(l) || throw(ArgumentError("length must be odd"))
    w = l>>1
    g = [exp(-x^2/(2*σ^2)) for x=-w:w]
    centered(g/sum(g))
end

"""
    gaussian((σ1, σ2, ...), [l]) -> (g1, g2, ...)

Construct a multidimensional gaussian filter as a product of single-dimension
factors, with standard deviation `σd` along dimension `d`. Optionally
provide the kernel length `l`, which must be a tuple of the same
length.
"""
gaussian(σs::NTuple{N,Real}, ls::NTuple{N,Integer}) where {N} =
    kernelfactors( map((σ,l)->gaussian(σ,l), σs, ls) )
gaussian(σs::NTuple{N,Real}) where {N} = kernelfactors(map(σ->gaussian(σ), σs))

gaussian(σs::AbstractVector, ls::AbstractVector) = gaussian((σs...,), (ls...,))
gaussian(σs::AbstractVector) = gaussian((σs...,))

#### IIR

struct TriggsSdika{T,k,l,L} <: IIRFilter{T}
    a::SVector{k,T}
    b::SVector{l,T}
    scale::T
    M::SMatrix{l,k,T,L}
    asum::T
    bsum::T

    TriggsSdika{T,k,l,L}(a, b, scale, M) where {T,k,l,L} =
        new{T,k,l,L}(a, b, scale, M, sum(a), sum(b))
end
"""
    TriggsSdika(a, b, scale, M)

Defines a kernel for one-dimensional infinite impulse response (IIR)
filtering. `a` is a "forward" filter, `b` a "backward" filter, `M` is
a matrix for matching boundary conditions at the right edge, and
`scale` is a constant scaling applied to each element at the
conclusion of filtering.

# Citation

B. Triggs and M. Sdika, "Boundary conditions for Young-van Vliet
recursive filtering". IEEE Trans. on Sig. Proc. 54: 2365-2367
(2006).
"""
TriggsSdika(a::SVector{k,T}, b::SVector{l,T}, scale, M::SMatrix{l,k,T,L}) where {T,k,l,L} = TriggsSdika{T,k,l,L}(a, b, scale, M)

"""
    TriggsSdika(ab, scale)

Create a symmetric Triggs-Sdika filter (with `a = b = ab`). `M` is
calculated for you. Only length 3 filters are currently supported.
"""
function TriggsSdika(a::SVector{3,T}, scale) where T
    a1, a2, a3 = a[1], a[2], a[3]
    Mdenom = (1+a1-a2+a3)*(1-a1-a2-a3)*(1+a2+(a1-a3)*a3)
    M = @SMatrix([-a3*a1+1-a3^2-a2     (a3+a1)*(a2+a3*a1)  a3*(a1+a3*a2);
                  a1+a3*a2            -(a2-1)*(a2+a3*a1)  -(a3*a1+a3^2+a2-1)*a3;
                  a3*a1+a2+a1^2-a2^2   a1*a2+a3*a2^2-a1*a3^2-a3^3-a3*a2+a3  a3*(a1+a3*a2)]);
    TriggsSdika(a, a, scale, M/Mdenom)
end
Base.vec(kernel::TriggsSdika) = kernel
Base.ndims(kernel::TriggsSdika) = 1
Base.ndims(::Type{T}) where {T<:TriggsSdika} = 1
Base.indices1(kernel::TriggsSdika) = 0:0
Base.indices(kernel::TriggsSdika) = (Base.indices1(kernel),)
Base.isempty(kernel::TriggsSdika) = false

iterdims(inds::Indices{1}, kern::TriggsSdika) = (), inds[1], ()
_reshape(kern::TriggsSdika, ::Type{Val{1}}) = kern

# Note that there's a sign reversal between Young & Triggs.
"""
    IIRGaussian([T], σ; emit_warning::Bool=true)

Construct an infinite impulse response (IIR) approximation to a
Gaussian of standard deviation `σ`. `σ` may either be a single real
number or a tuple of numbers; in the latter case, a tuple of such filters
will be created, each for filtering a different dimension of an array.

Optionally specify the type `T` for the filter coefficients; if not
supplied, it will match `σ` (unless `σ` is not floating-point, in
which case `Float64` will be chosen).

# Citation

I. T. Young, L. J. van Vliet, and M. van Ginkel, "Recursive Gabor
Filtering". IEEE Trans. Sig. Proc., 50: 2798-2805 (2002).
"""
function IIRGaussian(::Type{T}, σ::Real; emit_warning::Bool = true) where T
    if emit_warning && σ < 1 && σ != 0
        warn("σ is too small for accuracy")
    end
    m0 = convert(T,1.16680)
    m1 = convert(T,1.10783)
    m2 = convert(T,1.40586)
    q = convert(T,1.31564*(sqrt(1+0.490811*σ*σ) - 1))
    ascale = (m0+q)*(m1*m1 + m2*m2  + 2m1*q + q*q)
    B = (m0*(m1*m1 + m2*m2)/ascale)^2
    # This is what Young et al call -b, but in filt() notation would be called a
    a1 = q*(2*m0*m1 + m1*m1 + m2*m2 + (2*m0+4*m1)*q + 3*q*q)/ascale
    a2 = -q*q*(m0 + 2m1 + 3q)/ascale
    a3 = q*q*q/ascale
    a = SVector(a1,a2,a3)
    TriggsSdika(a, B)
end
IIRGaussian(σ::Real; emit_warning::Bool = true) = IIRGaussian(iirgt(σ), σ; emit_warning=emit_warning)

function IIRGaussian(::Type{T}, σs::NTuple{N,Real}; emit_warning::Bool = true) where {T,N}
    iirg(T, (), σs, tail(ntuple(d->true, Val{N})), emit_warning)
end
IIRGaussian(σs::Tuple; emit_warning::Bool = true) = IIRGaussian(iirgt(σs), σs; emit_warning=emit_warning)

IIRGaussian(σs::AbstractVector; kwargs...) = IIRGaussian((σs...,); kwargs...)
IIRGaussian(::Type{T}, σs::AbstractVector; kwargs...) where {T} = IIRGaussian(T, (σs...,); kwargs...)

iirgt(σ::AbstractFloat) = typeof(σ)
iirgt(σ::Real) = Float64
iirgt(σs::Tuple) = promote_type(map(iirgt, σs)...)

@inline function iirg(::Type{T}, pre, σs, post, emit_warning) where T
    kern = ReshapedOneD(pre, IIRGaussian(T, σs[1]; emit_warning=emit_warning), post)
    (kern, iirg(T, (pre..., post[1]), tail(σs), tail(post), emit_warning)...)
end
iirg(::Type{T}, pre, σs::Tuple{Real}, ::Tuple{}, emit_warning) where {T} =
    (ReshapedOneD(pre, IIRGaussian(T, σs[1]; emit_warning=emit_warning), ()),)

###### Utilities

"""
    kernelfactors(factors::Tuple)

Prepare a factored kernel for filtering. If passed a 2-tuple of
vectors of lengths `m` and `n`, this will return a 2-tuple of
`ReshapedVector`s that are effectively of sizes `m×1` and `1×n`. In
general, each successive `factor` will be reshaped to extend along the
corresponding dimension.

If passed a tuple of general arrays, it is assumed that each is shaped
appropriately along its "leading" dimensions; the dimensionality of each is
"extended" to `N = length(factors)`, appending 1s to the size as needed.
"""
kernelfactors(factors::NTuple{N,AbstractVector}) where {N} = _kernelfactors((), ntuple(d->true,Val{N}), (), factors)

_kernelfactors(pre, post, out, ::Tuple{}) = out
@inline function _kernelfactors(pre, post, out, factors)
    # L+M=N
    f = factors[1]
    newpost = tail(post)
    rv = ReshapedOneD(pre, f, newpost)
    _kernelfactors((pre..., true), newpost, (out..., rv), tail(factors))
end

# A variant in which we just need to fill out to N dimensions
kernelfactors(factors::NTuple{N,AbstractArray}) where {N} = map(f->_reshape(f, Val{N}), factors)

function gradfactors(extended::NTuple{N,Bool}, d::Int, k1, k2) where N
    kernelfactors(ntuple(i -> kdim(extended[i], i==d ? k1 : k2), Val{N}))
end

kdim(keep::Bool, k) = keep ? centered(k) : OffsetArray([one(eltype(k))], 0:0)

end
