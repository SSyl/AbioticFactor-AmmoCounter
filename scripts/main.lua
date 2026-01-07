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

-- Persist across UpdateAmmo calls to avoid recreating widgets every frame
local inventoryTextWidget = nil
local separatorWidget = nil

-- ============================================================
-- DATA READING
-- ============================================================

local function GetWeaponAmmoData(weapon, cachedMaxCapacity)
    local data = {
        loadedAmmo = nil,
        maxCapacity = nil,
        inventoryAmmo = nil,
        isValidWeapon = false
    }

    if not weapon:IsValid() then
        Log.DebugOnce("GetWeaponAmmoData: weapon invalid")
        return data
    end

    local ok1, loaded = pcall(function()
        return weapon.CurrentRoundsInMagazine
    end)
    if not ok1 then
        Log.WarningOnce("Failed to read CurrentRoundsInMagazine: %s", tostring(loaded))
    elseif loaded == nil then
        Log.WarningOnce("CurrentRoundsInMagazine returned nil")
    else
        data.loadedAmmo = loaded
    end

    -- Use cached max capacity if provided, otherwise read from weapon
    if cachedMaxCapacity then
        data.maxCapacity = cachedMaxCapacity
    else
        local ok2, capacity = pcall(function()
            return weapon.MaxMagazineSize
        end)
        if not ok2 then
            Log.WarningOnce("Failed to read MaxMagazineSize: %s", tostring(capacity))
        elseif capacity == nil then
            Log.WarningOnce("MaxMagazineSize returned nil")
        else
            data.maxCapacity = capacity
        end
    end

    local ok3, outParams = pcall(function()
        local params = {}
        weapon:InventoryHasAmmoForCurrentWeapon(false, params, {}, {})
        return params
    end)
    if not ok3 then
        Log.WarningOnce("Failed to call InventoryHasAmmoForCurrentWeapon: %s", tostring(outParams))
    elseif not outParams or outParams.Count == nil then
        Log.WarningOnce("InventoryHasAmmoForCurrentWeapon returned no Count (outParams=%s)", type(outParams))
    else
        data.inventoryAmmo = outParams.Count
    end

    data.isValidWeapon = (data.loadedAmmo ~= nil and data.maxCapacity ~= nil)

    if not data.isValidWeapon then
        Log.WarningOnce("Weapon data incomplete: loadedAmmo=%s, maxCapacity=%s", type(data.loadedAmmo), type(data.maxCapacity))
    end

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
    if not widget:IsValid() or not color then
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
-- WIDGET HELPERS (ShowMaxCapacity mode)
-- ============================================================

local function GetWidgetSlot(widget)
    local ok, slot = pcall(function()
        return widget.Slot
    end)
    return (ok and slot:IsValid()) and slot or nil
end

local function GetSlotOffsets(slot)
    if not slot then return nil end
    local ok, offsets = pcall(function()
        return slot:GetOffsets()
    end)
    return ok and offsets or nil
end

local function SetSlotPosition(slot, left, top, right, bottom)
    if not slot then return false end

    local ok = pcall(function()
        slot:SetOffsets({
            Left = left,
            Top = top,
            Right = right,
            Bottom = bottom
        })
    end)

    return ok
end

-- Clone widget using Template parameter to copy all properties
local function CloneWidget(templateWidget, canvas, widgetName)
    if not templateWidget:IsValid() or not canvas:IsValid() then
        return nil
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
        return nil
    end

    local slot = canvas:AddChildToCanvas(newWidget)
    if not slot:IsValid() then
        return nil
    end

    return newWidget
end

-- ============================================================
-- WIDGET CREATION (ShowMaxCapacity mode)
-- ============================================================

local function CreateSeparatorWidget(widget)
    if separatorWidget and separatorWidget:IsValid() then
        return separatorWidget
    end

    local ok, originalSep = pcall(function()
        return widget.Image_0
    end)

    local ok2, canvas = pcall(function()
        return widget.VisCanvas
    end)

    if not (ok and originalSep:IsValid()) or not (ok2 and canvas:IsValid()) then
        Log.Error("Failed to get separator template or canvas")
        return nil
    end

    local newSeparator = CloneWidget(originalSep, canvas, "InventoryAmmoSeparator")
    if not newSeparator then
        Log.Error("Failed to create separator widget")
        return nil
    end

    separatorWidget = newSeparator
    return newSeparator
end

-- Create inventory text widget (cloned from Text_CurrentAmmo)
local function CreateInventoryWidget(widget)
    if inventoryTextWidget and inventoryTextWidget:IsValid() then
        return inventoryTextWidget
    end

    local ok, textTemplate = pcall(function()
        return widget.Text_CurrentAmmo
    end)

    local ok2, canvas = pcall(function()
        return widget.VisCanvas
    end)

    if not (ok and textTemplate:IsValid()) or not (ok2 and canvas:IsValid()) then
        Log.Error("Failed to get text template or canvas")
        return nil
    end

    local newWidget = CloneWidget(textTemplate, canvas, "Text_InventoryAmmo")
    if not newWidget then
        Log.Error("Failed to create inventory text widget")
        return nil
    end

    -- IMPORTANT: Use SetJustification() function, not property assignment
    -- Widget is already constructed and will be displayed - must use function calls
    pcall(function()
        newWidget:SetJustification(0)  -- 0 = Left, 1 = Center, 2 = Right
    end)

    inventoryTextWidget = newWidget
    return newWidget
end

-- ============================================================
-- WIDGET POSITIONING (ShowMaxCapacity mode)
-- ============================================================

-- Reposition both separator and inventory widgets when weapon changes
local function RepositionShowMaxCapacityWidgets(widget, maxCapacity)
    if not maxCapacity then return end

    local ok1, originalSep = pcall(function() return widget.Image_0 end)
    local ok2, maxAmmoText = pcall(function() return widget.Text_MaxAmmo end)

    if not (ok1 and ok2 and originalSep:IsValid() and maxAmmoText:IsValid()) then
        return
    end

    -- Calculate base distance between Image_0 and Text_MaxAmmo dynamically
    local originalSlot = GetWidgetSlot(originalSep)
    local maxSlot = GetWidgetSlot(maxAmmoText)

    if not (originalSlot and maxSlot) then
        return
    end

    local originalOffsets = GetSlotOffsets(originalSlot)
    local maxOffsets = GetSlotOffsets(maxSlot)

    if not (originalOffsets and maxOffsets) then
        return
    end

    local baseDistance = maxOffsets.Left - originalOffsets.Left

    if not (separatorWidget and separatorWidget:IsValid() and inventoryTextWidget and inventoryTextWidget:IsValid()) then
        return
    end

    local sepSlot = GetWidgetSlot(separatorWidget)
    local invSlot = GetWidgetSlot(inventoryTextWidget)

    if not (sepSlot and invSlot) then
        return
    end

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

-- Update simple mode: Replace MaxAmmo text with inventory count
local function UpdateSimpleMode(widget, inventoryAmmo, maxCapacity)
    local ok, textWidget = pcall(function()
        return widget.Text_MaxAmmo
    end)

    if not ok or not textWidget:IsValid() then
        return
    end

    pcall(function()
        textWidget:SetText(FText(tostring(inventoryAmmo)))
    end)

    local color = GetInventoryAmmoColor(inventoryAmmo, maxCapacity)
    SetWidgetColor(textWidget, color)
end

-- Update ShowMaxCapacity mode: Keep MaxAmmo, add separate inventory widget
local function UpdateShowMaxCapacityMode(widget, inventoryAmmo, maxCapacity, weaponChanged)
    local sepWidget = separatorWidget
    if not sepWidget or not sepWidget:IsValid() then
        separatorWidget = nil  -- Clear stale reference
        sepWidget = CreateSeparatorWidget(widget)
    end

    local invWidget = inventoryTextWidget
    if not invWidget or not invWidget:IsValid() then
        inventoryTextWidget = nil  -- Clear stale reference
        invWidget = CreateInventoryWidget(widget)
    end

    if not sepWidget or not invWidget then
        return
    end

    if weaponChanged then
        RepositionShowMaxCapacityWidgets(widget, maxCapacity)
    end

    pcall(function()
        invWidget:SetText(FText(tostring(inventoryAmmo)))
    end)

    local color = GetInventoryAmmoColor(inventoryAmmo, maxCapacity)
    SetWidgetColor(invWidget, color)
end

-- Update inventory ammo display (router function)
-- Mode 1: ShowMaxCapacity = false → Replace "MaxAmmo" text with inventory count
-- Mode 2: ShowMaxCapacity = true → Keep max ammo, add separate inventory widget
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

-- Updates ammo display and returns current weapon address, inventory ammo, and max capacity for change tracking
-- Returns values unchanged on error to preserve state during race conditions
local function UpdateAmmoDisplay(widget, weapon, lastWeaponAddress, lastInventoryAmmo, cachedMaxCapacity)
    local okAddr, currentWeaponAddress = pcall(function()
        return weapon:GetAddress()
    end)
    if not okAddr then
        return lastWeaponAddress, lastInventoryAmmo, cachedMaxCapacity
    end

    local weaponChanged = (currentWeaponAddress ~= lastWeaponAddress)

    -- Only read max capacity from weapon when weapon changes or cache is empty
    local maxCapacityToUse = (weaponChanged or not cachedMaxCapacity) and nil or cachedMaxCapacity

    local data = GetWeaponAmmoData(weapon, maxCapacityToUse)

    if not data.isValidWeapon then
        return lastWeaponAddress, lastInventoryAmmo, cachedMaxCapacity
    end

    local inventoryChanged = (data.inventoryAmmo ~= lastInventoryAmmo)

    -- Always update loaded ammo color (runs every frame and will get overriden otherwise)
    UpdateLoadedAmmoColor(widget, data.loadedAmmo, data.maxCapacity)

    if inventoryChanged or weaponChanged then
        UpdateInventoryAmmoDisplay(widget, data.inventoryAmmo, data.maxCapacity, weaponChanged, inventoryChanged)
    end

    return currentWeaponAddress, data.inventoryAmmo, data.maxCapacity
end

-- ============================================================
-- HOOK REGISTRATION
-- ============================================================

local function RegisterAmmoHooks()
    local lastWeaponAddress = nil
    local lastInventoryAmmo = nil
    local cachedMaxCapacity = nil

    RegisterHook("/Game/Blueprints/Widgets/W_HUD_AmmoCounter.W_HUD_AmmoCounter_C:UpdateAmmo", function(Context)
        local success, err = pcall(function()

            local widget = Context:get()
            if not widget:IsValid() then
                return
            end

            -- Filter by visibility (game hides VisCanvas for items that don't use ammo)
            local ok_vis, visCanvas = pcall(function()
                return widget.VisCanvas
            end)

            if not ok_vis or not visCanvas:IsValid() then
                return
            end

            local visibility = visCanvas:GetVisibility()

            -- SelfHitTest (3) = active, Collapsed (1) = hidden
            if visibility ~= 3 then
                return
            end

            local playerPawn = UEHelpers.GetPlayer()
            if not playerPawn:IsValid() then
                return
            end

            local ok, weapon = pcall(function()
                return playerPawn.ItemInHand_BP
            end)

            if not ok or not weapon:IsValid() then
                -- Clear cache when weapon becomes invalid
                cachedMaxCapacity = nil
                return
            end


            if not weapon:IsA("/Game/Blueprints/Items/Weapons/Abiotic_Weapon_ParentBP.Abiotic_Weapon_ParentBP_C") then
                -- Clear cache for non-weapons
                cachedMaxCapacity = nil
                return
            end

            lastWeaponAddress, lastInventoryAmmo, cachedMaxCapacity = UpdateAmmoDisplay(widget, weapon, lastWeaponAddress, lastInventoryAmmo, cachedMaxCapacity)
        end)

        if not success then
            Log.Error("Hook error: %s", tostring(err))
        end
    end)

    Log.Debug("Hooks registered")
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

local hooksRegistered = false

RegisterInitGameStatePostHook(function()
    if not hooksRegistered then
        hooksRegistered = true
        Log.Debug("Game state initialized")
        RegisterAmmoHooks()
    end
end)

print("[Ammo Counter] Mod loaded\n")
