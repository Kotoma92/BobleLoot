--[[ UI/Theme.lua
     Single fixed palette for BobleLoot UI surfaces.
     Distilled from VoidstormGamba's "standard" palette.

     All colors are flat RGBA arrays { r, g, b, a } with values 0-1.
     Consumers read as:  ns.Theme.accent[1], etc.
     or unpack:          unpack(ns.Theme.accent)

     A future palette swap is a single-file table replacement.
]]

local _, ns = ...
local Theme = {}
ns.Theme = Theme

-- ── Accent / semantic ──────────────────────────────────────────────────
Theme.accent      = { 0.20, 0.85, 0.95, 1.00 }  -- cyan  #33D9F2
Theme.accentDim   = { 0.13, 0.55, 0.62, 1.00 }  -- dim cyan
Theme.gold        = { 1.00, 0.82, 0.00, 1.00 }  -- #FFD100
Theme.success     = { 0.10, 0.80, 0.30, 1.00 }  -- green  #19CC4D
Theme.warning     = { 1.00, 0.65, 0.00, 1.00 }  -- amber  #FFA600
Theme.danger      = { 0.90, 0.20, 0.20, 1.00 }  -- red    #E63333
Theme.muted       = { 0.55, 0.55, 0.55, 1.00 }  -- grey
Theme.white       = { 1.00, 1.00, 1.00, 1.00 }

-- ── Color-mode variants ────────────────────────────────────────────────
-- Each variant table mirrors the semantic color keys that change between modes.
-- Theme:SetColorMode swaps the live Theme.success/warning/danger/etc. references.

local COLOR_MODES = {
    default = {
        -- Standard red/yellow/green ramp (existing palette values).
        success  = { 0.10, 0.80, 0.30, 1.00 },  -- green  #19CC4D
        warning  = { 1.00, 0.65, 0.00, 1.00 },  -- amber  #FFA600
        danger   = { 0.90, 0.20, 0.20, 1.00 },  -- red    #E63333
        hcMode   = false,
    },
    deuter = {
        -- Orange-to-blue: accessible for deuteranopia and protanopia.
        -- Low (danger):   #FF8C00 orange
        -- High (success): #4D94FF blue
        success  = { 0.302, 0.580, 1.000, 1.00 },  -- blue   #4D94FF
        warning  = { 0.900, 0.550, 0.150, 1.00 },  -- intermediate amber-orange
        danger   = { 1.000, 0.549, 0.000, 1.00 },  -- orange #FF8C00
        hcMode   = false,
    },
    highcontrast = {
        -- Same hues as default; hcMode=true tells consumers to fill cell background
        -- with the score color and render text as white for maximum luminance contrast.
        success  = { 0.10, 0.80, 0.30, 1.00 },
        warning  = { 1.00, 0.65, 0.00, 1.00 },
        danger   = { 0.90, 0.20, 0.20, 1.00 },
        hcMode   = true,
    },
}

-- Consumer callback list. Each entry is a zero-argument function called by
-- Theme:ApplyColorMode after swapping the live palette references.
local _colorModeConsumers = {}

-- Current mode name (matches a key in COLOR_MODES).
Theme.currentMode = "default"

-- High-contrast flag: true when current mode fills cell backgrounds.
-- Consumers check this to decide text-vs-background coloring strategy.
Theme.hcMode = false

--- Register a callback that fires when the color mode is changed.
-- @param fn  zero-argument function; called after palette tables are swapped.
function Theme:RegisterColorModeConsumer(fn)
    if type(fn) == "function" then
        _colorModeConsumers[#_colorModeConsumers + 1] = fn
    end
end

--- Swap the active palette to the given mode and notify all consumers.
-- @param mode  "default" | "deuter" | "highcontrast"
--              Unknown values are silently ignored (mode stays unchanged).
function Theme:SetColorMode(mode)
    local variant = COLOR_MODES[mode]
    if not variant then return end

    -- Overwrite the live semantic color references in-place.
    -- Consumers that read ns.Theme.success etc. at render time see the new values.
    Theme.success = variant.success
    Theme.warning = variant.warning
    Theme.danger  = variant.danger
    Theme.hcMode  = variant.hcMode
    Theme.currentMode = mode

    -- Re-assign ScoreColor and ScoreColorRelative to mode-specific implementations.
    if mode == "deuter" then
        Theme.ScoreColor         = Theme._ScoreColorDeuter
        Theme.ScoreColorRelative = Theme._ScoreColorRelativeDeuter
    elseif mode == "highcontrast" then
        -- HC uses same thresholds as default; hcMode flag drives the visual change.
        Theme.ScoreColor         = Theme._ScoreColorDefault
        Theme.ScoreColorRelative = Theme._ScoreColorRelativeDefault
    else
        Theme.ScoreColor         = Theme._ScoreColorDefault
        Theme.ScoreColorRelative = Theme._ScoreColorRelativeDefault
    end

    -- Notify all registered consumers.
    for _, fn in ipairs(_colorModeConsumers) do
        local ok, err = pcall(fn)
        if not ok then
            -- Never let a broken consumer silently swallow the mode swap.
            error("BobleLoot Theme consumer error: " .. tostring(err), 2)
        end
    end
end

--- Convenience alias — called by SettingsPanel dropdown and OnEnable restore.
function Theme:ApplyColorMode(mode)
    return self:SetColorMode(mode)
end

-- ── Surfaces ───────────────────────────────────────────────────────────
Theme.bgBase      = { 0.08, 0.08, 0.10, 0.97 }  -- near-black
Theme.bgSurface   = { 0.12, 0.12, 0.16, 1.00 }  -- card bg
Theme.bgInput     = { 0.06, 0.06, 0.08, 1.00 }  -- edit box / slider track
Theme.bgTitleBar  = { 0.05, 0.05, 0.07, 1.00 }  -- title bar fill
Theme.bgTabActive = { 0.14, 0.14, 0.20, 1.00 }  -- active tab fill

-- ── Borders ────────────────────────────────────────────────────────────
Theme.borderNormal = { 0.20, 0.20, 0.25, 1.00 }
Theme.borderAccent = { 0.20, 0.85, 0.95, 1.00 }  -- same as accent

-- ── Fonts ──────────────────────────────────────────────────────────────
Theme.fontTitle   = "Fonts\\FRIZQT__.TTF"
Theme.fontBody    = "Fonts\\ARIALN.TTF"
Theme.sizeTitle   = 14
Theme.sizeHeading = 12
Theme.sizeBody    = 11
Theme.sizeSmall   = 10

-- ── Helpers ────────────────────────────────────────────────────────────

--- Apply a consistent backdrop to any frame via BackdropTemplateMixin.
-- @param frame     Frame that has been created with "BackdropTemplate"
-- @param bgKey     Key in ns.Theme for the background color (e.g. "bgBase")
-- @param borderKey Key in ns.Theme for the border color (e.g. "borderNormal")
function Theme.ApplyBackdrop(frame, bgKey, borderKey)
    local bg  = Theme[bgKey]     or Theme.bgBase
    local bdr = Theme[borderKey] or Theme.borderNormal
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(bdr[1], bdr[2], bdr[3], bdr[4])
end

-- ── Score-color implementations (mode-specific) ───────────────────────

-- Default (red/amber/green). Renamed from the Batch 1E original.
-- Reads Theme.success/warning/danger at call time so live palette swaps work.
function Theme._ScoreColorDefault(score)
    if score == nil then return Theme.muted end
    if score >= 70 then return Theme.success  end
    if score >= 40 then return Theme.warning  end
    return Theme.danger
end

--- Map a score to a color relative to the session's median and max.
-- Used by plan 1D's raid-anchored gradient in the voting frame.
-- Two-segment linear interpolation:
--   * score >= max      -> success
--   * median <= score   -> interpolate warning -> success as score goes from median -> max
--   * score <  median   -> interpolate danger  -> warning as score goes from 0      -> median
-- Fallbacks: if median/max are nil, missing, or equal, falls back to the
-- absolute Theme.ScoreColor thresholds so the tooltip still shows a sensible color.
-- Returns a new color array (safe to use directly in SetTextColor).
-- @param score   number 0-100
-- @param median  number or nil
-- @param max     number or nil
-- @return        color array { r, g, b, a }
function Theme._ScoreColorRelativeDefault(score, median, max)
    if score == nil then return Theme.muted end
    if median == nil or max == nil or max <= median then
        return Theme._ScoreColorDefault(score)
    end
    if score >= max then return { Theme.success[1], Theme.success[2], Theme.success[3], Theme.success[4] } end
    local function lerp(a, b, t) return a + (b - a) * t end
    local function mix(c1, c2, t)
        return {
            lerp(c1[1], c2[1], t),
            lerp(c1[2], c2[2], t),
            lerp(c1[3], c2[3], t),
            lerp(c1[4] or 1, c2[4] or 1, t),
        }
    end
    if score >= median then
        local t = (score - median) / (max - median)
        return mix(Theme.warning, Theme.success, t)
    else
        local t = (median > 0) and (score / median) or 0
        return mix(Theme.danger, Theme.warning, t)
    end
end

-- Deuteranopia/Protanopia (orange-to-blue). Same threshold logic; different palette.
-- SetColorMode("deuter") swaps Theme.success/warning/danger to orange/blue values
-- before assigning ScoreColor = _ScoreColorDeuter, so _ScoreColorDefault reads the
-- deuter colors at call time. Delegation is intentional.
function Theme._ScoreColorDeuter(score)
    return Theme._ScoreColorDefault(score)
end

function Theme._ScoreColorRelativeDeuter(score, median, max)
    return Theme._ScoreColorRelativeDefault(score, median, max)
end

-- Assign the live function pointers to Default implementations initially.
-- Theme:SetColorMode re-assigns these on mode change.
Theme.ScoreColor         = Theme._ScoreColorDefault
Theme.ScoreColorRelative = Theme._ScoreColorRelativeDefault
