AT_COMPILE_TIME :: true;

IMGUI_PATH :: "source";

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
    vulkanjai      := !array_find(args, "-no_vulkanjai"); // generate the VulkanJai backend (imgui_impl_vulkanjai.jai)

    if compile {
        imgui_src_files: [..] string;
        array_add(*imgui_src_files, tprint("%/imgui.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_widgets.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_draw.cpp", IMGUI_PATH));
        array_add(*imgui_src_files, tprint("%/imgui_tables.cpp", IMGUI_PATH));
        // @ToDo: Maybe add an option to exclude imgui_demo?
        array_add(*imgui_src_files, tprint("%/imgui_demo.cpp", IMGUI_PATH));

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
        array_add(*extra_clang_arguments, "-x", "c++", "-DWIN32_LEAN_AND_MEAN");
        array_add(*flatten_namespaces, "ImGui");
        array_add(*strip_prefixes, "ImGui");
        auto_detect_enum_prefixes = false;
        log_stripped_declarations = false;
        generate_compile_time_struct_checks = false;
        strip_flags |= .INLINED_FUNCTIONS; // "inline" functions are not present in the static library.

        visitor   = imgui_visitor;
        get_func_args_for_printing = imgui_get_function_arg_for_printing;
    }

    if !generate_bindings(options, output_filename)  return false;

    if vulkanjai {
        #if AT_COMPILE_TIME {
            if !generate_vulkanjai_backend()  return false;
        } else {
            log_error("The VulkanJai backend can only be generated at compile time, its shaders are compiled by a workspace. Set AT_COMPILE_TIME or pass -no_vulkanjai.");
            return false;
        }
    }

    return true;
}

begin_end_string_args: [..]*Declaration;

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

            // Some masks are negative in C (ImDrawFlags_InvalidMask_ = ~0x7FFFFFF0), they would be printed as 64 bit hex,
            // which doesn't fit the enum_flags. Use their 32 bit pattern (0x8000000F) instead.
            for en.enumerates {
                if !it.expression || it.expression.kind != .LITERAL  continue;
                literal := cast(*Literal) it.expression;
                if literal.literal_kind == .INTEGER && literal.int_value < 0 {
                    literal.int_value = literal.int_value & 0xFFFF_FFFF;
                }
            }
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

// The VulkanJai backend is written in backends/vulkanjai/. Its shaders are compiled to SPIR-V with ApilaSpirv,
// and the backend, the code it shares with the shaders and the SPIR-V are put together into one file.
VULKANJAI_BACKEND_PATH      :: "backends/vulkanjai";
VULKANJAI_SHADER_BUILD_PATH :: ".build/vulkanjai";
VULKANJAI_OUTPUT_FILENAME   :: "imgui_impl_vulkanjai.jai";

#if AT_COMPILE_TIME {
    ApilaSpirv :: #import "ApilaSpirv";

    // The entry points in shaders.jai (ApilaSpirv names the output files after them), and the names of their SPIR-V in the generated file.
    VULKANJAI_SHADERS :: struct { entry_point: string; constant_name: string; }.[
        .{ "ImGui_ImplVulkanJai_Mesh",     "IMGUI_IMPL_VULKANJAI_MESH_SPIRV" },
        .{ "ImGui_ImplVulkanJai_Fragment", "IMGUI_IMPL_VULKANJAI_FRAGMENT_SPIRV" },
    ];

    generate_vulkanjai_backend :: () -> bool {
        make_directory_if_it_does_not_exist(VULKANJAI_SHADER_BUILD_PATH, recursive = true);

        // So a stale .spv can't be baked if the compilation doesn't output it.
        for file_list(VULKANJAI_SHADER_BUILD_PATH) {
            if ends_with(it, ".spv")  file_delete(it);
        }

        root_options := get_build_options();
        w := compiler_create_workspace("ImGui VulkanJai backend shaders");
        if !w {
            log_error("Couldn't create the workspace for the shaders of the VulkanJai backend.");
            return false;
        }

        options := get_build_options(w);
        copy_commonly_propagated_fields(root_options, *options);
        options.output_type = .NO_OUTPUT;
        set_build_options(options, w);

        shader_options := ApilaSpirv.GetBuildOptions(w);
        shader_options.buildFolder = VULKANJAI_SHADER_BUILD_PATH;
        ApilaSpirv.SetBuildOptions(shader_options, w);

        compiled := false;
        {
            compiler_begin_intercept(w);
            defer compiler_end_intercept(w);

            add_build_file(tprint("%/shaders.jai", VULKANJAI_BACKEND_PATH), w);

            while true {
                message := compiler_wait_for_message();
                ApilaSpirv.ProcessMessage(message); // writes the .spv files on .COMPLETE

                if message.kind == .COMPLETE {
                    mc := cast(*Message_Complete) message;
                    compiled = mc.error_code == .NONE;
                    break;
                }
            }
        }

        if !compiled {
            log_error("Couldn't compile the shaders of the VulkanJai backend.");
            return false;
        }

        builder: String_Builder;
        print_to_builder(*builder, "// This file is generated by generate.jai from %/. Don't edit it, edit those files and run generate.jai again.\n\n", VULKANJAI_BACKEND_PATH);
        append(*builder, "// It is loaded by module.jai when the VULKANJAI_BACKEND module parameter is set.\n\n#scope_module\n\n");

        for string.["shared.jai", "backend.jai"] {
            path := tprint("%/%", VULKANJAI_BACKEND_PATH, it);
            text, ok := read_entire_file(path);
            if !ok {
                log_error("Couldn't read %.", path);
                return false;
            }

            print_to_builder(*builder, "// ---- % ----\n\n%\n", path, text);
        }

        append(*builder, "// ---- SPIR-V of the shaders in shaders.jai ----\n\n");
        append(*builder, "#scope_file\n\n");
        for VULKANJAI_SHADERS {
            path := tprint("%/%.spv", VULKANJAI_SHADER_BUILD_PATH, it.entry_point);
            spirv, ok := read_entire_file(path);
            if !ok {
                log_error("Couldn't read %. Did ApilaSpirv not output the entry point %?", path, it.entry_point);
                return false;
            }
            assert(spirv.count % 4 == 0, "% is not a list of 32 bit words.", path);

            // Words rather than bytes so the code is 4 byte aligned, as Vulkan wants it.
            words: [] u32;
            words.data  = xx spirv.data;
            words.count = spirv.count / 4;

            print_to_builder(*builder, "% :: u32.[", it.constant_name);
            for word, word_index: words {
                if word_index % 8 == 0  append(*builder, "\n   ");
                print_to_builder(*builder, " 0x%,", formatInt(word, base = 16, minimum_digits = 8));
            }
            append(*builder, "\n];\n\n");
        }

        output := builder_to_string(*builder);
        if !write_entire_file(VULKANJAI_OUTPUT_FILENAME, output) {
            log_error("Couldn't write %.", VULKANJAI_OUTPUT_FILENAME);
            return false;
        }

        log("Generated %.", VULKANJAI_OUTPUT_FILENAME);
        return true;
    }
}

#import "Basic";
#import "Bindings_Generator";
#import "BuildCpp";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "String";

FOOTER_UNIX :: #string END

#if OS == .MACOS    imgui :: #library "macos/ImGui";
#if OS == .LINUX    imgui :: #library "linux/ImGui";
#if OS == .LINUX    #library,system,link_always "libm"; // the static library uses cosf, sinf, fmodf...

END
