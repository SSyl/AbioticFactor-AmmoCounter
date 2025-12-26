print("=== [Ammo Counter] MOD LOADING ===\n")

--[[
=================================================================================
DATA DISCOVERY NOTES (for future refactoring)
=================================================================================

HOW WE FOUND THE WEAPON DATA:

1. PLAYER CHARACTER (Live View)
   Search: "Abiotic_PlayerCharacter_C"
   Found: Abiotic_PlayerCharacter_C /Game/Maps/Facility.Facility:PersistentLevel.Abiotic_PlayerCharacter_C_2147471781

2. WEAPON IN HAND (property on player)
   Path: Player → ItemInHand_BP
   Type: AAbiotic_Weapon_ParentBP_C (inherits from AAbiotic_Item_ParentBP_C)
   Value: /Game/Maps/Facility.Facility:PersistentLevel.Weapon_Gun_wFlashlight_C_2147465130

3. WEAPON PROPERTIES (found on Abiotic_Weapon_ParentBP_C)
   Location: D:\Git Repos\UE5-Modding-Notes\AbioticFactor\dumps\types\Abiotic_Weapon_ParentBP.lua

   CURRENT AMMO (loaded in magazine):
   - weapon.CurrentRoundsInMagazine (int32)
   - Always available immediately, no initialization delay

   MAGAZINE CAPACITY:
   - weapon.MaxMagazineSize (int32)
   - Always available immediately, no initialization delay

   AMMO TYPE FILTER:
   - weapon.CompatibleAmmoTypes (array of FDataTableRowHandle)
   - Empty array = no ammo system (laser pistol, screwdriver, etc.)
   - Has entries = uses ammo (pistol, sledge, fishing rod, etc.)

4. INVENTORY AMMO (still from weapon object method)
   - weapon:InventoryHasAmmoForCurrentWeapon(false, outParams, {}, {})
   - Returns count in outParams.Count

5. WIDGET VISIBILITY CHECK
   - widget:GetVisibility() returns enum:
     0 = Visible
     1 = Collapsed (hidden, skip processing)
     2 = Hidden (hidden, skip processing)
     3 = HitTestInvisible (visible, can't click)
     4 = SelfHitTestInvisible (visible, can't click - normal for HUD)
   - Only skip if 1 or 2 (truly hidden)
   - Game hides ammo counter widget when no ammo system on current item

WHY THIS MATTERS:
- OLD WAY: Read widget.CurrentAmmo and widget.MaxAmmo
  Problem: Widget properties initialize 1 frame late → red ammo bug on load

- NEW WAY: Read weapon.CurrentRoundsInMagazine and weapon.MaxMagazineSize
  Solution: Weapon properties available immediately → correct color on first frame

REFACTORING STATUS:
✅ Read from weapon.CurrentRoundsInMagazine and weapon.MaxMagazineSize (not widget)
✅ Add widget visibility check for filtering
✅ Use LogUtil and ConfigUtil for cleaner code
✅ Remove IsWeaponReady() (visibility check replaces it)
✅ Extract color logic into helper functions (GetAmmoColor, GetInventoryAmmoColor)
✅ Simplify debug logging (removed log deduplication, cleaner format)
✅ Add error logging for invalid maxCapacity state

REMAINING:
- Consider further cleanup of UpdateAmmoDisplay if needed
- Test all functionality to ensure refactoring didn't break anything

FUTURE OPTIMIZATIONS (Maybe):
- Consider caching weapon property reads to avoid reading every frame
  (Currently reads CurrentRoundsInMagazine and MaxMagazineSize each frame,
   but reads are very cheap and needed for change detection)
=================================================================================
]]--

local UEHelpers = require("UEHelpers")
local LogUtil = require("LogUtil")
local ConfigUtil = require("ConfigUtil")

-- ============================================================
-- CONFIG VALIDATION
-- ============================================================

local DefaultConfig = {
    Debug = false,
    ShowMaxCapacity = false,
    LoadedAmmoWarning = 0.5,  -- 50% magazine capacity
    InventoryAmmoWarning = nil,  -- nil = adaptive (matches magazine size)
    NoAmmo = {R = 249, G = 41, B = 41},  -- Red
    AmmoLow = {R = 255, G = 200, B = 32},  -- Yellow
    AmmoGood = {R = 114, G = 242, B = 255}  -- Cyan
}

local UserConfig = require("../config")
local Config = ConfigUtil.MergeDefaults(UserConfig, DefaultConfig)

-- Create logger (needs to be created after config is merged for Debug flag)
local Log = LogUtil.CreateLogger("Ammo Counter", Config)

-- Validate colors
Config.NoAmmo = ConfigUtil.ValidateColor(Config.NoAmmo, DefaultConfig.NoAmmo, Log)
Config.AmmoLow = ConfigUtil.ValidateColor(Config.AmmoLow, DefaultConfig.AmmoLow, Log)
Config.AmmoGood = ConfigUtil.ValidateColor(Config.AmmoGood, DefaultConfig.AmmoGood, Log)

-- Validate numbers
Config.LoadedAmmoWarning = ConfigUtil.ValidateNumber(Config.LoadedAmmoWarning, DefaultConfig.LoadedAmmoWarning, 0.0, 1.0, Log, "LoadedAmmoWarning")
if Config.InventoryAmmoWarning then
    Config.InventoryAmmoWarning = ConfigUtil.ValidateNumber(Config.InventoryAmmoWarning, nil, 1, nil, Log, "InventoryAmmoWarning")
end

-- Validate booleans
Config.ShowMaxCapacity = ConfigUtil.ValidateBoolean(Config.ShowMaxCapacity, DefaultConfig.ShowMaxCapacity, Log, "ShowMaxCapacity")
Config.Debug = ConfigUtil.ValidateBoolean(Config.Debug, DefaultConfig.Debug, Log, "Debug")

-- Convert colors to UE4 format
local COLOR_NO_AMMO = ConfigUtil.ConvertColor(Config.NoAmmo, 249, 41, 41)
local COLOR_AMMO_LOW = ConfigUtil.ConvertColor(Config.AmmoLow, 255, 200, 32)
local COLOR_AMMO_GOOD = ConfigUtil.ConvertColor(Config.AmmoGood, 114, 242, 255)

-- Config constants
local LOADED_AMMO_WARNING = Config.LoadedAmmoWarning
local INVENTORY_AMMO_THRESHOLD = Config.InventoryAmmoWarning
local SHOW_MAX_CAPACITY = Config.ShowMaxCapacity

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Determine ammo color based on loaded ammo and capacity
-- Returns color or nil if invalid state
local function GetAmmoColor(loadedAmmo, maxCapacity)
    if loadedAmmo == 0 then
        return COLOR_NO_AMMO
    elseif maxCapacity > 0 then
        local percentage = loadedAmmo / maxCapacity
        if percentage <= LOADED_AMMO_WARNING then
            return COLOR_AMMO_LOW
        else
            return COLOR_AMMO_GOOD
        end
    else
        -- This shouldn't happen with weapon object reads - log error
        Log("ERROR: maxCapacity is " .. tostring(maxCapacity) .. " when loadedAmmo is " .. tostring(loadedAmmo), "error")
        return nil  -- Don't set color, let widget keep default
    end
end

-- Determine inventory ammo color based on count and threshold
local function GetInventoryAmmoColor(inventoryAmmo, threshold)
    if inventoryAmmo == 0 then
        return COLOR_NO_AMMO
    elseif inventoryAmmo > 0 and inventoryAmmo <= threshold then
        return COLOR_AMMO_LOW
    else
        return COLOR_AMMO_GOOD
    end
end

-- Set widget color (wrapper to reduce duplication)
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
-- WIDGET CREATION
-- ============================================================

-- Create inventory ammo widget (only used when SHOW_MAX_CAPACITY is true)
-- Cached at module level to persist across UpdateAmmo calls
local inventoryTextWidget = nil
local separatorWidget = nil

local function CreateSeparatorWidget(widget)
    if separatorWidget and separatorWidget:IsValid() then
        return separatorWidget
    end

    local ok, originalSeparator = pcall(function()
        return widget.Image_0
    end)

    if not ok or not originalSeparator:IsValid() then
        Log("Failed to get Image_0 separator", "error")
        return nil
    end

    local ok2, canvas = pcall(function()
        return widget.VisCanvas
    end)

    if not ok2 or not canvas:IsValid() then
        Log("Failed to get VisCanvas for separator", "error")
        return nil
    end

    local imageClass = originalSeparator:GetClass()
    -- Use Template parameter to copy properties from original
    local newSeparator = StaticConstructObject(imageClass, canvas, FName("InventoryAmmoSeparator"), 0, 0, false, false, originalSeparator)

    if not newSeparator:IsValid() then
        Log("Failed to create separator widget", "error")
        return nil
    end

    local slot = canvas:AddChildToCanvas(newSeparator)
    if not slot:IsValid() then
        Log("Failed to add separator to canvas", "error")
        return nil
    end

    local ok3, originalSlot = pcall(function()
        return originalSeparator.Slot
    end)

    if ok3 and originalSlot:IsValid() then
        local ok4, originalOffsets = pcall(function()
            return originalSlot:GetOffsets()
        end)

        if ok4 and originalOffsets then
            local baseOffset = 60.83
            local extraOffset = 0

            -- Get MaxAmmo text width for dynamic positioning
            local ok5, maxAmmoText = pcall(function()
                return widget.Text_MaxAmmo
            end)

            if ok5 and maxAmmoText:IsValid() then
                local ok6, desiredSize = pcall(function()
                    return maxAmmoText:GetDesiredSize()
                end)

                if ok6 and desiredSize then
                    local baselineWidth = 37
                    extraOffset = desiredSize.X - baselineWidth
                end
            end

            slot:SetOffsets({
                Left = originalOffsets.Left + baseOffset + extraOffset,
                Top = originalOffsets.Top,
                Right = originalOffsets.Right,
                Bottom = originalOffsets.Bottom
            })
        end
    end

    separatorWidget = newSeparator
    Log("Separator widget created", "debug")
    return newSeparator
end

local function CreateInventoryWidget(widget)
    if inventoryTextWidget and inventoryTextWidget:IsValid() then
        return inventoryTextWidget
    end

    local ok, currentAmmoText = pcall(function()
        return widget.Text_CurrentAmmo
    end)

    if not ok or not currentAmmoText:IsValid() then
        Log("Failed to get Text_CurrentAmmo for cloning", "error")
        return nil
    end

    local ok2, canvas = pcall(function()
        return widget.VisCanvas
    end)

    if not ok2 or not canvas:IsValid() then
        Log("Failed to get VisCanvas", "error")
        return nil
    end

    local textBlockClass = currentAmmoText:GetClass()
    -- Use Template parameter to copy properties from Text_CurrentAmmo
    local newWidget = StaticConstructObject(textBlockClass, canvas, FName("Text_InventoryAmmo"), 0, 0, false, false, currentAmmoText)

    if not newWidget:IsValid() then
        Log("Failed to create inventory text widget", "error")
        return nil
    end

    -- Set text justification to left so it grows to the right instead of center
    pcall(function()
        newWidget.Justification = "Left"
    end)

    local slot = canvas:AddChildToCanvas(newWidget)
    if not slot:IsValid() then
        Log("Failed to add widget to canvas", "error")
        return nil
    end

    -- Get Text_MaxAmmo for positioning reference
    local ok3, maxAmmoText = pcall(function()
        return widget.Text_MaxAmmo
    end)

    if ok3 and maxAmmoText:IsValid() then
        local ok4, maxAmmoSlot = pcall(function()
            return maxAmmoText.Slot
        end)

        if ok4 and maxAmmoSlot:IsValid() then
            local ok5, maxOffsets = pcall(function()
                return maxAmmoSlot:GetOffsets()
            end)

            if ok5 and maxOffsets then
                -- Calculate dynamic offset based on MaxAmmo text width
                local baseOffset = 60.83
                local extraOffset = 0

                -- Try to get the rendered size of Text_MaxAmmo
                local ok6, desiredSize = pcall(function()
                    return maxAmmoText:GetDesiredSize()
                end)

                if ok6 and desiredSize then
                    Log("Initial MaxAmmo DesiredSize: X=" .. tostring(desiredSize.X) .. ", Y=" .. tostring(desiredSize.Y), "debug")
                    -- Adjust offset based on text width (negative = move left, positive = move right)
                    -- Baseline is 2-digit width (~37px like pistol "10")
                    local baselineWidth = 37
                    extraOffset = desiredSize.X - baselineWidth
                    Log("Initial extraOffset: " .. tostring(extraOffset), "debug")
                else
                    Log("Failed to get initial DesiredSize from MaxAmmo text", "debug")
                end

                slot:SetOffsets({
                    Left = maxOffsets.Left + baseOffset + extraOffset,
                    Top = -10.0,
                    Right = 57.0,
                    Bottom = maxOffsets.Bottom
                })
            end
        end
    end


    inventoryTextWidget = newWidget
    Log("Inventory ammo widget created", "debug")
    return newWidget
end

-- Update the ammo counter display with inventory count
local function UpdateAmmoDisplay(widget, weapon, lastWeaponAddress, lastInventoryAmmo, cachedMaxCapacity, lastLoadedAmmo)
    -- Validate weapon is still valid (can become invalid during weapon switching)
    if not weapon:IsValid() then
        return lastInventoryAmmo, lastWeaponAddress, cachedMaxCapacity, lastLoadedAmmo
    end

    -- Get inventory ammo count (weapon can become invalid between IsValid check and this call)
    local inventoryAmmo = 0
    local ok, outParams = pcall(function()
        local params = {}
        weapon:InventoryHasAmmoForCurrentWeapon(false, params, {}, {})
        return params
    end)

    if ok and outParams then
        inventoryAmmo = outParams.Count or 0
    else
        -- Weapon became invalid during call, return cached values
        return lastInventoryAmmo, lastWeaponAddress, cachedMaxCapacity, lastLoadedAmmo
    end

    -- Check weapon change
    local currentWeaponAddress = weapon:GetAddress()
    local weaponChanged = (currentWeaponAddress ~= lastWeaponAddress)

    -- Check inventory ammo change
    local inventoryAmmoChanged = (inventoryAmmo ~= lastInventoryAmmo)

    -- Read loaded ammo directly from weapon (NOT widget - immediate and reliable)
    local loadedAmmo = nil
    local ok_ammo, ammo_val = pcall(function()
        return weapon.CurrentRoundsInMagazine
    end)
    if ok_ammo and ammo_val ~= nil then
        loadedAmmo = ammo_val
    end

    -- Check loaded ammo change
    local loadedAmmoChanged = (loadedAmmo ~= lastLoadedAmmo)

    -- Read magazine capacity directly from weapon (NOT widget - immediate and reliable)
    local maxCapacity = cachedMaxCapacity
    if weaponChanged or maxCapacity == -1 then
        local ok, mag = pcall(function()
            return weapon.MaxMagazineSize
        end)
        if ok and mag then
            maxCapacity = mag
        end
    end

    -- Debug logging (only when something changes)
    if weaponChanged or inventoryAmmoChanged or loadedAmmoChanged then
        Log(string.format("Ammo update - Loaded: %d/%d | Inventory: %d | Changed: weapon=%s inv=%s loaded=%s",
            loadedAmmo or 0, maxCapacity or 0, inventoryAmmo or 0,
            tostring(weaponChanged), tostring(inventoryAmmoChanged), tostring(loadedAmmoChanged)), "debug")
    end

    -- Update loaded ammo color when values change
    if inventoryAmmoChanged or weaponChanged or loadedAmmoChanged then
        local ok, currentAmmoWidget = pcall(function()
            return widget.Text_CurrentAmmo
        end)

        if ok and currentAmmoWidget:IsValid() and loadedAmmo ~= nil then
            local color = GetAmmoColor(loadedAmmo, maxCapacity)
            SetWidgetColor(currentAmmoWidget, color)
        end
    end

    -- On first load or weapon switch, check if display is wrong (fallback only)
    local needsUpdate = false
    if not inventoryAmmoChanged and not weaponChanged and inventoryAmmo then
        local ok2, textWidget = pcall(function()
            return widget.Text_MaxAmmo
        end)
        if ok2 and textWidget:IsValid() then
            local currentText = textWidget:GetText():ToString()
            needsUpdate = (currentText ~= tostring(inventoryAmmo))
        end
    end

    -- Update if: inventory ammo changed, weapon changed, or display is wrong (fallback)
    if inventoryAmmo and (inventoryAmmoChanged or weaponChanged or needsUpdate) then
        if SHOW_MAX_CAPACITY then
            -- Mode: "Ammo in Gun | Max Capacity | Ammo in Inventory"
            -- Create separator if it doesn't exist
            if not separatorWidget or not separatorWidget:IsValid() then
                CreateSeparatorWidget(widget)
            end

            -- Reposition separator if weapon changed
            if weaponChanged and separatorWidget and separatorWidget:IsValid() then
                local ok, sepSlot = pcall(function()
                    return separatorWidget.Slot
                end)

                local ok2, originalSep = pcall(function()
                    return widget.Image_0
                end)

                if ok and sepSlot:IsValid() and ok2 and originalSep:IsValid() then
                    local ok3, originalSlot = pcall(function()
                        return originalSep.Slot
                    end)

                    if ok3 and originalSlot:IsValid() then
                        local ok4, originalOffsets = pcall(function()
                            return originalSlot:GetOffsets()
                        end)

                        if ok4 and originalOffsets then
                            local baseOffset = 60.83
                            -- Estimate width from digit count: 1 digit=~19px, 2 digit=~37px, 3 digit=~55px
                            local digitCount = string.len(tostring(maxCapacity))
                            local estimatedWidth = 19 + (digitCount - 1) * 18
                            local extraOffset = estimatedWidth - 37

                            sepSlot:SetOffsets({
                                Left = originalOffsets.Left + baseOffset + extraOffset,
                                Top = originalOffsets.Top,
                                Right = originalOffsets.Right,
                                Bottom = originalOffsets.Bottom
                            })
                        end
                    end
                end
            end

            -- Create inventory widget if it doesn't exist
            local invWidget = inventoryTextWidget
            if not invWidget or not invWidget:IsValid() then
                invWidget = CreateInventoryWidget(widget)
            end

            if invWidget and invWidget:IsValid() then
                -- Reposition if weapon changed
                if weaponChanged then
                    local ok, invSlot = pcall(function()
                        return invWidget.Slot
                    end)

                    local ok2, maxAmmoText = pcall(function()
                        return widget.Text_MaxAmmo
                    end)

                    if ok and invSlot:IsValid() and ok2 and maxAmmoText:IsValid() then
                        local ok3, maxAmmoSlot = pcall(function()
                            return maxAmmoText.Slot
                        end)

                        if ok3 and maxAmmoSlot:IsValid() then
                            local ok4, maxOffsets = pcall(function()
                                return maxAmmoSlot:GetOffsets()
                            end)

                            if ok4 and maxOffsets then
                                local baseOffset = 60.83
                                -- Estimate width from digit count: 1 digit=~19px, 2 digit=~37px, 3 digit=~55px
                                local digitCount = string.len(tostring(maxCapacity))
                                local estimatedWidth = 19 + (digitCount - 1) * 18
                                local extraOffset = estimatedWidth - 37


                                invSlot:SetOffsets({
                                    Left = maxOffsets.Left + baseOffset + extraOffset,
                                    Top = -10.0,
                                    Right = 57.0,
                                    Bottom = maxOffsets.Bottom
                                })
                            end
                        end
                    end
                end

                -- Only update if value actually changed
                if inventoryAmmoChanged or weaponChanged then
                    local setText = pcall(function()
                        invWidget:SetText(FText(tostring(inventoryAmmo)))
                    end)

                    if not setText then
                        Log("Failed to set inventory text", "error")
                    end

                    local threshold = INVENTORY_AMMO_THRESHOLD or maxCapacity
                    local color = GetInventoryAmmoColor(inventoryAmmo, threshold)
                    SetWidgetColor(invWidget, color)
                end
            end
        else
            -- Mode: "Ammo in Gun | Ammo in Inventory" (original behavior)
            local ok3, textWidget = pcall(function()
                return widget.Text_MaxAmmo
            end)
            if ok3 and textWidget:IsValid() then
                local setText = pcall(function()
                    textWidget:SetText(FText(tostring(inventoryAmmo)))
                end)

                if not setText then
                    Log("Failed to set text", "error")
                end

                local threshold = INVENTORY_AMMO_THRESHOLD or maxCapacity
                local color = GetInventoryAmmoColor(inventoryAmmo, threshold)
                SetWidgetColor(textWidget, color)
            end
        end

        return inventoryAmmo, currentWeaponAddress, maxCapacity, loadedAmmo
    end

    return lastInventoryAmmo, lastWeaponAddress, maxCapacity, lastLoadedAmmo
end

-- Hook UpdateAmmo to replace max capacity with inventory count
local function RegisterAmmoHooks()
    -- Cache per weapon to handle weapon switching correctly
    local lastWeaponPath = nil
    local lastInventoryAmmo = -1  -- -1 = not fetched yet, 0+ = actual value
    local cachedMaxCapacity = -1  -- -1 = not fetched yet, 0+ = actual value
    local lastLoadedAmmo = -1  -- -1 = not fetched yet, 0+ = actual value

    -- For Blueprint functions, BOTH callbacks act as post-callbacks
    -- So we put our logic in the "pre-hook" which actually runs AFTER UpdateAmmo
    RegisterHook("/Game/Blueprints/Widgets/W_HUD_AmmoCounter.W_HUD_AmmoCounter_C:UpdateAmmo", function(Context)
        -- This runs AFTER UpdateAmmo for blueprint functions

        local success, err = pcall(function()
            local widget = Context:get()
            if not widget:IsValid() then
                return
            end

            -- Check if widget is visible - game hides it for non-ammo weapons
            -- Visibility enum: 0=Visible, 1=Collapsed, 2=Hidden, 3=HitTestInvisible, 4=SelfHitTestInvisible
            -- SelfHitTestInvisible (4) means visible but not clickable (normal for HUD elements)
            local ok_vis, visibility = pcall(function()
                return widget:GetVisibility()
            end)

            -- Only skip if Collapsed (1) or Hidden (2) - widget is truly not visible
            if ok_vis and (visibility == 1 or visibility == 2) then
                return  -- Widget hidden, skip processing
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

            lastInventoryAmmo, lastWeaponPath, cachedMaxCapacity, lastLoadedAmmo = UpdateAmmoDisplay(
                widget,
                weapon,
                lastWeaponPath,
                lastInventoryAmmo,
                cachedMaxCapacity,
                lastLoadedAmmo
            )
        end)

        if not success then
            Log("Hook error: " .. tostring(err), "error")
        end
    end)

    Log("UpdateAmmo hook registered", "debug")
end

-- Initialize the mod
local hooksRegistered = false

RegisterInitGameStatePostHook(function(GameModeBase)
    -- Called after game state is initialized - safe to register hooks immediately
    if not hooksRegistered then
        hooksRegistered = true
        Log("Game state initialized, registering hooks", "debug")
        RegisterAmmoHooks()
    end
end)

print("[Ammo Counter] Mod loaded\n")
