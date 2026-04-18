import "base:internal"
import "base:intrinsics"
import "base:mem"
import "base:container/str"
import "base:container/slice"
import "base:container/dyn_array"
import "base:strconv"

import "core:encoding/base64"
import "core:encoding/json"
import "core:os"
import "core:strings_tools"


GLB_MAGIC :: 0x46546c67
GLB_HEADER_SIZE       :: size_of(GLB_Header)
GLB_CHUNK_HEADER_SIZE :: size_of(GLB_Chunk_Header)
GLTF_MIN_VERSION :: 2


/* 
Fix to avoid using core:path/filepath
*/
dir :: proc(path: string, allocator: mem.Allocator) -> (dirs: string) {
    path_trimmed := path
    last_char := len(path) - 1
    if path[last_char] == '/' {
        path_trimmed = path[:last_char]
    }
    dirs_slice, _ := strings_tools.split(path_trimmed, "/", allocator)
    last := dirs_slice[len(dirs_slice) - 1]
    return strings_tools.trim_suffix(path_trimmed, last)
}
ext :: proc(path: string) -> string {
    for i := len(path)-1; i >= 0 && (path[i] != '/'); i -= 1 {
        if path[i] == '.' {
            return path[i:]
        }
    }
    return ""
}



/*
    Main library interface procedures
*/

load_from_file :: proc(file_name: string, allocator: mem.Allocator) -> (data: ^Data, err: Error) {
    if !os.exists(file_name) {
        return nil, GLTF_Error{type = .No_File, proc_name = #procedure, param = {name = file_name}}
    }

    file_content, read_err := os.read_entire_file_from_path(file_name, allocator)
    if read_err != nil {
        return nil, GLTF_Error{type = .Cant_Read_File, proc_name = #procedure, param = {name = file_name}}
    }

    gltf_dir := dir(file_name, allocator)

    options := Options{
        delete_content = true,
        gltf_dir       = gltf_dir,
    }
    new_file_name: str.String(32)
    _ = str.set(&new_file_name, ext(file_name))
    strings_tools.to_lower(&new_file_name)
    switch str.str(&new_file_name) {
    case ".gltf":
        return parse(file_content, options, allocator)
    case ".glb":
        options.is_glb = true
        return parse(file_content, options, allocator)
    case:
        return nil, GLTF_Error{type = .Unknown_File_Type, proc_name = #procedure, param = {name = file_name}}
    }
}


parse :: proc(file_content: []u8, opt := Options{}, allocator: mem.Allocator) -> (data: ^Data, err: Error) {
    if len(file_content) < GLB_HEADER_SIZE {
        return data, GLTF_Error{type = .Data_Too_Short, proc_name = #procedure}
    }

    data, _ = mem.new(Data, allocator)

    json_data := file_content
    content_index: u32

    if opt.is_glb {
        header := (cast(^GLB_Header)(raw_data(file_content[:GLB_HEADER_SIZE])))
        content_index += u32(GLB_HEADER_SIZE)

        switch {
        case header.magic != GLB_MAGIC:
            return data, GLTF_Error{type = .Bad_GLB_Magic, proc_name = #procedure}
        case header.version < GLTF_MIN_VERSION:
            return data, GLTF_Error{type = .Unsupported_Version, proc_name = #procedure}
        }

        // GLB file format expects 1 JSON chunk right after header
        json_header := (cast(^GLB_Chunk_Header)(raw_data(file_content[content_index:content_index + u32(GLB_CHUNK_HEADER_SIZE)])))
        if json_header.type != CHUNK_TYPE_JSON {
            return data, GLTF_Error{type = .Wrong_Chunk_Type, proc_name = #procedure, param = {name = "JSON Chunk"}}
        }

        content_index += u32(GLB_CHUNK_HEADER_SIZE)
        json_data = file_content[content_index:content_index + u32(json_header.length)]
        content_index += u32(json_header.length)
    }

    json_parser := json.parser_create(json_data, allocator = allocator)
    parsed_object, json_err := json.parse_object(&json_parser)
    data.json_value = parsed_object
    if json_err != .None && json_err != .EOF {
        return data, JSON_Error{type = json_err, parser = json_parser}
    }

    data.asset        = asset_parse(parsed_object.(json.Object)) or_return
    data.accessors    = accessors_parse(parsed_object.(json.Object),    allocator) or_return
    data.animations   = animations_parse(parsed_object.(json.Object),   allocator) or_return
    data.buffers      = buffers_parse(parsed_object.(json.Object), opt.gltf_dir, allocator) or_return
    data.buffer_views = buffer_views_parse(parsed_object.(json.Object), allocator) or_return
    data.cameras      = cameras_parse(parsed_object.(json.Object),      allocator) or_return
    data.images       = images_parse(parsed_object.(json.Object), opt.gltf_dir, allocator) or_return
    data.materials    = materials_parse(parsed_object.(json.Object),    allocator) or_return
    data.meshes       = meshes_parse(parsed_object.(json.Object),       allocator) or_return
    data.nodes        = nodes_parse(parsed_object.(json.Object),        allocator) or_return
    data.samplers     = samplers_parse(parsed_object.(json.Object),     allocator) or_return
    if scene, ok := parsed_object.(json.Object)[SCENE_KEY]; ok {
        data.scene = Unsigned_Integer(scene.(f64))
    }
    data.scenes       = scenes_parse(parsed_object.(json.Object),      allocator) or_return
    data.skins        = skins_parse(parsed_object.(json.Object),       allocator) or_return
    data.textures     = textures_parse(parsed_object.(json.Object),    allocator) or_return
    data.extensions_used     = extensions_names_parse(parsed_object.(json.Object), EXTENSIONS_USED_KEY,     allocator)
    data.extensions_required = extensions_names_parse(parsed_object.(json.Object), EXTENSIONS_REQUIRED_KEY, allocator)
    if extensions, ok := parsed_object.(json.Object)[EXTENSIONS_KEY]; ok {
        data.extensions = extensions
    }
    if extras, ok := parsed_object.(json.Object)[EXTRAS_KEY]; ok {
        data.extras = extras
    }

    // Load remaining binary chunks.
    for buf_idx: uint; opt.is_glb && buf_idx < len(data.buffers) && uint(content_index) < len(file_content); buf_idx += 1 {
        chunk_header := (cast(^GLB_Chunk_Header)(raw_data(file_content[content_index:content_index + u32(GLB_CHUNK_HEADER_SIZE)])))
        content_index += u32(GLB_CHUNK_HEADER_SIZE)

        data.buffers[buf_idx].uri, _ = slice.create(u8, uint(chunk_header.length), allocator)
        intrinsics.mem_copy(raw_data(data.buffers[buf_idx].uri.([]u8)), raw_data(file_content[content_index:]), int(chunk_header.length))
        content_index += u32(chunk_header.length)
    }

    return data, nil
}

/*
    Utilitiy procedures
*/

extensions_names_parse :: proc(object: json.Object, name: string, allocator: mem.Allocator) -> (res: []string) {
    if name not_in object {
        return
    }

    name_array := object[name].(json.Array)
    res, _ = slice.create(string, name_array.len, allocator)

    for n, i in dyn_array.slice(name_array) {
        res[i] = n.(string)
    }

    return res
}


uri_parse :: proc(uri: Uri, gltf_dir: string, allocator: mem.Allocator) -> Uri {
    if uri == nil {
        return uri
    }
    if _, ok := uri.([]u8); ok {
        return uri
    }

    str_data := uri.(string)
    type_idx, found := strings_tools.index_rune(str_data, ':')
    if !found {
        // Check if this is possible file and if so load it
        s: str.String(64)
        internal.assert(str.setf(&s, "%/%", gltf_dir, str_data))
        bytes, err := os.read_entire_file_from_path(str.str(&s), allocator)
        if err != nil {
            return uri
        }
        return cast([]u8)bytes
    }

    type := str_data[:type_idx]
    switch type {
    case "data":
        encoding_start_idx, start_found := strings_tools.index_rune(str_data, ';')
        if !start_found {
            return uri
        }
        encoding_end_idx, end_found := strings_tools.index_rune(str_data, ',')
        if !end_found {
            return uri
        }

        encoding := str_data[encoding_start_idx + 1:encoding_end_idx]

        switch encoding {
        case "base64":
            // internal.assert(base64.decode(str_data[encoding_end_idx + 1:]))
            // return dec
            os.panic("Not implemented yet")
        }
    }

    return uri
}


@(private)
warning_unexpected_data :: proc(proc_name, key: string, val: json.Value, idx: uint = 0) {
    os.printfln("WARNING: Unexpected data in proc: % at index: %\nKey: %, value: %", proc_name, str.from_uint(idx), key, str.from_union(val))
}

/*
    Asseet parsing
*/

asset_parse :: proc(object: json.Object) -> (res: Asset, err: Error) {
    if ASSET_KEY not_in object {
        return res, GLTF_Error{type = .JSON_Missing_Section, proc_name = #procedure, param = {name = ASSET_KEY}}
    }

    version_found: bool

    for k, v in object[ASSET_KEY].(json.Object) {
        switch k {
        case "copyright":
            res.copyright = v.(string)

        case "generator":
            res.generator = v.(string)

        case "version":
            // Required
            version, ok := strconv.parse_f64(v.(string))
            if !ok {
                return res, GLTF_Error{type = .Invalid_Type, proc_name = #procedure, param = {name = "version"}}
            }
            res.version = Number(version)
            version_found = true

        case "minVersion":
            version, ok := strconv.parse_f64(v.(string))
            if !ok {
                continue
            }
            res.min_version = Number(version)

        case EXTENSIONS_KEY:
            res.extensions = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !version_found {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "version"}}
    } else if res.version > GLTF_MIN_VERSION {
        return res, GLTF_Error{type = .Unsupported_Version, proc_name = #procedure}
    }
    return res, nil
}

/*
    Accessors parsing
*/

accessors_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Accessor, err: Error) {
    if ACCESSORS_KEY not_in object {
        return
    }

    accessor_array := object[ACCESSORS_KEY].(json.Array)
    res, _ = slice.create(Accessor, accessor_array.len, allocator)

    for access, idx in dyn_array.slice(accessor_array) {
        component_type_set, count_set, type_set: bool

        for k, v in access.(json.Object) {
            switch k {
            case "bufferView":
                res[idx].buffer_view = Unsigned_Integer(v.(f64))

            case "byteOffset":
                res[idx].byte_offset = Unsigned_Integer(v.(f64))

            case "componentType":
                // Required
                res[idx].component_type = Component_Type(v.(f64))
                component_type_set = true

            case "normalized":
                res[idx].normalized = v.(bool)

            case "count":
                // Required
                res[idx].count = Unsigned_Integer(v.(f64))
                count_set = true

            case "type":
                // Required
                switch v.(string) {
                case "SCALAR":
                    res[idx].type = .Scalar
                    type_set = true

                case "VEC2":
                    res[idx].type = .Vector2
                    type_set = true

                case "VEC3":
                    res[idx].type = .Vector3
                    type_set = true

                case "VEC4":
                    res[idx].type = .Vector4
                    type_set = true

                case "MAT2":
                    res[idx].type = .Matrix2
                    type_set = true

                case "MAT3":
                    res[idx].type = .Matrix3
                    type_set = true

                case "MAT4":
                    res[idx].type = .Matrix4
                    type_set = true

                case:
                    return res,
                        GLTF_Error{type = .Invalid_Type, proc_name = #procedure, param = {name = v.(string), index = idx}}
                }

            case "max":
                max: [16]Number
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    max[i] = Number(num.(f64))
                }
                res[idx].max = max

            case "min":
                min: [16]Number
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    min[i] = Number(num.(f64))
                }
                res[idx].min = min

            case "sparse":
                res[idx].sparse = accessor_sparse_parse(v.(json.Object), allocator) or_return

            case "name":
                res[idx].name = v.(string)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if !component_type_set {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "componentType", index = idx},
                }
        }
        if !count_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "count", index = idx}}
        }
        if !type_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "type", index = idx}}
        }
    }

    return res, nil
}



accessor_sparse_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: Accessor_Sparse, err: Error) {
    for k, v in object {
        switch k {
        case "count": // Not used by this implementation
        case "indices":
            // Required
            res.indices = sparse_indices_parse(v.(json.Array), allocator) or_return

        case "values":
            // Required
            res.values = sparse_values_parse(v.(json.Array), allocator) or_return

        case EXTENSIONS_KEY:
            res.extensions = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if len(res.indices) == 0 {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "indices"}}
    }
    if len(res.values) == 0 {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "values"}}
    }

    return res, nil
}


sparse_indices_parse :: proc(array: json.Array, allocator: mem.Allocator) -> (res: []Accessor_Sparse_Indices, err: Error) {
    res, _ = slice.create(Accessor_Sparse_Indices, array.len, allocator)

    for index, idx in array.data[:array.len] {
        buffer_view_set, component_type_set: bool

        for k, v in index.(json.Object) {
            switch k {
            case "bufferView":
                // Required
                res[idx].buffer_view = Unsigned_Integer(v.(f64))
                buffer_view_set = true

            case "byteOffset":
                // Default 0
                res[idx].byte_offset = Unsigned_Integer(v.(f64))

            case "componentType":
                // Required
                res[idx].component_type = Component_Type(v.(f64))
                component_type_set = true

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if !buffer_view_set {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "bufferView", index = idx},
                }
        }
        if !component_type_set {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "componentType", index = idx},
                }
        }
    }

    return res, nil
}


sparse_values_parse :: proc(array: json.Array, allocator: mem.Allocator) -> (res: []Accessor_Sparse_Values, err: Error) {
    res, _ = slice.create(Accessor_Sparse_Values, array.len, allocator)

    for value, idx in array.data[:array.len] {
        buffer_view_set: bool

        for k, v in value.(json.Object) {
            switch k {
            case "bufferView":
                // Required
                res[idx].buffer_view = Unsigned_Integer(v.(f64))
                buffer_view_set = true

            case "byteOffset":
                // Defalt 0
                res[idx].byte_offset = Unsigned_Integer(v.(f64))

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if !buffer_view_set {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "bufferView", index = idx},
                }
        }
    }

    return res, nil
}

/*
    Animations parsing
*/

animations_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Animation, err: Error) {
    if ANIMATIONS_KEY not_in object {
        return
    }

    animations_array := object[ANIMATIONS_KEY].(json.Array)
    res, _ = slice.create(Animation, animations_array.len, allocator)

    for animation, idx in dyn_array.slice(animations_array) {
        for k, v in animation.(json.Object) {
            switch k {
            case "channels":
                // Required
                res[idx].channels = animation_channels_parse(v.(json.Array), allocator) or_return

            case "samplers":
                // Required
                res[idx].samplers = animation_samplers_parse(v.(json.Array), allocator) or_return

            case "name":
                res[idx].name = v.(string)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if len(res[idx].channels) == 0 {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "channels", index = idx}}
        }
        if len(res[idx].samplers) == 0 {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "samplers", index = idx}}
        }
    }
    return res, nil
}


animation_channels_parse :: proc(array: json.Array, allocator: mem.Allocator) -> (res: []Animation_Channel, err: Error) {
    res, _ = slice.create(Animation_Channel, array.len, allocator)

    for channel, idx in array.data[:array.len] {
        sampler_set, target_set: bool

        for k, v in channel.(json.Object) {
            switch k {
            case "sampler":
                // Required
                res[idx].sampler = Unsigned_Integer(v.(f64))
                sampler_set = true

            case "target":
                // Required
                res[idx].target = animation_channel_target_parse(v.(json.Object)) or_return
                target_set = true

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if !sampler_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "sampler", index = idx}}
        }
        if !target_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "target", index = idx}}
        }
    }

    return res, nil
}


animation_channel_target_parse :: proc(object: json.Object) -> (res: Animation_Channel_Target, err: Error) {
    path_set: bool

    for k, v in object {
        switch k {
        case "node":
            res.node = Unsigned_Integer(v.(f64))

        case "path":
            // Required
            if path, ok := v.(string); ok {
                path_set = true
                switch path {
                case "translation":
                    res.path = .Translation
                case "rotation":
                    res.path = .Rotation
                case "scale":
                    res.path = .Scale
                case "weights":
                    res.path = .Weights
                case:
                    path_set = false
                }
            }

        case EXTENSIONS_KEY:
            res.extensions = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !path_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "path"}}
    }

    return res, nil
}


animation_samplers_parse :: proc(array: json.Array, allocator: mem.Allocator) -> (res: []Animation_Sampler, err: Error) {
    res, _ = slice.create(Animation_Sampler, array.len, allocator)

    for sampler, idx in array.data[:array.len] {
        input_set, output_set: bool

        for k, v in sampler.(json.Object) {
            switch k {
            case "input":
                // Required
                res[idx].input = Unsigned_Integer(v.(f64))
                input_set = true

            case "interpolation":
                // Defalt Linear(0)
                switch v.(string) {
                case "LINEAR":
                    res[idx].interpolation = .Linear
                case "STEP":
                    res[idx].interpolation = .Step
                case "CUBICSPLINE":
                    res[idx].interpolation = .Cubic_Spline
                case:
                    return res,
                        GLTF_Error{type = .Invalid_Type, proc_name = #procedure, param = {name = v.(string), index = idx}}
                }

            case "output":
                // Required
                res[idx].output = Unsigned_Integer(v.(f64))
                output_set = true

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v)
            }
        }

        if !input_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "input", index = idx}}
        }
        if !output_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "output", index = idx}}
        }
    }
    return res, nil
}

/*
    Buffers parsing
*/

buffers_parse :: proc(object: json.Object, gltf_dir: string, allocator: mem.Allocator) -> (res: []Buffer, err: Error) {
    if BUFFERS_KEY not_in object {
        return
    }

    buffers_array := object[BUFFERS_KEY].(json.Array)
    res, _ = slice.create(Buffer, buffers_array.len, allocator)

    for buffer, idx in dyn_array.slice(buffers_array) {
        byte_length_set: bool

        for k, v in buffer.(json.Object) {
            switch k {
            case "byteLength":
                // Required
                res[idx].byte_length = Unsigned_Integer(v.(f64))
                byte_length_set = true

            case "name":
                res[idx].name = v.(string)

            case "uri":
                res[idx].uri = uri_parse(v.(string), gltf_dir, allocator)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if !byte_length_set {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "byteLength", index = idx},
                }
        }
    }

    return res, nil
}

/*
    Buffer Views parsing
*/

buffer_views_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Buffer_View, err: Error) {
    if BUFFER_VIEWS_KEY not_in object {
        return
    }

    views_array := object[BUFFER_VIEWS_KEY].(json.Array)
    res, _ = slice.create(Buffer_View, views_array.len, allocator)

    for view, idx in dyn_array.slice(views_array) {
        buffer_set, byte_length_set: bool

        for k, v in view.(json.Object) {
            switch k {
            case "buffer":
                // Required
                res[idx].buffer = Unsigned_Integer(v.(f64))
                buffer_set = true

            case "byteLength":
                // Required
                res[idx].byte_length = Unsigned_Integer(v.(f64))
                byte_length_set = true

            case "byteOffset":
                res[idx].byte_offset = Unsigned_Integer(v.(f64))

            case "byteStride":
                res[idx].byte_stride = Unsigned_Integer(v.(f64))

            case "name":
                res[idx].name = v.(string)

            case "target":
                res[idx].target = Buffer_Type_Hint(v.(f64))

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if !buffer_set {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "buffer", index = idx}}
        }
        if !byte_length_set {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "byteLength", index = idx},
                }
        }
    }

    return res, nil
}

/*
    Cameras parsing
*/

cameras_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Camera, err: Error) {
    if CAMERAS_KEY not_in object {
        return
    }

    cameras_array := object[CAMERAS_KEY].(json.Array)
    res, _ = slice.create(Camera, cameras_array.len, allocator)

    for camera, idx in dyn_array.slice(cameras_array) {
        for k, v in camera.(json.Object) {
            switch k {
            case "name":
                res[idx].name = v.(string)

            case "type": // Required and not used here. Camera.type is union that can contain only:
            // Orthographic_Camera or Perspective_Camera struct
            case "orthographic":
                res[idx].type = orthographic_camera_parse(v.(json.Object)) or_return

            case "perspective":
                res[idx].type = perspective_camera_parse(v.(json.Object)) or_return

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if res[idx].type == nil {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "type", index = idx}}
        }
    }

    return res, nil
}



orthographic_camera_parse :: proc(object: json.Object) -> (res: Orthographic_Camera, err: Error) {
    xmag_set, ymag_set, zfar_set, znear_set: bool

    for k, v in object {
        switch k {
        case "xmag":
            // Required
            res.xmag = Number(v.(f64))
            xmag_set = true

        case "ymag":
            // Required
            res.ymag = Number(v.(f64))
            ymag_set = true

        case "zfar":
            // Required
            res.zfar = Number(v.(f64))
            zfar_set = true

        case "znear":
            // Required
            res.znear = Number(v.(f64))
            znear_set = true

        case EXTENSIONS_KEY:
            res.extensions = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !xmag_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "xmag"}}
    }
    if !ymag_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "ymag"}}
    }
    if !zfar_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "zfar"}}
    }
    if !znear_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "znear"}}
    }

    return res, nil
}


perspective_camera_parse :: proc(object: json.Object) -> (res: Perspective_Camera, err: Error) {
    yfov_set, znear_set: bool

    for k, v in object {
        switch k {
        case "aspectRatio":
            res.aspect_ratio = Number(v.(f64))

        case "yfov":
            // Required
            res.yfov = Number(v.(f64))
            yfov_set = true

        case "zfar":
            res.zfar = Number(v.(f64))

        case "znear":
            // Required
            res.znear = Number(v.(f64))
            znear_set = true

        case EXTENSIONS_KEY:
            res.extensions = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !yfov_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "yfov"}}
    }
    if !znear_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "znear"}}
    }

    return res, nil
}

/*
    Images parsing
*/

images_parse :: proc(object: json.Object, gltf_dir: string, allocator: mem.Allocator) -> (res: []Image, err: Error) {
    if IMAGES_KEY not_in object {
        return
    }

    images_array := object[IMAGES_KEY].(json.Array)
    res, _ = slice.create(Image, images_array.len, allocator)

    for image, idx in dyn_array.slice(images_array) {
        for k, v in image.(json.Object) {
            switch k {
            case "bufferView":
                res[idx].buffer_view = Unsigned_Integer(v.(f64))

            case "mimeType":
                switch v.(string) {
                case "image/jpeg":
                    res[idx].type = .JPEG
                case "image/png":
                    res[idx].type = .PNG
                case:
                    return res,
                        GLTF_Error{type = .Unknown_File_Type, proc_name = #procedure, param = {name = v.(string), index = idx}}
                }

            case "name":
                res[idx].name = v.(string)

            case "uri":
                // res[idx].uri = uri_parse(v.(string), gltf_dir)
                res[idx].uri = v.(string)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }
    }

    return res, nil
}

/*
    Materials parsing
*/

materials_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Material, err: Error) {
    if MATERIALS_KEY not_in object {
        return
    }

    materials_array := object[MATERIALS_KEY].(json.Array)
    res, _ = slice.create(Material, materials_array.len, allocator)

    for material, idx in dyn_array.slice(materials_array) {
        res[idx].alpha_cutoff = 0.5

        for k, v in material.(json.Object) {
            switch k {
            case "alphaMode":
                // Default Opaque
                switch v.(string) {
                case "OPAQUE":
                    res[idx].alpha_mode = .Opaque
                case "MASK":
                    res[idx].alpha_mode = .Mask
                case "BLEND":
                    res[idx].alpha_mode = .Blend
                case:
                    return res,
                        GLTF_Error{type = .Invalid_Type, proc_name = #procedure, param = {name = v.(string), index = idx}}
                }

            case "alphaCutoff":
                // Default 0.5
                res[idx].alpha_cutoff = Number(v.(f64))

            case "doubleSided":
                // Default false
                res[idx].double_sided = v.(bool)

            case "emissiveFactor":
                // Default [0, 0, 0]
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    res[idx].emissive_factor[i] = Number(num.(f64))
                }

            case "emissiveTexture":
                res[idx].emissive_texture = texture_info_parse(v.(json.Object)) or_return

            case "name":
                res[idx].name = v.(string)

            case "normalTexture":
                res[idx].normal_texture = normal_texture_info_parse(v.(json.Object)) or_return

            case "occlusionTexture":
                res[idx].occlusion_texture = occlusion_texture_info_parse(v.(json.Object)) or_return

            case "pbrMetallicRoughness":
                res[idx].metallic_roughness = pbr_metallic_roughness_parse(v.(json.Object)) or_return

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }
    }
    return res, nil
}



normal_texture_info_parse :: proc(object: json.Object) -> (res: Material_Normal_Texture_Info, err: Error) {
    index_set: bool
    res.scale = 1

    for k, v in object {
        switch k {
        case "index":
            // Required
            res.index = Unsigned_Integer(v.(f64))
            index_set = true

        case "texCoord":
            // Default 0
            res.tex_coord = Unsigned_Integer(v.(f64))

        case "scale":
            // Default 1
            res.scale = Number(v.(f64))

        case EXTENSIONS_KEY:
            res.extras = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !index_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "index"}}
    }

    return res, nil
}


occlusion_texture_info_parse :: proc(object: json.Object) -> (res: Material_Occlusion_Texture_Info, err: Error) {
    index_set: bool
    res.strength = 1

    for k, v in object {
        switch k {
        case "index":
            // Required
            res.index = Unsigned_Integer(v.(f64))
            index_set = true

        case "texCoord":
            // Default 0
            res.tex_coord = Unsigned_Integer(v.(f64))

        case "strength":
            // Default 1
            res.strength = Number(v.(f64))

        case EXTENSIONS_KEY:
            res.extras = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !index_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "index"}}
    }

    return res, nil
}


pbr_metallic_roughness_parse :: proc(object: json.Object) -> (res: Material_Metallic_Roughness, err: Error) {
    res.base_color_factor = {1, 1, 1, 1}
    res.metallic_factor  = 1
    res.roughness_factor = 1

    for k, v in object {
        switch k {
        case "baseColorFactor":
            // Default [ 1, 1, 1, 1 ]
            dyn_arr := v.(json.Array)
            for num, i in dyn_array.slice(dyn_arr) {
                res.base_color_factor[i] = Number(num.(f64))
            }

        case "baseColorTexture":
            res.base_color_texture = texture_info_parse(v.(json.Object)) or_return

        case "metallicFactor":
            // Default 1
            res.metallic_factor = Number(v.(f64))

        case "roughnessFactor":
            // Default 1
            res.roughness_factor = Number(v.(f64))

        case "metallicRoughnessTexture":
            res.metallic_roughness_texture = texture_info_parse(v.(json.Object)) or_return

        case EXTENSIONS_KEY:
            res.extras = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    return res, nil
}

/*
    Meshes parsing
*/

meshes_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Mesh, err: Error) {
    if MESHES_KEY not_in object {
        return
    }

    meshes_array := object[MESHES_KEY].(json.Array)
    res, _ = slice.create(Mesh, meshes_array.len, allocator)

    for mesh, idx in dyn_array.slice(meshes_array) {
        for k, v in mesh.(json.Object) {
            switch k {
            case "name":
                res[idx].name = v.(string)

            case "primitives":
                // Required
                res[idx].primitives = mesh_primitives_parse(v.(json.Array), allocator) or_return

            case "weights":
                res[idx].weights, _ = slice.create(Number, (v.(json.Array)).len, allocator)
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    res[idx].weights[i] = Number(num.(f64))
                }

            case EXTENSIONS_KEY:
                res[idx].extras = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if len(res[idx].primitives) == 0 {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "primitives", index = idx},
                }
        }
    }
    return res, nil
}


mesh_primitives_parse :: proc(array: json.Array, allocator: mem.Allocator) -> (res: []Mesh_Primitive, err: Error) {
    res, _ = slice.create(Mesh_Primitive, array.len, allocator)

    for primitive, idx in array.data[:array.len] {
        res[idx].mode = .Triangles

        for key, val in primitive.(json.Object) {
            switch key {
            case "attributes":
                // Required
                for k, v in val.(json.Object) {
                    res[idx].attributes[k] = Unsigned_Integer(v.(f64))
                }

            case "indices":
                res[idx].indices = Unsigned_Integer(val.(f64))

            case "material":
                res[idx].material = Unsigned_Integer(val.(f64))

            case "mode":
                // Default Triangles(4)
                res[idx].mode = Mesh_Primitive_Mode(val.(f64))

            case "targets":
                res[idx].targets = mesh_targets_parse(val.(json.Object)) or_return

            case EXTENSIONS_KEY:
                res[idx].extensions = val

            case EXTRAS_KEY:
                res[idx].extras = val

            case:
                warning_unexpected_data(#procedure, key, val, idx)
            }
        }

        if len(res[idx].attributes) == 0 {
            return res,
                GLTF_Error {
                    type = .Missing_Required_Parameter,
                    proc_name = #procedure,
                    param = {name = "attributes", index = idx},
                }
        }
    }

    return res, nil
}



mesh_targets_parse :: proc(object: json.Object) -> (res: []Mesh_Target, err: Error) {
    internal.unimplemented(#procedure)
}

/*
    Nodes parsing
*/

nodes_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Node, err: Error) {
    if NODES_KEY not_in object {
        return
    }

    nodes_array := object[NODES_KEY].(json.Array)
    res, _ = slice.create(Node, nodes_array.len, allocator)

    for node, idx in dyn_array.slice(nodes_array) {
        res[idx].mat = Matrix4(1)
        res[idx].rotation = Quaternion(1)
        res[idx].scale = {1, 1, 1}

        for k, v in node.(json.Object) {
            switch k {
            case "camera":
                res[idx].camera = Unsigned_Integer(v.(f64))

            case "children":
                res[idx].children, _ = slice.create(Unsigned_Integer, (v.(json.Array)).len, allocator)
                dyn_arr := v.(json.Array)
                for child, i in dyn_array.slice(dyn_arr) {
                    res[idx].children[i] = Unsigned_Integer(child.(f64))
                }

            case "matrix":
                // Default identity matrix
                // Matrices are stored in column-major order. Odin matrices are indexed like this [row, col]
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    res[idx].mat[i % 4, i / 4] = Number(num.(f64))
                }

            case "mesh":
                res[idx].mesh = Unsigned_Integer(v.(f64))

            case "name":
                res[idx].name = v.(string)

            case "scale":
                // Default [1, 1, 1]
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    res[idx].scale[i] = Number(num.(f64))
                }

            case "skin":
                res[idx].skin = Unsigned_Integer(v.(f64))

            case "rotation":
                // Default [0, 0, 0, 1]
                rotation: [4]Number

                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    rotation[i] = Number(num.(f64))
                }
                intrinsics.mem_copy(&res[idx].rotation, &rotation, size_of(Quaternion))

            case "translation":
                // Defalt [0, 0, 0]
                dyn_arr := v.(json.Array)
                for num, i in dyn_array.slice(dyn_arr) {
                    res[idx].translation[i] = Number(num.(f64))
                }

            case "weights":
                res[idx].weights, _ = slice.create(Number, (v.(json.Array)).len, allocator)
                dyn_arr := v.(json.Array)
                for weight, i in dyn_array.slice(dyn_arr) {
                    res[idx].weights[i] = Number(weight.(f64))
                }

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }
    }
    return res, nil
}

/*
    Samplers parsing
*/

samplers_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Sampler, err: Error) {
    if SAMPLERS_KEY not_in object {
        return
    }

    samplers_array := object[SAMPLERS_KEY].(json.Array)
    res, _ = slice.create(Sampler, samplers_array.len, allocator)

    for sampler, idx in dyn_array.slice(samplers_array) {
        res[idx].wrapS = .Repeat
        res[idx].wrapT = .Repeat

        for k, v in sampler.(json.Object) {
            switch k {
            case "magFilter":
                res[idx].mag_filter = Magnification_Filter(v.(f64))

            case "minFilter":
                res[idx].min_filter = Minification_Filter(v.(f64))

            case "wrapS":
                // Default Repeat(10497)
                res[idx].wrapS = Wrap_Mode(v.(f64))

            case "wrapT":
                // Default Repeat(10497)
                res[idx].wrapT = Wrap_Mode(v.(f64))

            case "name":
                res[idx].name = v.(string)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }
    }
    return res, nil
}

/*
    Scenes parsing
*/

scenes_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Scene, err: Error) {
    if SCENES_KEY not_in object {
        return
    }

    scenes_array := object[SCENES_KEY].(json.Array)
    res, _ = slice.create(Scene, scenes_array.len, allocator)

    for scene, idx in dyn_array.slice(scenes_array) {
        for k, v in scene.(json.Object) {
            switch k {
            case "nodes":
                res[idx].nodes, _ = slice.create(Unsigned_Integer, (v.(json.Array)).len, allocator)
                dyn_arr := v.(json.Array)
                for node, i in dyn_array.slice(dyn_arr) {
                    res[idx].nodes[i] = Unsigned_Integer(node.(f64))
                }

            case "name":
                res[idx].name = v.(string)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }
    }

    return res, nil
}


/*
    Skins parsing
*/
skins_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Skin, err: Error) {
    if SKINS_KEY not_in object {
        return
    }

    skins_array := object[SKINS_KEY].(json.Array)
    res, _ = slice.create(Skin, skins_array.len, allocator)

    for skin, idx in dyn_array.slice(skins_array) {
        for k, v in skin.(json.Object) {
            switch k {
            case "inverseBindMatrices":
                res[idx].inverse_bind_matrices = Unsigned_Integer(v.(f64))

            case "joints":
                // Required
                res[idx].joints, _ = slice.create(Unsigned_Integer, (v.(json.Array)).len, allocator)
                dyn_arr := v.(json.Array)
                for joint, i in dyn_array.slice(dyn_arr) {
                    res[idx].joints[i] = Unsigned_Integer(joint.(f64))
                }

            case "name":
                res[idx].name = v.(string)

            case "skeleton":
                res[idx].skeleton = Unsigned_Integer(v.(f64))

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }

        if len(res[idx].joints) == 0 {
            return res,
                GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "joints", index = idx}}
        }
    }

    return res, nil
}


/*
    Textures parsing
*/

textures_parse :: proc(object: json.Object, allocator: mem.Allocator) -> (res: []Texture, err: Error) {
    if TEXTURES_KEY not_in object {
        return
    }

    textures_array := object[TEXTURES_KEY].(json.Array)
    res, _ = slice.create(Texture, textures_array.len, allocator)

    for texture, idx in dyn_array.slice(textures_array) {
        for k, v in texture.(json.Object) {
            switch k {
            case "sampler":
                res[idx].sampler = Unsigned_Integer(v.(f64))

            case "source":
                res[idx].source = Unsigned_Integer(v.(f64))

            case "name":
                res[idx].name = v.(string)

            case EXTENSIONS_KEY:
                res[idx].extensions = v

            case EXTRAS_KEY:
                res[idx].extras = v

            case:
                warning_unexpected_data(#procedure, k, v, idx)
            }
        }
    }

    return res, nil
}



texture_info_parse :: proc(object: json.Object) -> (res: Texture_Info, err: Error) {
    index_set: bool
    for k, v in object {
        switch k {
        case "index":
            //Required
            res.index = Unsigned_Integer(v.(f64))
            index_set = true

        case "texCoord":
            // Default 0
            res.tex_coord = Unsigned_Integer(v.(f64))

        case EXTENSIONS_KEY:
            res.extensions = v

        case EXTRAS_KEY:
            res.extras = v

        case:
            warning_unexpected_data(#procedure, k, v)
        }
    }

    if !index_set {
        return res, GLTF_Error{type = .Missing_Required_Parameter, proc_name = #procedure, param = {name = "index"}}
    }

    return res, nil
}
