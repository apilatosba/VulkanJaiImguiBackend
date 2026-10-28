// Dear ImGui: Renderer + Platform Backend for VulkanJai
//
// Implemented features:
//  [X] Renderer: User texture binding. Use ImGui_ImplVulkanJai_TextureId() with the resource heap offset WriteImageDescriptors(.., .Sampled) returned.
//  [X] Renderer: Large meshes support (64k+ vertices) even with 16-bit indices (ImGuiBackendFlags_RendererHasVtxOffset).
//  [X] Renderer: Texture updates support for dynamic font atlas (ImGuiBackendFlags_RendererHasTextures).
//  [X] Renderer: Standard draw callbacks: DrawCallback_ResetRenderState, DrawCallback_SetSamplerLinear, DrawCallback_SetSamplerNearest.
//  [X] Platform: Keyboard, mouse, text input, focus, clipboard and mouse cursor shapes (ImGuiBackendFlags_HasMouseCursors).
//
// The triangles are drawn with a mesh shader (one invocation per triangle) and a fragment shader, written in Jai and compiled with ApilaSpirv.
// The textures and the samplers are in VulkanJai's descriptor heaps.
//
// Usage:
//     ImGui :: #import "Imgui"(VULKANJAI_BACKEND = true);
//
//     window := InitializeVulkanAndWindow(.{});
//     ImGui.CreateContext();
//     ImGui.ImGui_ImplVulkanJai_Init(window);
//
//     while !WindowShouldClose(window) {
//         AcquireSwapchainImage(window);
//         UpdateInput(window);                          // before ImGui_ImplVulkanJai_NewFrame, the input is read from window.input
//         ImGui.ImGui_ImplVulkanJai_NewFrame();
//         ImGui.NewFrame();
//         ... your ui ...
//         ImGui.Render();
//
//         cmd := StartCommandRecording();
//         ActivateDescriptorHeaps(cmd);                 // the backend's textures and samplers are in the descriptor heaps
//         BeginRenderPass(cmd, ...);
//         ImGui.ImGui_ImplVulkanJai_RenderDrawData(ImGui.GetDrawData(), cmd);
//         EndRenderPass(cmd);
//         SubmitAndPresent(cmd, window);
//     }
//
//     WaitDevice();
//     ImGui.ImGui_ImplVulkanJai_Shutdown();
//     ImGui.DestroyContext();
//
// Notes:
//  - Call ImGui_ImplVulkanJai_RenderDrawData once per frame. The vertex/index buffers of a frame are reused swapchain image count frames later,
//    which AcquireSwapchainImage makes sure is done on the gpu.
//  - It changes the render state that BeginRenderPass sets (blending, culling, depth, scissor) and sets it back to what BeginRenderPass sets when it is done.
//  - It assumes the flipped viewport of BeginRenderPass (y up).
//  - imgui colors are sRGB. If the render target is sRGB (the swapchain of VulkanJai is), they are converted to linear in the fragment shader.

#scope_export

// renderTargetFormat is the format of the image imgui is drawn to, only used to know if it is sRGB. VK_FORMAT_UNDEFINED means the swapchain of VulkanJai.
ImGui_ImplVulkanJai_Init :: (window: *VJ.Window, renderTargetFormat := VkFormat.VK_FORMAT_UNDEFINED) -> bool {
    io := GetIO();
    platform_io := GetPlatformIO();
    assert(io.BackendRendererUserData == null, "Already initialized a renderer backend!");
    assert(io.BackendPlatformUserData == null, "Already initialized a platform backend!");
    assert(window != null);

    bd := New(Backend_Data);
    bd.window = window;
    bd.windowWasFocused = true;
    bd.frames = NewArray(window.swapchainImages.count, Frame_Render_Buffers);

    io.BackendRendererUserData = bd;
    io.BackendPlatformUserData = bd;
    io.BackendRendererName = "imgui_impl_vulkanjai";
    io.BackendPlatformName = "imgui_impl_vulkanjai";
    io.BackendFlags_ |= .RendererHasVtxOffset; // We can honor the ImDrawCmd::VtxOffset field, allowing for large meshes.
    io.BackendFlags_ |= .RendererHasTextures;  // We can honor ImGuiPlatformIO::Textures[] requests during render.
    io.BackendFlags_ |= .HasMouseCursors;      // We can honor GetMouseCursor() values.

    platform_io.DrawCallback_ResetRenderState = DrawCallback_ResetRenderState;
    platform_io.DrawCallback_SetSamplerLinear = DrawCallback_SetSamplerLinear;
    platform_io.DrawCallback_SetSamplerNearest = DrawCallback_SetSamplerNearest;
    platform_io.Renderer_TextureMaxWidth = xx VJ.vk.physicalDeviceProperties.limits.maxImageDimension2D;
    platform_io.Renderer_TextureMaxHeight = xx VJ.vk.physicalDeviceProperties.limits.maxImageDimension2D;
    platform_io.Platform_GetClipboardTextFn = GetClipboardText;
    platform_io.Platform_SetClipboardTextFn = SetClipboardText;

    if renderTargetFormat == .VK_FORMAT_UNDEFINED  renderTargetFormat = VJ.vk.surfaceFormat.format;
    bd.linearizeColors = IsSrgbFormat(renderTargetFormat);

    // The imgui textures are sampled with clamping, like the other backends do.
    samplers := VJ.SamplerInfo.[
        .{ magFilter = VK_FILTER_LINEAR,  minFilter = VK_FILTER_LINEAR,  mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR,  addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, anisotropyEnable = false },
        .{ magFilter = VK_FILTER_NEAREST, minFilter = VK_FILTER_NEAREST, mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST, addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, anisotropyEnable = false },
    ];
    bd.samplerIndex = VJ.WriteSamplerDescriptors(samplers);

    bd.pipeline = VJ.CreateMeshletPipeline(.{}, SpirvBytes(IMGUI_IMPL_VULKANJAI_MESH_SPIRV), SpirvBytes(IMGUI_IMPL_VULKANJAI_FRAGMENT_SPIRV), debugName = "imgui");

    for * bd.mouseCursors  it.* = null;
    bd.mouseCursors[MouseCursor.Arrow]      = glfwCreateStandardCursor(GLFW_ARROW_CURSOR);
    bd.mouseCursors[MouseCursor.TextInput]  = glfwCreateStandardCursor(GLFW_IBEAM_CURSOR);
    bd.mouseCursors[MouseCursor.ResizeNS]   = glfwCreateStandardCursor(GLFW_VRESIZE_CURSOR);
    bd.mouseCursors[MouseCursor.ResizeEW]   = glfwCreateStandardCursor(GLFW_HRESIZE_CURSOR);
    bd.mouseCursors[MouseCursor.Hand]       = glfwCreateStandardCursor(GLFW_HAND_CURSOR);
    bd.mouseCursors[MouseCursor.ResizeAll]  = glfwCreateStandardCursor(GLFW_RESIZE_ALL_CURSOR);
    bd.mouseCursors[MouseCursor.ResizeNESW] = glfwCreateStandardCursor(GLFW_RESIZE_NESW_CURSOR);
    bd.mouseCursors[MouseCursor.ResizeNWSE] = glfwCreateStandardCursor(GLFW_RESIZE_NWSE_CURSOR);
    bd.mouseCursors[MouseCursor.NotAllowed] = glfwCreateStandardCursor(GLFW_NOT_ALLOWED_CURSOR);

    return true;
}

// The gpu must be done with the frames that use imgui (WaitDevice()) before you call this.
ImGui_ImplVulkanJai_Shutdown :: () {
    bd := GetBackendData();
    assert(bd != null, "No backend to shutdown, or already shutdown?");
    io := GetIO();
    platform_io := GetPlatformIO();

    // Destroy all textures
    for VectorView(platform_io.Textures) {
        if it.RefCount == 1  DestroyTexture(it);
    }

    for * bd.frames  DestroyFrameRenderBuffers(it);
    array_free(bd.frames);

    VJ.DestroyMeshletPipeline(bd.pipeline);
    VJ.EraseSamplerDescriptors(bd.samplerIndex);

    for bd.mouseCursors {
        if it  glfwDestroyCursor(it);
    }

    io.BackendRendererName = null;
    io.BackendPlatformName = null;
    io.BackendRendererUserData = null;
    io.BackendPlatformUserData = null;
    io.BackendFlags_ &= ~(BackendFlags.RendererHasVtxOffset | .RendererHasTextures | .HasMouseCursors);
    platform_io.ClearRendererHandlers(platform_io);
    platform_io.ClearPlatformHandlers(platform_io);
    free(bd);
}

// Call after UpdateInput(window) and before ImGui.NewFrame().
ImGui_ImplVulkanJai_NewFrame :: () {
    bd := GetBackendData();
    assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplVulkanJai_Init()?");
    io := GetIO();
    window := bd.window;

    // Setup display size (every frame to accommodate for window resizing)
    io.DisplaySize = .{ xx window.width, xx window.height };
    if window.width > 0 && window.height > 0 && window.swapchainImages.count > 0 {
        framebufferSize := window.swapchainImages[0].description.size;
        io.DisplayFramebufferScale = .{ framebufferSize[0] / cast(float) window.width, framebufferSize[1] / cast(float) window.height };
    }

    // Setup time step
    // (Accept GetTime() not returning a monotonically increasing value, like imgui_impl_glfw does.)
    currentTime := VJ.GetTime();
    if currentTime <= bd.time  currentTime = bd.time + 0.00001;
    io.DeltaTime = ifx bd.time > 0 then cast(float) (currentTime - bd.time) else 1.0 / 60.0;
    bd.time = currentTime;

    UpdateInputEvents(bd);
    UpdateMouseCursor(bd);
}

// cmd must be in a render pass (BeginRenderPass) and have the descriptor heaps activated (ActivateDescriptorHeaps).
ImGui_ImplVulkanJai_RenderDrawData :: (draw_data: *ImDrawData, cmd: *VJ.CommandBuffer) {
    // Avoid rendering when minimized, scale coordinates for retina displays (screen coordinates != framebuffer coordinates)
    fbWidth  := cast(int) (draw_data.DisplaySize.x * draw_data.FramebufferScale.x + 0.5);
    fbHeight := cast(int) (draw_data.DisplaySize.y * draw_data.FramebufferScale.y + 0.5);
    if fbWidth <= 0 || fbHeight <= 0  return;

    bd := GetBackendData();
    assert(bd != null, "Context or backend not initialized! Did you call ImGui_ImplVulkanJai_Init()?");

    // Catch up with texture updates. Most of the times, the list will have 1 element with an OK status, aka nothing to do.
    // (This almost always points to ImGui::GetPlatformIO().Textures[] but is part of ImDrawData to allow overriding or disabling texture updates).
    if draw_data.Textures {
        for VectorView(draw_data.Textures.*) {
            if it.Status != .OK  UpdateTexture(it);
        }
    }

    // The swapchain was recreated with a different image count, so a different number of frames can be in flight.
    // Only happens on a resize at most, so waiting for the gpu to be done with the old buffers is fine.
    if bd.frames.count != bd.window.swapchainImages.count {
        VJ.WaitDevice();
        for * bd.frames  DestroyFrameRenderBuffers(it);
        array_free(bd.frames);
        bd.frames = NewArray(bd.window.swapchainImages.count, Frame_Render_Buffers);
        bd.frameIndex = 0;
    }

    bd.frameIndex = (bd.frameIndex + 1) % bd.frames.count;
    frame := *bd.frames[bd.frameIndex];

    drawCommandCount := 0;
    for drawList: VectorView(draw_data.CmdLists)  drawCommandCount += drawList.CmdBuffer.Size;

    // Upload vertex/index data into a single contiguous GPU buffer
    EnsureBufferSize(*frame.vertices, draw_data.TotalVtxCount * size_of(ImDrawVert), "imgui vertices");
    EnsureBufferSize(*frame.indices,  draw_data.TotalIdxCount * size_of(ImDrawIdx), "imgui indices");
    EnsureBufferSize(*frame.drawData, drawCommandCount * size_of(ImGui_ImplVulkanJai_DrawData), "imgui draw data");

    {
        vertexDestination := cast(*ImDrawVert) frame.vertices.cpu;
        indexDestination := cast(*ImDrawIdx) frame.indices.cpu;
        for drawList: VectorView(draw_data.CmdLists) {
            memcpy(vertexDestination, drawList.VtxBuffer.Data, drawList.VtxBuffer.Size * size_of(ImDrawVert));
            memcpy(indexDestination, drawList.IdxBuffer.Data, drawList.IdxBuffer.Size * size_of(ImDrawIdx));
            vertexDestination += drawList.VtxBuffer.Size;
            indexDestination += drawList.IdxBuffer.Size;
        }
    }

    bd.cmd = cmd;
    SetupRenderState(bd, draw_data);

    // Will project scissor/clipping rectangles into framebuffer space
    clipOffset := draw_data.DisplayPos;       // (0,0) unless using multi-viewports
    clipScale := draw_data.FramebufferScale;  // (1,1) unless using retina display which are often (2,2)

    // Render command lists
    // (Because we merged all buffers into a single one, we maintain our own offset into them)
    drawDatas := cast(*ImGui_ImplVulkanJai_DrawData) frame.drawData.cpu;
    drawDataIndex := 0;
    globalVertexOffset := 0;
    globalIndexOffset := 0;
    for drawList: VectorView(draw_data.CmdLists) {
        for * pcmd: VectorView(drawList.CmdBuffer) {
            if pcmd.UserCallback != null {
                // User callback, registered via ImDrawList::AddCallback(). The standard ones are identifiers, the rendering loop handles them.
                if pcmd.UserCallback == DrawCallback_ResetRenderState {
                    SetupRenderState(bd, draw_data);
                } else if pcmd.UserCallback == DrawCallback_SetSamplerLinear {
                    bd.currentSampler = 0;
                } else if pcmd.UserCallback == DrawCallback_SetSamplerNearest {
                    bd.currentSampler = 1;
                } else {
                    pcmd.UserCallback(drawList, pcmd);
                }
                continue;
            }

            if pcmd.ElemCount == 0  continue;

            // Project scissor/clipping rectangles into framebuffer space
            clipMin := Vector2.{ (pcmd.ClipRect.x - clipOffset.x) * clipScale.x, (pcmd.ClipRect.y - clipOffset.y) * clipScale.y };
            clipMax := Vector2.{ (pcmd.ClipRect.z - clipOffset.x) * clipScale.x, (pcmd.ClipRect.w - clipOffset.y) * clipScale.y };

            // Clamp to viewport as the scissor won't accept values that are off bounds
            if clipMin.x < 0  clipMin.x = 0;
            if clipMin.y < 0  clipMin.y = 0;
            if clipMax.x > cast(float) fbWidth   clipMax.x = cast(float) fbWidth;
            if clipMax.y > cast(float) fbHeight  clipMax.y = cast(float) fbHeight;
            if clipMax.x <= clipMin.x || clipMax.y <= clipMin.y  continue;

            // Apply scissor/clipping rectangle
            VJ.SetScissor(cmd, xx clipMin.x, xx clipMin.y, xx (clipMax.x - clipMin.x), xx (clipMax.y - clipMin.y));

            textureId := GetTexID(pcmd);
            assert(textureId != ImTextureID_Invalid, "The texture of a draw command has no ImTextureID. Did the backend not handle ImDrawData.Textures?");

            triangleCount := pcmd.ElemCount / 3;
            data := *drawDatas[drawDataIndex];
            data.* = bd.projection;
            data.vertices = cast(*ImGui_ImplVulkanJai_Vertex) (frame.vertices.gpu.data + cast(u64) ((globalVertexOffset + pcmd.VtxOffset) * size_of(ImDrawVert)));
            data.indices = cast(*u16) (frame.indices.gpu.data + cast(u64) ((globalIndexOffset + pcmd.IdxOffset) * size_of(ImDrawIdx)));
            data.triangleCount = triangleCount;
            data.textureOffset = xx TextureIdToResourceHeapOffset(textureId);
            data.samplerOffset = xx ((bd.samplerIndex + bd.currentSampler) * VJ.vk.samplerDescriptorStride);

            // The operators of VJ.GpuPointer are not visible through the VJ namespace, so the arithmetic is done on .data.
            dataGpu := VJ.GpuPointer(void).{ frame.drawData.gpu.data + cast(u64) (drawDataIndex * size_of(ImGui_ImplVulkanJai_DrawData)) };
            drawDataIndex += 1;

            workgroupCount := (triangleCount + IMGUI_IMPL_VULKANJAI_TRIANGLES_PER_WORKGROUP - 1) / IMGUI_IMPL_VULKANJAI_TRIANGLES_PER_WORKGROUP;
            VJ.DispatchMesh(cmd, VJ.GpuPointer(void).{}, dataGpu, dataGpu, workgroupCount, 1, 1);
        }

        globalIndexOffset += drawList.IdxBuffer.Size;
        globalVertexOffset += drawList.VtxBuffer.Size;
    }

    bd.cmd = null;

    // Set the state back to what BeginRenderPass sets, so the rendering after imgui in the same render pass is not affected.
    VJ.SetBlendEnable(cmd, false);
    VJ.SetCullMode(cmd, VK_CULL_MODE_BACK_BIT);
    VJ.SetDepthTestEnable(cmd, true);
    VJ.SetDepthWriteEnable(cmd, true);
    VJ.SetScissor(cmd, 0, 0, xx fbWidth, xx fbHeight);
}

// Use this to draw your own images with ImGui.Image() etc. resourceHeapOffset is what WriteImageDescriptors(.., .Sampled) returned.
// (The offset is stored + 1, because ImTextureID_Invalid is 0 and 0 is a valid offset.)
ImGui_ImplVulkanJai_TextureId :: (resourceHeapOffset: int) -> ImTextureID {
    return cast(ImTextureID) (resourceHeapOffset + 1);
}

// Called by RenderDrawData for the textures of imgui. You can call it yourself if you manage ImDrawData.Textures yourself.
ImGui_ImplVulkanJai_UpdateTexture :: (tex: *ImTextureData) {
    UpdateTexture(tex);
}

#scope_file

VJ :: #import "VulkanJai";
#import "osor_vulkan";
#import "glfw";

Backend_Data :: struct {
    window:           *VJ.Window;
    pipeline:         VJ.MeshletPipeline;
    linearizeColors:  bool;
    samplerIndex:     int; // the first of the 2 samplers in the sampler heap: [0] linear, [1] nearest
    time:             float64;

    frames:           [] Frame_Render_Buffers; // one per frame in flight
    frameIndex:       int;

    // set during RenderDrawData
    cmd:              *VJ.CommandBuffer;
    projection:       ImGui_ImplVulkanJai_DrawData; // only the projection and linearizeColors are set
    currentSampler:   int;

    // platform
    mouseCursors:     [MouseCursor.COUNT] *GLFWcursor;
    lastMouseCursor:  *GLFWcursor;
    windowWasFocused: bool;
    keysDown:         [KEY_MAP.count] bool;
    mouseButtonsDown: [MOUSE_BUTTON_COUNT] bool;
}

Gpu_Buffer :: struct {
    cpu:   *void;
    gpu:   VJ.GpuPointer(void);
    size:  int;
}

Frame_Render_Buffers :: struct {
    vertices:  Gpu_Buffer;
    indices:   Gpu_Buffer;
    drawData:  Gpu_Buffer; // [] ImGui_ImplVulkanJai_DrawData, one per draw command
}

Texture :: struct {
    image:              VJ.Image;
    memory:             VJ.GpuPointer(void); // the memory of the image
    resourceHeapOffset: int;
}

GetBackendData :: () -> *Backend_Data {
    if !GetCurrentContext()  return null;
    return cast(*Backend_Data) GetIO().BackendRendererUserData;
}

// Draw callbacks. Intentionally empty. Used as identifiers for the rendering loop to call its code.
DrawCallback_ResetRenderState  :: (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call {}
DrawCallback_SetSamplerLinear  :: (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call {}
DrawCallback_SetSamplerNearest :: (parent_list: *ImDrawList, cmd: *ImDrawCmd) #c_call {}

SetupRenderState :: (bd: *Backend_Data, draw_data: *ImDrawData) {
    cmd := bd.cmd;
    VJ.BindMeshletPipeline(cmd, bd.pipeline);

    // Alpha blending enabled, no face culling, no depth testing
    VJ.SetBlendEnable(cmd, true);
    VJ.SetBlendMode(cmd, .{
        srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
        dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        colorBlendOp        = VK_BLEND_OP_ADD,
        srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
        dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        alphaBlendOp        = VK_BLEND_OP_ADD,
    });
    VJ.SetCullMode(cmd, VK_CULL_MODE_NONE);
    VJ.SetDepthTestEnable(cmd, false);
    VJ.SetDepthWriteEnable(cmd, false);

    // Setup scale and translation:
    // Our visible imgui space lies from draw_data.DisplayPos (top left) to draw_data.DisplayPos + draw_data.DisplaySize (bottom right).
    // The viewport of BeginRenderPass is flipped (y up): clip space y = 1 is the top of the render target.
    p := *bd.projection;
    p.scaleX = 2.0 / draw_data.DisplaySize.x;
    p.scaleY = -2.0 / draw_data.DisplaySize.y;
    p.translateX = -1.0 - draw_data.DisplayPos.x * p.scaleX;
    p.translateY = 1.0 - draw_data.DisplayPos.y * p.scaleY;
    p.linearizeColors = xx bd.linearizeColors;

    bd.currentSampler = 0; // linear
}

EnsureBufferSize :: (buffer: *Gpu_Buffer, size: int, debugName: string) {
    if size <= buffer.size  return;

    // The buffer of this frame is not used by the gpu anymore, see the notes at the top.
    if buffer.gpu.data  VJ.GpuFree(buffer.gpu);

    newSize := max(size + size / 2, 4096);
    buffer.gpu, buffer.cpu = VJ.GpuMalloc(newSize, 16, .Default, debugName);
    assert(buffer.cpu != null, "couldn't allocate % bytes for %", newSize, debugName);
    buffer.size = newSize;
}

DestroyFrameRenderBuffers :: (frame: *Frame_Render_Buffers) {
    for * (*Gpu_Buffer).[*frame.vertices, *frame.indices, *frame.drawData] {
        if it.*.gpu.data  VJ.GpuFree(it.*.gpu);
        it.*.* = .{};
    }
}

UpdateTexture :: (tex: *ImTextureData) {
    if tex.Status == .OK  return;
    bd := GetBackendData();

    if tex.Status == .WantCreate {
        // Create and upload new texture to graphics system
        assert(tex.TexID == ImTextureID_Invalid && tex.BackendUserData == null);
        assert(tex.Format == .RGBA32);

        description: VJ.ImageDescription = .{
            size        = .[xx tex.Width, xx tex.Height, 1],
            format      = VK_FORMAT_R8G8B8A8_UNORM,
            arrayLayers = 1,
            mipLevels   = 1,
            sampleCount = 1,
            usage       = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        };

        debugName := tprint("imgui texture %", tex.UniqueID);
        backendTex := New(Texture);
        size, alignment := VJ.GetImageSizeAndAlignment(description);
        backendTex.memory = VJ.GpuMalloc(size, alignment, .Gpu, debugName);
        assert(backendTex.memory.data != 0, "couldn't allocate % bytes for %", size, debugName);
        backendTex.image = VJ.CreateImage(backendTex.memory, description, debugName);
        backendTex.resourceHeapOffset = VJ.WriteImageDescriptors(.[backendTex.image], .Sampled);

        // Store identifiers
        tex.TexID = ImGui_ImplVulkanJai_TextureId(backendTex.resourceHeapOffset);
        tex.BackendUserData = backendTex;
    }

    if tex.Status == .WantCreate || tex.Status == .WantUpdates {
        backendTex := cast(*Texture) tex.BackendUserData;

        // Update full texture or selected blocks. We only ever write to textures regions which have never been used before!
        // This backend choose to use tex.UpdateRect but you can use tex.Updates[] to upload individual regions.
        // We could use the smaller rect on WantCreate but using the full rect allows us to clear the texture.
        isCreate := tex.Status == .WantCreate;
        uploadX := ifx isCreate then 0 else cast(s32) tex.UpdateRect.x;
        uploadY := ifx isCreate then 0 else cast(s32) tex.UpdateRect.y;
        uploadW := ifx isCreate then tex.Width else cast(s32) tex.UpdateRect.w;
        uploadH := ifx isCreate then tex.Height else cast(s32) tex.UpdateRect.h;

        uploadPitch := uploadW * tex.BytesPerPixel;
        texturePitch := tex.Width * tex.BytesPerPixel;
        uploadSize := uploadH * uploadPitch;

        stagingGpu, stagingCpu := VJ.GpuMalloc(uploadSize, 16, .Default, "imgui texture upload");
        assert(stagingCpu != null, "couldn't allocate % bytes for the texture upload", uploadSize);
        for y: 0..uploadH - 1 {
            source := tex.Pixels + (uploadX * tex.BytesPerPixel) + (uploadY + y) * texturePitch;
            memcpy(stagingCpu + y * uploadPitch, source, uploadPitch);
        }

        cmd := VJ.StartCommandRecording();
        VJ.CopyToImage(cmd, stagingGpu, backendTex.image, .[uploadX, uploadY, 0], .[xx uploadW, xx uploadH, 1]);
        VJ.GpuBarrier(cmd, VK_PIPELINE_STAGE_2_TRANSFER_BIT, VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT);
        VJ.Submit(cmd);

        // The staging buffer is freed once the upload is done executing on the gpu.
        VJ.DeferGpuFree(.[.{ timelineValue = cmd.doneTimelineValue, buffer = stagingGpu }]);

        SetStatus(tex, .OK);
    }

    if tex.Status == .WantDestroy && tex.UnusedFrames >= bd.frames.count {
        DestroyTexture(tex);
    }
}

DestroyTexture :: (tex: *ImTextureData) {
    backendTex := cast(*Texture) tex.BackendUserData;
    if backendTex {
        assert(ImGui_ImplVulkanJai_TextureId(backendTex.resourceHeapOffset) == tex.TexID);
        VJ.EraseResourceDescriptors(backendTex.resourceHeapOffset);
        VJ.DestroyImage(backendTex.image);
        VJ.GpuFree(backendTex.memory);
        free(backendTex);

        // Clear identifiers and mark as destroyed (in order to allow e.g. calling InvalidateDeviceObjects while running)
        tex.TexID = ImTextureID_Invalid;
        tex.BackendUserData = null;
    }

    SetStatus(tex, .Destroyed);
}

TextureIdToResourceHeapOffset :: (id: ImTextureID) -> int {
    return cast(int) id - 1;
}

// ImTextureData::SetStatus() is inline, so it is not in the library.
SetStatus :: (tex: *ImTextureData, status: ImTextureStatus) {
    tex.Status = status;
    if status == .Destroyed && !tex.WantDestroyNextFrame && tex.Pixels != null  tex.Status = .WantCreate;
}

// ImDrawCmd::GetTexID() is inline, so it is not in the library.
GetTexID :: (pcmd: *ImDrawCmd) -> ImTextureID {
    if pcmd.TexRef._TexData  return pcmd.TexRef._TexData.TexID;
    return pcmd.TexRef._TexID;
}

VectorView :: (v: ImVector($T)) -> [] T {
    result: [] T;
    result.data = v.Data;
    result.count = v.Size;
    return result;
}

SpirvBytes :: (words: [] u32) -> [] u8 {
    result: [] u8;
    result.data = xx words.data;
    result.count = words.count * size_of(u32);
    return result;
}

IsSrgbFormat :: (format: VkFormat) -> bool {
    return format == .VK_FORMAT_R8_SRGB        || format == .VK_FORMAT_R8G8_SRGB      ||
           format == .VK_FORMAT_R8G8B8_SRGB    || format == .VK_FORMAT_B8G8R8_SRGB    ||
           format == .VK_FORMAT_R8G8B8A8_SRGB  || format == .VK_FORMAT_B8G8R8A8_SRGB  ||
           format == .VK_FORMAT_A8B8G8R8_SRGB_PACK32;
}

//
// Platform
//

GetClipboardText :: (ctx: *ImGuiContext) -> *u8 #c_call {
    result: *u8;
    push_context {
        // the string is owned by glfw and null terminated, imgui copies it
        result = VJ.GetClipboardText().data;
    }
    return result;
}

SetClipboardText :: (ctx: *ImGuiContext, text: *u8) #c_call {
    push_context {
        VJ.SetClipboardText(to_string(text));
    }
}

UpdateInputEvents :: (bd: *Backend_Data) {
    io := GetIO();
    window := bd.window;

    if window.isFocused != bd.windowWasFocused {
        io.AddFocusEvent(io, window.isFocused);
        bd.windowWasFocused = window.isFocused;
    }

    // Keyboard. A key that was pressed and released within the frame is sent as a press and a release.
    io.AddKeyEvent(io, .Mod_Ctrl,  VJ.IsKeyDown(window, .LeftControl) || VJ.IsKeyDown(window, .RightControl));
    io.AddKeyEvent(io, .Mod_Shift, VJ.IsKeyDown(window, .LeftShift)   || VJ.IsKeyDown(window, .RightShift));
    io.AddKeyEvent(io, .Mod_Alt,   VJ.IsKeyDown(window, .LeftAlt)     || VJ.IsKeyDown(window, .RightAlt));
    io.AddKeyEvent(io, .Mod_Super, VJ.IsKeyDown(window, .LeftSuper)   || VJ.IsKeyDown(window, .RightSuper));

    for KEY_MAP {
        down := VJ.IsKeyDown(window, it.key);
        if down != bd.keysDown[it_index] {
            io.AddKeyEvent(io, it.imguiKey, down);
            bd.keysDown[it_index] = down;
        } else if !down && VJ.IsKeyPressed(window, it.key) {
            io.AddKeyEvent(io, it.imguiKey, true);
            io.AddKeyEvent(io, it.imguiKey, false);
        }
    }

    // Text input. Read without dequeuing so the application can still use the queue.
    {
        queue := *window.input.keyboard.characterQueue;
        for 0..queue.count - 1 {
            io.AddInputCharacter(io, queue.array[(queue.head + it) % queue.array.count]);
        }
    }

    // Mouse. The position of VulkanJai is y up.
    mouse := *window.input.mouse;
    io.AddMousePosEvent(io, mouse.position.x, cast(float) window.height - mouse.position.y);

    for 0..MOUSE_BUTTON_COUNT - 1 {
        down := mouse.buttonsDown[it];
        if down != bd.mouseButtonsDown[it] {
            io.AddMouseButtonEvent(io, xx it, down);
            bd.mouseButtonsDown[it] = down;
        } else if !down && mouse.buttonsPressed[it] > 0 {
            io.AddMouseButtonEvent(io, xx it, true);
            io.AddMouseButtonEvent(io, xx it, false);
        }
    }

    if mouse.wheel != 0 || mouse.horizontalWheel != 0 {
        io.AddMouseWheelEvent(io, mouse.horizontalWheel, mouse.wheel);
    }
}

UpdateMouseCursor :: (bd: *Backend_Data) {
    io := GetIO();
    window := bd.window;
    if (io.ConfigFlags_ & .NoMouseCursorChange) || glfwGetInputMode(window.window, GLFW_CURSOR) == GLFW_CURSOR_DISABLED {
        bd.lastMouseCursor = null; // Invalidate so that if user changes underlying cursor we will update it next time we can.
        return;
    }

    imguiCursor := GetMouseCursor();
    if imguiCursor == .None || io.MouseDrawCursor {
        // Hide OS mouse cursor if imgui is drawing it or if it wants no cursor
        if bd.lastMouseCursor != null {
            VJ.SetCursorMode(window, .Hidden);
            bd.lastMouseCursor = null;
        }
    } else {
        // Show OS mouse cursor
        cursor := bd.mouseCursors[imguiCursor];
        if !cursor  cursor = bd.mouseCursors[MouseCursor.Arrow];
        if bd.lastMouseCursor != cursor {
            glfwSetCursor(window.window, cursor);
            bd.lastMouseCursor = cursor;
        }
        VJ.SetCursorMode(window, .Normal);
    }
}

MOUSE_BUTTON_COUNT :: 5; // ImGuiMouseButton_COUNT

Key_Mapping :: struct {
    key:      VJ.KeyboardKey;
    imguiKey: Key;
}

KEY_MAP :: Key_Mapping.[
    .{ .Tab,          .Tab },
    .{ .Left,         .LeftArrow },
    .{ .Right,        .RightArrow },
    .{ .Up,           .UpArrow },
    .{ .Down,         .DownArrow },
    .{ .PageUp,       .PageUp },
    .{ .PageDown,     .PageDown },
    .{ .Home,         .Home },
    .{ .End,          .End },
    .{ .Insert,       .Insert },
    .{ .Delete,       .Delete },
    .{ .Backspace,    .Backspace },
    .{ .Space,        .Space },
    .{ .Enter,        .Enter },
    .{ .Escape,       .Escape },
    .{ .Apostrophe,   .Apostrophe },
    .{ .Comma,        .Comma },
    .{ .Minus,        .Minus },
    .{ .Period,       .Period },
    .{ .Slash,        .Slash },
    .{ .Semicolon,    .Semicolon },
    .{ .Equal,        .Equal },
    .{ .LeftBracket,  .LeftBracket },
    .{ .Backslash,    .Backslash },
    .{ .World1,       .Oem102 },
    .{ .RightBracket, .RightBracket },
    .{ .GraveAccent,  .GraveAccent },
    .{ .CapsLock,     .CapsLock },
    .{ .ScrollLock,   .ScrollLock },
    .{ .NumLock,      .NumLock },
    .{ .PrintScreen,  .PrintScreen },
    .{ .Pause,        .Pause },
    .{ .Kp0,          .Keypad0 },
    .{ .Kp1,          .Keypad1 },
    .{ .Kp2,          .Keypad2 },
    .{ .Kp3,          .Keypad3 },
    .{ .Kp4,          .Keypad4 },
    .{ .Kp5,          .Keypad5 },
    .{ .Kp6,          .Keypad6 },
    .{ .Kp7,          .Keypad7 },
    .{ .Kp8,          .Keypad8 },
    .{ .Kp9,          .Keypad9 },
    .{ .KpDecimal,    .KeypadDecimal },
    .{ .KpDivide,     .KeypadDivide },
    .{ .KpMultiply,   .KeypadMultiply },
    .{ .KpSubtract,   .KeypadSubtract },
    .{ .KpAdd,        .KeypadAdd },
    .{ .KpEnter,      .KeypadEnter },
    .{ .KpEqual,      .KeypadEqual },
    .{ .LeftShift,    .LeftShift },
    .{ .LeftControl,  .LeftCtrl },
    .{ .LeftAlt,      .LeftAlt },
    .{ .LeftSuper,    .LeftSuper },
    .{ .RightShift,   .RightShift },
    .{ .RightControl, .RightCtrl },
    .{ .RightAlt,     .RightAlt },
    .{ .RightSuper,   .RightSuper },
    .{ .Menu,         .Menu },
    .{ .D0,           ._0 },
    .{ .D1,           ._1 },
    .{ .D2,           ._2 },
    .{ .D3,           ._3 },
    .{ .D4,           ._4 },
    .{ .D5,           ._5 },
    .{ .D6,           ._6 },
    .{ .D7,           ._7 },
    .{ .D8,           ._8 },
    .{ .D9,           ._9 },
    .{ .A, .A }, .{ .B, .B }, .{ .C, .C }, .{ .D, .D }, .{ .E, .E }, .{ .F, .F }, .{ .G, .G }, .{ .H, .H }, .{ .I, .I },
    .{ .J, .J }, .{ .K, .K }, .{ .L, .L }, .{ .M, .M }, .{ .N, .N }, .{ .O, .O }, .{ .P, .P }, .{ .Q, .Q }, .{ .R, .R },
    .{ .S, .S }, .{ .T, .T }, .{ .U, .U }, .{ .V, .V }, .{ .W, .W }, .{ .X, .X }, .{ .Y, .Y }, .{ .Z, .Z },
    .{ .F1,  .F1 },  .{ .F2,  .F2 },  .{ .F3,  .F3 },  .{ .F4,  .F4 },  .{ .F5,  .F5 },  .{ .F6,  .F6 },
    .{ .F7,  .F7 },  .{ .F8,  .F8 },  .{ .F9,  .F9 },  .{ .F10, .F10 }, .{ .F11, .F11 }, .{ .F12, .F12 },
    .{ .F13, .F13 }, .{ .F14, .F14 }, .{ .F15, .F15 }, .{ .F16, .F16 }, .{ .F17, .F17 }, .{ .F18, .F18 },
    .{ .F19, .F19 }, .{ .F20, .F20 }, .{ .F21, .F21 }, .{ .F22, .F22 }, .{ .F23, .F23 }, .{ .F24, .F24 },
];
