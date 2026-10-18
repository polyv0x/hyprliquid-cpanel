-- SPDX-FileCopyrightText: 2026 polyv0x
-- SPDX-License-Identifier: GPL-3.0-or-later

-- Presentation only: names, defaults, bounds and preset definitions come from IPC.
local M = {}
M.groups = {
    { name = "Overall", fields = { "glass_opacity", "effect_scale" } },
    { name = "Blur", fields = { "blur_sigma", "blur_alpha0", "blur_alpha3", "blur_dist3" } },
    { name = "Refraction", fields = { "outer_refraction_amount", "outer_refraction_inv_height", "inner_refraction_amount", "inner_refraction_inv_height", "refraction_threshold0", "refraction_threshold1", "refraction_opacity", "neighbor_contribution", "neighbor_falloff" } },
    { name = "Color fringe", fields = { "aberration_amount", "inv_aberration_height" } },
    { name = "Face", fields = { "face_opacity", "holding_tone_opacity", "face_slope", "face_intercept", "use_measured_face" } },
    { name = "Edge bleed", fields = { "edge_bleed_amount", "edge_bleed_inv_height", "edge_bleed_opacity", "bleed_darken" } },
    { name = "Rim", fields = { "rim_width", "rim_soft", "rim_opacity" } },
    { name = "Material shadow", fields = { "shadow_amount", "shadow_inv_height", "shadow_offset" } },
    { name = "Advanced coverage", fields = { "coverage_offset", "coverage_width" } },
}

function M.label(name)
    if name == "use_measured_face" then return "Measured face mix" end
    if name == "neighbor_falloff" then return "Reflection falloff" end
    local label = name:gsub("_", " ")
    return label:sub(1, 1):upper() .. label:sub(2)
end

function M.logarithmic(parameter)
    return parameter.min > 0 and (parameter.name:find("inv_height", 1, true) ~= nil or parameter.name == "inv_aberration_height")
end

function M.slider(parameter, value)
    -- Keep the thumb within the native control's range even when displaying
    -- a pending profile that the renderer is about to reject.
    value = math.max(parameter.min, math.min(parameter.max, value))
    if M.logarithmic(parameter) then
        local low, high = math.log(parameter.min), math.log(parameter.max)
        return 0, 1, 0.001, (math.log(math.max(parameter.min, value)) - low) / (high - low)
    end
    local range = parameter.max - parameter.min
    return parameter.min, parameter.max, range <= 4 and 0.001 or 0.1, value
end

function M.value(parameter, value)
    if M.logarithmic(parameter) then
        return math.exp(math.log(parameter.min) + value * (math.log(parameter.max) - math.log(parameter.min)))
    end
    return value
end

return M
