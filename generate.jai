AT_COMPILE_TIME :: true;

IMGUI_PATH :: "source";

// Real functions wrapping the inline functions of imgui_internal.h (like GetActiveID), which have no symbol in the library.
// The .cpp is compiled into the library and the .h is parsed for the bindings. To wrap another inline function, add it to both.
WRAPPERS_PATH       :: "wrappers";
WRAPPERS_NAMESPACE  :: "ImGuiWrappers"; // flattened, so the wrappers get the names of the functions they wrap

// Puts #type_info_none on the generated structs. Without Type_Info the structs can't be printed or inspected at runtime,
// but the executable is smaller and the compiler doesn't complain about big structs like ImDrawList.
STRUCTS_TYPE_INFO_NONE :: true;

DECLARATIONS_TO_OMIT :: string.[
    // We have custom declarations for these in module.jai:
    "ImVec2",
    "ImVec4",
    "ImColor",
    "ImVector",
    "ImDrawCallback",
    "ImSmallStack_", // the default type of its SZ_T template parameter doesn't translate

    // Jai has its own, better "String_Builder"
    "ImGuiTextBuffer",

    "ImDrawCallback_ResetRenderState", // casting an integer to a function pointer is not supported in Jai.
];

// imgui_internal.h is parsed only for these. Everything else in it is omitted.
INTERNAL_FUNCTION_PREFIXES_TO_KEEP :: string.[
    "DockBuilder", // ImGui::DockBuilderXXX, to build dock layouts from code
];

// Returned by the kept internal functions, generated without fields (only usable through pointers).
// The structs that imgui.h forward declares (ImGuiContext...) but imgui_internal.h defines are also generated without fields, like when only imgui.h is parsed.
INTERNAL_OPAQUE_STRUCTS :: string.[
    "ImGuiDockNode",
];

// The values of these internal enums are added to the public enum, e.g. ImGuiDockNodeFlags_DockSpace, which DockBuilderAddNode() needs.
INTERNAL_ENUMS_TO_MERGE :: struct { internal: string; public: string; }.[
    .{ "ImGuiDockNodeFlagsPrivate_", "ImGuiDockNodeFlags_" },
];

#if AT_COMPILE_TIME {
    #run,stallable {
        set_build_options_dc(.{do_output=false});
        root_options := get_build_options();
        args := root_options.compile_time_command_line;
        if !generate_bindings(args) {
            compiler_set_workspace_status(.FAILED);
        }
    }
} else {
    #import "System";

    main :: () {
        set_working_directory(path_strip_filename(get_path_of_running_executable()));
        args := get_command_line_arguments();
        if !generate_bindings(args) {
            exit(1);
        }
    }
}

generate_bindings :: (args: [] string) -> bool {
    compile        := array_find(args, "-compile");
    compile_debug  := array_find(args, "-debug");

    if compile {
        imgui_src_files: [..] string;
        array_add(*imgui_src_files, tprint("%/imgui.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_widgets.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_draw.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_tables.cpp", IMGUI_PATH));
        // @ToDo: Maybe add an option to exclude imgui_demo?
        array_add(*imgui_src_files, tprint("%/imgui_demo.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_internal_wrappers.cpp", WRAPPERS_PATH));

        success := true;
        #if OS == .WINDOWS {
            make_directory_if_it_does_not_exist("windows");
            success &&= build_cpp_dynamic_lib("windows/ImGui", ..imgui_src_files, extra = .["/DIMGUI_API=__declspec(dllexport)"], debug=compile_debug);
            // We set IMGUI_DISABLE_WIN32_DEFAULT_IME_FUNCTIONS. Otherwise all users of the ImGui module have to link against "imm32".
            success &&= build_cpp_static_lib("windows/ImGui", ..imgui_src_files, extra = .["/DIMGUI_API=__declspec(dllexport)", "/DIMGUI_DISABLE_WIN32_DEFAULT_IME_FUNCTIONS"], debug=compile_debug);
        } else #if OS == .LINUX {
            make_directory_if_it_does_not_exist("linux");
            success &&= build_cpp_dynamic_lib("linux/ImGui", ..imgui_src_files, debug=compile_debug);
            // @Hack: Is -fno-threadsafe-statics really the way to go? Without it, we get linker errors when using the static library
            // due to "__cxa_guard_acquire" et al not being defined. The library users probably need to link agains libc++ or something. But do we really want to enforce that?
            success &&= build_cpp_static_lib("linux/ImGui", ..imgui_src_files, extra = .["-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics", "-fPIC"], debug=compile_debug);
        } else #if OS == .MACOS {
            #import "Process";
            make_directory_if_it_does_not_exist("macos");
            LIB_PATH :: "macos/ImGui";
            success &&= build_universal_macos_binary(LIB_PATH, ..imgui_src_files, type = .DYNAMIC_LIBRARY, debug = compile_debug, extra = .["-std=c++20"]);
            success &&= build_universal_macos_binary(LIB_PATH, ..imgui_src_files, type = .STATIC_LIBRARY,  debug = compile_debug, extra = .["-std=c++20", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics"]);
        } else {
            assert(false);
        }

        if !success     return false;
    }

    defer array_reset(*begin_end_string_args);

    public_forward_declarations = collect_forward_declarations(tprint("%/imgui.h", IMGUI_PATH));
    defer array_reset(*public_forward_declarations);

    output_filename: string;
    options: Generate_Bindings_Options;
    {
        using options;

        #if OS == .WINDOWS {
            array_add(*library_search_paths, "windows");
            output_filename = "windows.jai";
        } else {
            #if OS == .LINUX {
                array_add(*library_search_paths, "linux");
            } else #if OS == .MACOS {
                array_add(*library_search_paths, "macos");
            } else {
                assert(false);
            }
            output_filename = "unix.jai";
            generate_library_declarations = false;
            footer = FOOTER_UNIX;
        }

        array_add(*libraries,     .{filename="ImGui"});
        array_add(*include_paths, IMGUI_PATH);
        array_add(*source_files,  tprint("%/imgui.h", IMGUI_PATH));
        array_add(*source_files,  tprint("%/imgui_internal.h", IMGUI_PATH)); // only for the declarations in INTERNAL_*, see imgui_visitor
        array_add(*source_files,  tprint("%/imgui_internal_wrappers.h", WRAPPERS_PATH));
        array_add(*extra_clang_arguments, "-x", "c++", "-DWIN32_LEAN_AND_MEAN");
        array_add(*flatten_namespaces, "ImGui");
        array_add(*flatten_namespaces, WRAPPERS_NAMESPACE);
        array_add(*strip_prefixes, "ImGui");
        auto_detect_enum_prefixes = false;
        log_stripped_declarations = false;
        generate_compile_time_struct_checks = false;
        strip_flags |= .INLINED_FUNCTIONS; // "inline" functions are not present in the static library.

        visitor   = imgui_visitor;
        get_func_args_for_printing = imgui_get_function_arg_for_printing;
    }

    return generate_bindings(options, output_filename);
}

begin_end_string_args: [..]*Declaration;

public_forward_declarations: [..] string; // "struct ImGuiContext;" in imgui.h

enums_for_typedefs: Table(string, *Enum);

imgui_visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
    // ImGui has "typedef ints" for each enum. but we want to just use the enums directly,
    // so we get nice type safety, and .unary dots, etc.
    //
    // Look for declarations inside functions (i.e., arguments) or structs (i.e., fields)
    get_associated_enum_name :: (name: string) -> string {
        if name.count > 1 && name[name.count - 1] != #char "_" {
            return tprint("%_", name);
        }
        return name;
    }

    // From imgui_internal.h we only want what's listed in INTERNAL_*. (The namespaces are not omitted, they are merged with the ones of imgui.h.)
    if (!parent_decl || parent_decl.kind == .NAMESPACE) && decl.kind != .NAMESPACE {
        if is_from_internal_header(decl) {
            if !keep_internal_declaration(decl) {
                decl.decl_flags |= .OMIT_FROM_OUTPUT;
                return .STOP;
            }
        } else if is_from_internal_header(decl.comment.location.file) {
            decl.comment = .{}; // declared again in imgui_internal.h (typedef int ImDrawTextFlags;), the comment is from there
        }
    }

    if !parent_decl {
        if array_find(DECLARATIONS_TO_OMIT, decl.name) {
            decl.decl_flags |= .OMIT_FROM_OUTPUT;
            return .STOP;
        }
        if decl.name == "ImGuiContext" {
            decl.output_name = decl.name; // Don’t shorten ImGuiContext to Context as this would conflict
        }

        if decl.kind == .TYPEDEF {
            old_name := decl.name;
            if old_name {
                new_name := get_associated_enum_name(old_name);
                for context.generator.global_scope.members {
                    if it.kind != .ENUM  || it.name != new_name     continue;
                    if is_from_internal_header(it)  continue; // omitted, e.g. ImDrawTextFlags_

                    en := cast(*Enum)it;

                    // Don't output the integer typedef
                    decl.decl_flags |= .OMIT_FROM_OUTPUT;

                    // Make sure the enums like "FocusFlags_" get outputted as "FocusFlags"
                    if en.output_name.count > 2 && en.output_name[en.output_name.count - 1] == #char "_" {
                        en.output_name.count -= 1;
                    }

                    // Keep the comment, if there is one:
                    if decl.comment.text && !en.comment.text {
                        en.comment = decl.comment;
                    }

                    table_add(*enums_for_typedefs, old_name, en);
                    break;
                }
            }
        }
    }

    // Look for function arguments with "typedef" types.
    if parent_decl &&
        (parent_decl.kind == .FUNCTION || parent_decl.kind == .STRUCT) &&
        decl.kind == .DECLARATION && decl.type.type_of_typedef != null
    {
        old_name := decl.type.type_of_typedef.name;
        if old_name {
            found, en := table_find(*enums_for_typedefs, old_name);
            if found {
                change_type_to_enum(decl, en);
            }
        }
    }

    // The template arguments of a member like "ImSmallStack_<ImDrawFlags,3> _DrawFlagsStack" end up as its initializer ("= 3").
    if parent_decl && parent_decl.kind == .STRUCT && decl.kind == .DECLARATION && decl.expression && decl.type {
        struct_type := find_underlying_type(decl.type).type_of_struct;
        if struct_type && struct_type.name == "ImSmallStack_"  decl.expression = null;
    }

    if decl.kind == .STRUCT && STRUCTS_TYPE_INFO_NONE {
        decl.decl_flags |= .TYPE_INFO_NONE;
    }

    if decl.kind == .ENUM {
        // ImGui has lots of enums that should be enum flags. Luckily, they all end in "…Flags_".
        if ends_with(decl.name, "Flags_") {
            en := cast(*Enum)decl;
            en.flags |= .IS_ENUM_FLAGS;
            en.flags |= .VALUES_IN_HEX;
            for en.enumerates  fix_negative_flag_value(it);
        }
    }

    if decl.kind == .FUNCTION {
        func := cast(*Function)decl;
        type := func.type.type_of_function;
        // ImGui also has functions with pairs of arguments like "text_begin" and "text_end"
        // for the pointers to the beginning and end of a string. We'll generate wrappers for
        // those function which take a jai string.
        //
        // Here we collect pointers to "_begin" arguments, and use them in
        // get_func_args_for_printing below.
        for type.arguments {
            if it_index == 0 || !ends_with(it.name, "_end")     continue;
            arg_type := find_underlying_type(it.type);
            if !arg_type.pointer_to || !(arg_type.pointer_to.number_flags & ._8BIT) continue; // Only convert *u8 ranges to string

            name_part := slice(it.name, 0, it.name.count - "_end".count);
            if !name_part   continue;

            // the first arg may appear as "text_begin" or just "text"
            name_part_with_begin := tprint("%_begin", name_part);
            prev_arg := type.arguments[it_index - 1];
            if prev_arg.name == name_part || prev_arg.name == name_part_with_begin {
                array_add(*begin_end_string_args, prev_arg);
                func.decl_flags |= .NEEDS_ARGUMENT_WRAPPER;
            }
        }
    }

    return .RECURSE;
}

// Some masks are negative in C (ImDrawFlags_InvalidMask_ = ~0x7FFFFFF0), they would be printed as 64 bit hex,
// which doesn't fit the enum_flags. Use their 32 bit pattern (0x8000000F) instead.
fix_negative_flag_value :: (enumerate: *Declaration) {
    if !enumerate.expression || enumerate.expression.kind != .LITERAL  return;
    literal := cast(*Literal) enumerate.expression;
    if literal.literal_kind == .INTEGER && literal.int_value < 0 {
        literal.int_value = literal.int_value & 0xFFFF_FFFF;
    }
}

is_from_internal_header :: (decl: *Declaration) -> bool {
    return is_from_internal_header(decl.location.file);
}

is_from_internal_header :: (file: CXFile) -> bool {
    if !file  return false;
    filename_clang := clang_getFileName(file);
    defer clang_disposeString(filename_clang);
    filename := to_string(clang_getCString(filename_clang));
    return ends_with(filename, "imgui_internal.h");
}

// The names of the structs declared with "struct Name;" in the header.
collect_forward_declarations :: (path: string) -> [..] string {
    names: [..] string;
    text, ok := read_entire_file(path);
    if !ok {
        log_error("Couldn't read %.", path);
        return names;
    }

    for line: split(text, "\n",, temp) {
        rest := trim(line);
        if !begins_with(rest, "struct ")  continue;
        advance(*rest, "struct ".count);

        semicolon := find_index_from_left(rest, #char ";");
        if semicolon < 0  continue;
        name := trim(slice(rest, 0, semicolon));
        is_identifier := name.count > 0;
        for name  if !is_alnum(it) && it != #char "_"  is_identifier = false;
        if !is_identifier  continue; // not a forward declaration, e.g. "struct ImVec2 { float x, y; };"

        array_add(*names, name);
    }
    return names;
}

// Returns whether the top level declaration of imgui_internal.h should be in the bindings.
keep_internal_declaration :: (decl: *Declaration) -> bool {
    if decl.kind == {
        case .FUNCTION;
            for INTERNAL_FUNCTION_PREFIXES_TO_KEEP {
                if begins_with(decl.name, it)  return true;
            }

        case .STRUCT;
            s := cast(*Struct) decl;
            if array_find(INTERNAL_OPAQUE_STRUCTS, decl.name) || array_find(public_forward_declarations, decl.name) {
                array_reset(*s.declarations);
                array_reset(*s.parents);
                decl.comment = .{}; // the comment of the definition is about the fields (e.g. "sizeof() 176~216")
                return true;
            }

            // The generator adds a "__RAW" variant to structs that are inherited from (ImGuiViewport by ImGuiViewportP). It isn't needed when the subclass is omitted.
            for s.parents {
                parent := find_underlying_type(it.type).type_of_struct;
                if parent && !is_from_internal_header(parent)  parent.flags &= ~.MAY_HAVE_SUBCLASS;
            }

        case .ENUM;
            for INTERNAL_ENUMS_TO_MERGE {
                if decl.name != it.internal  continue;

                for public_decl: context.generator.global_scope.members {
                    if public_decl.kind != .ENUM || public_decl.name != it.public  continue;

                    // The public enum was visited already, so its flags are set and its values fixed.
                    public_enum := cast(*Enum) public_decl;
                    for enumerate: (cast(*Enum) decl).enumerates {
                        enumerate.parent = public_enum;
                        // Strip the prefix like the generator does for the public values: ImGuiDockNodeFlags_DockSpace -> DockSpace
                        if begins_with(enumerate.name, it.public)  enumerate.output_name = slice(enumerate.name, it.public.count, enumerate.name.count - it.public.count);
                        if public_enum.flags & .IS_ENUM_FLAGS  fix_negative_flag_value(enumerate);
                        array_add(*public_enum.enumerates, enumerate);
                    }
                    return false; // its values are in the public enum now
                }

                log_error("Couldn't find the enum % to merge % into.", it.public, it.internal);
            }
    }

    return false;
}

// Modify function with _begin and _end string arguments as they get printed.
// See the note above about "text_begin".
imgui_get_function_arg_for_printing :: (func: *Function, type: *Function_Type, mode: Arg_Print_Mode) -> []*Declaration {
    args: [..]*Declaration;
    for type.arguments {
        if array_find(begin_end_string_args, it) {
            if mode == {
                case .OUTER_WRAPPER;
                    // For the outer wrapper, remove any "_begin" part of the argument, and
                    // change its type to a jai string
                    arg_copy := New(Declaration);
                    (arg_copy.*) = it.*;
                    arg_copy.type = context.generator.type_def_jai_string;
                    if ends_with(it.name, "_begin") {
                        arg_copy.output_name = slice(it.name, 0, it.name.count - "_begin".count);
                    }
                    array_add(*args, arg_copy);

                    it_index += 1; // skip the next argument-we collpase the _begin and _end args into one string arg

                    continue;
                case .INNER_WRAPPER_CALL;
                    // For the inner wrapper function call, we pass the incoming arg
                    // as two arguments: "jai_string.data, jai_string.data + jai_string.count" -- corresponding
                    // to the _begin and _end parts.
                    base_arg_name := it.name;
                    if ends_with(it.name, "_begin") {
                        base_arg_name = slice(it.name, 0, it.name.count - "_begin".count);
                    }

                    arg_copy := New(Declaration);
                    (arg_copy.*) = it.*;
                    arg_copy.output_name = tprint("%.data", base_arg_name);
                    array_add(*args, arg_copy);

                    arg_copy_2 := New(Declaration);
                    (arg_copy_2.*) = it.*;
                    arg_copy_2.output_name = tprint("%.data + %.count", base_arg_name, base_arg_name);
                    array_add(*args, arg_copy_2);

                    it_index += 1; // skip the next arg, since we already added a second one above
                    continue;
            }
        }

        array_add(*args, it);
    }

    return args;
}

#import "Basic";
#import "Bindings_Generator";
#import "BuildCpp";
#import "Compiler";
#import "File";
#import "Hash_Table";
#import "String";

FOOTER_UNIX :: #string END

#if OS == .MACOS    imgui :: #library "macos/ImGui";
#if OS == .LINUX    imgui :: #library "linux/ImGui";
#if OS == .LINUX    #library,system,link_always "libm"; // the static library uses cosf, sinf, fmodf...

END
