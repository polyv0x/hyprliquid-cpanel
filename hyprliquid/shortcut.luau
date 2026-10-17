local function render(view)
    view = view or {}
    shortcut.setLabel("Hyprliquid")
    shortcut.setIcon("droplet")
    shortcut.setActive(view.available == true and view.confirmed.enabled == true)
    shortcut.setEnabled(true)
end

noctalia.state.watch("view", render)
render(noctalia.state.get("view"))

function onClick()
    noctalia.togglePanel("polyv0x/hyprliquid:panel")
end
