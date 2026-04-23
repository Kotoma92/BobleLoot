--[[ UI/Toast.lua
     BobleLoot toast notification surface.
     Roadmap item 3.12.

     Public API:
       ns.Toast:Show(message, level)   -- "success"|"warning"|"error"
       ns.Toast:Setup(addonArg)        -- called from Core:OnEnable

     AceEvents consumed (registered in Setup):
       BobleLoot_SyncWarning           -- from Sync._recordWarning (plan 3E, Task 5)
       BobleLoot_SyncProgress          -- from Batch 2C chunked sync
       BobleLoot_SyncTimedOut          -- from Batch 2C chunked sync
       BobleLoot_SchemaDriftWarning    -- from Batch 3C schema-drift detection
       BobleLoot_DataStale             -- from RaidReminder (plan 3E, Task 10)

     Design notes:
       * One frame only. Subsequent events update text in-place.
       * Fade in 0.2s, hold 3s, fade out 0.5s.
       * Never uses UIErrorsFrame.
       * Colors: success=Theme.success, warning=Theme.warning, error=Theme.danger.
       * Position is fixed (top-centre); not user-movable (toasts are ephemeral).
]]

local ADDON_NAME, ns = ...
local Toast = {}
ns.Toast = Toast

local T            -- set to ns.Theme in Setup; avoids forward-ref at file load
local frame        -- the single toast frame
local textLabel    -- FontString child of frame
local holdTimer    -- C_Timer handle for the 3-second hold phase
local addon        -- set in Setup

local FRAME_W   = 280
local FRAME_H   = 40
local FADE_IN   = 0.2
local HOLD_SECS = 3.0
local FADE_OUT  = 0.5

local LEVEL_COLOR = {
    success = function() return T.success end,
    warning = function() return T.warning end,
    error   = function() return T.danger  end,
}

-- ── Frame creation (lazy, once) ───────────────────────────────────────

local function BuildFrame()
    if frame then return end
    T = ns.Theme

    frame = CreateFrame("Frame", "BobleLootToastFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -60)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(200)

    T.ApplyBackdrop(frame, "bgTitleBar", "borderAccent")

    textLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    textLabel:SetFont(T.fontBody, T.sizeBody, "OUTLINE")
    textLabel:SetPoint("CENTER", frame, "CENTER", 0, 0)
    textLabel:SetJustifyH("CENTER")
    textLabel:SetWidth(FRAME_W - 16)

    -- Left-edge color stripe (3px wide, full height), tinted per level.
    local stripe = frame:CreateTexture(nil, "OVERLAY")
    stripe:SetSize(3, FRAME_H - 2)
    stripe:SetPoint("LEFT", frame, "LEFT", 1, 0)
    stripe:SetColorTexture(1, 1, 1, 1)
    frame._stripe = stripe

    frame:SetAlpha(0)
    frame:Hide()
end

-- ── Animation helpers ─────────────────────────────────────────────────

local function CancelHold()
    if holdTimer then
        holdTimer:Cancel()
        holdTimer = nil
    end
end

local function StartFadeOut()
    CancelHold()
    UIFrameFadeOut(frame, FADE_OUT, frame:GetAlpha(), 0)
    C_Timer.After(FADE_OUT, function()
        if frame then frame:Hide() end
    end)
end

local function StartHold()
    CancelHold()
    holdTimer = C_Timer.NewTimer(HOLD_SECS, StartFadeOut)
end

-- ── Public API ────────────────────────────────────────────────────────

--- Show (or update) the toast.
-- @param message  string — text to display (max ~50 chars for legibility)
-- @param level    string — "success"|"warning"|"error" (default "success")
function Toast:Show(message, level)
    BuildFrame()
    level = level or "success"
    local colorFn = LEVEL_COLOR[level] or LEVEL_COLOR.success
    local col = colorFn()

    textLabel:SetText(message)
    textLabel:SetTextColor(col[1], col[2], col[3], col[4] or 1)
    if frame._stripe then
        frame._stripe:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end

    -- If already visible: update text in place; restart hold timer.
    if frame:IsShown() then
        CancelHold()
        -- Cancel any running fade-out by snapping alpha back to 1.
        frame:SetAlpha(1)
        StartHold()
        return
    end

    -- Fresh show: fade in then hold.
    frame:SetAlpha(0)
    frame:Show()
    UIFrameFadeIn(frame, FADE_IN, 0, 1)
    C_Timer.After(FADE_IN, StartHold)
end

-- ── AceEvent listeners ────────────────────────────────────────────────

--- Wire AceEvent listeners. Called once from Core:OnEnable after addon
-- has fully initialized its AceEvent mixin.
function Toast:Setup(addonArg)
    addon = addonArg
    T = ns.Theme

    -- Sync warning (fired by Sync._recordWarning, plan 3E Task 5).
    addon:RegisterMessage("BobleLoot_SyncWarning", function(_, sender, reason)
        local msg = string.format("[BL] Sync warning from %s: %s", sender, reason)
        Toast:Show(msg, "warning")
    end)

    -- Chunked sync progress (Batch 2C contract).
    -- Arguments: sender (string), received (number), total (number).
    addon:RegisterMessage("BobleLoot_SyncProgress", function(_, sender, received, total)
        local msg = string.format("[BL] Syncing from %s: %d/%d chunks", sender, received, total)
        Toast:Show(msg, "success")
    end)

    -- Chunked sync timeout (Batch 2C contract).
    -- Arguments: sender (string).
    addon:RegisterMessage("BobleLoot_SyncTimedOut", function(_, sender)
        local msg = string.format("[BL] Sync from %s timed out — using local data.", sender)
        Toast:Show(msg, "error")
    end)

    --[[ CROSS-CONTRACT: Batch 3C
         LH:DetectSchemaVersion must fire addon:SendMessage("BobleLoot_SchemaDriftWarning", description)
         when detection fails or the detected schema version differs from the expected version.
         Contract requirements:
           1. addon:SendMessage must be called (not addon:Print alone).
           2. The event name is exactly "BobleLoot_SchemaDriftWarning" (no variation).
           3. The description argument is a non-nil string (max 60 chars recommended).
         Example calls from Batch 3C:
           addon:SendMessage("BobleLoot_SchemaDriftWarning", "factionrealm key absent")
           addon:SendMessage("BobleLoot_SchemaDriftWarning", "rcSchemaDetected=0 (unknown shape)")
    ]]
    -- RC schema-drift warning (Batch 3C contract).
    -- Arguments: description (string).
    addon:RegisterMessage("BobleLoot_SchemaDriftWarning", function(_, description)
        local msg = "[BL] RC schema drift: " .. (description or "unknown")
        Toast:Show(msg, "warning")
    end)

    -- Dataset staleness warning (plan 3E Task 10 — RaidReminder fires this).
    -- Arguments: hoursOld (number).
    addon:RegisterMessage("BobleLoot_DataStale", function(_, hoursOld)
        local msg = string.format("[BL] Dataset is %dh old — run wowaudit.py", hoursOld or 0)
        Toast:Show(msg, "warning")
    end)
end
