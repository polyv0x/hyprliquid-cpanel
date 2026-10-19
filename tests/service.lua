-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

-- Deterministic host harness. Run the production modules with delayed IPC replies
-- and filesystem failures; the nested test exercises Noctalia's real JSON/VM/UI.
local root = arg[1] or "."
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function expect(condition, message) assert(condition, message or "expectation failed") end

local function host(initialFiles)
    local h = { now = 0, dark = true, state = {}, watchers = {}, queue = {}, files = initialFiles or {}, tokens = {}, token = 0, writes = 0, calls = {}, restore = true }
    local n = {}
    h.noctalia = n
    n.json = {
        encode = function(value)
            h.token = h.token + 1
            local token = "json:" .. h.token
            h.tokens[token] = copy(value)
            return token
        end,
        decode = function(value) return copy(h.tokens[value]) end,
    }
    n.state = {
        get = function(key) return copy(h.state[key]) end,
        set = function(key, value)
            h.state[key] = copy(value)
            for _, callback in ipairs(h.watchers[key] or {}) do callback(copy(value)) end
        end,
        watch = function(key, fn)
            h.watchers[key] = h.watchers[key] or {}
            table.insert(h.watchers[key], fn)
        end,
    }
    n.getConfig = function(key) expect(key == "restore_profile"); return h.restore end
    n.nowMs = function() return h.now end
    n.isDarkMode = function() return h.dark end
    n.setUpdateInterval = function(interval) h.interval = interval end
    n.pluginDataDir = function() return "/data" end
    n.fileExists = function(path) return h.files[path] ~= nil end
    n.readFile = function(path) return h.files[path] end
    n.writeFile = function(path, value)
        h.writes = h.writes + 1
        if h.failWrite then return false, "disk full" end
        h.files[path] = value
        return true
    end
    n.renameFile = function(from, to)
        if h.failRename then return false, "rename failed" end
        h.files[to], h.files[from] = h.files[from], nil
        return true
    end
    n.runAsync = function(argv, callback)
        expect(type(argv) == "table" and argv[1] == "hyprctl" and argv[2] == "hyprliquid:control", "transport must use direct argv")
        if h.reject then return false end
        expect(#h.queue == 0, "more than one IPC request in flight")
        local request = n.json.decode(argv[3])
        table.insert(h.queue, { request = request, callback = callback })
        table.insert(h.calls, request)
        return true
    end
    local function load(path, extras)
        local env = setmetatable({ noctalia = n }, { __index = _G })
        for key, value in pairs(extras or {}) do env[key] = value end
        env.require = function(relative)
            local directory = path:match("^(.*)/")
            local module = load(directory .. "/" .. relative)
            return module.result
        end
        env.result = assert(loadfile(path, "t", env))()
        return env
    end
    h.load = load
    h.start = function()
        h.watchers, h.queue = {}, {}
        h.service = load(root .. "/hyprliquid/service.luau")
    end
    h.reply = function(reply, failed)
        local call = table.remove(h.queue, 1)
        expect(call, "expected an IPC request")
        call.callback(failed or { exitCode = 0, stdout = n.json.encode(reply), stderr = "", timedOut = false })
        return call.request
    end
    h.tick = function(ms) h.now = h.now + ms; h.service.update() end
    h.request = function(kind, fields)
        local request = fields or {}
        request.kind, request.id = kind, "intent:" .. tostring(#h.calls) .. ":" .. tostring(h.now)
        n.state.set("request", request)
    end
    h.view = function() return h.state.view end
    return h
end

local baseline = { epoch = "epoch1", revision = 1, generation = 1, enabled = true, base_preset = "soft-glass", theme = "dark",
    active = false, panel = { overrides = {} }, material = { rim_opacity = 0.6, inner_refraction_amount = -10, coverage_offset = -0.25 } }
local function reply(state)
    return { api = 1, ok = true, state = copy(state), parameters = {
        { name = "rim_opacity", min = 0, max = 1.6, default = 0 },
        { name = "inner_refraction_amount", min = -120, max = 120, default = 0 },
        { name = "coverage_offset", min = -1, max = 1, default = 0.1 },
        { name = "outer_refraction_inv_height", min = 0.001, max = 1, default = 0.034 },
    }, presets = { { id = "soft-glass", valid = true }, { id = "clear-glass", valid = true } } }
end
local function applied(state, profile)
    local result = copy(state)
    result.revision, result.active = result.revision + 1, true
    result.panel = copy(profile)
    result.panel.overrides = result.panel.overrides or {}
    result.base_preset, result.theme, result.enabled = profile.base_preset, profile.theme, profile.enabled
    for k, v in pairs(result.panel.overrides) do result.material[k] = v end
    return result
end
local function newHost()
    local h = host()
    h.start()
    h.reply(reply(baseline))
    return h
end
local function edit(h, value, flush, mode)
    local profile = copy(h.view().draft)
    profile.overrides.inner_refraction_amount = value
    h.request("edit", { profile = profile, theme_mode = mode or "dark", flush = flush })
end

local h = newHost()
for i = 1, 40 do edit(h, -i, false); h.now = h.now + 1 end
expect(#h.calls == 1, "drag should coalesce")
h.tick(75)
expect(#h.queue == 1 and h.queue[1].request.profile.overrides.inner_refraction_amount == -40)
local first = copy(h.queue[1].request.profile)
edit(h, -79, true)
expect(#h.queue == 1, "final drag must wait for in-flight write")
expect(h.view().draft.overrides.inner_refraction_amount == -79 and h.view().pending)
local state = applied(baseline, first)
h.reply(reply(state))
expect(h.view().draft.overrides.inner_refraction_amount == -79, "old reply overwrote newer intent")
expect(h.noctalia.json.decode(h.files["/data/profiles.json"]).current.overrides.inner_refraction_amount == -40,
    "autosave must contain the accepted value, not the newer pending draft")
expect(h.queue[1].request.if_revision == state.revision)
state = applied(state, h.queue[1].request.profile)
h.reply(reply(state))
expect(not h.view().pending and h.view().confirmed.material.inner_refraction_amount == -79)
expect(h.noctalia.json.decode(h.files["/data/profiles.json"]).current.overrides.inner_refraction_amount == -79)
print("PASS: coalescing, one in-flight request, late reply and final signed drag")

local live = newHost()
edit(live, -1, false); live.tick(60); edit(live, -2, false); live.tick(15)
expect(#live.queue == 1 and live.queue[1].request.profile.overrides.inner_refraction_amount == -2,
    "a continuous drag must not postpone the live-update deadline")

h.request("save", { new_name = "Negative glass" })
expect(h.view().selected == "Negative_glass" and #h.view().profiles == 1)
local file = h.files["/data/profiles.json"]
expect(h.noctalia.json.decode(file).profiles[1].overrides.inner_refraction_amount == -79)
h.failRename = true
h.request("rename", { name = "Negative_glass", new_name = "Renamed" })
expect(h.files["/data/profiles.json"] == file and h.view().profiles[1].name == "Negative_glass")
h.failRename = false
h.request("rename", { name = "Negative_glass", new_name = "Renamed" })
expect(h.view().selected == "Renamed")
h.start()
h.reply(reply(state))
expect(#h.queue == 0 and h.view().selected == "Renamed", "restart should adopt matching checkpoint")
local reloaded = copy(baseline)
reloaded.revision, reloaded.generation = state.revision + 1, 2
h.request("refresh"); h.tick(1); h.reply(reply(reloaded)); h.tick(75)
expect(h.queue[1].request.profile.overrides.inner_refraction_amount == -79, "reload must restore saved profile")
state = applied(reloaded, h.queue[1].request.profile); h.reply(reply(state))
local external = copy(state)
external.revision = external.revision + 1
external.material.inner_refraction_amount = -25
h.request("refresh"); h.tick(1); h.reply(reply(external))
expect(h.view().selected == "" and #h.queue == 0, "terminal edit must release ownership")
h.request("delete", { name = "Renamed" })
expect(#h.view().profiles == 0 and #h.queue == 0, "deleting profile must not mutate renderer")
print("PASS: atomic persistence, rename failure, restart, reload restoration and external ownership")

h = newHost()
h.request("save", { new_name = "Before" })
h.request("save", { new_name = "Replace me" })
h.request("save", { new_name = "After" })
local originals = copy(h.view().profiles)
local replacement = { base_preset = "clear-glass", enabled = false, overrides = { inner_refraction_amount = -31 } }
h.request("edit", { profile = replacement, theme_mode = "follow", flush = true })
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
file = h.files["/data/profiles.json"]
for _, confirmation in ipairs({ false, "true" }) do
    h.request("save", { new_name = "Replace me", overwrite = confirmation })
    expect(h.view().error and h.files["/data/profiles.json"] == file and equal(h.view().profiles, originals),
        "duplicate saves require explicit boolean confirmation")
end
h.request("rename", { name = "Before", new_name = "Replace me", overwrite = true })
expect(h.view().error and equal(h.view().profiles, originals), "overwrite confirmation must not bypass rename collisions")
edit(h, -32, false, "follow")
h.request("save", { new_name = "Replace me", overwrite = true })
expect(h.view().error and h.files["/data/profiles.json"] == file, "overwrite must wait for pending edits")
h.tick(75); state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
file = h.files["/data/profiles.json"]
local callsBeforeOverwrite = #h.calls
h.failRename = true
h.request("save", { new_name = "Replace me", overwrite = true })
expect(h.view().storage_error and h.files["/data/profiles.json"] == file and equal(h.view().profiles, originals),
    "failed overwrite must preserve the original profile in memory and on disk")
h.failRename = false
h.request("save", { new_name = "Replace me", overwrite = true })
local overwritten = h.noctalia.json.decode(h.files["/data/profiles.json"])
expect(not h.view().error and not h.view().storage_error and #overwritten.profiles == 3)
expect(equal(overwritten.profiles[1], originals[1]) and equal(overwritten.profiles[3], originals[3]),
    "overwrite must preserve other profiles and list order")
expect(overwritten.profiles[2].name == "Replace_me" and overwritten.profiles[2].base_preset == "clear-glass"
    and overwritten.profiles[2].enabled == false and overwritten.profiles[2].theme_mode == "follow"
    and overwritten.profiles[2].overrides.inner_refraction_amount == -32)
expect(overwritten.selected == "Replace_me" and overwritten.current.overrides.inner_refraction_amount == -32)
expect(#h.calls == callsBeforeOverwrite, "saving an overwrite must not reapply the renderer")
h.start(); h.reply(reply(state))
expect(#h.queue == 0 and h.view().selected == "Replace_me" and equal(h.view().profiles, overwritten.profiles),
    "overwritten profiles must survive restart")
print("PASS: confirmed overwrite, pending edits, atomic failure, profile order and restart")

h = newHost()
h.request("save", { new_name = " Glass  name " })
expect(h.view().selected == "_Glass__name_" and h.view().profiles[1].name == "_Glass__name_",
    "every space, including surrounding and repeated spaces, must become an underscore")
h.request("rename", { name = "_Glass__name_", new_name = "Renamed glass" })
expect(h.view().selected == "Renamed_glass" and h.view().profiles[1].name == "Renamed_glass")
file = h.files["/data/profiles.json"]
h.request("save", { new_name = "Renamed glass" })
expect(h.view().error and h.files["/data/profiles.json"] == file,
    "duplicate checks must use the name after spaces become underscores")
for _, name in ipairs({ "", false, "bad\tname" }) do
    h.request("save", { new_name = name })
    expect(h.view().error and h.files["/data/profiles.json"] == file, "invalid names must remain rejected")
end
print("PASS: space normalization for save, rename and duplicate detection")

h = newHost()
edit(h, -5, true, "follow")
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
h.dark = false; h.tick(1000)
expect(h.queue[1].request.profile.theme == "light")
state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
edit(h, -6, true, "dark")
state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
h.dark = true; h.tick(1000); h.dark = false; h.tick(1000)
expect(#h.queue == 0 and h.view().theme_mode == "dark")
edit(h, -7, true)
local failed = reply(state); failed.ok, failed.error, failed.code = false, "changed elsewhere", "revision_conflict"
h.reply(failed)
expect(h.view().error == "changed elsewhere" and not h.view().pending and h.view().confirmed.material.inner_refraction_amount == -6)
edit(h, -8, true)
h.reply(nil, { exitCode = 0, stdout = "truncated", timedOut = true })
expect(not h.view().available and not h.view().pending)
h.tick(1); h.reply(reply(state))
expect(h.view().available and #h.queue == 0)
h.reject = true; edit(h, -9, true)
expect(not h.view().available and h.view().error:find("hyprctl", 1, true))
print("PASS: follow theme, explicit theme, conflicts, timeouts, failed starts and reconnect")

h = host({ ["/data/profiles.json"] = "broken-json" })
h.start(); h.reply(reply(baseline)); h.request("save", { new_name = "Unsafe overwrite" })
expect(h.files["/data/profiles.json"] == "broken-json" and h.writes == 0 and h.view().storage_error)
print("PASS: corrupt profile file preserved")

h = host(); h.start()
local incompatible = reply(baseline); incompatible.api = 0
h.reply(incompatible)
expect(not h.view().available and h.view().error:find("incompatible", 1, true))
h.request("refresh"); h.tick(1); h.reply(reply(baseline))
expect(h.view().available)
print("PASS: incompatible renderer recovery")

-- Current settings persist independently of named profiles.
h = newHost()
edit(h, -36, true, "follow")
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
local autosaved = h.noctalia.json.decode(h.files["/data/profiles.json"])
expect(autosaved.version == 2 and autosaved.selected == "" and #autosaved.profiles == 0)
expect(autosaved.current.theme_mode == "follow" and autosaved.current.overrides.inner_refraction_amount == -36)
h.start(); h.reply(reply(state))
expect(#h.queue == 0 and h.view().theme_mode == "follow", "Noctalia restart must adopt unsaved named-profile-free edits")
local restarted = copy(baseline)
restarted.epoch = "epoch2"
h.dark = false
h.start(); h.reply(reply(restarted)); h.tick(75)
expect(h.queue[1].request.profile.overrides.inner_refraction_amount == -36 and h.queue[1].request.profile.theme == "light",
    "Hyprland restart must restore edits and resolve the current shell theme")
state = applied(restarted, h.queue[1].request.profile); h.reply(reply(state))
reloaded = copy(restarted); reloaded.revision, reloaded.generation = state.revision + 1, 2
h.request("refresh"); h.tick(1); h.reply(reply(reloaded)); h.tick(75)
expect(h.queue[1].request.profile.overrides.inner_refraction_amount == -36, "config reload must restore automatic settings")
state = applied(reloaded, h.queue[1].request.profile); h.reply(reply(state))
local goodFile = h.files["/data/profiles.json"]
edit(h, -999, true)
local rejected = reply(state); rejected.ok, rejected.code, rejected.error = false, "invalid_value", "Out of range"
h.reply(rejected)
expect(h.files["/data/profiles.json"] == goodFile and h.view().theme_mode == "follow",
    "rejected edits must preserve the last good autosave and theme choice")
h.failRename = true; edit(h, -37, true)
state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
expect(h.files["/data/profiles.json"] == goodFile and h.view().storage_error,
    "failed autosaves must preserve the previous file and report the error")
h.failRename = false; edit(h, -38, true)
state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
expect(not h.view().storage_error)
h.request("save", { new_name = "Snapshot" })
edit(h, -39, true); state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
expect(h.view().selected == "" and h.view().profiles[1].overrides.inner_refraction_amount == -38,
    "autosaving an edit must not overwrite a named profile")
h.request("select", { name = "Snapshot" }); state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
h.request("delete", { name = "Snapshot" })
h.start(); h.reply(reply(baseline)); h.tick(75)
expect(h.queue[1].request.profile.overrides.inner_refraction_amount == -38,
    "deleting a named profile must retain the current settings")
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
h.request("reset")
local reset = copy(baseline); reset.revision = state.revision + 1
h.reply(reply(reset))
autosaved = h.noctalia.json.decode(h.files["/data/profiles.json"])
expect(autosaved.current == nil and autosaved.checkpoint == nil and autosaved.selected == "")
h.start(); h.reply(reply(restarted)); h.tick(75)
expect(#h.queue == 0, "reset material must not resurrect after restart")
print("PASS: automatic persistence, startup/reload, theme, rejection, storage failure, snapshots and reset")

h = newHost(); edit(h, -42, true)
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
h.restore = false; h.start(); h.reply(reply(restarted)); h.tick(75)
expect(#h.queue == 0, "restore preference must also apply to automatic settings")
h.restore = true; h.start()
h.reply(nil, { exitCode = 1, stdout = "", stderr = "not loaded" })
expect(not h.view().available)
h.tick(15000); h.reply(reply(restarted)); h.tick(75)
expect(h.queue[1].request.profile.overrides.inner_refraction_amount == -42,
    "startup before the renderer loads must recover and restore later")
print("PASS: restoration preference and delayed renderer startup")

h = newHost()
local legacy = { version = 1, profiles = { { name = "Legacy", base_preset = "lens", enabled = false,
    theme_mode = "dark", overrides = { inner_refraction_amount = -63, use_measured_face = 0.5 } } }, selected = "Legacy" }
h.files["/data/profiles.json"] = h.noctalia.json.encode(legacy)
h.start(); h.reply(reply(baseline)); h.tick(75)
expect(h.queue[1].request.profile.enabled == false and h.queue[1].request.profile.overrides.inner_refraction_amount == -63)
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
autosaved = h.noctalia.json.decode(h.files["/data/profiles.json"])
expect(autosaved.version == 2 and autosaved.selected == "Legacy" and autosaved.profiles[1].name == "Legacy")
expect(autosaved.current.enabled == false)
h = host(); h.start(); h.reply(reply(state))
expect(#h.queue == 0 and h.noctalia.json.decode(h.files["/data/profiles.json"]).current.enabled == false,
    "first activation must capture an existing active material without a renderer write")
local badCurrent = { version = 2, profiles = {}, selected = "", current = { base_preset = "lens", enabled = true,
    theme_mode = "dark", overrides = { blur_sigma = "bad" } } }
h.files["/data/profiles.json"] = h.noctalia.json.encode(badCurrent)
local badFile = h.files["/data/profiles.json"]
h.start(); h.reply(reply(state))
expect(h.files["/data/profiles.json"] == badFile and h.view().storage_error, "invalid automatic settings must be preserved")
print("PASS: version 1 migration, disabled effect, active material capture and invalid storage")

-- Exercise callbacks from actual panel trees, including zero-based selectors.
h = newHost()
local ui = setmetatable({}, { __index = function(_, kind) return function(props, children) return { kind = kind, props = props, children = children or {} } end end })
local panelEnv = h.load(root .. "/hyprliquid/panel.luau", { ui = ui, panel = { render = function(tree) h.tree = tree end, close = function() end } })
panelEnv.onOpen()
local function find(node, key)
    if node.props.key == key or node.kind == key then return node end
    for _, child in ipairs(node.children) do local found = find(child, key); if found then return found end end
end
find(h.tree, "preset").props.onChange("1", "clear-glass")
expect(h.queue[1].request.profile.base_preset == "clear-glass")
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
for _, choice in ipairs({ { index = "1", mode = "light" }, { index = "0", mode = "dark" } }) do
    find(h.tree, "theme").props.onChange(choice.index)
    expect(h.queue[1].request.profile.theme == choice.mode and h.queue[1].request.profile.base_preset == "clear-glass",
        "theme selector must send the selected variant without changing the base preset")
    expect(h.queue[1].request.profile.overrides == nil, "theme selector must inherit renderer variants without pinning scalar values")
    state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
    local savedTheme = h.noctalia.json.decode(h.files["/data/profiles.json"])
    expect(h.view().theme_mode == choice.mode and savedTheme.current.theme_mode == choice.mode)
end
find(h.tree, "Refraction-heading").props.onClick()
find(h.tree, "inner_refraction_amount-slider").props.onChange("-55")
find(h.tree, "inner_refraction_amount-slider").props.onDragEnd()
expect(h.queue[1].request.profile.overrides.inner_refraction_amount == -55)
state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
local callsBeforeEcho = #h.calls
local logarithmicSlider = find(h.tree, "outer_refraction_inv_height-slider").props
local snapped = logarithmicSlider.min + math.floor((logarithmicSlider.value - logarithmicSlider.min) / logarithmicSlider.step + 0.5) * logarithmicSlider.step
logarithmicSlider.onChange(string.format("%.6f", snapped))
expect(#h.calls == callsBeforeEcho and not h.view().pending, "native step rounding must not create a material override")
find(h.tree, "inner_refraction_amount-slider").props.onChange("-55.000000")
find(h.tree, "inner_refraction_amount-slider").props.onDragEnd()
find(h.tree, "preset").props.onChange("1", "clear-glass")
find(h.tree, "enabled").props.onChange("true")
expect(#h.calls == callsBeforeEcho and not h.view().pending, "render echoes must not create user edits")
find(h.tree, "inner_refraction_amount-reset").props.onClick()
expect(h.queue[1].request.profile.overrides == nil, "field reset must remove sparse override")
state = applied(state, h.queue[1].request.profile); h.reply(reply(state))
find(h.tree, "Rim-heading").props.onClick()
local invalidProfile = copy(h.view().draft)
invalidProfile.overrides.rim_opacity = 999
h.request("edit", { profile = invalidProfile, theme_mode = "dark", flush = true })
local invalidAck = h.view().ack
find(h.tree, "rim_opacity-slider").props.onChange("1.600000")
expect(h.view().ack == invalidAck and h.view().draft.overrides.rim_opacity == 999,
    "native clamping of a pending invalid profile must not create an edit")
print("PASS: actual panel callbacks, select index, drag-end flush and per-field reset")

h = newHost()
local overwritePanel = h.load(root .. "/hyprliquid/panel.luau", { ui = ui,
    panel = { render = function(tree) h.tree = tree end, close = function() end } })
overwritePanel.onOpen()
find(h.tree, "profiles-heading").props.onClick()
find(h.tree, "input").props.onChange("My glass")
find(h.tree, "profile-save").props.onClick()
expect(#h.view().profiles == 1 and h.view().selected == "My_glass" and not find(h.tree, "overwrite-dialog"),
    "a new name must save without an overwrite dialog")
expect(find(h.tree, "input").props.value == "My_glass", "Save must show the normalized name in the input")
edit(h, -48, true, "follow")
state = applied(baseline, h.queue[1].request.profile); h.reply(reply(state))
file = h.files["/data/profiles.json"]
local writesBeforeDialog = h.writes
find(h.tree, "input").props.onChange("My glass")
find(h.tree, "profile-save").props.onClick()
expect(find(h.tree, "overwrite-dialog") and not find(h.tree, "profile-save") and not find(h.tree, "preset"),
    "duplicate Save must show a modal confirmation instead of editable controls")
expect(h.writes == writesBeforeDialog and h.files["/data/profiles.json"] == file and not h.view().error,
    "opening the confirmation must not submit a save or show a duplicate-name error")
find(h.tree, "overwrite-cancel").props.onClick()
expect(not find(h.tree, "overwrite-dialog") and find(h.tree, "input").props.value == "My_glass")
expect(h.writes == writesBeforeDialog and h.files["/data/profiles.json"] == file, "Cancel must preserve the saved profile")
find(h.tree, "profile-save").props.onClick()
overwritePanel.onClose(); overwritePanel.onOpen()
expect(not find(h.tree, "overwrite-dialog") and h.files["/data/profiles.json"] == file,
    "closing or dismissing the panel must cancel the confirmation")
find(h.tree, "profile-save").props.onClick()
find(h.tree, "overwrite-confirm").props.onClick()
expect(not find(h.tree, "overwrite-dialog") and not h.view().error and #h.view().profiles == 1)
expect(h.state.request.overwrite == true and h.view().selected == "My_glass"
    and h.view().profiles[1].overrides.inner_refraction_amount == -48 and h.view().profiles[1].theme_mode == "follow")
expect(h.writes == writesBeforeDialog + 1, "Confirm must replace the profile exactly once")
print("PASS: panel save, overwrite dialog, Cancel, dismissal and confirmed replacement")
