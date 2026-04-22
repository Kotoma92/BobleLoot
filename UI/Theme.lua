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

--- Map a 0-100 score to a color table from this Theme.
-- Thresholds: >= 70 -> success (green), >= 40 -> warning (amber), else danger (red).
-- Returns a reference to the color array (do not mutate the return value).
-- @param score  number 0-100
-- @return       color array { r, g, b, a }
function Theme.ScoreColor(score)
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
function Theme.ScoreColorRelative(score, median, max)
    if score == nil then return Theme.muted end
    if median == nil or max == nil or max <= median then
        return Theme.ScoreColor(score)
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
