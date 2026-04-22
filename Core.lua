--[[ Core.lua
     Boble Loot initialization. Sets up AceAddon, SavedVariables, the
     slash command, and exposes the addon namespace.
]]

local ADDON_NAME, ns = ...

local AceAddon   = LibStub("AceAddon-3.0")
local AceConsole = LibStub("AceConsole-3.0")
local AceDB      = LibStub("AceDB-3.0")

local BobleLoot = AceAddon:NewAddon(ADDON_NAME,
    "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")
ns.addon = BobleLoot
_G.BobleLoot = BobleLoot

BobleLoot.version = "1.1.0"

local DB_DEFAULTS = {
    profile = {
        enabled       = true,
        showColumn    = true,
        testItemCount       = 5,
        testUseDatasetItems = true,
        lootHistoryDays     = 28,
        lootMinIlvl         = 0,
        lootWeights = {
            bis      = 1.5,
            major    = 1.0,
            mainspec = 1.0,
            minor    = 0.5,
        },
        weights = {
            sim        = 0.40,
            bis        = 0.20,
            history    = 0.15,
            attendance = 0.15,
            mplus      = 0.10,
        },
        weightsEnabled = {
            sim        = true,
            bis        = true,
            history    = true,
            attendance = true,
            mplus      = true,
        },
        partialBiSValue = 0.25,
        -- Caps; if overrideCaps is true we override the value baked
        -- into the data file (useful when tweaking without regenerating).
        overrideCaps = false,
        simCap       = 5.0,
        mplusCap     = 40,   -- M+ dungeons completed this season -> 1.0
        historyCap   = 5,
        minimap  = { hide = false, minimapPos = 220 },
        panelPos = { point = "CENTER", x = 0, y = 0 },
        lastTab  = "weights",
    },
}

function BobleLoot:OnInitialize()
    self.db = AceDB:New("BobleLootDB", DB_DEFAULTS, true)
    self:RegisterChatCommand("bl",       "OnSlashCommand")
    self:RegisterChatCommand("bobleloot","OnSlashCommand")

    if ns.SettingsPanel and ns.SettingsPanel.Setup then
        ns.SettingsPanel:Setup(self)
    end
end

function BobleLoot:OnEnable()
    if ns.Sync and ns.Sync.Setup then
        ns.Sync:Setup(self)
    end
    if ns.RaidReminder and ns.RaidReminder.Setup then
        ns.RaidReminder:Setup(self)
    end
    if ns.LootHistory and ns.LootHistory.Setup then
        ns.LootHistory:Setup(self)
    end
    if ns.MinimapButton and ns.MinimapButton.Setup then
        ns.MinimapButton:Setup(self)
    end
    -- Hook RCLootCouncil if present; otherwise wait for it to load.
    if not self:TryHookRC() then
        self:RegisterEvent("ADDON_LOADED", "OnAddonLoaded")
    end
end

-- Synced settings (broadcast by raid leader; persisted in BobleLootSyncDB).
function BobleLoot:GetSyncedSettings()
    _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}
    _G.BobleLootSyncDB.settings = _G.BobleLootSyncDB.settings or {}
    return _G.BobleLootSyncDB.settings
end

function BobleLoot:IsTransparencyEnabled()
    return self:GetSyncedSettings().transparency == true
end

function BobleLoot:SetTransparencyEnabled(enabled, broadcast)
    self:GetSyncedSettings().transparency = enabled and true or false
    if broadcast and ns.Sync and ns.Sync.SendSettings then
        ns.Sync:SendSettings(self)
    end
    if ns.LootFrame and ns.LootFrame.Refresh then
        ns.LootFrame:Refresh()
    end
end

function BobleLoot:OnAddonLoaded(_, name)
    if name == "RCLootCouncil" then
        if self:TryHookRC() then
            self:UnregisterEvent("ADDON_LOADED")
        end
    end
end

function BobleLoot:TryHookRC()
    local ok, RC = pcall(function()
        return LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    end)
    if not ok or not RC then return false end
    local hookedAny = false
    if ns.VotingFrame and ns.VotingFrame.Hook then
        if ns.VotingFrame:Hook(self, RC) then hookedAny = true end
    end
    if ns.LootFrame and ns.LootFrame.Hook then
        if ns.LootFrame:Hook(self, RC) then hookedAny = true end
    end
    return hookedAny
end

-- Public API ---------------------------------------------------------------

function BobleLoot:GetData()
    return _G.BobleLoot_Data
end

function BobleLoot:GetScore(itemID, candidateName, opts)
    if not ns.Scoring then return nil end
    return ns.Scoring:Compute(itemID, candidateName, self.db.profile, self:GetData(), opts)
end

-- Slash --------------------------------------------------------------------

function BobleLoot:OnSlashCommand(input)
    input = (input or ""):trim():lower()
    if input == "" or input == "config" or input == "options" then
        if ns.SettingsPanel and ns.SettingsPanel.Open then
            ns.SettingsPanel:Open()
        else
            self:Print("Settings panel not loaded.")
        end
    elseif input == "version" then
        self:Print("version " .. self.version)
    elseif input == "minimap" then
        if ns.MinimapButton and ns.MinimapButton.ToggleMinimapIcon then
            ns.MinimapButton:ToggleMinimapIcon(self)
            local hidden = self.db.profile.minimap.hide
            self:Print("minimap icon " .. (hidden and "hidden." or "shown."))
        end
    elseif input == "broadcast" or input == "push" then
        if ns.Sync and ns.Sync.BroadcastNow then
            ns.Sync:BroadcastNow(self)
            self:Print("announced dataset to raid.")
        end
    elseif input == "transparency on" or input == "transparency off" then
        if not UnitIsGroupLeader("player") then
            self:Print("only the raid/group leader can toggle transparency.")
        else
            self:SetTransparencyEnabled(input == "transparency on", true)
            self:Print("transparency mode " ..
                (self:IsTransparencyEnabled() and "ENABLED" or "DISABLED") .. ".")
        end
    elseif input:match("^score ") then
        local itemID, name = input:match("^score%s+(%d+)%s+(.+)$")
        if itemID and name then
            local s, breakdown = self:GetScore(tonumber(itemID), name)
            if s then
                self:Print(string.format("%s on item %s: %d", name, itemID, s))
                for k, v in pairs(breakdown or {}) do
                    self:Print(string.format("  %s = %.2f", k, v))
                end
            else
                self:Print("No score (missing data).")
            end
        else
            self:Print("Usage: /bl score <itemID> <Name-Realm>")
        end
    elseif input == "checkdata" or input == "remind" then
        if ns.RaidReminder and ns.RaidReminder.ForceCheck then
            ns.RaidReminder:ForceCheck(self)
        end
    elseif input == "lootdb" or input == "loothistory" then
        if ns.LootHistory then
            if ns.LootHistory.Diagnose then ns.LootHistory:Diagnose(self) end
            ns.LootHistory:Apply(self)
            local lh = ns.LootHistory
            self:Print(string.format("Re-applied loot history. matched=%d scanned=%d source=%s",
                lh.lastMatched or 0, lh.lastScanned or 0, lh.lastSource or "?"))
        else
            self:Print("LootHistory module not loaded.")
        end
    elseif input:match("^debugchar%s+") then
        local name = input:match("^debugchar%s+(.+)$")
        if ns.LootHistory and ns.LootHistory.DiagnoseChar then
            ns.LootHistory:DiagnoseChar(self, name)
        end
    elseif input == "test" or input:match("^test%s+%d+$") then
        local n = tonumber(input:match("^test%s+(%d+)$")) or self.db.profile.testItemCount or 5
        if ns.TestRunner and ns.TestRunner.Run then
            ns.TestRunner:Run(self, n, self.db.profile.testUseDatasetItems)
        end
    else
        self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | /bl transparency on|off | /bl checkdata | /bl lootdb | /bl debugchar <Name-Realm> | /bl test [N] | /bl score <itemID> <Name-Realm>")
    end
end
