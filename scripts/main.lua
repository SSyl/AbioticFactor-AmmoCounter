print("=== [Ammo Counter] MOD LOADING ===\n")

local UEHelpers = require("UEHelpers")
local LogUtil = require("LogUtil")
local ConfigUtil = require("ConfigUtil")

-- ============================================================
-- CONFIG
-- ============================================================

local UserConfig = require("../config")
local Config = ConfigUtil.ValidateConfig(UserConfig, LogUtil.CreateLogger("Ammo Counter (Config)", UserConfig))
local Log = LogUtil.CreateLogger("Ammo Counter", Config)

local COLOR_NO_AMMO = Config.NoAmmo
local COLOR_AMMO_LOW = Config.AmmoLow
local COLOR_AMMO_GOOD = Config.AmmoGood

-- ============================================================
-- WIDGET CACHES (ShowMaxCapacity mode)
-- ============================================================

local inventoryTextWidget = CreateInvalidObject()
local separatorWidget = CreateInvalidObject()

-- ============================================================
-- CACHED REFERENCES
-- ============================================================

local cachedPlayerPawn = CreateInvalidObject()
local cachedWidget = CreateInvalidObject()
local cachedWeapon = CreateInvalidObject()

-- Change detection state
local lastWeaponAddress = nil
local lastInventoryAmmo = nil
local cachedMaxCapacity = nil

-- Cached classes for IsA checks
local cachedWeaponClass = CreateInvalidObject()
local cachedPlayerCharacterClass = CreateInvalidObject()

-- ============================================================
-- CLASS HELPERS
-- ============================================================

local function GetWeaponClass()
    if not cachedWeaponClass:IsValid() then
        cachedWeaponClass = StaticFindObject("/Game/Blueprints/Items/Weapons/Abiotic_Weapon_ParentBP.Abiotic_Weapon_ParentBP_C")
    end
    return cachedWeaponClass
end

local function GetPlayerCharacterClass()
    if not cachedPlayerCharacterClass:IsValid() then
        cachedPlayerCharacterClass = StaticFindObject("/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C")
    end
    return cachedPlayerCharacterClass
end

-- ============================================================
-- DATA READING
-- ============================================================

local function GetWeaponAmmoData(weapon, cachedMax)
    local data = {
        loadedAmmo = nil,
        maxCapacity = nil,
        inventoryAmmo = nil,
        isValidWeapon = false
    }

    if not weapon:IsValid() then return data end

    data.loadedAmmo = weapon.CurrentRoundsInMagazine
    data.maxCapacity = cachedMax or weapon.MaxMagazineSize

    local outParams = {}
    weapon:InventoryHasAmmoForCurrentWeapon(false, outParams, {}, {})
    if outParams.Count ~= nil then
        data.inventoryAmmo = outParams.Count
    end

    data.isValidWeapon = (data.loadedAmmo ~= nil and data.maxCapacity ~= nil)

    return data
end

-- ============================================================
-- COLOR LOGIC
-- ============================================================

local function GetLoadedAmmoColor(loadedAmmo, maxCapacity)
    if loadedAmmo == 0 then
        return COLOR_NO_AMMO
    elseif maxCapacity > 0 then
        local percentage = loadedAmmo / maxCapacity
        return (percentage <= Config.LoadedAmmoWarning) and COLOR_AMMO_LOW or COLOR_AMMO_GOOD
    else
        Log.Error("Invalid state: loadedAmmo=%s but maxCapacity=%s", tostring(loadedAmmo), tostring(maxCapacity))
        return COLOR_AMMO_GOOD
    end
end

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

local function SetWidgetColor(widget, color)
    if not widget:IsValid() or not color then return end
    widget:SetColorAndOpacity({
        SpecifiedColor = color,
        ColorUseRule = "UseColor_Specified"
    })
end

-- ============================================================
-- WIDGET HELPERS (ShowMaxCapacity mode)
-- ============================================================

local function SetSlotPosition(slot, left, top, right, bottom)
    if not slot:IsValid() then return end
    slot:SetOffsets({
        Left = left,
        Top = top,
        Right = right,
        Bottom = bottom
    })
end

local function CloneWidget(templateWidget, canvas, widgetName)
    local invalid = CreateInvalidObject()
    if not templateWidget:IsValid() or not canvas:IsValid() then
        return invalid
    end

    local widgetClass = templateWidget:GetClass()
    local newWidget = StaticConstructObject(
        widgetClass,
        canvas,
        FName(widgetName),
        0, 0, false, false,
        templateWidget  -- Template parameter - copies all properties
    )

    if not newWidget:IsValid() then
        return invalid
    end

    local slot = canvas:AddChildToCanvas(newWidget)
    if not slot:IsValid() then
        return invalid
    end

    return newWidget
end

-- ============================================================
-- WIDGET CREATION (ShowMaxCapacity mode)
-- ============================================================

local function CreateSeparatorWidget(widget)
    if separatorWidget:IsValid() then return separatorWidget end

    local originalSep = widget.Image_0
    local canvas = widget.VisCanvas

    if not originalSep:IsValid() or not canvas:IsValid() then
        Log.Error("Failed to get separator template or canvas")
        return separatorWidget
    end

    local newSeparator = CloneWidget(originalSep, canvas, "InventoryAmmoSeparator")
    if newSeparator:IsValid() then
        separatorWidget = newSeparator
    else
        Log.Error("Failed to create separator widget")
    end

    return separatorWidget
end

local function CreateInventoryWidget(widget)
    if inventoryTextWidget:IsValid() then return inventoryTextWidget end

    local textTemplate = widget.Text_CurrentAmmo
    local canvas = widget.VisCanvas

    if not textTemplate:IsValid() or not canvas:IsValid() then
        Log.Error("Failed to get text template or canvas")
        return inventoryTextWidget
    end

    local newWidget = CloneWidget(textTemplate, canvas, "Text_InventoryAmmo")
    if newWidget:IsValid() then
        newWidget:SetJustification(0)  -- 0 = Left
        inventoryTextWidget = newWidget
    else
        Log.Error("Failed to create inventory text widget")
    end

    return inventoryTextWidget
end

-- ============================================================
-- WIDGET POSITIONING (ShowMaxCapacity mode)
-- ============================================================

local function RepositionShowMaxCapacityWidgets(widget, maxCapacity)
    if not maxCapacity then return end

    local originalSep = widget.Image_0
    local maxAmmoText = widget.Text_MaxAmmo

    if not originalSep:IsValid() or not maxAmmoText:IsValid() then return end

    local originalSlot = originalSep.Slot
    local maxSlot = maxAmmoText.Slot

    if not originalSlot:IsValid() or not maxSlot:IsValid() then return end

    local originalOffsets = originalSlot:GetOffsets()
    local maxOffsets = maxSlot:GetOffsets()

    local baseDistance = maxOffsets.Left - originalOffsets.Left

    if not separatorWidget:IsValid() or not inventoryTextWidget:IsValid() then return end

    local sepSlot = separatorWidget.Slot
    local invSlot = inventoryTextWidget.Slot

    local digitCount = string.len(tostring(maxCapacity))
    local extraOffset = digitCount * 18

    SetSlotPosition(
        sepSlot,
        maxOffsets.Left + baseDistance + extraOffset,
        originalOffsets.Top,
        originalOffsets.Right,
        originalOffsets.Bottom
    )

    SetSlotPosition(
        invSlot,
        maxOffsets.Left + (baseDistance * 2) + extraOffset,
        -10.0,
        57.0,
        maxOffsets.Bottom
    )
end

-- ============================================================
-- WIDGET UPDATES
-- ============================================================

local function UpdateLoadedAmmoColor(widget, loadedAmmo, maxCapacity)
    local textWidget = widget.Text_CurrentAmmo

    if textWidget:IsValid() and loadedAmmo ~= nil then
        local color = GetLoadedAmmoColor(loadedAmmo, maxCapacity)
        SetWidgetColor(textWidget, color)
    end
end

local function UpdateSimpleMode(widget, inventoryAmmo, maxCapacity)
    local textWidget = widget.Text_MaxAmmo

    if not textWidget:IsValid() then return end

    textWidget:SetText(FText(tostring(inventoryAmmo)))

    local color = GetInventoryAmmoColor(inventoryAmmo, maxCapacity)
    SetWidgetColor(textWidget, color)
end

local function UpdateShowMaxCapacityMode(widget, inventoryAmmo, maxCapacity, weaponChanged)
    if not separatorWidget:IsValid() then
        CreateSeparatorWidget(widget)
    end

    if not inventoryTextWidget:IsValid() then
        CreateInventoryWidget(widget)
    end

    if not separatorWidget:IsValid() or not inventoryTextWidget:IsValid() then return end

    if weaponChanged then
        RepositionShowMaxCapacityWidgets(widget, maxCapacity)
    end

    inventoryTextWidget:SetText(FText(tostring(inventoryAmmo)))

    local color = GetInventoryAmmoColor(inventoryAmmo, maxCapacity)
    SetWidgetColor(inventoryTextWidget, color)
end

local function UpdateInventoryAmmoDisplay(widget, inventoryAmmo, maxCapacity, weaponChanged, inventoryChanged)
    if not inventoryAmmo then
        return
    end

    if not inventoryChanged and not weaponChanged then
        return
    end

    if Config.ShowMaxCapacity then
        UpdateShowMaxCapacityMode(widget, inventoryAmmo, maxCapacity, weaponChanged)
    else
        UpdateSimpleMode(widget, inventoryAmmo, maxCapacity)
    end
end

-- ============================================================
-- MAIN UPDATE LOGIC
-- ============================================================

local function UpdateAmmoDisplay(widget, weapon)
    local currentWeaponAddress = weapon:GetAddress()
    local weaponChanged = (currentWeaponAddress ~= lastWeaponAddress)

    local maxCapacityToUse = (weaponChanged or not cachedMaxCapacity) and nil or cachedMaxCapacity

    local data = GetWeaponAmmoData(weapon, maxCapacityToUse)

    if not data.isValidWeapon then
        return
    end

    local inventoryChanged = (data.inventoryAmmo ~= lastInventoryAmmo)

    -- Always update loaded ammo color (runs every frame and will get overridden otherwise)
    UpdateLoadedAmmoColor(widget, data.loadedAmmo, data.maxCapacity)

    if inventoryChanged or weaponChanged then
        UpdateInventoryAmmoDisplay(widget, data.inventoryAmmo, data.maxCapacity, weaponChanged, inventoryChanged)
    end

    lastWeaponAddress = currentWeaponAddress
    lastInventoryAmmo = data.inventoryAmmo
    cachedMaxCapacity = data.maxCapacity
end

-- ============================================================
-- INVENTORY CHANGE DETECTION (OnRep_CurrentInventory Hook)
-- ============================================================

local function OnInventoryChanged()
    if not cachedWidget:IsValid() then return end
    if not cachedWeapon:IsValid() then return end

    local outParams = {}
    cachedWeapon:InventoryHasAmmoForCurrentWeapon(false, outParams, {}, {})

    if outParams.Count == nil then return end

    local inventoryAmmo = outParams.Count
    local maxCapacity = cachedWeapon.MaxMagazineSize

    UpdateInventoryAmmoDisplay(cachedWidget, inventoryAmmo, maxCapacity, false, true)

    Log.Debug("Inventory ammo changed: %d", inventoryAmmo)
end

local function RegisterInventoryHook()
    local ok, err = pcall(function()
        RegisterHook("/Game/Blueprints/Characters/Abiotic_InventoryComponent.Abiotic_InventoryComponent_C:OnRep_CurrentInventory", function(Context)
            local inventory = Context:get()
            if not inventory:IsValid() then return end

            local owner = inventory:GetOwner()
            if not owner:IsValid() then return end

            -- Early exit: only process PlayerCharacter inventories
            local playerClass = GetPlayerCharacterClass()
            if not owner:IsA(playerClass) then return end

            if not cachedPlayerPawn:IsValid() then
                cachedPlayerPawn = UEHelpers.GetPlayer()
                if not cachedPlayerPawn:IsValid() then return end
            end

            -- Filter: only process local player's inventory (compare addresses)
            local ownerAddr = owner:GetAddress()
            local playerAddr = cachedPlayerPawn:GetAddress()
            if ownerAddr ~= playerAddr then return end

            OnInventoryChanged()
        end)
    end)

    if not ok then
        Log.Debug("Inventory hook not ready: %s", tostring(err))
    end

    return ok
end

-- ============================================================
-- HOOK REGISTRATION
-- ============================================================

local function RegisterAmmoHooks()
    local ok, err = pcall(function()
        RegisterHook("/Game/Blueprints/Widgets/W_HUD_AmmoCounter.W_HUD_AmmoCounter_C:UpdateAmmo", function(Context)
            local success, hookErr = pcall(function()
                local widget = Context:get()
                if not widget:IsValid() then return end

                -- Filter by visibility (game hides VisCanvas for items that don't use ammo)
                local visCanvas = widget.VisCanvas

                if not visCanvas:IsValid() then return end

                local visibility = visCanvas:GetVisibility()

                -- SelfHitTest (3) = active, Collapsed (1) = hidden
                if visibility ~= 3 then
                    cachedWidget = CreateInvalidObject()
                    cachedWeapon = CreateInvalidObject()
                    return
                end

                if not cachedPlayerPawn:IsValid() then
                    cachedPlayerPawn = UEHelpers.GetPlayer()
                    if not cachedPlayerPawn:IsValid() then return end
                end

                local weapon = cachedPlayerPawn.ItemInHand_BP

                if not weapon:IsValid() then
                    cachedMaxCapacity = nil
                    cachedWidget = CreateInvalidObject()
                    cachedWeapon = CreateInvalidObject()
                    return
                end

                local weaponClass = GetWeaponClass()
                if not weapon:IsA(weaponClass) then
                    cachedMaxCapacity = nil
                    cachedWidget = CreateInvalidObject()
                    cachedWeapon = CreateInvalidObject()
                    return
                end

                cachedWidget = widget
                cachedWeapon = weapon

                UpdateAmmoDisplay(widget, weapon)
            end)

            if not success then
                Log.Error("Hook error: %s", tostring(hookErr))
            end
        end)
    end)

    if not ok then
        Log.Debug("Ammo display hook not ready: %s", tostring(err))
    end

    return ok
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

-- Cleanup on map transition (PreHook fires for all machines on menu return)
RegisterInitGameStatePreHook(function(Context)
    cachedPlayerPawn = CreateInvalidObject()
    cachedWidget = CreateInvalidObject()
    cachedWeapon = CreateInvalidObject()
    inventoryTextWidget = CreateInvalidObject()
    separatorWidget = CreateInvalidObject()
    cachedWeaponClass = CreateInvalidObject()
    cachedPlayerCharacterClass = CreateInvalidObject()
    lastWeaponAddress = nil
    lastInventoryAmmo = nil
    cachedMaxCapacity = nil
    Log.Debug("Cache cleared on game state change")
end)

-- ============================================================
-- HOOK REGISTRATION WITH RETRY
-- ============================================================
-- RegisterInitGameStatePostHook hooks AGameModeBase which only exists
-- on server/host — clients never receive the callback. Use bounded
-- retry instead so hooks register on all machines.

local ammoHookRegistered = false
local inventoryHookRegistered = false

local function TryRegisterHooks()
    if not ammoHookRegistered then
        if RegisterAmmoHooks() then
            ammoHookRegistered = true
            Log.Debug("Ammo display hook registered")
        end
    end

    if not inventoryHookRegistered then
        if RegisterInventoryHook() then
            inventoryHookRegistered = true
            Log.Debug("Inventory hook registered")
        end
    end

    return ammoHookRegistered and inventoryHookRegistered
end

local MAX_HOOK_ATTEMPTS = 20

local function RegisterHooksWithRetry(attempts)
    attempts = attempts or 0

    if attempts >= MAX_HOOK_ATTEMPTS then
        if not ammoHookRegistered then
            Log.Warning("Failed to register ammo display hook after %d attempts", MAX_HOOK_ATTEMPTS)
        end
        if not inventoryHookRegistered then
            Log.Warning("Failed to register inventory hook after %d attempts", MAX_HOOK_ATTEMPTS)
        end
        return
    end

    if not TryRegisterHooks() then
        ExecuteWithDelay(500, function()
            RegisterHooksWithRetry(attempts + 1)
        end)
    else
        Log.Debug("All hooks registered")
    end
end

ExecuteWithDelay(500, function()
    RegisterHooksWithRetry()
end)

print("[Ammo Counter] Mod loaded\n")
