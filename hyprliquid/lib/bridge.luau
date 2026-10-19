-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

-- The only renderer transport. JSON stays a single argv value; no shell or Lua eval.
local M = {}

function M.copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = M.copy(item) end
    return result
end

function M.profile(state)
    return {
        base_preset = state.base_preset,
        theme = state.theme,
        enabled = state.enabled,
        overrides = M.copy(state.panel.overrides),
    }
end

function M.call(request, callback)
    request = M.copy(request)
    -- Empty Luau tables may encode as arrays. Omission means no overrides
    -- in a complete profile and also avoids depending on null sentinels.
    for _, key in ipairs({ "profile", "patch" }) do
        if request[key] and request[key].overrides and next(request[key].overrides) == nil then
            request[key].overrides = nil
        end
    end
    local payload, encodeError = noctalia.json.encode(request)
    if not payload then callback(nil, "Could not communicate with Hyprliquid: " .. tostring(encodeError)); return end
    local accepted = noctalia.runAsync({ "hyprctl", "hyprliquid:control", payload }, function(result)
        if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then
            callback(nil, result.timedOut and "Hyprliquid did not respond in time" or "Could not connect to Hyprliquid: " .. (result.stderr or ""))
            return
        end
        local reply = noctalia.json.decode(result.stdout or "")
        if type(reply) ~= "table" or type(reply.ok) ~= "boolean" then
            callback(nil, "Cannot connect to Hyprliquid. Make sure the plugin is up to date and loaded in Hyprland.")
        elseif reply.api ~= 1 then
            callback(nil, "This Hyprliquid version is incompatible. Update the plugin and reconnect.")
        elseif type(reply.state) ~= "table" or type(reply.state.epoch) ~= "string"
            or type(reply.state.revision) ~= "number" or type(reply.state.material) ~= "table"
            or type(reply.state.panel) ~= "table" then
            callback(nil, "Could not read the glass settings from Hyprliquid. Reconnect to try again.")
        else
            local errorMessage
            if not reply.ok then errorMessage = reply.error or "Hyprliquid rejected the edit" end
            callback(reply, errorMessage)
        end
    end, 3000)
    if not accepted then callback(nil, "Could not start hyprctl. Check that it is installed and available.") end
end

return M
