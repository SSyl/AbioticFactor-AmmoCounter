# Ammo Counter

A UE4SS mod for Abiotic Factor that replaces the magazine capacity display with your total inventory ammo count.

## What it does

Instead of showing `[Current Mag] / [Magazine Capacity]`, the HUD now displays `[Current Mag] / [Total Ammo in Inventory]`.

The counter is color-coded based on remaining ammo:
- **Red** - Out of ammo
- **Yellow** - Low ammo (one magazine or less by default)
- **Cyan** - Plenty of ammo

## Installation

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) if you haven't already
2. Extract this mod folder to `Abiotic Factor/AbioticFactor/Binaries/Win64/Mods/`
3. Make sure `enabled.txt` exists in the mod folder

## Configuration

Edit `config.lua` to customize colors and behavior.

### Low Ammo Threshold

By default, the counter turns yellow when you have one magazine or less remaining. This automatically adapts to each weapon (10 rounds for pistols, 1 arrow for crossbows, etc.).

You can override this with a fixed number:

```lua
OneMagLeftThreshold = "default"  -- Automatic (adapts per weapon)
OneMagLeftThreshold = 10         -- Yellow at 10 rounds or fewer
OneMagLeftThreshold = 20         -- Yellow at 20 rounds or fewer
```

### Colors

All colors use 0-255 RGB values. The defaults match the game's UI style, but you can customize them:

```lua
MultipleMags = {
    R = 114,
    G = 242,
    B = 255
}
```

## Technical Notes

- Uses `RegisterInitGameStatePostHook` for reliable initialization
- Hooks `W_HUD_AmmoCounter:UpdateAmmo` to replace the display
- Caches weapon state to minimize performance impact
- Includes fallback detection for first-load edge cases

## Requirements

- UE4SS 3.x
- Abiotic Factor version 1.1+
