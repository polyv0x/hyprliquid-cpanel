-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

local function render(view)
    view = view or {}
    local state = view.confirmed
    local status = view.available and (state.enabled and "On" or "Off") or "Unavailable"
    barWidget.setGlyph("droplet")
    barWidget.setText("Hyprliquid")
    barWidget.setTooltip("Hyprliquid · " .. status .. (view.error and ("\n" .. view.error) or ""))
end

noctalia.state.watch("view", render)
render(noctalia.state.get("view"))

function onClick()
    noctalia.togglePanel("polyv0x/hyprliquid:panel")
end
