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
    if not payload then callback(nil, "Could not encode request: " .. tostring(encodeError)); return end
    local accepted = noctalia.runAsync({ "hyprctl", "hyprliquid:control", payload }, function(result)
        if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then
            callback(nil, result.timedOut and "Hyprliquid request timed out" or "Hyprliquid IPC failed: " .. (result.stderr or ""))
            return
        end
        local reply = noctalia.json.decode(result.stdout or "")
        if type(reply) ~= "table" or type(reply.ok) ~= "boolean" then
            callback(nil, "Hyprliquid is unavailable or lacks control API 1")
        elseif reply.api ~= 1 then
            callback(nil, "Incompatible Hyprliquid control API (requires 1)")
        elseif type(reply.state) ~= "table" or type(reply.state.epoch) ~= "string"
            or type(reply.state.revision) ~= "number" or type(reply.state.material) ~= "table"
            or type(reply.state.panel) ~= "table" then
            callback(nil, "Invalid Hyprliquid state response")
        else
            local errorMessage
            if not reply.ok then errorMessage = reply.error or "Hyprliquid rejected the edit" end
            callback(reply, errorMessage)
        end
    end, 3000)
    if not accepted then callback(nil, "Could not start hyprctl") end
end

return M
