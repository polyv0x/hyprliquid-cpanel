-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

local bridge = require("./lib/bridge.luau")
local profiles = require("./lib/profiles.luau")
local data, storagePath, storageError = profiles.load()
local priorView = noctalia.state.get("view")
local confirmed, descriptor, draft
local available, busy, writing = false, false, false
local pending, due, nextPoll = nil, 0, 0
local themeMode, lastId, errorMessage = nil, "", nil
local open = noctalia.state.get("panel_open") == true
local firstRead = true
local pump, probe

local function publish()
    noctalia.state.set("view", {
        available = available, error = errorMessage, storage_error = storageError,
        confirmed = confirmed, descriptor = descriptor, draft = draft,
        theme_mode = themeMode, profiles = data.profiles, selected = data.selected,
        restore_enabled = noctalia.getConfig("restore_profile") == true,
        pending = pending ~= nil or writing, ack = lastId,
    })
    noctalia.setUpdateInterval((open or pending or busy) and 75 or 1000)
end

local function persist(nextData, keepOnFailure)
    local ok, err = profiles.write(storagePath, nextData)
    if ok or keepOnFailure then data = nextData end
    storageError = ok and nil or err
    return ok
end

local function detach()
    if data.selected ~= "" or data.current or data.checkpoint then
        local nextData = bridge.copy(data)
        nextData.selected, nextData.current, nextData.checkpoint = "", nil, nil
        -- Yield ownership even if the disk is unwritable.
        persist(nextData, true)
    end
end

local function remember(mode, selected, reset)
    local nextData = bridge.copy(data)
    nextData.selected = selected or ""
    nextData.current = not reset and profiles.snapshot(confirmed, mode) or nil
    nextData.checkpoint = not reset and profiles.checkpoint(confirmed) or nil
    persist(nextData, true)
end

local function enqueue(profile, mode, selected, flush, reset)
    local wasPending = pending ~= nil
    pending = { profile = bridge.copy(profile), mode = mode, selected = selected or "", reset = reset }
    draft, themeMode = bridge.copy(profile), mode
    errorMessage = nil
    -- Keep the first deadline during a continuous drag, so it updates live.
    if flush or not wasPending then due = noctalia.nowMs() + (flush and 0 or 75) end
    publish()
    if flush then pump() end
end

local function changed(left, right)
    return not left or left.epoch ~= right.epoch or left.revision ~= right.revision
end

local function release(state, message)
    pending = nil
    confirmed = state
    draft = state and bridge.profile(state) or nil
    themeMode = state and state.theme or nil
    detach()
    errorMessage = message
end

local function maybeRestore(state, previous)
    local saved = data.current
    if not saved or noctalia.getConfig("restore_profile") ~= true then return false end
    local checkpoint = data.checkpoint
    if checkpoint and checkpoint.epoch == state.epoch and checkpoint.revision == state.revision then
        themeMode = saved.theme_mode
        return false
    end
    local restarted = not checkpoint or checkpoint.epoch ~= state.epoch or checkpoint.generation ~= state.generation
    if not state.active and restarted and (firstRead or changed(previous, state)) then
        enqueue(profiles.renderer(saved), saved.theme_mode, data.selected, false)
        return true
    end
    release(state, "Glass settings changed elsewhere; automatic restoration stopped")
    return false
end

probe = function()
    if busy then return end
    busy = true
    nextPoll = noctalia.nowMs() + (open and 2000 or 15000)
    publish()
    bridge.call({ op = "describe" }, function(reply, err)
        busy = false
        if not reply or not reply.ok or type(reply.parameters) ~= "table" or type(reply.presets) ~= "table" then
            available = false
            pending = nil
            draft = confirmed and bridge.profile(confirmed) or nil
            errorMessage = err or "Could not read the available glass controls. Update Hyprliquid and reconnect."
            publish()
            return
        end
        local previous, wasAvailable = confirmed, available
        confirmed, descriptor, available = reply.state, reply, true
        -- Adopt an already-active material when upgrading from profiles-only
        -- storage. This saves today's settings without reapplying the effect.
        local captureActive = firstRead and confirmed.active and not data.current and data.selected == ""
        if not wasAvailable then errorMessage = nil end
        if changed(previous, confirmed) then
            if pending then
                release(confirmed, "Glass settings changed elsewhere; pending changes cancelled")
            else
                draft, themeMode = bridge.profile(confirmed), confirmed.theme
                if not maybeRestore(confirmed, previous) and not firstRead and changed(previous, confirmed) then
                    -- An external runtime edit in the same renderer generation wins.
                    if previous and previous.epoch == confirmed.epoch and previous.generation == confirmed.generation then
                        release(confirmed, "Glass settings changed elsewhere")
                    end
                end
            end
        elseif firstRead then
            maybeRestore(confirmed, previous)
        end
        if captureActive then
            if priorView and priorView.confirmed and not changed(priorView.confirmed, confirmed) then
                themeMode = priorView.theme_mode or confirmed.theme
            end
            remember(themeMode, "", false)
        end
        firstRead = false
        publish()
        pump()
    end)
end

pump = function()
    if busy or not pending or not available or not confirmed or noctalia.nowMs() < due then return end
    local sent = pending
    pending, busy, writing = nil, true, true
    local request = { op = sent.reset and "reset" or "apply", if_epoch = confirmed.epoch, if_revision = confirmed.revision }
    if not sent.reset then request.profile = sent.profile end
    publish()
    bridge.call(request, function(reply, err)
        busy, writing = false, false
        if not reply then
            available, pending = false, nil
            draft = bridge.profile(confirmed)
            themeMode = confirmed.theme
            errorMessage = err
            nextPoll = 0
        elseif not reply.ok then
            if changed(confirmed, reply.state) then
                release(reply.state, err)
            else
                -- A rejected value must not erase the last accepted settings.
                pending = nil
                draft = bridge.profile(confirmed)
                themeMode = data.current and data.current.theme_mode or confirmed.theme
                errorMessage = err
            end
        else
            confirmed = reply.state
            remember(sent.mode, sent.selected, sent.reset)
            if not pending then
                draft = bridge.profile(confirmed)
                themeMode = sent.reset and confirmed.theme or sent.mode
            end
        end
        publish()
        pump()
    end)
end

local function handle(request)
    if type(request) ~= "table" or type(request.kind) ~= "string" then return end
    lastId = request.id or lastId
    local kind = request.kind
    if kind == "refresh" then nextPoll = 0; publish(); return end
    if kind == "save" or kind == "rename" or kind == "delete" then
        if pending or writing then errorMessage = "Wait for the current edit to finish"; publish(); return end
        local nextData = bridge.copy(data)
        local existing, index = profiles.find(nextData, request.name)
        if kind == "delete" then
            if not existing then errorMessage = "Saved profile not found"; publish(); return end
            table.remove(nextData.profiles, index)
            if nextData.selected == request.name then nextData.selected = "" end
        else
            local name = profiles.normalizeName(request.new_name)
            if not profiles.validName(name) then errorMessage = "Use a profile name of 1–80 printable characters"; publish(); return end
            local duplicate, duplicateIndex = profiles.find(nextData, name)
            if duplicate and (kind ~= "save" or request.overwrite ~= true) then
                errorMessage = "A profile with that name already exists"; publish(); return
            end
            if kind == "rename" then
                if not existing then errorMessage = "Saved profile not found"; publish(); return end
                existing.name = name
                if nextData.selected == request.name then nextData.selected = name end
            else
                if not available or not confirmed then errorMessage = "Connect to Hyprliquid before saving"; publish(); return end
                local saved = profiles.snapshot(confirmed, themeMode)
                saved.name = name
                if duplicate then nextData.profiles[duplicateIndex] = saved
                else table.insert(nextData.profiles, saved) end
                nextData.current = profiles.snapshot(confirmed, themeMode)
                nextData.selected, nextData.checkpoint = name, profiles.checkpoint(confirmed)
            end
        end
        if persist(nextData, false) then errorMessage = nil end
        publish()
        return
    end
    if not available or not confirmed then errorMessage = "Hyprliquid is unavailable"; publish(); return end
    if kind == "select" then
        local saved = profiles.find(data, request.name)
        if saved then enqueue(profiles.renderer(saved), saved.theme_mode, saved.name, true)
        else errorMessage = "Saved profile not found"; publish() end
    elseif kind == "reset" then
        enqueue(bridge.profile(confirmed), confirmed.theme, "", true, true)
    elseif kind == "edit" and type(request.profile) == "table" then
        if request.theme_mode ~= "dark" and request.theme_mode ~= "light" and request.theme_mode ~= "follow" then
            errorMessage = "Invalid theme mode"; publish(); return
        end
        local profile = bridge.copy(request.profile)
        profile.theme = request.theme_mode == "follow" and (noctalia.isDarkMode() and "dark" or "light") or request.theme_mode
        enqueue(profile, request.theme_mode, "", request.flush == true)
    end
end

noctalia.state.watch("request", handle)
noctalia.state.watch("panel_open", function(value)
    open = value == true
    if open then nextPoll = 0 end
    publish()
end)

function update()
    if available and not busy and not pending and themeMode == "follow" then
        local theme = noctalia.isDarkMode() and "dark" or "light"
        if confirmed.theme ~= theme then
            local profile = bridge.profile(confirmed)
            profile.theme = theme
            enqueue(profile, "follow", data.selected, true)
        end
    end
    pump()
    if not busy and not pending and noctalia.nowMs() >= nextPoll then probe() end
end

function onConfigChanged()
    -- Disabling restoration does not discard an active edit or start a write.
    publish()
end

function onIpc(event)
    if event == "refresh" then nextPoll = 0; update() end
end

-- Exit deliberately leaves the last accepted renderer state intact. Subprocess
-- callbacks are owned/cancelled by Noctalia; restart reads before taking ownership.
publish()
probe()
