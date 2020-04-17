using GeoData, Test, Statistics, Dates, Plots
using GeoData: name, mode, window
testpath = joinpath(dirname(pathof(GeoData)), "../test/")
include(joinpath(testpath, "test_utils.jl"))

geturl("https://raw.githubusercontent.com/rspatial/raster/master/inst/external/rlogo.grd", "rlogo.grd")
geturl("https://github.com/rspatial/raster/raw/master/inst/external/rlogo.gri", "rlogo.gri")
path = joinpath(testpath, "data/rlogo")
@test isfile(path * ".grd")
@test isfile(path * ".gri")

@testset "array" begin
    grdarray = GeoData.GrdArray(path);
    grdarray |> plot

    @testset "array properties" begin
        @test grdarray isa GrdArray{Float32,3}
    end

    @testset "dimensions" begin
        @test length(val(dims(dims(grdarray), Lon))) == 101
        @test ndims(grdarray) == 3
        @test dims(grdarray) isa Tuple{<:Lon,<:Lat,<:Band}
        @test refdims(grdarray) == ()
        @test bounds(grdarray) == ((0.0, 101.0), (0.0, 77.0), (1, 3))
    end

    @testset "other fields" begin
        @test GeoData.window(grdarray) == ()
        @test missingval(grdarray) == -3.4f38 
        @test metadata(grdarray) isa GrdMetadata
        @test name(grdarray) == "red:green:blue"
    end

    @testset "getindex" begin 
        @test grdarray[Band(1)] isa GeoArray{Float32,2} 
        @test grdarray[Lat(1), Band(1)] isa GeoArray{Float32,1} 
        @test grdarray[Lon(1), Band(1)] isa GeoArray{Float32,1}
        @test grdarray[Lon(1), Lat(1), Band(1)] isa Float32 
        @test grdarray[1, 1, 1] isa Float32
    end

    # @testset "setindex" begin 
    #     A = grdarray[:, :, :]
    #     temp = grdarray[1, 1, 1]
    #     println(temp)
    #     @test temp != 100.0f0
    #     grdarray[1, 1, 1] = 100.0f0
    #     grdarray[:, :, :] = 100.0f0
    #     @test grdarray[1, 1, 1] == 100.0f0
    #     grdarray[1, 1, 1] = temp
    #     @test grdarray[1, 1, 1] == temp
    #     println("sum: ", sum(A .- grdarray[:, :, :]))
    #     temp = grdarray[Lon(20), Lat(10), Band(3)]
    #     println(temp)
    #     @test temp != 200.0f0
    #     grdarray[Lon(20), Lat(10), Band(3)] = 200.0f0
    #     @test grdarray[20, 10, 3] == 200.0f0
    #     grdarray[Lon(20), Lat(10), Band(3)] = temp
    # end

    @testset "selectors" begin
        geoarray = grdarray[Lat(Contains(3)), Lon(:), Band(1)]
        @test geoarray isa GeoArray{Float32,1}
        @test grdarray[Lon(Contains(20)), Lat(Contains(10)), Band(1)] isa Float32
    end

    @testset "conversion to GeoArray" begin
        geoarray = grdarray[Lon(1:50), Lat(1:1), Band(1)]
        @test size(geoarray) == (50, 1)
        @test eltype(geoarray) <: Float32
        @time geoarray isa GeoArray{Float32,1} 
        @test dims(geoarray) isa Tuple{<:Lon,Lat}
        @test refdims(geoarray) isa Tuple{<:Band} 
        @test metadata(geoarray) == metadata(grdarray)
        @test missingval(geoarray) == -3.4f38
        @test name(geoarray) == "red:green:blue"
    end

    @testset "save" begin
        # TODO save and load subset
        geoarray = GeoArray(grdarray)
        filename = tempname()
        write(filename, GrdArray, geoarray)
        saved = GeoArray(GrdArray(filename))
        @test size(saved) == size(geoarray)
        @test refdims(saved) == ()
        @test bounds(saved) == bounds(geoarray)
        @test size(saved) == size(geoarray)
        @test missingval(saved) === missingval(geoarray)
        @test metadata(saved) != metadata(geoarray)
        @test metadata(saved)["creator"] == "GeoData.jl"
        @test all(metadata.(dims(saved)) .== metadata.(dims(geoarray)))
        @test name(saved) == name(geoarray)
        @test all(mode.(dims(saved)) .== mode.(dims(geoarray)))
        @test dims(saved) isa typeof(dims(geoarray))
        @test all(val.(dims(saved)) .== val.(dims(geoarray)))
        @test all(mode.(dims(saved)) .== mode.(dims(geoarray)))
        @test all(metadata.(dims(saved)) .== metadata.(dims(geoarray)))
        @test dims(saved) == dims(geoarray)
        @test all(data(saved) .=== data(geoarray))
        @test saved isa typeof(geoarray)
        @test data(saved) == data(grdarray)
        # 2d array. 1 bands is added again on save
        filename2 = tempname()
        write(filename2, GrdArray, grdarray[Band(1)])
        saved = GeoArray(GrdArray(filename2))
        @test size(saved) == size(grdarray[Band(1:1)])
        @test data(saved) == data(grdarray[Band(1:1)])
    end

    @testset "plot" begin
        p = grdarray |> plot
    end

end

@testset "stack" begin
    grdstack = GrdStack((a=path, b=path))

    @testset "indexing" begin
        @test grdstack[:a][Lat(1), Lon(1), Band(1)] == 255.0f0
        @test grdstack[:a][Lat([2,3]), Lon(1), Band(1)] == [255.0f0, 255.0f0] 
    end

    @testset "child array properties" begin
        @test size(grdstack[:a]) == size(GeoArray(grdstack[:a])) == (101, 77, 3)
        @test grdstack[:a] isa GrdArray{Float32,3}
    end

    @testset "window" begin
        windowedstack = GrdStack((a=path, b=path); window=(Lat(1:5), Lon(1:5), Band(1)))
        @test window(windowedstack) == (Lat(1:5), Lon(1:5), Band(1))
        windowedarray = GeoArray(windowedstack[:a])
        @test windowedarray isa GeoArray{Float32,2}
        @test length.(dims(windowedarray)) == (5, 5)
        @test size(windowedarray) == (5, 5)
        @test windowedarray[1:3, 2:2] == reshape([255.0f0, 255.0f0, 255.0f0], 3, 1)
        @test windowedarray[1:3, 2] == [255.0f0, 255.0f0, 255.0f0]
        @test windowedarray[1, 2] == 255.0f0
        windowedstack = GrdStack((a=path, b=path); window=(Lat(1:5), Lon(1:5), Band(1:1)))
        windowedarray = windowedstack[:b]
        @test windowedarray[1:3, 2:2, 1:1] == reshape([255.0f0, 255.0f0, 255.0f0], 3, 1, 1)
        @test windowedarray[1:3, 2:2, 1] == reshape([255.0f0, 255.0f0, 255.0f0], 3, 1)
        @test windowedarray[1:3, 2, 1] == [255.0f0, 255.0f0, 255.0f0]
        @test windowedarray[1, 2, 1] == 255.0f0
        windowedstack = GrdStack((a=path, b=path); window=Band(1))
        windowedarray = GeoArray(windowedstack[:b])
        @test windowedarray[1:3, 2:2] == reshape([255.0f0, 255.0f0, 255.0f0], 3, 1)
        @test windowedarray[1:3, 2] == [255.0f0, 255.0f0, 255.0f0]
        @test windowedarray[1, 2] == 255.0f0
    end

    # Stack Constructors
    @testset "conversion to GeoStack" begin
        stack = GeoStack(grdstack)
        @test Symbol.(Tuple(keys(grdstack))) == keys(stack)
        smallstack = GeoStack(grdstack; keys=(:a,))
        @test keys(smallstack) == (:a,)
    end

    if VERSION > v"1.1-"
        @testset "copy" begin
            geoarray = zero(GeoArray(grdstack[:a]))
            copy!(geoarray, grdstack, :a)
            # First wrap with GeoArray() here or == loads from disk for each cell.
            # we need a general way of avoiding this in all disk-based sources
            @test geoarray == GeoArray(grdstack[:a])
        end
    end

    @testset "save" begin
        geoarray = GeoArray(grdstack[:b])
        filename = tempname()
        write(filename, GrdArray, grdstack)
        base, ext = splitext(filename)
        filename_b = string(base, "_b", ext)
        saved = GeoArray(GrdArray(filename_b))
        @test sum(saved) == sum(geoarray)
        saved[3, 1, 1]
        findmin(geoarray)
        findmin(saved)
        data(saved) == data(geoarray)
    end

end

nothing
