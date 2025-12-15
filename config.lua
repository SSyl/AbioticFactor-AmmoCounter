-- Ammo Counter Configuration
-- Customize the colors for different ammo states

return {
    -- Low ammo warning threshold
    -- "default" = Automatic (yellow when you have 1 magazine or less of ammo)
    --   This adapts to each weapon: 10 rounds for 9mm pistol, 1 arrow for crossbow, etc.
    -- Or set a specific number to use the same threshold for all weapons:
    --   OneMagLeftThreshold = 10   -- Yellow when 10 or fewer rounds remain
    --   OneMagLeftThreshold = 20   -- Yellow when 20 or fewer rounds remain
    OneMagLeftThreshold = "default",

    -- Color when you have multiple magazines worth of ammo (default UI cyan)
    -- RGB values are 0-255
    MultipleMags = {
        R = 114,
        G = 242,
        B = 255
    },

    -- Color when you have one magazine or less of ammo (yellow)
    -- RGB values are 0-255
    OneMagLeft = {
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
    }
}
