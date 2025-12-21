-- Ammo Counter Configuration
-- Customize the colors for different ammo states

return {
    -- Display mode for ammo counter
    -- false = "Ammo in Gun | Ammo in Inventory" (default, original mod behavior)
    -- true  = "Ammo in Gun | Max Capacity | Ammo in Inventory"
    -- Example: Grinder missing half ammo with 40 in inventory would show: 5 | 10 | 40
    ShowMaxCapacity = false,

    -- Loaded ammo warning threshold (ammo currently in the gun)
    -- When current ammo drops to or below this percentage, it turns yellow
    -- Value: 0.0 to 1.0 (e.g., 0.5 = 50% of max capacity)
    LoadedAmmoWarning = 0.5,

    -- Inventory ammo warning threshold (spare ammo in inventory)
    -- "adaptive" = Adapts to each weapon's max capacity (yellow when 1 reload or less)
    -- Examples: 10 rounds for 9mm Pistol, 10 for Grinder, 1 arrow for Crossbow
    -- Or set a specific number to use the same threshold for all weapons:
    --   InventoryAmmoWarning = 20   -- Yellow when 20 or fewer rounds remain
    --   InventoryAmmoWarning = 50   -- Yellow when 50 or fewer rounds remain
    InventoryAmmoWarning = "adaptive",

    -- Color when ammo is at good levels (default UI cyan)
    -- RGB values are 0-255
    AmmoGood = {
        R = 114,
        G = 242,
        B = 255
    },

    -- Color when ammo is low (yellow)
    -- RGB values are 0-255
    AmmoLow = {
        R = 255,
        G = 200,
        B = 32
    },

    -- Color when you have no ammo (red)
    -- RGB values are 0-255
    NoAmmo = {
        R = 249,
        G = 41,
        B = 41
    },

    -- Advanced: Enable debug logging (useful for troubleshooting)
    -- Leave this as false unless you're experiencing issues
    -- When enabled, prints detailed information to UE4SS.log
    Debug = false
}
