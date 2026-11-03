#include "imgui_internal_wrappers.h"

namespace ImGuiWrappers
{
    ImGuiID GetActiveID() { return ImGui::GetActiveID(); }
    ImGuiID GetFocusID()  { return ImGui::GetFocusID(); }
}
