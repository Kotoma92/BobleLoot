--[[ UI/MinimapButton.lua
     LibDataBroker launcher for BobleLoot.
     Left-click  -> toggle the custom settings panel.
     Right-click -> EasyMenu quick-actions dropdown.
     Tooltip     -> live dataset/history/transparency summary.
]]

local ADDON_NAME, ns = ...
local MB = {}
ns.MinimapButton = MB

local addon  -- set in Setup

-- ── LDB object ────────────────────────────────────────────────────────

local LDB = LibStub("LibDataBroker-1.1")
local DBIcon = LibStub("LibDBIcon-1.0")

local ldbObj = LDB:NewDataObject("BobleLoot", {
    type  = "launcher",
    label = "Boble Loot",
    icon  = "Interface\\Icons\\inv_misc_dice_01",

    OnClick = function(_, button)
        if button == "LeftButton" then
            if ns.SettingsPanel and ns.SettingsPanel.Toggle then
                ns.SettingsPanel:Toggle()
            end
        elseif button == "RightButton" then
            MB:ShowDropdown()
        end
    end,

    OnTooltipShow = function(tt)
        MB:BuildTooltip(tt)
    end,
})

-- ── Tooltip builder ───────────────────────────────────────────────────

function MB:BuildTooltip(tt)
    local T = ns.Theme
    tt:AddLine("|cff" .. string.format("%02x%02x%02x",
        math.floor(T.accent[1] * 255),
        math.floor(T.accent[2] * 255),
        math.floor(T.accent[3] * 255)) .. "Boble Loot|r")

    local data = _G.BobleLoot_Data
    if not data then
        tt:AddLine("|cff" .. string.format("%02x%02x%02x",
            math.floor(T.muted[1] * 255),
            math.floor(T.muted[2] * 255),
            math.floor(T.muted[3] * 255))
            .. "Dataset: not loaded|r")
    else
        tt:AddDoubleLine("Dataset version:", data.generatedAt or "?",
            1, 1, 1,
            T.muted[1], T.muted[2], T.muted[3])

        local count = 0
        for _ in pairs(data.characters or {}) do count = count + 1 end
        tt:AddDoubleLine("Characters loaded:", tostring(count), 1, 1, 1, 1, 1, 1)
    end

    -- Loot history line
    local lh = ns.LootHistory
    if lh and lh.lastMatched then
        tt:AddDoubleLine(
            "Loot history:",
            string.format("%d/%d (source: %s)",
                lh.lastMatched or 0,
                lh.lastScanned or 0,
                lh.lastSource  or "?"),
            1, 1, 1,
            T.muted[1], T.muted[2], T.muted[3])
    else
        tt:AddDoubleLine("Loot history:", "not yet applied",
            1, 1, 1,
            T.muted[1], T.muted[2], T.muted[3])
    end

    -- Transparency state
    if IsInGroup() or IsInRaid() then
        local on = addon and addon:IsTransparencyEnabled()
        local syncS = addon and addon:GetSyncedSettings()
        local leader = syncS and syncS.transparencyLeader or nil
        if on then
            local suffix = leader and (" (by " .. leader .. ")") or ""
            tt:AddDoubleLine("Transparency:", "ON" .. suffix,
                1, 1, 1, T.success[1], T.success[2], T.success[3])
        else
            tt:AddDoubleLine("Transparency:", "OFF",
                1, 1, 1, T.muted[1], T.muted[2], T.muted[3])
        end
    else
        tt:AddDoubleLine("Transparency:", "N/A (solo)",
            1, 1, 1,
            T.muted[1], T.muted[2], T.muted[3])
    end

    tt:AddLine(" ")
    tt:AddLine("|cff" .. string.format("%02x%02x%02x",
        math.floor(T.muted[1] * 255),
        math.floor(T.muted[2] * 255),
        math.floor(T.muted[3] * 255))
        .. "Left-click: open settings  |  Right-click: quick actions|r")
end

-- ── Right-click dropdown (body in Task 5) ─────────────────────────────

function MB:ShowDropdown()
    -- Implemented in Task 5. Stub is intentional.
    -- EasyMenu wiring added there to keep task diffs small.
end

-- ── Public API ────────────────────────────────────────────────────────

function MB:Setup(addonArg)
    addon = addonArg
    local db = addon.db.profile

    -- Ensure minimap sub-table exists with defaults.
    if not db.minimap then
        db.minimap = { hide = false, minimapPos = 220 }
    end

    -- Guard against double-register on /reload.
    if not DBIcon:IsRegistered("BobleLoot") then
        DBIcon:Register("BobleLoot", ldbObj, db.minimap)
    end
end

--- Toggle minimap icon visibility. Called by /bl minimap slash command.
function MB:ToggleMinimapIcon(addonArg)
    local db = (addonArg or addon).db.profile
    db.minimap.hide = not db.minimap.hide
    if db.minimap.hide then
        DBIcon:Hide("BobleLoot")
    else
        DBIcon:Show("BobleLoot")
    end
end
