print("=== [Ammo Counter] MOD LOADING ===\n")

local UEHelpers = require("UEHelpers")
local LogUtil = require("LogUtil")
local ConfigUtil = require("ConfigUtil")

-- ============================================================
-- CONFIG
-- ============================================================

local UserConfig = require("../config")
local Config = ConfigUtil.ValidateAmmoCounterConfig(UserConfig, LogUtil.CreateLogger("Ammo Counter (Config)", UserConfig))
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

local function GetWeaponAmmoData(weapon)
    local data = {
        loadedAmmo = nil,
        maxCapacity = nil,
        inventoryAmmo = nil,
        isValidWeapon = false
    }

    local ok1, loaded = pcall(function()
        return weapon.CurrentRoundsInMagazine
    end)
    if ok1 and type(loaded) == "number" then
        data.loadedAmmo = loaded
    end

    local ok2, capacity = pcall(function()
        return weapon.MaxMagazineSize
    end)
    if ok2 and type(capacity) == "number" then
        data.maxCapacity = capacity
    end

    local ok3, outParams = pcall(function()
        local params = {}
        weapon:InventoryHasAmmoForCurrentWeapon(false, params, {}, {})
        return params
    end)
    if ok3 and outParams and type(outParams.Count) == "number" then
        data.inventoryAmmo = outParams.Count
    end

    -- Valid if we successfully read both essential ammo values as numbers
    data.isValidWeapon = (type(data.loadedAmmo) == "number" and type(data.maxCapacity) == "number")

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
        Log("Invalid state: loadedAmmo=" .. tostring(loadedAmmo) .. " but maxCapacity=" .. tostring(maxCapacity), "error")
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

    widget:SetColorAndOpacity({
        SpecifiedColor = color,
        ColorUseRule = "UseColor_Specified"
    })

    return true
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
    return slot:GetOffsets()
end

local function SetSlotPosition(slot, left, top, right, bottom)
    if not slot then return false end

    slot:SetOffsets({
        Left = left,
        Top = top,
        Right = right,
        Bottom = bottom
    })

    return true
end

-- Clone widget using Template parameter to copy all properties
local function CloneWidget(templateWidget, canvas, widgetName)
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
        Log("Failed to get separator template or canvas", "error")
        return nil
    end

    local newSeparator = CloneWidget(originalSep, canvas, "InventoryAmmoSeparator")
    if not newSeparator then
        Log("Failed to create separator widget", "error")
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
        Log("Failed to get text template or canvas", "error")
        return nil
    end

    local newWidget = CloneWidget(textTemplate, canvas, "Text_InventoryAmmo")
    if not newWidget then
        Log("Failed to create inventory text widget", "error")
        return nil
    end

    -- IMPORTANT: Use SetJustification() function, not property assignment
    -- Widget is already constructed and will be displayed - must use function calls
    newWidget:SetJustification(0)  -- 0 = Left, 1 = Center, 2 = Right

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

    textWidget:SetText(FText(tostring(inventoryAmmo)))

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

    invWidget:SetText(FText(tostring(inventoryAmmo)))

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

-- Updates ammo display and returns current weapon address and inventory ammo for change tracking
-- Returns values unchanged on error to preserve state during race conditions
local function UpdateAmmoDisplay(widget, weapon, lastWeaponAddress, lastInventoryAmmo)
    local data = GetWeaponAmmoData(weapon)

    if not data.isValidWeapon then
        return lastWeaponAddress, lastInventoryAmmo
    end

    local currentWeaponAddress = weapon:GetAddress()
    local weaponChanged = (currentWeaponAddress ~= lastWeaponAddress)
    local inventoryChanged = (data.inventoryAmmo ~= lastInventoryAmmo)

    -- Always update loaded ammo color (runs every frame and will get overriden otherwise)
    UpdateLoadedAmmoColor(widget, data.loadedAmmo, data.maxCapacity)

    if inventoryChanged or weaponChanged then
        UpdateInventoryAmmoDisplay(widget, data.inventoryAmmo, data.maxCapacity, weaponChanged, inventoryChanged)
    end

    return currentWeaponAddress, data.inventoryAmmo
end

-- ============================================================
-- HOOK REGISTRATION
-- ============================================================

local function RegisterAmmoHooks()
    local lastWeaponAddress = nil
    local lastInventoryAmmo = nil

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
                return
            end


            if not weapon:IsA("/Game/Blueprints/Items/Weapons/Abiotic_Weapon_ParentBP.Abiotic_Weapon_ParentBP_C") then
                return -- Early exit for non-weapons
            end

            lastWeaponAddress, lastInventoryAmmo = UpdateAmmoDisplay(widget, weapon, lastWeaponAddress, lastInventoryAmmo)
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
