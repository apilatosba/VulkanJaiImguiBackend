// Real (non-inline) functions wrapping the inline functions of imgui_internal.h.
//
// Inline functions have no symbol in the compiled ImGui library, so they can't be called from Jai.
// The wrappers are compiled into the library (see generate.jai) and get bindings like the functions of imgui.h.
// They are in their own namespace because they can't have the same name as the inline functions in "ImGui".
// generate.jai flattens it, so in Jai they have the names of the functions they wrap.

#pragma once

#include "../source/imgui.h"
#include "../source/imgui_internal.h"

namespace ImGuiWrappers
{
    IMGUI_API ImGuiID GetActiveID(); // The ID of the item that is being interacted with (e.g. a slider being dragged), 0 if none.
    IMGUI_API ImGuiID GetFocusID();  // The ID of the item that has the keyboard/gamepad navigation focus, 0 if none.
}
