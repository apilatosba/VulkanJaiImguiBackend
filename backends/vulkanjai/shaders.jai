// The shaders of the VulkanJai backend, written with ApilaSpirv.
// backend.jai imports this file and gives the shaders to VJ.CreateMeshletPipeline, the VulkanJai metaprogram bakes their SPIR-V into the program.

#import "ApilaSpirv";
#import "Math";

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

    textureIndex:    u32; // index of the texture in the resource heap
    samplerIndex:    u32; // index of the sampler in the sampler heap
    linearizeColors: u32; // 1 if the render target is sRGB. imgui colors are in sRGB, so they are converted to linear before the hardware converts them back.
}

// The workgroup size of the mesh shader. Each workgroup outputs this many triangles, 3 vertices each.
IMGUI_IMPL_VULKANJAI_TRIANGLES_PER_WORKGROUP :: 64;

ImGui_ImplVulkanJai_MeshOutVertex :: struct {
    color: f32x4;
    uv:    f32x2;
}

ImGui_ImplVulkanJai_MeshOutPrimitive :: struct { }

// Each invocation outputs one triangle. The triangles are not indexed, each one has its own 3 vertices.
ImGui_ImplVulkanJai_Mesh :: (vOut: [] ImGui_ImplVulkanJai_MeshOutVertex, pOut: [] ImGui_ImplVulkanJai_MeshOutPrimitive, data: *ImGui_ImplVulkanJai_DrawData) {
    firstTriangle := workgroupid.x * IMGUI_IMPL_VULKANJAI_TRIANGLES_PER_WORKGROUP;
    triangleCount: u32 = IMGUI_IMPL_VULKANJAI_TRIANGLES_PER_WORKGROUP;
    remaining := data.triangleCount - firstTriangle;
    if (remaining < triangleCount) triangleCount = remaining;

    SetMeshOutputs(triangleCount * 3, triangleCount);

    t := localinvocationid.x;
    if (t < triangleCount) {
        firstIndex := (firstTriangle + t) * 3;
        o := t * 3;

        v0 := data.vertices[data.indices[firstIndex]];
        meshvertices[o].position = f32x4.{ v0.posX * data.scaleX + data.translateX, v0.posY * data.scaleY + data.translateY, 0, 1 };
        vOut[o].color = unpackunorm4x8(v0.col);
        vOut[o].uv = f32x2.{ v0.uvX, v0.uvY };

        v1 := data.vertices[data.indices[firstIndex + 1]];
        meshvertices[o + 1].position = f32x4.{ v1.posX * data.scaleX + data.translateX, v1.posY * data.scaleY + data.translateY, 0, 1 };
        vOut[o + 1].color = unpackunorm4x8(v1.col);
        vOut[o + 1].uv = f32x2.{ v1.uvX, v1.uvY };

        v2 := data.vertices[data.indices[firstIndex + 2]];
        meshvertices[o + 2].position = f32x4.{ v2.posX * data.scaleX + data.translateX, v2.posY * data.scaleY + data.translateY, 0, 1 };
        vOut[o + 2].color = unpackunorm4x8(v2.col);
        vOut[o + 2].uv = f32x2.{ v2.uvX, v2.uvY };

        meshtriangles[t] = s32x3.{ xx o, xx (o + 1), xx (o + 2) };
    }
}

ImGui_ImplVulkanJai_Fragment :: (v: ImGui_ImplVulkanJai_MeshOutVertex, p: ImGui_ImplVulkanJai_MeshOutPrimitive, data: *ImGui_ImplVulkanJai_DrawData) -> f32x4 {
    color := v.color * texture(images[data.textureIndex], samplers[data.samplerIndex], v.uv);

    if (data.linearizeColors != 0) {
        color = f32x4.{ SrgbToLinear(color.x), SrgbToLinear(color.y), SrgbToLinear(color.z), color.w };
    }

    return color;
}

// The exact inverse of what the hardware does when it writes to an sRGB image, so the colors of imgui come out unchanged.
SrgbToLinear :: (c: f32) -> f32 {
    return ifx c <= 0.04045 then c / 12.92 else pow((c + 0.055) / 1.055, 2.4);
}
