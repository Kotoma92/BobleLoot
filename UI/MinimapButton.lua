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

-- Use silent LibStub lookups so a missing/corrupt Libs/ folder degrades
-- to "no minimap button" instead of breaking addon load entirely.
local LDB    = LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub("LibDBIcon-1.0",    true)

if not LDB or not DBIcon then
    function MB:Setup() end                -- no-op stubs
    function MB:ToggleMinimapIcon() end
    function MB:ShowDropdown() end
    function MB:BuildTooltip() end
    return
end

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

-- ── Dropdown frame (created once, reused on each right-click) ─────────

local dropdownFrame = CreateFrame("Frame", "BobleLootMinimapDropdown", UIParent,
    "UIDropDownMenuTemplate")

-- ── Right-click dropdown ───────────────────────────────────────────────

function MB:ShowDropdown()
    local isLeader = UnitIsGroupLeader("player")
    local lh       = ns.LootHistory
    local data     = _G.BobleLoot_Data
    local addonVer = addon and addon.version or "?"

    local menu = {
        -- Header (disabled title)
        { text = "Boble Loot", isTitle = true, notClickable = true, notCheckable = true },

        -- Broadcast dataset
        {
            text = "Broadcast dataset",
            notCheckable = true,
            disabled = not isLeader,
            func = function()
                if ns.Sync and ns.Sync.BroadcastNow then
                    ns.Sync:BroadcastNow(addon)
                    addon:Print("announced dataset to raid.")
                end
            end,
        },

        -- Refresh loot history
        {
            text = "Refresh loot history",
            notCheckable = true,
            func = function()
                if ns.LootHistory and ns.LootHistory.Apply then
                    ns.LootHistory:Apply(addon)
                    local lh2 = ns.LootHistory
                    addon:Print(string.format(
                        "Loot history refreshed. matched=%d scanned=%d source=%s",
                        lh2.lastMatched or 0,
                        lh2.lastScanned or 0,
                        lh2.lastSource  or "?"))
                end
            end,
        },

        -- Run test session (submenu)
        {
            text = "Run test session",
            notCheckable = true,
            hasArrow = true,
            menuList = {
                {
                    text = "3 items", notCheckable = true,
                    func = function()
                        if ns.TestRunner then
                            ns.TestRunner:Run(addon, 3,
                                addon.db.profile.testUseDatasetItems ~= false)
                        end
                    end,
                },
                {
                    text = "5 items", notCheckable = true,
                    func = function()
                        if ns.TestRunner then
                            ns.TestRunner:Run(addon, 5,
                                addon.db.profile.testUseDatasetItems ~= false)
                        end
                    end,
                },
                {
                    text = "10 items", notCheckable = true,
                    func = function()
                        if ns.TestRunner then
                            ns.TestRunner:Run(addon, 10,
                                addon.db.profile.testUseDatasetItems ~= false)
                        end
                    end,
                },
            },
        },

        -- Transparency mode toggle (leader-only checkbox)
        {
            text = "Transparency mode",
            checked = addon and addon:IsTransparencyEnabled() or false,
            disabled = not isLeader,
            tooltipOnButton = true,
            tooltipTitle    = isLeader and nil or "Leader only",
            tooltipText     = isLeader and nil
                or "Only the raid/group leader can toggle transparency mode.",
            func = function()
                if not isLeader then return end
                local v = not (addon and addon:IsTransparencyEnabled())
                addon:SetTransparencyEnabled(v, true)
                -- Refresh settings panel if open
                if ns.SettingsPanel and ns.SettingsPanel.Refresh then
                    ns.SettingsPanel:Refresh()
                end
            end,
        },

        -- Explain last score
        {
            text = "Explain last score",
            notCheckable = true,
            -- Disable when no explain context exists yet this session.
            disabled = not (ns.ExplainPanel and ns.ExplainPanel.HasLast
                            and ns.ExplainPanel:HasLast()),
            func = function()
                if ns.ExplainPanel and ns.ExplainPanel.OpenLast then
                    ns.ExplainPanel:OpenLast()
                end
            end,
        },

        -- Loot history viewer
        {
            text = "Loot history",
            notCheckable = true,
            func = function()
                if ns.HistoryViewer and ns.HistoryViewer.Toggle then
                    ns.HistoryViewer:Toggle()
                end
            end,
        },

        -- Separator
        { text = "", disabled = true, notCheckable = true },

        -- Open settings
        {
            text = "Open settings",
            notCheckable = true,
            func = function()
                if ns.SettingsPanel and ns.SettingsPanel.Open then
                    ns.SettingsPanel:Open()
                end
            end,
        },

        -- Version info (disabled, read-only)
        {
            text = "Version " .. addonVer,
            notClickable = true,
            notCheckable = true,
            disabled = true,
        },
    }

    EasyMenu(menu, dropdownFrame, "cursor", 0, 0, "MENU")
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
