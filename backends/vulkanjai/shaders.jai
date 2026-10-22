// The shaders of the VulkanJai backend, compiled to SPIR-V with ApilaSpirv by generate.jai.
// The SPIR-V is baked into imgui_impl_vulkanjai.jai, so you only need to run generate.jai again if you change this file.

#import "ApilaSpirv";
#load "shared.jai";

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
} @mesh @64_1_1 @192_64 @triangles

ImGui_ImplVulkanJai_Fragment :: (v: ImGui_ImplVulkanJai_MeshOutVertex, p: ImGui_ImplVulkanJai_MeshOutPrimitive, data: *ImGui_ImplVulkanJai_DrawData) -> f32x4 {
    color := v.color * texture(images[data.textureOffset], samplers[data.samplerOffset], v.uv);

    if (data.linearizeColors != 0) {
        color = f32x4.{ SrgbToLinear(color.x), SrgbToLinear(color.y), SrgbToLinear(color.z), color.w };
    }

    return color;
} @fragment

// The exact inverse of what the hardware does when it writes to an sRGB image, so the colors of imgui come out unchanged.
SrgbToLinear :: (c: f32) -> f32 {
    return ifx c <= 0.04045 then c / 12.92 else pow((c + 0.055) / 1.055, 2.4);
}
