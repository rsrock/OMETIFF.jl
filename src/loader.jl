function load(f::File{format"OMETIFF"})
    open(f) do s
        ret = load(s)
    end
end

function load(io::Stream{format"OMETIFF"})
    if !contains(get(io.filename), ".ome.tif") && !contains(get(io.filename), ".ome.tiff")
        throw(FileIO.LoaderError("OMETIFF", "Not an OME TIFF file!"))
    end

    orig_file = TiffFile(io)
    summary = load_comments(orig_file)

    # load master OME-XML that contains all information about this dataset
    omexml = load_master_xml(orig_file)

    # find all images in this dataset
    images = find(omexml, "/ns:OME/ns:Image",["ns"=>namespace(omexml)])
    results = Array{AxisArray}(length(images))

    pos_names = nodecontent.(find(omexml, "/ns:OME/ns:Image/ns:StageLabel[@Name]/@Name",["ns"=>namespace(omexml)]))
    # if all position names aren't unique then substitute names
    if length(pos_names) == 0 || !allunique(pos_names)
        pos_names = ["Pos$i" for i in 1:length(images)]
    end

    pixels = []
    master_rawtype = Nullable{DataType}()
    mappedtype = Int64
    master_dims = []
    axes_dims = Nullable{Vector{AxisArrays.Axis}}()
    for (idx, image) in enumerate(images)
        pixel = findfirst(image, "./ns:Pixels", ["ns"=>namespace(omexml)])
        dims, axes_info = build_axes(pixel)
        rawtype, mappedtype = type_mapping[pixel["Type"]]

        if isnull(master_rawtype)
            master_rawtype = Nullable(rawtype)
        elseif get(master_rawtype) != rawtype
            throw(FileIO.LoaderError("OMETIFF", "Multiple different storage types not supported in a multi position image"))
        end

        if isnull(axes_dims)
            axes_dims = Nullable(axes_info)
            master_dims = dims
        elseif get(axes_dims) != axes_info
            throw(FileIO.LoaderError("OMETIFF", "Axes changing between multiple imaging positions is not supported yet"))
        end
        push!(pixels, pixel)
    end
    push!(get(axes_dims), Axis{:position}(Symbol.(pos_names)))
    push!(master_dims, length(pos_names))

    data = Array{get(master_rawtype), length(master_dims)}(master_dims...)

    for (pos_idx, pixel) in enumerate(pixels)
        files = Dict{String, TiffFile}()

        tiffdatas = find(pixel, "./ns:TiffData", ["ns"=>namespace(omexml)])

        # TODO: Only the IFDs with a corresponding slice should be loaded.
        slices = DefaultDict{String, Dict{Int, ImageSlice}}(Dict{Int, ImageSlice}())
        for tiffdata in tiffdatas
            slice = read_tiffdata(tiffdata, files, orig_file)
            slices[slice.file.filepath][slice.ifd_idx] = slice
        end

        height, width = master_dims[1:2]

        for (filepath, ifds) in slices
            file = files[filepath]
            for i in sort(collect(keys(ifds)))
                ifd = ifds[i]
                strip_offsets = next(file)

                n_strips = length(strip_offsets)
                strip_len = floor(Int, (width * height) / n_strips)
                read_dims = n_strips > 1 ? (strip_len) : (height, width)

                # TODO: This shouldn't be allocated for each ifd
                tmp = Array{get(master_rawtype)}(read_dims...)
                for j in 1:n_strips
                    seek(file.io, strip_offsets[j])
                    read!(file.io, tmp)
                    tmp = file.need_bswap ? bswap.(tmp) : tmp
                    if n_strips > 1
                        data[j, :, ifd.z_idx, ifd.c_idx, ifd.t_idx, pos_idx]= tmp
                    else
                        data[:, :, ifd.z_idx, ifd.c_idx, ifd.t_idx, pos_idx] = tmp
                    end
                end
            end
        end

        # drop unnecessary axes
        # TODO: Reduce the number of allocations here
    end
    squeezed_data = squeeze(Gray.(reinterpret(mappedtype, data)), (find(master_dims .== 1)...))
    ImageMeta(AxisArray(squeezed_data, get(axes_dims)[master_dims .> 1]...), Summary=summary)
end

"""Corresponding Julian types for OME-XML types"""
type_mapping = Dict(
    "uint8" => (UInt8, N0f8),
    "uint16" => (UInt16, N0f16),
    "uint32" => (UInt32, N0f32),
    "float" => (Float32, Float32),
    "double" => (Float64, Float64),
    "int8" => (Int8, N0f8)
)
