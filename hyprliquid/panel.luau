-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

local bridge = require("./lib/bridge.luau")
local controls = require("./lib/controls.luau")
local profiles = require("./lib/profiles.luau")
local view = noctalia.state.get("view") or {}
local draft, mode = view.draft, view.theme_mode
local opened, awaiting, dirty = false, false, false
local lastRequest, serial = "", 0
local session = tostring(noctalia.nowMs())
local profileName, profileChoice = "", ""
local profileNameRevision = 0
local overwriteName
local expanded = { Overall = true, Blur = true }
local render

local function send(kind, fields)
    serial = serial + 1
    lastRequest = session .. ":" .. tostring(serial)
    local request = fields or {}
    request.kind, request.id = kind, lastRequest
    awaiting = true
    noctalia.state.set("request", request)
end

local function normalizeProfileName()
    local name = profiles.normalizeName(profileName)
    if name ~= profileName then
        -- Inputs retain their text, so recreate the field to show the new name.
        profileName, profileNameRevision = name, profileNameRevision + 1
    end
    return name
end

local function saveProfile()
    if awaiting or view.pending then return end
    normalizeProfileName()
    for _, profile in ipairs(view.profiles or {}) do
        if profile.name == profileName then
            overwriteName = profileName
            render()
            return
        end
    end
    send("save", { new_name = profileName })
    render()
end

local function cancelOverwrite()
    overwriteName = nil
    render()
end

local function confirmOverwrite()
    if not overwriteName or awaiting or view.pending then return end
    local name = overwriteName
    overwriteName = nil
    send("save", { new_name = name, overwrite = true })
    render()
end

local function edit(flush)
    if not draft then return end
    dirty = true
    send("edit", { profile = bridge.copy(draft), theme_mode = mode, flush = flush == true })
    render()
end

local function flush()
    if dirty then edit(true) end
end

local function text(value, role)
    return ui.label({ text = value, color = role or "on_surface_variant", maxLines = 4 })
end

local function parameterRow(parameter, waiting)
    local name = parameter.name
    local overridden = draft.overrides[name] ~= nil
    local value = view.confirmed.material[name] or parameter.default
    if waiting and overridden then value = draft.overrides[name] end
    local low, high, step, position = controls.slider(parameter, value)
    -- Match the native thumb's step rounding so its render echo is not an edit.
    position = math.max(low, math.min(high, low + math.floor((position - low) / step + 0.5) * step))
    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = controls.label(name), flexGrow = 1 }),
            text(string.format("%.4g", value), "on_surface"),
            ui.button({ key = name .. "-reset", glyph = "restore", tooltip = "Reset to preset value",
                variant = "ghost", controlSize = "sm", enabled = overridden,
                onClick = function() draft.overrides[name] = nil; edit(true) end }),
        }),
        ui.slider({ key = name .. "-slider", min = low, max = high, step = step, value = position,
            onChange = function(raw)
                local number = tonumber(raw)
                -- v5.2 also emits onChange when a retained control receives a
                -- new value from render(). Ignore that echo (including float
                -- formatting noise); only a distinct user value is an edit.
                if number and math.abs(number - position) > 0.000001 * math.max(1, math.abs(position)) then
                    draft.overrides[name] = controls.value(parameter, number)
                    edit(false)
                end
            end,
            onDragEnd = flush,
        }),
        text(overridden and "Custom value" or "From the preset or Hyprland settings"),
    }
    if controls.logarithmic(parameter) then
        table.insert(children, text("Higher values keep the effect closer to the edge."))
    end
    return ui.column({ key = name, gap = 4 }, children)
end

render = function()
    if not opened then return end
    local waiting = awaiting or view.pending == true
    if overwriteName then
        panel.render(ui.column({ key = "overwrite-dialog", gap = 16, padding = 24,
            flexGrow = 1, justify = "center" }, {
            ui.glyph({ name = "device-floppy", size = 32, color = "primary" }),
            ui.label({ text = "Overwrite saved profile?", fontSize = 20, fontWeight = "bold" }),
            text("A profile named “" .. overwriteName .. "” already exists. Replace it with the current settings?"),
            ui.row({ gap = 8, justify = "end" }, {
                ui.button({ key = "overwrite-cancel", text = "Cancel", variant = "outline", onClick = cancelOverwrite }),
                ui.button({ key = "overwrite-confirm", text = "Overwrite", variant = "primary", enabled = not waiting,
                    onClick = confirmOverwrite }),
            }),
        }))
        return
    end
    local body = {}
    local ready = view.available == true and view.confirmed and draft and view.descriptor
    if view.error then table.insert(body, text(view.error, "error")) end
    if view.storage_error then table.insert(body, text(view.storage_error, "error")) end
    if not ready then
        table.insert(body, text("Hyprliquid is unavailable. Make sure the plugin is up to date and loaded in Hyprland, then reconnect."))
        table.insert(body, ui.button({ text = "Reconnect", onClick = function() send("refresh"); render() end }))
    else
        table.insert(body, ui.row({ gap = 12, align = "center" }, {
            ui.label({ text = "Glass effect", flexGrow = 1, fontWeight = "medium" }),
            text(view.confirmed.enabled and "Enabled" or "Disabled"),
            ui.toggle({ key = "enabled", checked = draft.enabled, onChange = function(value)
                local checked = value == "true"
                if checked ~= draft.enabled then draft.enabled = checked; edit(true) end
            end }),
        }))
        local status = "Following Hyprland configuration"
        if view.confirmed.active then
            status = view.storage_error and "Custom settings active"
                or (view.restore_enabled and "Changes saved · restored on restart" or "Changes saved · restoration disabled")
        end
        table.insert(body, text(waiting and "Applying changes…" or status, waiting and "primary" or nil))
        local presets, presetIndex = {}, -1
        for _, preset in ipairs(view.descriptor.presets) do
            if preset.valid then
                table.insert(presets, preset.id)
                if preset.id == draft.base_preset then presetIndex = #presets - 1 end
            end
        end
        table.insert(body, text("Base preset"))
        table.insert(body, ui.select({ key = "preset", options = presets, selectedIndex = presetIndex,
            onChange = function(index)
                local preset = presets[(tonumber(index) or -1) + 1]
                if preset and preset ~= draft.base_preset then draft.base_preset, draft.overrides = preset, {}; edit(true) end
            end }))
        local modes = { "dark", "light", "follow" }
        local modeIndex = mode == "follow" and 2 or (mode == "light" and 1 or 0)
        table.insert(body, text("Theme"))
        table.insert(body, ui.select({ key = "theme", options = { "Dark", "Light", "Follow Noctalia" }, selectedIndex = modeIndex,
            onChange = function(index)
                local selected = modes[(tonumber(index) or -1) + 1]
                if selected and selected ~= mode then mode = selected; edit(true) end
            end }))
        table.insert(body, ui.button({ text = "Reset to configuration", glyph = "restore", variant = "outline",
            onClick = function() dirty = false; send("reset"); render() end }))

        table.insert(body, ui.button({ key = "profiles-heading", text = "Saved profiles",
            glyph = expanded.Profiles and "chevron-down" or "chevron-right", variant = "ghost", contentAlign = "start",
            onClick = function() expanded.Profiles = not expanded.Profiles; render() end }))
        local profileRows = {}
        table.insert(profileRows, ui.separator({}))
        table.insert(profileRows, ui.label({ text = "Saved profiles", fontWeight = "bold" }))
        local choices, chosen = { "Select a saved profile…" }, 0
        local savedProfiles = view.profiles or {}
        for index, profile in ipairs(savedProfiles) do
            table.insert(choices, profile.name)
            if profile.name == profileChoice then chosen = index end
        end
        table.insert(profileRows, ui.select({ key = "saved", options = choices, selectedIndex = chosen, enabled = not waiting,
            onChange = function(index)
                local profile = savedProfiles[tonumber(index) or 0]
                if profile and profile.name ~= view.selected then
                    profileChoice = profile.name; dirty = false; send("select", { name = profile.name }); render()
                end
            end }))
        table.insert(profileRows, text(view.selected ~= "" and ("Selected: " .. (view.selected or "")) or "No named profile selected"))
        table.insert(profileRows, ui.input({ key = "profile-name-" .. tostring(profileNameRevision), value = profileName, placeholder = "Profile name",
            onChange = function(value) profileName = value end }))
        table.insert(profileRows, ui.row({ gap = 8 }, {
            ui.button({ key = "profile-save", text = "Save", glyph = "device-floppy", enabled = not waiting,
                onClick = saveProfile }),
            ui.button({ text = "Rename", enabled = not waiting and chosen > 0,
                onClick = function()
                    local name = normalizeProfileName()
                    send("rename", { name = profileChoice, new_name = name }); profileChoice = name; render()
                end }),
            ui.button({ text = "Delete", variant = "destructive", enabled = not waiting and chosen > 0,
                onClick = function() send("delete", { name = profileChoice }); profileChoice = ""; render() end }),
        }))
        table.insert(profileRows, text("Changes are saved automatically. Save keeps a named snapshot you can return to later."))

        if expanded.Profiles then
            table.insert(body, ui.column({ key = "profiles", gap = 10 }, profileRows))
        end

        local parameters = {}
        for _, parameter in ipairs(view.descriptor.parameters) do parameters[parameter.name] = parameter end
        -- Hide obsolete parameters also reported by older plugin versions.
        local covered = { use_measured_face = true }
        for _, group in ipairs(controls.groups) do
            local children = {
                ui.button({ key = group.name .. "-heading", text = group.name, glyph = expanded[group.name] and "chevron-down" or "chevron-right",
                    variant = "ghost", contentAlign = "start",
                    onClick = function() expanded[group.name] = not expanded[group.name]; render() end }),
            }
            if expanded[group.name] and group.name == "Advanced coverage" then
                table.insert(children, text("Edge coverage only. Window radius, borders and rounding stay under Hyprland’s control."))
            end
            for _, name in ipairs(group.fields) do
                covered[name] = true
                if expanded[group.name] and parameters[name] then table.insert(children, parameterRow(parameters[name], waiting)) end
            end
            table.insert(body, ui.column({ key = group.name, gap = 12 }, children))
        end
        -- Future parameters can be presented without copying backend metadata.
        for _, parameter in ipairs(view.descriptor.parameters) do
            if not covered[parameter.name] then table.insert(body, parameterRow(parameter, waiting)) end
        end
    end
    panel.render(ui.column({ gap = 12, flexGrow = 1, align = "stretch" }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "droplet", size = 22 }),
            ui.label({ text = "Hyprliquid", fontSize = 20, fontWeight = "bold", flexGrow = 1 }),
            ui.button({ glyph = "x", variant = "ghost", tooltip = "Close", onClick = function() panel.close() end }),
        }),
        ui.scroll({ key = "controls", flexGrow = 1, gap = 12, align = "stretch" }, body),
    }))
end

noctalia.state.watch("view", function(value)
    view = value or {}
    if not awaiting or view.ack == lastRequest then
        awaiting = false
        draft, mode = bridge.copy(view.draft), view.theme_mode
        if not view.pending then dirty = false end
    end
    render()
end)

function onOpen()
    opened = true
    overwriteName = nil
    view = noctalia.state.get("view") or {}
    draft, mode = bridge.copy(view.draft), view.theme_mode
    awaiting, dirty = false, false
    profileChoice = view.selected or ""
    noctalia.state.set("panel_open", true)
    render()
end

function onClose()
    overwriteName = nil
    flush()
    opened = false
    noctalia.state.set("panel_open", false)
end

function onExit()
    noctalia.state.set("panel_open", false)
end
