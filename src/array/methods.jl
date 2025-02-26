# Array info
for (m, f) in ((:Base, :size), (:Base, :axes), (:Base, :firstindex), (:Base, :lastindex))
    @eval begin
        @inline $m.$f(A::AbstractDimArray, dims::AllDims) = $m.$f(A, dimnum(A, dims))
    end
end

# Reducing methods

# With a function arg version
for (m, f) in ((:Base, :sum), (:Base, :prod), (:Base, :maximum), (:Base, :minimum), 
                     (:Base, :extrema), (:Statistics, :mean))
    _f = Symbol('_', f)
    @eval begin
        # Base methods
        $m.$f(A::AbstractDimArray; dims=:, kw...) = $_f(A::AbstractDimArray, dims; kw...)
        $m.$f(f, A::AbstractDimArray; dims=:, kw...) = $_f(f, A::AbstractDimArray, dims; kw...)
        # Local dispatch methods
        # - Return a reduced DimArray
        $_f(A::AbstractDimArray, dims; kw...) =
            rebuild(A, $m.$f(parent(A); dims=dimnum(A, _astuple(dims)), kw...), reducedims(A, dims))
        $_f(f, A::AbstractDimArray, dims; kw...) =
            rebuild(A, $m.$f(f, parent(A); dims=dimnum(A, _astuple(dims)), kw...), reducedims(A, dims))
        # - Return a scalar
        $_f(A::AbstractDimArray, dims::Colon; kw...) = $m.$f(parent(A); dims, kw...)
        $_f(f, A::AbstractDimArray, dims::Colon; kw...) = $m.$f(f, parent(A); dims, kw...)
    end
end
# With no function arg version
for (m, f) in ((:Statistics, :std), (:Statistics, :var))
    _f = Symbol('_', f)
    @eval begin
        # Base methods
        $m.$f(A::AbstractDimArray; corrected::Bool=true, mean=nothing, dims=:) =
            $_f(A, corrected, mean, dims)
        # Local dispatch methods - Returns a reduced array
        $_f(A::AbstractDimArray, corrected, mean, dims) =
            rebuild(A, $m.$f(parent(A); corrected=corrected, mean=mean, dims=dimnum(A, _astuple(dims))), reducedims(A, dims))
        # - Returns a scalar
        $_f(A::AbstractDimArray, corrected, mean, dims::Colon) =
            $m.$f(parent(A); corrected=corrected, mean=mean, dims=:)
    end
end
for (m, f) in ((:Statistics, :median), (:Base, :any), (:Base, :all))
    _f = Symbol('_', f)
    @eval begin
        # Base methods
        $m.$f(A::AbstractDimArray; dims=:) = $_f(A, dims)
        # Local dispatch methods - Returns a reduced array
        $_f(A::AbstractDimArray, dims) =
            rebuild(A, $m.$f(parent(A); dims=dimnum(A, _astuple(dims))), reducedims(A, dims))
        # - Returns a scalar
        $_f(A::AbstractDimArray, dims::Colon) = $m.$f(parent(A); dims=:)
    end
end

# These are not exported but it makes a lot of things easier using them
function Base._mapreduce_dim(f, op, nt::NamedTuple{(),<:Tuple}, A::AbstractDimArray, dims)
    rebuild(A, Base._mapreduce_dim(f, op, nt, parent(A), dimnum(A, _astuple(dims))), reducedims(A, dims))
end
function Base._mapreduce_dim(f, op, nt::NamedTuple{(),<:Tuple}, A::AbstractDimArray, dims::Colon)
    Base._mapreduce_dim(f, op, nt, parent(A), dims)
end
function Base._mapreduce_dim(f, op, nt, A::AbstractDimArray, dims)
    rebuild(A, Base._mapreduce_dim(f, op, nt, parent(A), dimnum(A, dims)), reducedims(A, dims))
end
@static if VERSION >= v"1.6" 
    function Base._mapreduce_dim(f, op, nt::Base._InitialValue, A::AbstractDimArray, dims)
        rebuild(A, Base._mapreduce_dim(f, op, nt, parent(A), dimnum(A, dims)), reducedims(A, dims))
    end
    function Base._mapreduce_dim(f, op, nt::Base._InitialValue, A::AbstractDimArray, dims::Colon)
        Base._mapreduce_dim(f, op, nt, parent(A), dims)
    end
end

# TODO: Unfortunately Base/accumulate.jl kw methods all force dims to be Integer.
# accumulate wont work unless that is relaxed, or we copy half of the file here.
# Base._accumulate!(op, B, A, dims::AllDims, init::Union{Nothing, Some}) =
    # Base._accumulate!(op, B, A, dimnum(A, dims), init)

# Dimension dropping

function Base.dropdims(A::AbstractDimArray; dims)
    dims = DD.dims(A, dims)
    data = Base.dropdims(parent(A); dims=dimnum(A, dims))
    rebuildsliced(A, data, _dropinds(A, dims))
end

@inline _dropinds(A, dims::DimTuple) = dims2indices(A, map(d -> rebuild(d, 1), dims))
@inline _dropinds(A, dim::Dimension) = dims2indices(A, rebuild(dim, 1))


# Function application

function Base.map(f, As::AbstractDimArray...)
    comparedims(As...)
    newdata = map(f, map(parent, As)...)
    rebuild(first(As); data=newdata)
end

function Base.mapslices(f, A::AbstractDimArray; dims=1, kw...)
    dimnums = dimnum(A, _astuple(dims))
    data = mapslices(f, parent(A); dims=dimnums, kw...)
    rebuild(A, data)
end

@static if VERSION < v"1.9-alpha1"
    """
        Base.eachslice(A::AbstractDimArray; dims)

    Create a generator that iterates over dimensions `dims` of `A`, returning arrays that
    select all the data from the other dimensions in `A` using views.

    The generator has `size` and `axes` equivalent to those of the provided `dims`.
    """
    function Base.eachslice(A::AbstractDimArray; dims)
        dimtuple = _astuple(dims)
        all(hasdim(A, dimtuple...)) || throw(DimensionMismatch("A doesn't have all dimensions $dims"))
        _eachslice(A, dimtuple)
    end
else
    @inline function Base.eachslice(A::AbstractDimArray; dims, drop=true)
        dimtuple = _astuple(dims)
        all(hasdim(A, dimtuple...)) || throw(DimensionMismatch("A doesn't have all dimensions $dims"))
        _eachslice(A, dimtuple, drop)
    end
    Base.@constprop :aggressive function _eachslice(A::AbstractDimArray{T,N}, dims, drop) where {T,N}
        slicedims = Dimensions.dims(A, dims)
        Adims = Dimensions.dims(A)
        if drop
            ax = map(dim -> axes(A, dim), slicedims)
            slicemap = map(Adims) do dim
                hasdim(slicedims, dim) ? dimnum(slicedims, dim) : (:)
            end
            return Slices(A, slicemap, ax)
        else
            ax = map(Adims) do dim
                hasdim(slicedims, dim) ? axes(A, dim) : axes(reducedims(dim, dim), 1)
            end
            slicemap = map(Adims) do dim
                hasdim(slicedims, dim) ? dimnum(A, dim) : (:)
            end
            return Slices(A, slicemap, ax)
        end
    end
end

# works for arrays and for stacks
function _eachslice(x, dims::Tuple)
    slicedims = Dimensions.dims(x, dims)
    return (view(x, d...) for d in DimIndices(slicedims))
end

# Duplicated dims

for fname in (:cor, :cov)
    @eval function Statistics.$fname(A::AbstractDimArray{<:Any,2}; dims=1, kw...)
        newdata = Statistics.$fname(parent(A); dims=dimnum(A, dims), kw...)
        removed_idx = dimnum(A, dims)
        newrefdims = $dims(A)[removed_idx]
        newdim = $dims(A)[3 - removed_idx]
        rebuild(A, newdata, (newdim, newdim), (newrefdims,))
    end
end

# Rotations

Base.rotl90(A::AbstractDimMatrix) = rebuild(A, rotl90(parent(A)), _rotdims_90(dims(A)))
function Base.rotl90(A::AbstractDimMatrix, k::Integer)
    rebuild(A, rotl90(parent(A), k), _rotdims_k(dims(A), k))
end

Base.rotr90(A::AbstractDimMatrix) = rebuild(A, rotr90(parent(A)), _rotdims_270(dims(A)))
function Base.rotr90(A::AbstractDimMatrix, k::Integer)
    rebuild(A, rotr90(parent(A), k), _rotdims_k(dims(A), -k))
end

Base.rot180(A::AbstractDimMatrix) = rebuild(A, rot180(parent(A)), _rotdims_180(dims(A)))

# Not type stable - but we have to lose type stability somewhere when
# dims are being swapped, by an Int value, so it may as well be here
function _rotdims_k(dims, k)
    k = mod(k, 4)
    k == 1 ? _rotdims_90(dims) :
    k == 2 ? _rotdims_180(dims) :
    k == 3 ? _rotdims_270(dims) : dims
end

_rotdims_90((dim_a, dim_b)) = reverse(dim_b), dim_a
_rotdims_180((dim_a, dim_b)) = reverse(dim_a), reverse(dim_b)
_rotdims_270((dim_a, dim_b)) = dim_b, reverse(dim_a)

# Dimension reordering

for (pkg, fname) in [(:Base, :permutedims), (:Base, :adjoint),
                     (:Base, :transpose), (:LinearAlgebra, :Transpose)]
    @eval begin
        @inline $pkg.$fname(A::AbstractDimArray{<:Any,2}) =
            rebuild(A, $pkg.$fname(parent(A)), reverse(dims(A)))
        @inline $pkg.$fname(A::AbstractDimArray{<:Any,1}) =
            rebuild(A, $pkg.$fname(parent(A)), (AnonDim(Base.OneTo(1)), dims(A)...))
    end
end
@inline function Base.permutedims(A::AbstractDimArray, perm)
    rebuild(A, permutedims(parent(A), dimnum(A, Tuple(perm))), sortdims(dims(A), Tuple(perm)))
end
@inline function Base.PermutedDimsArray(A::AbstractDimArray{T,N}, perm) where {T,N}
    perm_inds = dimnum(A, Tuple(perm))
    iperm_inds = invperm(perm_inds)
    data = parent(A)
    data_perm = PermutedDimsArray{T,N,perm_inds,iperm_inds,typeof(data)}(data)
    rebuild(A, data_perm, sortdims(dims(A), Tuple(perm)))
end

# Concatenation
function Base._cat(_catdims::Tuple, A1::AbstractDimArray, As::AbstractDimArray...)
    catdims = map(_catdims) do d
        d isa DimType && return d(NoLookup())
        if d isa Int 
            if hasdim(A1, d)
                return dims(A1, d)
            else
                return AnonDim(NoLookup())
            end
        end
        return key2dim(d)
    end
    return _cat(catdims, A1, As...)
end
function Base._cat(catdim::Union{Int,DimOrDimType}, Xin::AbstractDimArray...)
    Base._cat((catdim,), Xin...)
end
function _cat(catdims::Tuple, A1::AbstractDimArray, As::AbstractDimArray...)
    Xin = (A1, As...)
    comparedims(map(x -> otherdims(x, catdims), Xin)...; val=true)
    newcatdims = map(catdims) do catdim
        if all(x -> hasdim(x, catdim), Xin)
            # We concatenate an existing dimension
            newcatdim = if lookup(A1, catdim) isa NoLookup
                rebuild(catdim, NoLookup())
            else
                # vcat the index for the catdim in each of Xin
                reduce(vcat, map(x -> dims(x, catdim), Xin))
            end
        else
            # Concatenate new dims
            if all(map(x -> hasdim(refdims(x), catdim), Xin))
                if catdim isa Dimension && val(catdim) isa AbstractArray && !(lookup(catdim) isa NoLookup{AutoIndex})
                    # Combine the refdims properties with the passed in catdim
                    set(refdims(first(Xin), catdim), catdim)
                else
                    # vcat the refdims 
                    reduce(vcat, map(x -> refdims(x, catdim), Xin))
                end
            else
                # Use the catdim as the new dimension
                catdim
            end
        end
    end
    inserted_dims = dims(newcatdims, dims(A1))
    appended_dims = otherdims(newcatdims, inserted_dims)
    updated_dims = setdims(dims(A1), inserted_dims)
    newdims = (updated_dims..., appended_dims...)

    inserted_dnums = dimnum(A1, inserted_dims)
    appended_dnums = ntuple(i -> i + length(dims(A1)), length(appended_dims))
    cat_dnums = (inserted_dnums..., appended_dnums...)

    newrefdims = otherdims(refdims(A1), newcatdims)
    T = Base.promote_eltypeof(Xin...)
    data = map(parent, Xin)
    newA = Base._cat_t(cat_dnums, T, data...)
    rebuild(A1, newA, format(newdims, newA), newrefdims)
end

function Base.hcat(As::Union{AbstractDimVector,AbstractDimMatrix}...)
    A1 = first(As)
    catdim = if A1 isa AbstractDimVector
        AnonDim()
    else
        vcat(map(last ∘ dims, As)...)
    end
    noncatdim = dims(A1, 1)
    # Make sure this is exactly the same dimension for all arrays
    comparedims(map(x -> dims(x, 1), As)...; val=true)
    newdims = (noncatdim, catdim)
    newA = hcat(map(parent, As)...)
    return rebuild(A1, newA, format(newdims, newA))
end

function Base.vcat(As::Union{AbstractDimVector,AbstractDimMatrix}...)
    A1 = first(As)
    catdim = vcat(map(first ∘ dims, As)...)
    newdims = if A1 isa AbstractDimVector
        (catdim,)
    else
        noncatdim = dims(A1, 2)
        # Make sure this is exactly the same dimension for all arrays
        comparedims(map(x -> dims(x, 2), As)...; val=true)
        (catdim, noncatdim)
    end
    newA = vcat(map(parent, As)...)
    return rebuild(A1, newA, format(newdims, newA))
end

function Base.vcat(d1::Dimension, ds::Dimension...)
    comparedims(d1, ds...; length=false)
    newlookup = _vcat_lookups(lookup((d1, ds...))...)
    rebuild(d1, newlookup)
end

# LookupArrays may need adjustment for `cat`
function _vcat_lookups(lookups::LookupArray...)
    newindex = _vcat_index(lookups...)
    return rebuild(lookups[1]; data=newindex)
end
function _vcat_lookups(lookups::AbstractSampled...)
    newindex = _vcat_index(lookups...)
    newlookup = _vcat_lookups(sampling(first(lookups)), span(first(lookups)), lookups...)
    return rebuild(newlookup; data=newindex)
end
function _vcat_lookups(::Any, ::Regular, lookups...)
    s = step(first(lookups))
    lastval = last(first(lookups))
    foreach(Base.tail(lookups)) do l
        span(l) isa Regular || _mixed_span_error(Regular)
        step(span(l)) == s || throw(DimensionMismatch("Step sizes $(step(span(l))) and $s do not match"))
        lastval + s ≈ first(l) || throw(DimensionMismatch("Regular lookups do not join with the correct step size. To cat anyway, set lookups to `Irregular` using `set`."))
        lastval = last(l)
    end
    first(lookups)
end
function _vcat_lookups(::Intervals, ::Explicit, lookups...)
    len = mapreduce(+, lookups) do l
        span(l) isa Explicit || _mixed_span_error(Explicit)
        size(val(span(l)), 2) 
    end
    combined_span_mat = similar(val(span(first(lookups))), 2, len)
    i = 1
    foreach(lookups) do l
        span_mat = val(span(l))
        l = size(span_mat, 2)
        combined_span_mat[:, i:i+l - 1] .= span_mat
        i += l
    end
    rebuild(first(lookups); span=Explicit(combined_span_mat))
end
function _vcat_lookups(::Intervals, ::Irregular, lookups...)
    map(lookups) do l
        span(l) isa Irregular || _mixed_span_error(Irregular)
    end
    allbounds = map(bounds ∘ span, lookups)
    newbounds = minimum(map(first, allbounds)), maximum(map(last, allbounds))
    rebuild(lookups[1]; span=Irregular(newbounds))
end
function _vcat_lookups(::Points, ::Irregular, lookups...)
    map(lookups) do l
        span(l) isa Irregular || _mixed_span_error(Irregular)
    end
    rebuild(first(lookups); span=Irregular(nothing, nothing))
end

_vcat_index(A1::NoLookup, A::NoLookup...) = OneTo(mapreduce(length, +, (A1, A...)))
# TODO: handle vcat OffsetArrays?
# Otherwise just vcat. TODO: handle order breaking vcat?
# function _vcat_index(lookup::LookupArray, lookups...) 
    # _vcat_index(span(lookup), lookup, lookups...) 
# end
function _vcat_index(lookup1::LookupArray, lookups::LookupArray...)
    xl = length(lookup1) > 0 ? last(lookup1) : nothing
    if order(lookup1) isa Ordered 
        foreach(lookups) do lookup
            order(lookup) === order(lookup1) || throw(DimensionMismatch("Lookups do not all have the same order"))
            if !isnothing(xl)
                if order(lookup) isa ForwardOrdered
                    length(lookup) == 0 || first(lookup) > xl || _lookup_index_cat_error(lookup, xl)
                else
                    length(lookup) == 0 || first(lookup) < xl || _lookup_index_cat_error(lookup, xl)
                end
            end
            if length(lookup) > 0
                xl = last(lookup)
            end
            return nothing
        end
    end
    shifted = map((lookup1, lookups...)) do l
        parent(maybeshiftlocus(locus(lookup1), l))
    end
    return reduce(vcat, shifted)
end

_lookup_index_cat_error(lookup, xl) = error("Lookups overlap or are not in order at $(first(lookup)) and $xl")
_mixed_span_error(T) = throw(DimensionMismatch("Not all lookups have `$T` spans."))

function Base.inv(A::AbstractDimArray{T,2}) where T
    newdata = inv(parent(A))
    newdims = reverse(dims(A))
    rebuild(A, newdata, newdims)
end

# Index breaking

# TODO: change the index and traits of the reduced dimension and return a DimArray.
Base.unique(A::AbstractDimArray; dims::Union{DimOrDimType,Int,Colon}=:) = _unique(A, dims)
Base.unique(A::AbstractDimArray{<:Any,1}) = unique(parent(A))

_unique(A::AbstractDimArray, dims) = unique(parent(A); dims=dimnum(A, dims))
_unique(A::AbstractDimArray, dims::Colon) = unique(parent(A); dims=:)

Base.diff(A::AbstractDimVector; dims=1) = _diff(A, dimnum(A, dims))
Base.diff(A::AbstractDimArray; dims) = _diff(A, dimnum(A, dims))

@inline function _diff(A::AbstractDimArray{<:Any,N}, dims::Integer) where {N}
    r = axes(A)
    # Copied from Base.diff
    r0 = ntuple(i -> i == dims ? UnitRange(1, last(r[i]) - 1) : UnitRange(r[i]), N)
    rebuildsliced(A, diff(parent(A); dims=dimnum(A, dims)), r0)
end

# Forward `replace` to parent objects
function Base._replace!(new::Base.Callable, res::AbstractDimArray, A::AbstractDimArray, count::Int) 
    Base._replace!(new, parent(res), parent(A), count) 
    return res
end

function Base.reverse(A::AbstractDimArray; dims=1)
    newdims = _reverse(DD.dims(A, dims))
    newdata = reverse(parent(A); dims=dimnum(A, dims))
    # Use setdims here because newdims is not all the dims
    setdims(rebuild(A, newdata), newdims)
end

_reverse(dims::Tuple) = map(d -> reverse(d), dims)
_reverse(dim::Dimension) = reverse(dim)

# Dimension
Base.reverse(dim::Dimension) = rebuild(dim, reverse(lookup(dim)))

Base.dataids(A::AbstractDimArray) = Base.dataids(parent(A)) 
