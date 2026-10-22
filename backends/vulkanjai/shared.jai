// Shared between the shaders (shaders.jai) and the backend (backend.jai).
// The shaders are compiled with ApilaSpirv, so only use types that both sides understand.

// The layout of ImDrawVert.
ImGui_ImplVulkanJai_Vertex :: struct {
    posX: float;
    posY: float;
    uvX:  float;
    uvY:  float;
    col:  u32; // RGBA, 8 bits per channel, R in the lowest byte
}

// One per ImDrawCmd. The same pointer is passed to the mesh and the fragment shader.
ImGui_ImplVulkanJai_DrawData :: struct {
    vertices:        *ImGui_ImplVulkanJai_Vertex; // the vertex buffer, offset to the first vertex of the draw command (ImDrawCmd.VtxOffset)
    indices:         *u16;                        // the index buffer, offset to the first index of the draw command (ImDrawCmd.IdxOffset). ImDrawIdx is u16.
    triangleCount:   u32;                         // ImDrawCmd.ElemCount / 3

    // clip space position = pos * scale + translate
    scaleX:          float;
    scaleY:          float;
    translateX:      float;
    translateY:      float;

    textureOffset:   u32; // byte offset of the texture in the resource heap
    samplerOffset:   u32; // byte offset of the sampler in the sampler heap
    linearizeColors: u32; // 1 if the render target is sRGB. imgui colors are in sRGB, so they are converted to linear before the hardware converts them back.
}

IMGUI_IMPL_VULKANJAI_TRIANGLES_PER_WORKGROUP :: 64; // must match the @64_1_1 @192_64 notes of the mesh shader
