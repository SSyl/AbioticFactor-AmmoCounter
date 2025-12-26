print("=== [Ammo Counter] MOD LOADING ===\n")

--[[
=================================================================================
AMMO COUNTER MOD - Refactored Architecture
=================================================================================

CORE PRINCIPLE: Read from weapon object, not widget
- weapon.CurrentRoundsInMagazine = loaded ammo (always correct, immediate)
- weapon.MaxMagazineSize = magazine capacity (always correct, immediate)
- widget visibility check = filtering (game hides widget for non-ammo items)

DATA SOURCES (from Live View + Type Dumps):
Player: UEHelpers.GetPlayer() → Abiotic_PlayerCharacter_C
Weapon: player.ItemInHand_BP → AAbiotic_Weapon_ParentBP_C
Loaded Ammo: weapon.CurrentRoundsInMagazine (int32)
Magazine Size: weapon.MaxMagazineSize (int32)
Inventory Ammo: weapon:InventoryHasAmmoForCurrentWeapon() → outParams.Count

Type Dump Locations:
- Abiotic_Weapon_ParentBP.lua (weapon properties)
- Abiotic_PlayerCharacter.lua (player properties)

=================================================================================
]]--

local UEHelpers = require("UEHelpers")
local LogUtil = require("LogUtil")
local ConfigUtil = require("ConfigUtil")

-- ============================================================
-- CONFIG
-- ============================================================

local UserConfig = require("../config")
local Config = ConfigUtil.ValidateAmmoCounterConfig(UserConfig, LogUtil.CreateLogger("Ammo Counter (Config)", UserConfig))
local Log = LogUtil.CreateLogger("Ammo Counter", Config)

-- Colors are already in UE format from ValidateAmmoCounterConfig
local COLOR_NO_AMMO = Config.NoAmmo
local COLOR_AMMO_LOW = Config.AmmoLow
local COLOR_AMMO_GOOD = Config.AmmoGood

-- ============================================================
-- DATA READING
-- ============================================================

-- Read all ammo data from weapon object
local function GetWeaponAmmoData(weapon)
    local data = {
        loadedAmmo = nil,
        maxCapacity = nil,
        inventoryAmmo = nil,
        isValidWeapon = false
    }

    if not weapon:IsValid() then
        return data
    end

    -- Read loaded ammo (current rounds in magazine)
    local ok1, loaded = pcall(function()
        return weapon.CurrentRoundsInMagazine
    end)
    if ok1 and loaded ~= nil then
        data.loadedAmmo = loaded
    end

    -- Read magazine capacity
    local ok2, capacity = pcall(function()
        return weapon.MaxMagazineSize
    end)
    if ok2 and capacity ~= nil then
        data.maxCapacity = capacity
    end

    -- Read inventory ammo count
    local ok3, outParams = pcall(function()
        local params = {}
        weapon:InventoryHasAmmoForCurrentWeapon(false, params, {}, {})
        return params
    end)
    if ok3 and outParams and outParams.Count ~= nil then
        data.inventoryAmmo = outParams.Count
    end

    -- Mark as valid weapon if we successfully read both essential ammo values
    data.isValidWeapon = (data.loadedAmmo ~= nil and data.maxCapacity ~= nil)

    return data
end

-- ============================================================
-- COLOR LOGIC
-- ============================================================

-- Determine color for loaded ammo (ammo in magazine)
local function GetLoadedAmmoColor(loadedAmmo, maxCapacity)
    if loadedAmmo == 0 then
        return COLOR_NO_AMMO
    elseif maxCapacity > 0 then
        local percentage = loadedAmmo / maxCapacity
        return (percentage <= Config.LoadedAmmoWarning) and COLOR_AMMO_LOW or COLOR_AMMO_GOOD
    else
        Log("Invalid state: loadedAmmo=" .. tostring(loadedAmmo) .. " but maxCapacity=" .. tostring(maxCapacity), "error")
        return COLOR_AMMO_GOOD  -- Fallback to default
    end
end

-- Determine color for inventory ammo (ammo in backpack)
local function GetInventoryAmmoColor(inventoryAmmo, maxCapacity)
    local threshold = Config.InventoryAmmoWarning or maxCapacity

    if inventoryAmmo == 0 then
        return COLOR_NO_AMMO
    elseif inventoryAmmo <= threshold then
        return COLOR_AMMO_LOW
    else
        return COLOR_AMMO_GOOD
    end
end

-- Apply color to widget
local function SetWidgetColor(widget, color)
    if not widget or not widget:IsValid() or not color then
        return false
    end

    local ok = pcall(function()
        widget:SetColorAndOpacity({
            SpecifiedColor = color,
            ColorUseRule = "UseColor_Specified"
        })
    end)

    return ok
end

-- ============================================================
-- WIDGET UPDATES
-- ============================================================

-- Update loaded ammo color (left number on HUD)
local function UpdateLoadedAmmoColor(widget, loadedAmmo, maxCapacity)
    local ok, textWidget = pcall(function()
        return widget.Text_CurrentAmmo
    end)

    if ok and textWidget:IsValid() and loadedAmmo ~= nil then
        local color = GetLoadedAmmoColor(loadedAmmo, maxCapacity)
        SetWidgetColor(textWidget, color)
    end
end

-- Update inventory ammo display (right number on HUD)
-- Mode 1: ShowMaxCapacity = false → Replace "MaxAmmo" text with inventory count
-- Mode 2: ShowMaxCapacity = true → Keep max ammo, add separate inventory widget
local function UpdateInventoryAmmoDisplay(widget, inventoryAmmo, maxCapacity, weaponChanged)
    if not inventoryAmmo then
        return
    end

    if not Config.ShowMaxCapacity then
        -- Simple mode: Replace max ammo text with inventory count
        local ok, textWidget = pcall(function()
            return widget.Text_MaxAmmo
        end)

        if ok and textWidget:IsValid() then
            pcall(function()
                textWidget:SetText(FText(tostring(inventoryAmmo)))
            end)

            local color = GetInventoryAmmoColor(inventoryAmmo, maxCapacity)
            SetWidgetColor(textWidget, color)
        end
    else
        -- Advanced mode: Show "Loaded | Max | Inventory"
        -- TODO: Implement ShowMaxCapacity mode (requires widget creation)
        Log("ShowMaxCapacity mode not yet implemented in refactored version", "warning")
    end
end

-- ============================================================
-- MAIN UPDATE LOGIC
-- ============================================================

-- Updates ammo display and returns current weapon address for tracking weapon changes
-- Returns lastWeaponAddress unchanged on error to preserve state during race conditions
local function UpdateAmmoDisplay(widget, weapon, lastWeaponAddress)
    -- Read all weapon data
    local data = GetWeaponAmmoData(weapon)

    if not data.isValidWeapon then
        return lastWeaponAddress  -- Return unchanged if we couldn't read ammo data
    end

    -- Detect weapon change
    local currentWeaponAddress = weapon:GetAddress()
    local weaponChanged = (currentWeaponAddress ~= lastWeaponAddress)

    if weaponChanged then
        Log(string.format("Weapon changed - Loaded: %d/%d | Inventory: %d", data.loadedAmmo or 0, data.maxCapacity or 0, data.inventoryAmmo or 0), "debug")
    end

    UpdateLoadedAmmoColor(widget, data.loadedAmmo, data.maxCapacity)

    UpdateInventoryAmmoDisplay(widget, data.inventoryAmmo, data.maxCapacity, weaponChanged)

    return currentWeaponAddress
end

-- ============================================================
-- HOOK REGISTRATION
-- ============================================================

local function RegisterAmmoHooks()
    local lastWeaponAddress = nil

    RegisterHook("/Game/Blueprints/Widgets/W_HUD_AmmoCounter.W_HUD_AmmoCounter_C:UpdateAmmo", function(Context)
        local success, err = pcall(function()

            local widget = Context:get()
            if not widget:IsValid() then
                return
            end

            -- Filter by visibility (game hides widget for non-ammo items)
            -- HUD ammo counter is always visibility 4 (SelfHitTestInvisible) when active
            -- Other values mean we return early as there's nothing to do
            local ok_vis, visibility = pcall(function()
                return widget:GetVisibility()
            end)

            if not ok_vis or visibility ~= 4 then
                return  -- Widget not visible or not in expected state
            end

            local playerPawn = UEHelpers.GetPlayer()
            if not playerPawn:IsValid() then
                return
            end

            local ok, weapon = pcall(function()
                return playerPawn.ItemInHand_BP
            end)

            if not ok or not weapon:IsValid() then
                return
            end

            lastWeaponAddress = UpdateAmmoDisplay(widget, weapon, lastWeaponAddress)
        end)

        if not success then
            Log("Hook error: " .. tostring(err), "error")
        end
    end)

    Log("Hooks registered", "debug")
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local hooksRegistered = false

RegisterInitGameStatePostHook(function()
    if not hooksRegistered then
        hooksRegistered = true
        Log("Game state initialized", "debug")
        RegisterAmmoHooks()
    end
end)

print("[Ammo Counter] Mod loaded\n")
