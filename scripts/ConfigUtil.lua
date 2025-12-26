-- ============================================================
-- CONFIG UTILITIES (Universal)
-- Handles configuration validation and provides config-related helpers
-- Generic utilities that work across different mod types
-- ============================================================

local ConfigUtil = {}

-- Merge user config with defaults
function ConfigUtil.MergeDefaults(userConfig, defaults)
    local config = userConfig or {}

    for key, defaultValue in pairs(defaults) do
        if config[key] == nil then
            config[key] = defaultValue
        end
    end

    return config
end

-- Validate RGB color table (0-255 values)
-- Returns validated color table or default if invalid
function ConfigUtil.ValidateColor(colorConfig, defaultColor, logFunc)
    if type(colorConfig) ~= "table" then
        if logFunc then
            logFunc("Invalid color format (must be table with R, G, B), using default", "warning")
        end
        return defaultColor
    end

    local function validateRGB(val, component)
        if type(val) ~= "number" or val < 0 or val > 255 then
            if logFunc then
                logFunc("Invalid color." .. component .. " (must be 0-255), using default", "warning")
            end
            return false
        end
        return true
    end

    if not (validateRGB(colorConfig.R, "R") and
            validateRGB(colorConfig.G, "G") and
            validateRGB(colorConfig.B, "B")) then
        return defaultColor
    end

    return colorConfig
end

-- Convert RGB (0-255) color to UE4 format (0-1) with alpha
function ConfigUtil.ConvertColor(colorConfig, defaultR, defaultG, defaultB)
    local function clampRGB(val, default)
        local num = tonumber(val) or default
        return math.max(0, math.min(255, num))
    end

    if not colorConfig then
        return {R = defaultR / 255, G = defaultG / 255, B = defaultB / 255, A = 1.0}
    end

    return {
        R = clampRGB(colorConfig.R, defaultR) / 255,
        G = clampRGB(colorConfig.G, defaultG) / 255,
        B = clampRGB(colorConfig.B, defaultB) / 255,
        A = 1.0
    }
end

-- Validate numeric value with min/max bounds
function ConfigUtil.ValidateNumber(value, default, min, max, logFunc, fieldName)
    if type(value) ~= "number" then
        if logFunc and fieldName then
            logFunc("Invalid " .. fieldName .. " (must be number), using " .. tostring(default), "warning")
        end
        return default
    end

    if (min and value < min) or (max and value > max) then
        if logFunc and fieldName then
            local bounds = ""
            if min and max then
                bounds = " (must be " .. min .. "-" .. max .. ")"
            elseif min then
                bounds = " (must be >= " .. min .. ")"
            elseif max then
                bounds = " (must be <= " .. max .. ")"
            end
            logFunc("Invalid " .. fieldName .. bounds .. ", using " .. tostring(default), "warning")
        end
        return default
    end

    return value
end

-- Validate boolean value
function ConfigUtil.ValidateBoolean(value, default, logFunc, fieldName)
    if type(value) ~= "boolean" then
        if logFunc and fieldName then
            logFunc("Invalid " .. fieldName .. " (must be boolean), using " .. tostring(default), "warning")
        end
        return default
    end
    return value
end

return ConfigUtil
