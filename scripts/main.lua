print("=== [Ammo Counter] MOD LOADING ===\n")

local UEHelpers = require("UEHelpers")
local Config = require("../config")
local DEBUG = Config.Debug or false

local function ConvertColor(colorConfig, defaultR, defaultG, defaultB)
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

local COLOR_NO_AMMO = ConvertColor(Config.NoAmmo, 249, 41, 41)
local COLOR_AMMO_LOW = ConvertColor(Config.AmmoLow, 255, 200, 32)
local COLOR_AMMO_GOOD = ConvertColor(Config.AmmoGood, 114, 242, 255)

-- Validate and clamp LoadedAmmoWarning to 0.0-1.0
local LOADED_AMMO_WARNING = math.max(0.0, math.min(1.0, tonumber(Config.LoadedAmmoWarning) or 0.5))

-- Validate InventoryAmmoWarning (nil = adaptive, number = clamped to min 1)
local INVENTORY_AMMO_THRESHOLD = tonumber(Config.InventoryAmmoWarning)
if INVENTORY_AMMO_THRESHOLD then
    INVENTORY_AMMO_THRESHOLD = math.max(1, INVENTORY_AMMO_THRESHOLD)
end

local SHOW_MAX_CAPACITY = Config.ShowMaxCapacity == true

-- Log cache for deduplication
local lastLogMessage = nil

local function Log(message, level)
    level = level or "info"

    if level == "debug" and not DEBUG then
        return
    end

    local prefix = ""
    if level == "error" then
        prefix = "ERROR: "
    elseif level == "warning" then
        prefix = "WARNING: "
    end

    print("[Ammo Counter] " .. prefix .. tostring(message) .. "\n")
end

local function IsWeaponReady(weapon)
    if not weapon:IsValid() then
        return false
    end

    local ok, currentOwner = pcall(function()
        return weapon.CurrentOwner
    end)
    if not ok or not currentOwner:IsValid() then
        return false
    end

    local ok2, itemData = pcall(function()
        return weapon.ItemData
    end)
    if not ok2 or not itemData:IsValid() then
        return false
    end

    local ok3, isWeapon = pcall(function()
        return itemData.IsWeapon_63_57F6A703413EA260B1455CA81F2D4911
    end)
    if not ok3 or not isWeapon then
        return false
    end

    -- WeaponData property uses Unreal Engine's mangled name format: PropertyName_Index_GUID
    -- Found in W_HUD_AmmoCounter_UpdateAmmo bytecode export (line 1039)
    -- Engine requires the full mangled name - short form "WeaponData" causes nullptr errors
    local ok4, weaponData = pcall(function()
        return itemData.WeaponData_61_3C29CF6C4A7F9DD435F9318FEE4B033D
    end)
    if not ok4 or not weaponData:IsValid() then
        return false
    end

    local ok5, changeableData = pcall(function()
        return weapon.ChangeableData
    end)
    if not ok5 or not changeableData:IsValid() then
        return false
    end

    return true
end

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

    -- Get inventory ammo count
    local outParams = {}
    weapon:InventoryHasAmmoForCurrentWeapon(false, outParams, {}, {})
    local inventoryAmmo = outParams.Count

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

    -- Build consolidated log message
    local logMessage = string.format(
        "=== UpdateAmmoDisplay ===\n" ..
        "  weaponChanged: %s | inventoryChanged: %s (%d->%d) | loadedChanged: %s (%d->%d)\n" ..
        "  Loaded: %d | Inventory: %d | MaxCap: %d",
        tostring(weaponChanged),
        tostring(inventoryAmmoChanged), lastInventoryAmmo or -1, inventoryAmmo or -1,
        tostring(loadedAmmoChanged), lastLoadedAmmo or -1, loadedAmmo or -1,
        loadedAmmo or -1, inventoryAmmo or -1, maxCapacity or -1
    )

    -- Only log if message changed
    if logMessage ~= lastLogMessage then
        Log(logMessage, "debug")
        lastLogMessage = logMessage
    end

    -- Set loaded ammo color when inventory, weapon, or loaded ammo changes
    if inventoryAmmoChanged or weaponChanged or loadedAmmoChanged then
        local ok, currentAmmoWidget = pcall(function()
            return widget.Text_CurrentAmmo
        end)

        if ok and currentAmmoWidget:IsValid() then
            if loadedAmmo ~= nil then
                local color
                local colorName = ""

                if loadedAmmo == 0 then
                    color = COLOR_NO_AMMO
                    colorName = "NO_AMMO (red)"
                elseif maxCapacity > 0 then
                    local percentage = loadedAmmo / maxCapacity
                    if percentage <= LOADED_AMMO_WARNING then
                        color = COLOR_AMMO_LOW
                        colorName = "AMMO_LOW (yellow)"
                    else
                        color = COLOR_AMMO_GOOD
                        colorName = "AMMO_GOOD (cyan)"
                    end
                else
                    -- maxCapacity not ready yet, use default cyan
                    color = COLOR_AMMO_GOOD
                    colorName = "AMMO_GOOD (cyan - maxCap not ready)"
                end

                Log("  >>> COLOR UPDATE: " .. colorName, "debug")

                pcall(function()
                    local colorStruct = {
                        SpecifiedColor = color,
                        ColorUseRule = "UseColor_Specified"
                    }
                    currentAmmoWidget:SetColorAndOpacity(colorStruct)
                end)
            end
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

                    local colorSuccess, colorErr = pcall(function()
                        local threshold = INVENTORY_AMMO_THRESHOLD or maxCapacity

                        local color
                        if inventoryAmmo == 0 then
                            color = COLOR_NO_AMMO
                        elseif inventoryAmmo > 0 and inventoryAmmo <= threshold then
                            color = COLOR_AMMO_LOW
                        else
                            color = COLOR_AMMO_GOOD
                        end

                        local colorStruct = {
                            SpecifiedColor = color,
                            ColorUseRule = "UseColor_Specified"
                        }
                        invWidget:SetColorAndOpacity(colorStruct)
                    end)

                    if not colorSuccess then
                        Log("Setting inventory color: " .. tostring(colorErr), "error")
                    end
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

                local colorSuccess, colorErr = pcall(function()
                    local threshold = INVENTORY_AMMO_THRESHOLD or maxCapacity

                    local color
                    if inventoryAmmo == 0 then
                        color = COLOR_NO_AMMO
                    elseif inventoryAmmo > 0 and inventoryAmmo <= threshold then
                        color = COLOR_AMMO_LOW
                    else
                        color = COLOR_AMMO_GOOD
                    end

                    local colorStruct = {
                        SpecifiedColor = color,
                        ColorUseRule = "UseColor_Specified"
                    }
                    textWidget:SetColorAndOpacity(colorStruct)
                end)

                if not colorSuccess then
                    Log("Setting color: " .. tostring(colorErr), "error")
                end
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
