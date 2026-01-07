local ConfigUtil = {}

-- ============================================================
-- GENERIC VALIDATORS
-- ============================================================

-- Validate and convert RGB color (0-255) to UE format (0-1)
function ConfigUtil.ValidateColor(value, default, logFunc, fieldName)
    local function isValidRGB(color)
        return type(color) == "table"
            and type(color.R) == "number" and color.R >= 0 and color.R <= 255
            and type(color.G) == "number" and color.G >= 0 and color.G <= 255
            and type(color.B) == "number" and color.B >= 0 and color.B <= 255
    end

    local source = value
    if not isValidRGB(value) then
        if value ~= nil and logFunc and fieldName then
            logFunc("Invalid " .. fieldName .. " (must be {R=0-255, G=0-255, B=0-255}), using default", "warning")
        end
        source = default
    end

    return {
        R = source.R / 255,
        G = source.G / 255,
        B = source.B / 255,
        A = 1.0
    }
end

function ConfigUtil.ValidateNumber(value, default, min, max, logFunc, fieldName)
    if type(value) ~= "number" then
        if value ~= nil and logFunc and fieldName then
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

function ConfigUtil.ValidateBoolean(value, default, logFunc, fieldName)
    if type(value) ~= "boolean" then
        if value ~= nil and logFunc and fieldName then
            logFunc("Invalid " .. fieldName .. " (must be boolean), using " .. tostring(default), "warning")
        end
        return default
    end
    return value
end

-- ============================================================
-- AMMO COUNTER CONFIG VALIDATOR
-- ============================================================

local DEFAULTS = {
    Debug = false,
    ShowMaxCapacity = false,
    LoadedAmmoWarning = 0.5,
    InventoryAmmoWarning = nil,
    NoAmmo = {R = 249, G = 41, B = 41},
    AmmoLow = {R = 255, G = 200, B = 32},
    AmmoGood = {R = 114, G = 242, B = 255},
}

function ConfigUtil.ValidateConfig(userConfig, logFunc)
    local config = userConfig or {}

    config.Debug = ConfigUtil.ValidateBoolean(config.Debug, DEFAULTS.Debug, logFunc, "Debug")
    config.ShowMaxCapacity = ConfigUtil.ValidateBoolean(config.ShowMaxCapacity, DEFAULTS.ShowMaxCapacity, logFunc, "ShowMaxCapacity")

    config.LoadedAmmoWarning = ConfigUtil.ValidateNumber(config.LoadedAmmoWarning, DEFAULTS.LoadedAmmoWarning, 0.0, 1.0, logFunc, "LoadedAmmoWarning")

    -- InventoryAmmoWarning: "adaptive" (or nil) = use maxCapacity, number = fixed threshold
    if config.InventoryAmmoWarning == "adaptive" then
        config.InventoryAmmoWarning = nil  -- nil triggers adaptive behavior
    elseif config.InventoryAmmoWarning ~= nil then
        config.InventoryAmmoWarning = ConfigUtil.ValidateNumber(config.InventoryAmmoWarning, nil, 1, nil, logFunc, "InventoryAmmoWarning")
    end

    config.NoAmmo = ConfigUtil.ValidateColor(config.NoAmmo, DEFAULTS.NoAmmo, logFunc, "NoAmmo")
    config.AmmoLow = ConfigUtil.ValidateColor(config.AmmoLow, DEFAULTS.AmmoLow, logFunc, "AmmoLow")
    config.AmmoGood = ConfigUtil.ValidateColor(config.AmmoGood, DEFAULTS.AmmoGood, logFunc, "AmmoGood")

    return config
end

return ConfigUtil
