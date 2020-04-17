using .ArchGDAL

const AG = ArchGDAL

export GDALarray, GDALstack, GDALmetadata, GDALdimMetadata


# Metadata ########################################################################

"""
[`ArrayMetadata`](@ref) wrapper for `GDALarray`.
"""
struct GDALmetadata{K,V} <: ArrayMetadata{K,V}
    val::Dict{K,V}
end

"""
[`DimMetadata`](@ref) wrapper for `GDALarray` dimensions.
"""
struct GDALdimMetadata{K,V} <: DimMetadata{K,V}
    val::Dict{K,V}
end


# Array ########################################################################

"""
    GDALarray(filename; usercrs=nothing, name="", refdims=(), window=())

Load a file lazily with gdal. GDALarray will be converted to GeoArray after
indexing or other manipulations. `GeoArray(GDAlarray(filename))` will do this
immediately.

`EPSG` or `ProjString`. If `usercrs` is passed to the constructor, all selectors will
use its projection, converting automatically to the underlying projection from GDAL.

## Arguments
- `filename`: `String` pointing to a grd file. Extension is optional.

## Keyword arguments
- `name`: Name for the array.
- `refdims`: Add dimension position array was sliced from. Mostly used programatically.
- `usercrs`: can be any CRS `GeoFormat` form GeoFormatTypes.jl, such as `WellKnownText`
- `window`: `Tuple` of `Dimension`, `Selector` or regular index to be applied when 
  loading the array. Can save on disk load time for large files.
"""
struct GDALarray{T,N,F,D<:Tuple,R<:Tuple,Na<:AbstractString,Me,Mi,W,S
                } <: DiskGeoArray{T,N,D,LazyArray{T,N}}
    filename::F
    dims::D
    refdims::R
    name::Na
    metadata::Me
    missingval::Mi
    window::W
    size::S
end
GDALarray(filename::AbstractString; kwargs...) = begin
    isfile(filename) || error("file not found: $filename")
    gdalapply(dataset -> GDALarray(dataset; kwargs...), filename)
end
GDALarray(dataset::AG.Dataset; usercrs=nothing, dims=dims(dataset, usercrs), refdims=(),
          name="", metadata=metadata(dataset), missingval=missingval(dataset), window=()) = begin
    filename = first(AG.filelist(dataset))
    sze = gdalsize(dataset)
    if window != ()
        window = to_indices(dataset, dims2indices(dims, window))
        sze = windowsize(window)
    end
    T = AG.pixeltype(AG.getband(dataset, 1))
    N = length(sze)
    GDALarray{T,N,typeof.((filename,dims,refdims,name,metadata,missingval,window,sze))...
       }(filename, dims, refdims, name, metadata, missingval, window, sze)
end

# AbstractGeoArray methods

data(A::GDALarray) =
    gdalapply(filename(A)) do dataset
        _window = maybewindow2indices(dataset, dims(A), window(A))
        readwindowed(dataset, _window)
    end

# Base methods

Base.getindex(A::GDALarray, I::Vararg{<:Union{<:Integer,<:AbstractArray}}) =
    gdalapply(filename(A)) do dataset
        _window = maybewindow2indices(dataset, dims(A), window(A))
        # Slice for both window and indices
        _dims, _refdims = slicedims(slicedims(dims(A), refdims(A), _window)..., I)
        data = readwindowed(dataset, _window, I...)
        rebuild(A, data, _dims, _refdims)
    end
Base.getindex(A::GDALarray, i1::Integer, I::Vararg{<:Integer}) =
    gdalapply(filename(A)) do dataset
        _window = maybewindow2indices(dataset, dims(A), window(A))
        readwindowed(dataset, _window, i1, I...)
    end

"""
    Base.write(filename::AbstractString, ::Type{GDALarray}, A::AbstractGeoArray)

Write a [`GDALarray`](@ref) to a .tiff file.
"""
Base.write(filename::AbstractString, ::Type{GDALarray}, A::AbstractGeoArray{T,2}) where T = begin
    all(hasdim(A, (Lon, Lat))) || error("Array must have Lat and Lon dims to write to GTiff")
    A = permutedims(A, (Lon(), Lat()))
    nbands = 1
    indices = 1
    gdalwrite(filename, A, nbands, indices)
end
Base.write(filename::AbstractString, ::Type{GDALarray}, A::AbstractGeoArray{T,3}) where T = begin
    all(hasdim(A, (Lon, Lat))) || error("Array must have Lat and Lon dims to write to GeoTiff")
    hasdim(A, Band()) || error("Must have a `Band` dimension to write a 3-dimensional array to GeoTiff")
    correctedA = permutedims(A, (Lon(), Lat(), Band())) |>
        a -> reorderindex(a, (Lon(Forward()), Lat(Reverse()), Band(Forward()))) |>
        a -> reorderrelation(a, Forward())
    lat_array_ord = arrayorder(correctedA, Lat)
    if !(lat_array_ord isa Reverse)
        @warn "Array data order for saving `Lat` is `$lat_array_ord`, usualy `Reverse()`"
    end
    nbands = size(A, Band())
    indices = Cint[1]
    gdalwrite(filename, correctedA, nbands, indices)
end


# AbstractGeoStack methods

GDALstack(filename; kwargs...) = DiskStack(filename; childtype=GDALarray, kwargs...)

querychild(f, ::Type{GDALarray}, filename::AbstractString, stack) =
    gdalapply(f, filename)


# DimensionalData methods for ArchGDAL types ###############################

dims(dataset::AG.Dataset, usercrs=nothing) = begin
    gt = try
        AG.getgeotransform(dataset)
    catch
        GDAL_EMPTY_TRANSFORM
    end

    latsize, lonsize = AG.height(dataset), AG.width(dataset)

    nbands = AG.nraster(dataset)
    band = Band(1:nbands, mode=Categorical())
    sourcecrs = crs(dataset)

    lonlat_metadata=GDALdimMetadata()

    # Output a BoundedIndex dims when the transformation is lat/lon alligned,
    # otherwise use TransformedIndex with an affine map.
    if isalligned(gt)
        lonstep = gt[GDAL_WE_RES]
        lonmin = gt[GDAL_TOPLEFT_X]
        lonmax = lonmin + lonstep * (lonsize - 1)
        lonrange = LinRange(lonmin, lonmax, lonsize)

        latstep = gt[GDAL_NS_RES]
        latmax = gt[GDAL_TOPLEFT_Y]
        latmin = latmax + latstep * (latsize - 1)
        latrange = LinRange(latmax, latmin, latsize)

        areaorpoint = gdalmetadata(dataset, "AREA_OR_POINT")
        # Spatial data defaults to area/inteval?
        if areaorpoint == "Point"
            sampling = Points()
        else areaorpoint
            # GeoTiff uses the "pixelCorner" convention
            sampling = Intervals(Start())
        end

        latmode = ProjectedIndex(
            # Latitude is in reverse to how we plot it.
            order=Ordered(Reverse(), Reverse(), Forward()),
            sampling=sampling,
            # Use the range step as is will be different to latstep due to float error
            span=Regular(step(latrange)),
            crs=sourcecrs,
            usercrs=usercrs
        )
        lonmode = ProjectedIndex(
            span=Regular(step(lonrange)),
            sampling=sampling,
            crs=sourcecrs,
            usercrs=usercrs
        )

        lon = Lon(lonrange; mode=lonmode, metadata=lonlat_metadata)
        lat = Lat(latrange; mode=latmode, metadata=lonlat_metadata)

        formatdims(map(Base.OneTo, (lonsize, latsize, nbands)), (lon, lat, band))
    else
        error("Rotated/transformed mode not handled currently")
        # affinemap = geotransform_to_affine(geotransform)
        # x = X(affinemap; mode=TransformedIndex(dims=Lon()))
        # y = Y(affinemap; mode=TransformedIndex(dims=Lat()))

        # formatdims((lonsize, latsize, nbands), (x, y, band))
    end
end

missingval(dataset::AG.Dataset, args...) = begin
    band = AG.getband(dataset, 1)
    missingval = AG.getnodatavalue(band)
    T = AG.pixeltype(band)
    try
        missingval = convert(T, missingval)
    catch
        @warn "No data value from GDAL $(missingval) is not convertible to data type $T. `missingval` is probably incorrect."
    end
    missingval
end

metadata(dataset::AG.Dataset, args...) = begin
    band = AG.getband(dataset, 1)
    # color = AG.getname(AG.getcolorinterp(band))
    scale = AG.getscale(band)
    offset = AG.getoffset(band)
    # norvw = AG.noverview(band)
    units = AG.getunittype(band)
    path = first(AG.filelist(dataset))
    GDALmetadata(Dict("filepath"=>path, "scale"=>scale, "offset"=>offset, "units"=>units))
end

crs(dataset::AG.Dataset, args...) =
    WellKnownText(GeoFormatTypes.CRS(), string(AG.getproj(dataset)))


# Utils ########################################################################

gdalapply(f, filename::AbstractString) =
    AG.read(filename) do dataset
        f(dataset)
    end

gdalsize(dataset) = begin
    band = AG.getband(dataset, 1)
    AG.width(band), AG.height(band), AG.nraster(dataset)
end

gdalmetadata(dataset, key) = begin
    meta = AG.metadata(dataset)
    regex = Regex("$key=(.*)")
    i = findfirst(f -> occursin(regex, f), meta)
    if i isa Nothing
        nothing
    else
        match(regex, meta[i])[1]
    end
end

gdalwrite(filename, A, nbands, indices; compress="DEFLATE", tiled="YES") = begin
    AG.create(filename;
        driver=AG.getdriver("GTiff"),
        width=size(A, 1),
        height=size(A, 2),
        nbands=nbands,
        dtype=eltype(A),
        options=["COMPRESS=$compress", "TILED=$tiled"],
       ) do dataset
        lon, lat = dims(A, (Lon(), Lat()))
        proj = convert(String, crs(mode(dims(A, Lat()))))
        AG.setproj!(dataset, proj)
        AG.setgeotransform!(dataset, build_geotransform(lat, lon))
        AG.write!(dataset, data(A), indices)
    end
    return filename
end

#= Geotranforms ########################################################################

See https://lists.osgeo.org/pipermail/gdal-dev/2011-July/029449.html

"In the particular, but common, case of a “north up” image without any rotation or
shearing, the georeferencing transform takes the following form" :
adfGeoTransform[0] /* top left x */
adfGeoTransform[1] /* w-e pixel resolution */
adfGeoTransform[2] /* 0 */
adfGeoTransform[3] /* top left y */
adfGeoTransform[4] /* 0 */
adfGeoTransform[5] /* n-s pixel resolution (negative value) */
=#

const GDAL_EMPTY_TRANSFORM = [0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
const GDAL_TOPLEFT_X = 1
const GDAL_WE_RES = 2
const GDAL_ROT1 = 3
const GDAL_TOPLEFT_Y = 4
const GDAL_ROT2 = 5
const GDAL_NS_RES = 6

isalligned(geotransform) =
    geotransform[GDAL_ROT1] == 0 && geotransform[GDAL_ROT2] == 0

geotransform_to_affine(gt) = begin
    AffineMap([gt[GDAL_WE_RES] gt[GDAL_ROT1]; gt[GDAL_ROT2] gt[GDAL_NS_RES]],
              [gt[GDAL_TOPLEFT_X], gt[GDAL_TOPLEFT_Y]])
end

# TODO handle Forward/Reverse orders
build_geotransform(lat, lon) = begin
    gt = zeros(6)
    gt[GDAL_TOPLEFT_X] = first(lon)
    gt[GDAL_WE_RES] = step(lon)
    gt[GDAL_ROT1] = 0.0
    gt[GDAL_TOPLEFT_Y] = first(lat)
    gt[GDAL_ROT2] = 0.0
    gt[GDAL_NS_RES] = step(lat)
    return gt
end

