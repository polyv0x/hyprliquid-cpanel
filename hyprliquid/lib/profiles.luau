-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

local copy = require("./bridge.luau").copy
local M = {}

function M.empty()
    return { version = 2, profiles = {}, selected = "" }
end

function M.normalizeName(name)
    if type(name) ~= "string" then return nil end
    return (name:gsub(" ", "_"))
end

function M.validName(name)
    return type(name) == "string" and #name > 0 and #name <= 80
        and name == name:match("^%s*(.-)%s*$") and not name:find("%c")
end

local function validMaterial(profile)
    if type(profile) ~= "table" or type(profile.base_preset) ~= "string" or type(profile.enabled) ~= "boolean"
        or (profile.theme_mode ~= "dark" and profile.theme_mode ~= "light" and profile.theme_mode ~= "follow")
        or type(profile.overrides) ~= "table" then return false end
    for key, value in pairs(profile.overrides) do
        if type(key) ~= "string" or type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then return false end
    end
    return true
end

function M.validate(data)
    if type(data) ~= "table" or (data.version ~= 1 and data.version ~= 2) or type(data.profiles) ~= "table"
        or type(data.selected) ~= "string" then return false end
    local names = {}
    for index, profile in pairs(data.profiles) do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or index > #data.profiles
            or not validMaterial(profile) or not M.validName(profile.name) or names[profile.name] then return false end
        names[profile.name] = true
    end
    if data.current ~= nil and not validMaterial(data.current) then return false end
    if data.selected ~= "" and not names[data.selected] then return false end
    if data.checkpoint ~= nil then
        local c = data.checkpoint
        if type(c) ~= "table" or type(c.epoch) ~= "string" or type(c.revision) ~= "number"
            or type(c.generation) ~= "number" then return false end
    end
    return true
end

function M.load()
    local directory, err = noctalia.pluginDataDir()
    if not directory then return M.empty(), nil, tostring(err) end
    local path = directory .. "/profiles.json"
    if not noctalia.fileExists(path) then return M.empty(), path end
    local contents, readError = noctalia.readFile(path)
    if not contents then return M.empty(), nil, "Could not read profiles: " .. tostring(readError) end
    local data = noctalia.json.decode(contents)
    if not M.validate(data) then return M.empty(), nil, "Profiles file is invalid or from a newer version; it has been preserved" end
    if data.version == 1 then
        local selected = M.find(data, data.selected)
        if selected then
            data.current = copy(selected)
            data.current.name = nil
        end
        data.version = 2
    end
    -- Drop an obsolete override before restoring saved settings. Keep all other
    -- fields for the renderer to validate normally.
    for _, profile in ipairs(data.profiles) do profile.overrides.use_measured_face = nil end
    if data.current then data.current.overrides.use_measured_face = nil end
    return data, path
end

function M.write(path, data)
    if not path then return false, "Profile storage is unavailable; the existing file is preserved" end
    if not M.validate(data) then return false, "Invalid profile data" end
    local contents, err = noctalia.json.encode(data, true)
    if not contents then return false, tostring(err) end
    local temporary = path .. ".tmp"
    local ok, writeError = noctalia.writeFile(temporary, contents)
    if not ok then return false, tostring(writeError) end
    local renamed, renameError = noctalia.renameFile(temporary, path)
    if not renamed then return false, tostring(renameError) end
    return true
end

function M.find(data, name)
    for index, profile in ipairs(data.profiles) do
        if profile.name == name then return profile, index end
    end
    return nil
end

function M.checkpoint(state)
    return { epoch = state.epoch, revision = state.revision, generation = state.generation }
end

function M.snapshot(state, mode)
    return {
        base_preset = state.base_preset,
        enabled = state.enabled,
        theme_mode = mode or state.theme,
        overrides = copy(state.panel.overrides),
    }
end

function M.renderer(profile)
    return {
        base_preset = profile.base_preset,
        enabled = profile.enabled,
        theme = profile.theme_mode == "follow" and (noctalia.isDarkMode() and "dark" or "light") or profile.theme_mode,
        overrides = copy(profile.overrides),
    }
end

return M
