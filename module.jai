// Bindings for Dear ImGui.

#module_parameters (
    // Loads the Renderer + Platform Backend for VulkanJai (backends/vulkanjai/backend.jai). Needs the VulkanJai, ApilaSpirv, osor_vulkan and glfw modules.
    // Its shaders are baked by the VulkanJai metaprogram, so the build script has to give the messages of the workspace to VulkanJai.ProcessMessage (see backend.jai).
    VULKANJAI_BACKEND := true
);

ImVec2      :: Vector2;
ImVec4      :: Vector4;
ImColor     :: Vector4;

ImVector :: struct (T: Type) {
    Size: s32;
    Capacity: s32;
    Data: *T;
}

ImDrawCallback :: #type (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call;

// [Internal] Used for small stacks. Do not use.
ImSmallStack_ :: struct (T: Type, Capacity: s32, SZ_T: Type = ImU16) {
    LocalData: [Capacity] T;
    Size:      SZ_T = 0;
}

// Stands in for the inline constructor ImTextureRef(ImTextureID), which has no symbol to bind. imgui.h asks bindings to provide this helper.
ImTextureRefFromID :: (tex_id: ImTextureID) -> ImTextureRef #no_context {
    tex_ref: ImTextureRef;
    tex_ref._TexID = tex_id;
    return tex_ref;
}

#scope_module

#import "Basic";
#import "Math";

#if OS == .WINDOWS {
    #load "windows.jai";
    #library,system,link_always "user32"; // Needed by imgui unless ImGui is compiled it with "IMGUI_DISABLE_WIN32_DEFAULT_CLIPBOARD_FUNCS"
} else {
    #load "unix.jai";
}

#if VULKANJAI_BACKEND {
    #load "backends/vulkanjai/backend.jai";
}
