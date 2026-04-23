--[[ Core.lua
     Boble Loot initialization. Sets up AceAddon, SavedVariables, the
     slash command, and exposes the addon namespace.
]]

local ADDON_NAME, ns = ...

local AceAddon   = LibStub("AceAddon-3.0")
local AceConsole = LibStub("AceConsole-3.0")
local AceDB      = LibStub("AceDB-3.0")

local BobleLoot = AceAddon:NewAddon(ADDON_NAME,
    "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0", "AceTimer-3.0")
ns.addon = BobleLoot
_G.BobleLoot = BobleLoot

BobleLoot.version = "1.3.0"

-- Pending awards: { [fingerprint] = { name, itemID, ts } }
-- Populated by LH:RegisterPendingAward (called from LH:Setup event handlers).
-- Pruned by BobleLoot:PrunePendingAwards.
BobleLoot._pendingAwards = BobleLoot._pendingAwards or {}

-- StaticPopup for /bl importpaste (roadmap 4.3).
-- Defined at module level so it is registered once during addon load.
-- BobleLoot is referenced by the global _G.BobleLoot; safe because StaticPopup
-- callbacks fire at interaction time, long after addon initialisation.
StaticPopupDialogs["BOBLELOOT_IMPORT_PASTE"] = {
    text = "Paste BobleLoot export JSON below:\n(use /bl importpaste to open)",
    button1 = "Import",
    button2 = "Cancel",
    hasEditBox = true,
    editBoxWidth = 500,
    maxLetters = 0,           -- no limit; JSON bundles can be several KB
    OnAccept = function(self)
        local text = self.editBox and self.editBox:GetText()
                     or self.EditBox and self.EditBox:GetText()
                     or ""
        BobleLoot:DoImportPaste(text)
    end,
    OnCancel = function() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local DB_DEFAULTS = {
    profile = {
        -- Migration framework (item 2.7): tracks the last migration version
        -- successfully applied to this profile.  0 = no migrations run yet.
        dbVersion     = 0,

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
        -- Per-role history weight multiplier (2.2).
        -- 1.0 = no adjustment, 0.5 = half influence, 0.0 = history excluded.
        roleHistoryWeights = {
            raider = 1.0,
            trial  = 0.5,
            bench  = 0.5,
        },
        -- Vault and BOE loot weight relative to a normal awarded drop (2.4).
        vaultWeight = 0.5,
        -- Vault selection entries stored as synthetic loot history (2.4).
        vaultEntries = {},
        -- Whether sim selection uses character's main spec (true) or max
        -- across all specs (false). Default true per 2.1 design.
        specAwareSimSelection = true,
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
        conflictThreshold = 5,   -- 2.10: ~prefix when top-two gap <= this
        suppressTransparencyLabel = false,  -- 2.11: player hides BL label even when leader enables transparency
        -- 4.2: Catalyst / tier-token synthetic loot tracking.
        synthWeight  = 0.75,  -- weight relative to a normal RC drop (1.0). Configurable.
        synthHistory = {},    -- list of { name, itemID, itemLink, t, synthType, weight }
        minimap  = { hide = false, minimapPos = 220 },
        panelPos = { point = "CENTER", x = 0, y = 0 },
        historyViewerPos = { point = "CENTER", x = 0, y = 0 },
        comparePos = { point = "CENTER", x = 0, y = 80 },
        ghostPresets = {
            -- "prog" mirrors the user's live weights at first load.
            -- Seeded at startup from db.profile.weights if weights differ.
            prog = {
                sim        = 0.40,
                bis        = 0.20,
                history    = 0.15,
                attendance = 0.15,
                mplus      = 0.10,
            },
            -- "farm" preset: history-heavy for loot-equity-focused decisions.
            farm = {
                sim        = 0.30,
                bis        = 0.10,
                history    = 0.40,
                attendance = 0.15,
                mplus      = 0.05,
            },
            -- activeGhostPreset: which preset the toggle button applies.
            activeGhostPreset = "farm",
        },
        lastTab  = "weights",
        -- 3.8 score-trend tracking
        trackTrends      = true,        -- leader-side toggle; non-leaders ignore
        trendHistoryDays = 28,          -- rolling window kept in scoreHistory
        scoreHistory     = {},          -- [charName] = { {ts,score,itemID}, ... }
        -- 3.5 wasted-loot
        wastedLootMap    = {},          -- [fingerprint] = true
    },
}

function BobleLoot:OnInitialize()
    self.db = AceDB:New("BobleLootDB", DB_DEFAULTS, true)

    -- Run any pending DB migrations (item 2.7).  Must happen before any
    -- other module reads profile data, so it sits right after AceDB:New().
    if ns.Migrations and ns.Migrations.Run then
        ns.Migrations:Run(self.db.profile)
    end

    self:RegisterChatCommand("bl",       "OnSlashCommand")
    self:RegisterChatCommand("bobleloot","OnSlashCommand")

    if ns.SettingsPanel and ns.SettingsPanel.Setup then
        ns.SettingsPanel:Setup(self)
    end
    if ns.ExplainPanel and ns.ExplainPanel.Setup then
        ns.ExplainPanel:Setup(self)
    end
end

function BobleLoot:OnEnable()
    if ns.ComparePopout and ns.ComparePopout.Setup then
        ns.ComparePopout:Setup(self)
    end
    if ns.Sync and ns.Sync.Setup then
        ns.Sync:Setup(self)
    end
    if ns.RaidReminder and ns.RaidReminder.Setup then
        ns.RaidReminder:Setup(self)
    end
    if ns.LootHistory and ns.LootHistory.Setup then
        ns.LootHistory:Setup(self)
    end
    -- Catalyst / tier-token synthetic loot tracking (roadmap 4.2).
    if ns.CatalystTracker and ns.CatalystTracker.Setup then
        ns.CatalystTracker:Setup(self)
    end
    if ns.MinimapButton and ns.MinimapButton.Setup then
        ns.MinimapButton:Setup(self)
    end
    if ns.Toast and ns.Toast.Setup then
        ns.Toast:Setup(self)
    end
    if ns.HistoryViewer and ns.HistoryViewer.Setup then
        ns.HistoryViewer:Setup(self)
    end
    -- Great Vault collection tracking (Batch 2.4).
    if C_WeeklyRewards then
        self:RegisterEvent("WEEKLY_REWARDS_ITEM_GRABBED", "OnVaultItemGrabbed")
    end

    -- Wasted-loot trade detection (3.5).
    self:RegisterEvent("TRADE_CLOSED", "OnTradeClosed")

    -- Invalidate stale leader-score cache when leadership changes mid-raid
    -- (item 2.6).  The new leader's scores are unknown until they broadcast
    -- a fresh SCORES message; showing the old leader's scores would mislead
    -- candidates in transparency mode.
    self:RegisterEvent("PARTY_LEADER_CHANGED", function()
        self._leaderScores = nil
    end)

    -- Keep the "prog" ghost preset in sync with the user's current weights
    -- so it accurately mirrors their live configuration on first load.
    local gp = self.db.profile.ghostPresets
    local lw = self.db.profile.weights
    if gp and lw then
        for k, v in pairs(lw) do
            gp.prog[k] = v
        end
    end

    -- Hook RCLootCouncil if present; otherwise wait for it to load.
    if not self:TryHookRC() then
        self:RegisterEvent("ADDON_LOADED", "OnAddonLoaded")
    end
end

function BobleLoot:OnVaultItemGrabbed(event, itemLocation)
    -- itemLocation is a C_Item.ItemLocation. Resolve name and ilvl.
    local playerName = UnitName("player")
    local realm      = GetRealmName and GetRealmName() or ""
    realm = realm:gsub("%s+", "")
    local fullName   = (playerName and realm ~= "") and (playerName .. "-" .. realm)
                       or playerName or "Unknown"
    local link  = (itemLocation and C_Item and C_Item.GetItemLink)
                  and C_Item.GetItemLink(itemLocation) or nil
    local ilvl  = (itemLocation and C_Item and C_Item.GetCurrentItemLevel)
                  and C_Item.GetCurrentItemLevel(itemLocation) or nil
    if ns.LootHistory and ns.LootHistory.RecordVaultSelection then
        ns.LootHistory:RecordVaultSelection(self, fullName, link, ilvl)
    end
end

function BobleLoot:PrunePendingAwards()
    local now = time()
    for fp, entry in pairs(self._pendingAwards) do
        if now - entry.ts > 300 then
            self._pendingAwards[fp] = nil
        end
    end
end

function BobleLoot:OnTradeClosed()
    -- TRADE_CLOSED fires for both successful trades and cancellations.
    -- GetTradePlayerItemInfo returns nil link on cancellation, so nil-
    -- guards below handle that transparently.
    self:PrunePendingAwards()
    local profile = self.db and self.db.profile
    if not profile then return end

    -- Inspect items the local player gave away (up to 7 trade slots).
    for slot = 1, 7 do
        local _, _, _, _, link = GetTradePlayerItemInfo(slot)
        if link then
            local itemID = C_Item and C_Item.GetItemInfoInstant and
                select(2, C_Item.GetItemInfoInstant(link))
            if itemID then
                -- The local player is trading this item out.
                -- Check if the local player has a pending award for it
                -- (meaning they were the RC recipient and are now giving it away).
                local playerName = UnitName("player")
                if playerName then
                    local fp = ns.LootHistory and
                        ns.LootHistory:MakeFingerprint(playerName, itemID)
                    if fp and self._pendingAwards[fp] then
                        ns.LootHistory:MarkWasted(playerName, itemID, profile)
                        self._pendingAwards[fp] = nil
                        self:Print(string.format(
                            "BobleLoot: marked item %d as wasted for %s (traded away).",
                            itemID, playerName))
                    end
                end
            end
        end
    end

    -- Inspect items the trade target gave the local player — not relevant
    -- for wasted-loot detection (we care about outbound awards). Skipped.
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

-- Trusted-sender whitelist management (item 2.5).
-- The whitelist lives in BobleLootSyncDB so it persists across reloads
-- but is NOT profile-scoped (it is a global account-level trust decision).
function BobleLoot:AddTrustedSender(name)
    _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}
    _G.BobleLootSyncDB.trustedSenders = _G.BobleLootSyncDB.trustedSenders or {}
    _G.BobleLootSyncDB.trustedSenders[name] = true
    self:Print(string.format("'%s' added to trusted senders.", name))
end

function BobleLoot:RemoveTrustedSender(name)
    local db = _G.BobleLootSyncDB
    if db and db.trustedSenders then
        db.trustedSenders[name] = nil
    end
    self:Print(string.format("'%s' removed from trusted senders.", name))
end

function BobleLoot:GetData()
    return _G.BobleLoot_Data
end

-- Import a dataset from a pasted JSON bundle (roadmap 4.3).
-- Called by the BOBLELOOT_IMPORT_PASTE StaticPopup OnAccept handler
-- and by /bl importpaste (via DoImportPaste directly, for testing).
function BobleLoot:DoImportPaste(text)
    local function fireResult(ok, msg)
        -- Route through Batch 3E toast system if available; fall back to Print.
        if self.SendMessage then
            self:SendMessage("BobleLoot_ImportResult", ok, msg)
        end
        self:Print((ok and "|cff00ff00" or "|cffff5555") .. msg .. "|r")
    end

    text = text and (text:gsub("^%s*(.-)%s*$", "%1")) or ""
    if text == "" then
        fireResult(false, "Import failed: paste is empty.")
        return
    end

    -- Parse JSON via dkjson (loaded via Libs.xml before Core.lua).
    if not _G.dkjson then
        fireResult(false, "Import failed: dkjson library not loaded.")
        return
    end
    local ok, bundle = pcall(_G.dkjson.decode, text)
    if not ok or type(bundle) ~= "table" then
        fireResult(false, "Import failed: JSON parse error.")
        return
    end

    -- Schema validation.
    if bundle.schema ~= "bobleloot-export-v1" then
        fireResult(false, "Import failed: not a BobleLoot bundle (schema mismatch).")
        return
    end
    if type(bundle.characters) ~= "table" then
        fireResult(false, "Import failed: bundle missing 'characters' table.")
        return
    end

    local charCount = 0
    for _ in pairs(bundle.characters) do charCount = charCount + 1 end
    if charCount == 0 then
        fireResult(false, "Imported bundle has 0 characters — check the export.")
        return
    end

    -- Build a data table in the same shape Sync.lua and Scoring.lua expect.
    local data = {
        characters  = bundle.characters,
        generatedAt = bundle.generatedAt or bundle.exportedAt or "imported",
        teamUrl     = bundle.teamUrl,
        simCap      = bundle.scoringConfig and bundle.scoringConfig.simCap or 5.0,
        mplusCap    = bundle.scoringConfig and bundle.scoringConfig.mplusCap or 40,
        historyCap  = bundle.scoringConfig and bundle.scoringConfig.historyCap or 5,
        _imported   = true,  -- flag so diagnostics can distinguish imported data
    }

    -- Load into live globals and SyncDB.
    _G.BobleLoot_Data = data
    _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}
    _G.BobleLootSyncDB.data = data

    -- Re-apply loot history against the new dataset.
    if ns.LootHistory and ns.LootHistory.Apply then
        C_Timer.After(0.5, function() ns.LootHistory:Apply(self) end)
    end

    -- Broadcast to the raid (Batch 1C contract: BroadcastNow -> SendHello).
    if ns.Sync and ns.Sync.BroadcastNow then
        ns.Sync:BroadcastNow(self)
        fireResult(true, string.format(
            "Imported %d characters from bundle. Broadcasting to raid...", charCount))
    else
        fireResult(true, string.format(
            "Imported %d characters from bundle (sync not available).", charCount))
    end
end

function BobleLoot:GetScore(itemID, candidateName, opts)
    if not ns.Scoring then return nil end
    local score, breakdown = ns.Scoring:Compute(
        itemID, candidateName, self.db.profile, self:GetData(), opts)
    -- Record for trend history (leader-side only; UnitIsGroupLeader guard).
    if score ~= nil and UnitIsGroupLeader("player") and ns.Scoring.RecordScore then
        ns.Scoring:RecordScore(candidateName, itemID, score, self.db.profile)
    end
    return score, breakdown
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
            if ns.Toast and ns.Toast.Show then
                ns.Toast:Show(
                    "Transparency mode " .. (self:IsTransparencyEnabled() and "ENABLED" or "DISABLED"),
                    self:IsTransparencyEnabled() and "success" or "warning"
                )
            end
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
    elseif input:match("^explain") then
        -- /bl explain <Name-Realm>   or   /bl explain   (re-opens last)
        local name = input:match("^explain%s+(.+)$")
        if ns.ExplainPanel then
            if name then
                -- Trim trailing spaces from the name.
                name = name:match("^%s*(.-)%s*$")
                ns.ExplainPanel:OpenFor(name)
            else
                ns.ExplainPanel:OpenLast()
            end
        else
            self:Print("ExplainPanel not loaded.")
        end
    elseif input == "checkdata" or input == "remind" then
        if ns.RaidReminder and ns.RaidReminder.ForceCheck then
            ns.RaidReminder:ForceCheck(self)
        end
    elseif input == "importpaste" or input == "import" then
        -- /bl importpaste: open the paste dialog. Leader check is advisory only
        -- (solo testing should still work without a group).
        if not UnitIsGroupLeader("player") then
            self:Print("Note: only the raid/group leader should import a dataset.")
        end
        -- File I/O is not available in WoW Lua. The argument after 'import'
        -- is silently ignored; use the paste dialog instead.
        StaticPopup_Show("BOBLELOOT_IMPORT_PASTE")
    elseif input == "synthhistory" or input == "synth" then
        -- Diagnostic: list synthetic loot entries from profile.synthHistory (roadmap 4.2).
        local synth = self.db.profile.synthHistory or {}
        if #synth == 0 then
            self:Print("No synthetic loot entries recorded this session.")
        else
            self:Print(string.format("%d synthetic loot entr%s:",
                #synth, #synth == 1 and "y" or "ies"))
            for i, e in ipairs(synth) do
                self:Print(string.format("  [%d] %s | %s | %s | w=%.2f | %s",
                    i,
                    e.name or "?",
                    e.itemLink or tostring(e.itemID or "?"),
                    e.synthType or "?",
                    e.weight or 0,
                    date("%Y-%m-%d %H:%M", e.t or 0)))
            end
        end
    elseif input == "lootdb" or input == "loothistory" then
        if ns.LootHistory then
            if ns.LootHistory.Diagnose then ns.LootHistory:Diagnose(self) end

            -- Schema detection output.
            local verdict = ns.LootHistory.lastVerdictForDiag
                         or (ns.LootHistory.DetectSchemaVersion
                             and ns.LootHistory:DetectSchemaVersion(nil, self))
            if verdict then
                local colour = (verdict.status == "ok")
                    and "|cff19CC4D"   -- green
                    or  (verdict.status == "degraded" and "|cffFFA600" or "|cffE63333")
                self:Print(string.format(
                    "RC schema status: %s%s|r  (check #%d, RC v%s, at %s)",
                    colour,
                    verdict.status,
                    verdict.version,
                    verdict.rcVersion,
                    date("%H:%M:%S", verdict.checkedAt)))
                self:Print("  Source: " .. (verdict.sourceUsed or "?"))
                if #verdict.missingFields > 0 then
                    self:Print("  Missing field groups: "
                        .. table.concat(verdict.missingFields, "; "))
                else
                    self:Print("  All expected field groups present.")
                end
            end

            ns.LootHistory:Apply(self)
            local lh = ns.LootHistory
            self:Print(string.format("Re-applied loot history. matched=%d scanned=%d source=%s",
                lh.lastMatched or 0, lh.lastScanned or 0, lh.lastSource or "?"))
        else
            self:Print("LootHistory module not loaded.")
        end
    elseif input == "history" then
        if ns.HistoryViewer then
            ns.HistoryViewer:Toggle()
        else
            self:Print("History viewer not loaded.")
        end
    elseif input == "benchscore" or input:match("^benchscore%s+%d+$") then
        --[[ CROSS-CONTRACT: Batch 3B (ns.Scoring:ComputeAll)
             Roadmap item 3.6: "Compute scores for all roster members.
               Expose ns.Scoring:ComputeAll(itemID) returning a sorted list."
             Expected signature: ns.Scoring:ComputeAll(itemID, profile, data)
             Returns: { { name = "Name-Realm", score = number }, ... } sorted descending.
             Characters for whom Compute returns nil (missing sim data) are omitted.
             This handler guards with `if not (ns.Scoring and ns.Scoring.ComputeAll)`
             and prints a clear fallback until Batch 3B is merged.
        ]]
        local itemID = tonumber(input:match("^benchscore%s+(%d+)$"))
        -- Fall back to current voting frame item if no ID provided.
        if not itemID and ns.VotingFrame and ns.VotingFrame.currentItemID then
            itemID = ns.VotingFrame.currentItemID
        end
        if not itemID then
            self:Print("Usage: /bl benchscore <itemID>  (or run during a vote session)")
            return
        end
        if not (ns.Scoring and ns.Scoring.ComputeAll) then
            self:Print("Bench scoring not available (Scoring:ComputeAll missing — requires Batch 3B).")
            return
        end
        local results = ns.Scoring:ComputeAll(itemID, self.db.profile, self:GetData())
        if not results or #results == 0 then
            self:Print("No scores computed. Ensure the dataset is loaded (/bl checkdata).")
            return
        end
        -- Build the formatted output string.
        local parts = {}
        for _, entry in ipairs(results) do
            parts[#parts + 1] = string.format("%s=%d", entry.name, entry.score)
        end
        -- Truncate to first 10 players if roster is very large.
        local MAX_SHOWN = 10
        local suffix = (#results > MAX_SHOWN)
            and string.format(" ... (%d more)", #results - MAX_SHOWN)
            or ""
        local top = {}
        for i = 1, math.min(MAX_SHOWN, #results) do top[#top + 1] = parts[i] end
        local itemLink = select(2, GetItemInfo(itemID)) or tostring(itemID)
        local output = string.format("[BL Bench] %s: %s%s",
            itemLink, table.concat(top, ", "), suffix)
        -- Send to officer channel if available, otherwise party.
        -- SendChatMessage("OFFICER") silently fails (fires an error frame message)
        -- if the player lacks officer permissions; the pcall captures this and
        -- falls back to PARTY so output is never silently dropped.
        local sent = false
        if IsInRaid() or IsInGroup() then
            local ok = pcall(function()
                SendChatMessage(output, "OFFICER")
            end)
            if ok then
                sent = true
            end
        end
        if not sent then
            if IsInGroup() then
                SendChatMessage(output, "PARTY")
            else
                self:Print(output)
            end
        end
    elseif input:match("^trust%s+add%s+") then
        local name = input:match("^trust%s+add%s+(.+)$")
        if name then self:AddTrustedSender(name) else
            self:Print("Usage: /bl trust add <Name-Realm>") end
    elseif input:match("^trust%s+remove%s+") then
        local name = input:match("^trust%s+remove%s+(.+)$")
        if name then self:RemoveTrustedSender(name) else
            self:Print("Usage: /bl trust remove <Name-Realm>") end
    elseif input == "trust list" then
        local db = _G.BobleLootSyncDB
        local list = db and db.trustedSenders or {}
        local any = false
        for name in pairs(list) do
            self:Print("  trusted: " .. name)
            any = true
        end
        if not any then self:Print("trustedSenders is empty.") end
    elseif input:match("^debugchar%s+") then
        local name = input:match("^debugchar%s+(.+)$")
        if ns.LootHistory and ns.LootHistory.DiagnoseChar then
            ns.LootHistory:DiagnoseChar(self, name)
        end
    elseif input == "syncwarnings" or input == "syncwarn" then
        if ns.Sync and ns.Sync.GetRecentWarnings then
            local w = ns.Sync:GetRecentWarnings()
            if #w == 0 then
                self:Print("No sync warnings this session.")
            else
                self:Print(string.format("%d sync warning(s) this session:", #w))
                for i, entry in ipairs(w) do
                    self:Print(string.format("  [%d] %s from %s: %s",
                        i,
                        date("%H:%M:%S", entry.time),
                        entry.sender,
                        entry.reason))
                end
            end
        end
    elseif input:match("^conflict%s+%d+$") then
        local n = tonumber(input:match("^conflict%s+(%d+)$"))
        if n then
            n = math.max(0, math.min(n, 20))
            self.db.profile.conflictThreshold = n
            self:Print(string.format(
                "Conflict threshold set to %d. Takes effect on next voting frame render.", n))
        end
    elseif input == "syncinflight" then
        if ns.Sync and ns.Sync.GetInflightTransfers then
            local transfers = ns.Sync:GetInflightTransfers()
            local count = 0
            for sender, info in pairs(transfers) do
                count = count + 1
                self:Print(string.format(
                    "  %s: %d/%d chunks (version %s, started %s ago)",
                    sender,
                    info.received,
                    info.total,
                    tostring(info.version),
                    tostring(math.floor(time() - info.startedAt)) .. "s"))
            end
            if count == 0 then
                self:Print("No chunked transfers currently in flight.")
            end
        else
            self:Print("Sync module not loaded.")
        end
    elseif input == "test" or input:match("^test%s+%d+$") then
        local n = tonumber(input:match("^test%s+(%d+)$")) or self.db.profile.testItemCount or 5
        if ns.TestRunner and ns.TestRunner.Run then
            ns.TestRunner:Run(self, n, self.db.profile.testUseDatasetItems)
        end
    elseif input:match("^wasteloot%s+") then
        local name, link = input:match("^wasteloot%s+(%S+)%s+(|?.*)")
        if name and link and link ~= "" then
            local itemID = C_Item and C_Item.GetItemInfoInstant and
                select(2, C_Item.GetItemInfoInstant(link))
            if itemID and ns.LootHistory then
                ns.LootHistory:MarkWasted(name, itemID, self.db.profile)
                self:Print(string.format("Marked item %d wasted for %s.", itemID, name))
            else
                self:Print("Could not resolve item from link. Paste the item link directly.")
            end
        else
            self:Print("Usage: /bl wasteloot <Name-Realm> <itemlink>")
        end
    elseif input == "wastedloot list" or input == "wasteloot list" then
        local map = self.db.profile.wastedLootMap
        if not map or not next(map) then
            self:Print("No wasted-loot entries recorded.")
        else
            local count = 0
            for fp, _ in pairs(map) do
                self:Print("  wasted: " .. fp)
                count = count + 1
            end
            self:Print(string.format("Total: %d wasted entry(s).", count))
        end
    elseif input == "wastedloot clear" or input == "wasteloot clear" then
        self.db.profile.wastedLootMap = {}
        self:Print("Wasted-loot map cleared.")
    else
        self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | " ..
            "/bl transparency on|off | /bl conflict <0-20> | /bl checkdata | /bl lootdb | " ..
            "/bl synthhistory | /bl importpaste | " ..
            "/bl history | /bl benchscore [itemID] | " ..
            "/bl trust add|remove|list <Name-Realm> | " ..
            "/bl debugchar <Name-Realm> | /bl test [N] | " ..
            "/bl score <itemID> <Name-Realm> | /bl syncwarnings | /bl syncinflight | " ..
            "/bl explain <Name-Realm> | " ..
            "/bl wasteloot <Name-Realm> <link> | /bl wastedloot list | /bl wastedloot clear")
    end
end
