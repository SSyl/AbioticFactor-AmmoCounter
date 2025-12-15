print("=== [Ammo Counter] MOD LOADING ===\n")

local UEHelpers = require("UEHelpers")
local Config = require("../config")
local DEBUG = Config.Debug or false

local function ConvertColor(colorConfig, defaultR, defaultG, defaultB)
    if not colorConfig then
        return {R = defaultR / 255, G = defaultG / 255, B = defaultB / 255, A = 1.0}
    end
    return {
        R = (colorConfig.R or defaultR) / 255,
        G = (colorConfig.G or defaultG) / 255,
        B = (colorConfig.B or defaultB) / 255,
        A = 1.0
    }
end

local COLOR_NO_AMMO = ConvertColor(Config.NoAmmo, 249, 41, 41)
local COLOR_ONE_MAG_LEFT = ConvertColor(Config.OneMagLeft, 255, 200, 32)
local COLOR_MULTIPLE_MAGS = ConvertColor(Config.MultipleMags, 114, 242, 255)
local THRESHOLD_OVERRIDE = tonumber(Config.OneMagLeftThreshold)

local function DebugLog(message)
    if DEBUG then
        print("[Ammo Counter] " .. tostring(message) .. "\n")
    end
end

local function IsWeaponReady(weapon)
    if not weapon or not weapon:IsValid() then
        return false
    end

    local currentOwner = weapon.CurrentOwner
    if not currentOwner or not currentOwner:IsValid() then
        return false
    end

    local itemData = weapon.ItemData
    if not itemData or not itemData:IsValid() then
        return false
    end

    -- Not all ItemInHand_BP items are weapons (e.g. flashlight, medkit)
    local isWeapon = itemData.IsWeapon_63_57F6A703413EA260B1455CA81F2D4911
    if not isWeapon then
        return false
    end

    -- WeaponData property uses Unreal Engine's mangled name format: PropertyName_Index_GUID
    -- Found in W_HUD_AmmoCounter_UpdateAmmo bytecode export (line 1039)
    -- Engine requires the full mangled name - short form "WeaponData" causes nullptr errors
    local weaponData = itemData.WeaponData_61_3C29CF6C4A7F9DD435F9318FEE4B033D
    if not weaponData or not weaponData:IsValid() then
        return false
    end

    local changeableData = weapon.ChangeableData
    if not changeableData or not changeableData:IsValid() then
        return false
    end

    return true
end

-- Update the ammo counter display with inventory count
local function UpdateAmmoDisplay(widget, weapon, lastWeaponAddress, lastCount)
    local outParams = {}
    weapon:InventoryHasAmmoForCurrentWeapon(false, outParams, {}, {})
    local count = outParams.Count

    -- Get magazine size from widget (already set by UpdateAmmo)
    local magazineSize = widget.MaxAmmo or 0

    local currentWeaponAddress = weapon:GetAddress()
    local weaponChanged = (currentWeaponAddress ~= lastWeaponAddress)
    local countChanged = (count ~= lastCount)

    -- On first load or weapon switch, check if display is wrong (fallback only)
    local needsUpdate = false
    if not countChanged and not weaponChanged and count then
        local textWidget = widget.Text_MaxAmmo
        if textWidget and textWidget:IsValid() then
            local currentText = textWidget:GetText():ToString()
            needsUpdate = (currentText ~= tostring(count))
        end
    end

    -- Update if: count changed, weapon changed, or display is wrong (fallback)
    if count and (countChanged or weaponChanged or needsUpdate) then
        if countChanged or weaponChanged then
            DebugLog("Updating display to: " .. count)
        end

        local textWidget = widget.Text_MaxAmmo
        if textWidget and textWidget:IsValid() then
            DebugLog("Setting text to: " .. tostring(count) .. ", magazineSize: " .. tostring(magazineSize))

            local setText = pcall(function()
                textWidget:SetText(FText(tostring(count)))
            end)

            if not setText then
                DebugLog("ERROR: Failed to set text")
            end

            local colorSuccess, colorErr = pcall(function()
                local threshold = THRESHOLD_OVERRIDE or magazineSize

                local color
                if count == 0 then
                    color = COLOR_NO_AMMO
                elseif count > 0 and count <= threshold then
                    color = COLOR_ONE_MAG_LEFT
                else
                    color = COLOR_MULTIPLE_MAGS
                end

                local colorStruct = {
                    SpecifiedColor = color,
                    ColorUseRule = "UseColor_Specified"
                }
                textWidget:SetColorAndOpacity(colorStruct)
            end)

            if not colorSuccess then
                DebugLog("ERROR setting color: " .. tostring(colorErr))
            end
        end

        return count, currentWeaponAddress
    end

    return lastCount, lastWeaponAddress
end

-- Hook UpdateAmmo to replace magazine capacity with inventory count
local function RegisterAmmoHooks()
    -- Cache per weapon to handle weapon switching correctly
    local lastWeaponPath = nil
    local lastInventoryCount = -1

    -- For Blueprint functions, BOTH callbacks act as post-callbacks
    -- So we put our logic in the "pre-hook" which actually runs AFTER UpdateAmmo
    RegisterHook("/Game/Blueprints/Widgets/W_HUD_AmmoCounter.W_HUD_AmmoCounter_C:UpdateAmmo", function(Context)
        -- This runs AFTER UpdateAmmo for blueprint functions

        local success, err = pcall(function()
            local widget = Context:get()
            if not widget or not widget:IsValid() then
                return
            end

            local playerPawn = UEHelpers.GetPlayer()
            if not playerPawn or not playerPawn:IsValid() then
                return
            end

            local weapon = playerPawn.ItemInHand_BP
            if not IsWeaponReady(weapon) then
                return
            end

            lastInventoryCount, lastWeaponPath = UpdateAmmoDisplay(
                widget,
                weapon,
                lastWeaponPath,
                lastInventoryCount
            )
        end)

        if not success then
            DebugLog("HOOK ERROR: " .. tostring(err))
        end
    end)

    DebugLog("UpdateAmmo hook registered")
end

-- Initialize the mod
local hooksRegistered = false

RegisterInitGameStatePostHook(function(GameModeBase)
    -- Called after game state is initialized - safe to register hooks immediately
    if not hooksRegistered then
        hooksRegistered = true
        DebugLog("Game state initialized, registering hooks")
        RegisterAmmoHooks()
    end
end)

print("[Ammo Counter] Mod loaded\n")
