--[[ LootFrame.lua
     Transparency mode: hooks RCLootCouncil's candidate-side loot frame
     ("RCLootFrame" — the window where each raider sees the item and
     clicks Need / Greed / Pass) and adds a "Your score" line + tooltip.

     Only renders when:
       * the raid leader has enabled transparency mode (synced setting),
       * the local player is present in the loaded dataset,
       * the item has at least one scorable component for that player.

     RCLootCouncil's LootFrame module shape has changed across versions.
     We probe a few well-known entry-container field names and fall back
     to a no-op rather than erroring.
]]

local _, ns = ...
local LF = {}
ns.LootFrame = LF

local SCORE_FRAME_KEY = "_BobleLootScore"

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function playerKeys()
    local name  = UnitName("player")
    local nrealm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    local drealm = GetRealmName and GetRealmName() or nil
    local keys = { name }
    if nrealm then table.insert(keys, name .. "-" .. nrealm) end
    if drealm and drealm ~= nrealm then
        table.insert(keys, name .. "-" .. drealm)
        table.insert(keys, name .. "-" .. drealm:gsub("%s+", ""))
    end
    return keys
end

local function lookupChar(data)
    if not data or not data.characters then return nil end
    for _, k in ipairs(playerKeys()) do
        if data.characters[k] then return k end
    end
    return nil
end

local function itemIDFromAny(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" then return v end
        if type(v) == "string" then
            local id = tonumber(v:match("item:(%d+)"))
            if id then return id end
        end
    end
    return nil
end

local function entryItemID(entry)
    local resolver = LF.resolver
    if resolver and resolver.lootEntryItemID then
        local ok, id = pcall(resolver.lootEntryItemID, entry)
        if ok and id then return id end
    end
    -- Inline fallback (identical to FALLBACK_RESOLVER.lootEntryItemID).
    if not entry then return nil end
    return itemIDFromAny(
        entry.link,
        entry.itemLink,
        entry.item and entry.item.link,
        entry.session and entry.session.link,
        entry.itemID,
        entry.id
    )
end

local function colorFor(score)
    if score >= 70 then     return "|cff40ff40" end
    if score >= 40 then     return "|cffffd040" end
    return "|cffff5050"
end

----------------------------------------------------------------------------
-- score label per entry
----------------------------------------------------------------------------

-- Find RC's time-left bar on the entry so we can anchor the score
-- right under it. RC's LootFrame entry has used a few different field
-- names for this widget across versions; try them in order, then fall
-- back to the entry's top-right corner.
local TIMEOUT_FIELDS = {
    "timeoutBar", "timeoutFrame", "timeoutText",
    "timeLeftBar", "timeLeft", "tlBar", "tl",
}

local function findTimeoutWidget(entryFrame)
    for _, name in ipairs(TIMEOUT_FIELDS) do
        local w = entryFrame[name]
        if w and w.GetObjectType then return w end
    end
    return nil
end

local function attachLabel(entryFrame)
    if entryFrame[SCORE_FRAME_KEY] then return entryFrame[SCORE_FRAME_KEY] end
    local fs = entryFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Place directly under the "Time left" widget on the entry. If we
    -- can't find it (different RC version), fall back to top-right of
    -- the entry — close enough to where time-left normally lives.
    local anchor = findTimeoutWidget(entryFrame)
    if anchor then
        fs:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    else
        fs:SetPoint("TOPRIGHT", entryFrame, "TOPRIGHT", -8, -22)
    end
    fs:SetJustifyH("RIGHT")
    fs:SetText("")
    entryFrame[SCORE_FRAME_KEY] = fs

    -- Tooltip on hover — use the entry frame itself; harmless if it
    -- already has scripts (we use HookScript).
    entryFrame:HookScript("OnEnter", function(self)
        local ctx = self[SCORE_FRAME_KEY .. "_ctx"]
        if not ctx then return end
        if ctx.notInDataset then
            local playerName = UnitName("player") or "?"
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cffddddddBoble Loot|r")
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string.format(
                "|cffaaaaaa%s is not in the BobleLoot dataset.|r", playerName))
            GameTooltip:AddLine(
                "|cff888888Run tools/wowaudit.py and /reload.|r")
            GameTooltip:Show()
            return
        end
        if ctx.noComponents then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cffddddddBoble Loot|r")
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffaaaaaa No scoring data for this item.|r")
            GameTooltip:AddLine("|cff888888All score components returned no data.|r")
            GameTooltip:Show()
            return
        end
        if not ctx.score then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

        -- Title + separator
        GameTooltip:AddLine("|cffddddddBoble Loot \xe2\x80\x94 your score|r")
        GameTooltip:AddLine(
            "|cff444444" .. string.rep("\xe2\x80\x94", 26) .. "|r")

        -- Score line
        GameTooltip:AddDoubleLine("Score",
            string.format("%.1f / 100", ctx.score),
            1, 0.82, 0,  1, 1, 1)

        if ctx.fromLeader then
            GameTooltip:AddLine(
                "|cff80c0ffSent by raid leader (authoritative).|r")
        end

        -- Component breakdown
        if ctx.breakdown then
            GameTooltip:AddLine(" ")
            -- Column header (muted)
            GameTooltip:AddDoubleLine(
                "|cff666666Component           (raw stat)|r",
                "|cff666666wt%    norm   =  pts|r",
                1, 1, 1,  1, 1, 1)

            local order  = ns.Scoring.COMPONENT_ORDER
            local labels = ns.Scoring.COMPONENT_LABEL
            local weights = ns.addon and ns.addon.db
                            and ns.addon.db.profile
                            and ns.addon.db.profile.weights or {}
            local totalConfigW = 0
            for _, key in ipairs(order) do
                totalConfigW = totalConfigW + (weights[key] or 0)
            end

            local excluded = {}
            for _, key in ipairs(order) do
                local v = ctx.breakdown[key]
                if v then
                    local rawStr
                    -- Use VotingFrame's formatRaw if accessible, else fallback.
                    -- LootFrame is in the same addon namespace, so we delegate
                    -- to a shared helper exposed on ns.VotingFrame.
                    rawStr = ns.VotingFrame and ns.VotingFrame.formatRaw
                             and ns.VotingFrame.formatRaw(key, v)
                             or  string.format("%.2f", v.value or 0)
                    local left  = string.format("%s |cff666666(%s)|r",
                                      labels[key] or key, rawStr)
                    local right = string.format(
                        "|cffcccccc%2.0f%%|r  |cff6699ff%.2f|r  |cff888888=|r  |cffffffff%4.1f|r",
                        (v.effectiveWeight or 0) * 100,
                        v.value or 0,
                        v.contribution or 0)
                    GameTooltip:AddDoubleLine(left, right, 0.9, 0.9, 0.9, 1, 1, 1)
                else
                    table.insert(excluded, labels[key] or key)
                end
            end

            -- Renormalization caveat (2+ excluded)
            if #excluded >= 2 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cff808080Excluded: "
                    .. table.concat(excluded, ", ") .. "|r")
                local activeW = 0
                for _, key in ipairs(order) do
                    if ctx.breakdown[key] then
                        activeW = activeW + (weights[key] or 0)
                    end
                end
                if totalConfigW > 0 and activeW < totalConfigW then
                    local pct = math.floor(activeW / totalConfigW * 100 + 0.5)
                    GameTooltip:AddLine(string.format(
                        "|cff808080Score over %d%% of configured weights.|r", pct))
                end
            elseif #excluded == 1 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cff666666Excluded: "
                    .. table.concat(excluded, ", ") .. "|r")
            end
        end

        GameTooltip:Show()
    end)
    entryFrame:HookScript("OnLeave", function() GameTooltip:Hide() end)

    return fs
end

local function renderEntry(addon, entry, entryFrame)
    if not entryFrame then return end
    local fs = attachLabel(entryFrame)

    if not addon:IsTransparencyEnabled() then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end

    -- 2.11: player-side opt-out. Checked after the transparency-enabled
    -- guard so we don't show a blank label when transparency is off —
    -- the outer guard already handles that. This guard only fires when
    -- transparency IS on but the local player has suppressed their label.
    if addon.db and addon.db.profile and addon.db.profile.suppressTransparencyLabel then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end

    local data = addon:GetData()
    local key  = lookupChar(data)
    local iid  = entryItemID(entry)
    if not iid then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end
    if not key then
        -- Player is not in dataset. Show muted label + explanatory tooltip.
        local m = ns.Theme and ns.Theme.muted or {0.53, 0.53, 0.53, 1}
        fs:SetText(string.format("|cff%02x%02x%02xBL: \xe2\x80\x94|r",
            math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255)))
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = { notInDataset = true }
        return
    end

    -- Prefer the leader's authoritative broadcast so transparency-mode
    -- score matches what the leader sees in the council window.
    local score, breakdown, fromLeader
    local leaderMap = addon._leaderScores and addon._leaderScores[iid]
    if leaderMap then
        local s = leaderMap[key]
        if s == nil then
            -- Try player's bare name too — leader may have keyed by either.
            s = leaderMap[UnitName("player")]
        end
        if s ~= nil then
            score, fromLeader = s, true
        end
    end
    if score == nil then
        score, breakdown = ns.Scoring:Compute(iid, key, addon.db.profile, data)
    end

    if not score then
        -- Player is in dataset but all scoring components returned nil.
        local m = ns.Theme and ns.Theme.muted or {0.53, 0.53, 0.53, 1}
        fs:SetTextColor(m[1], m[2], m[3])
        fs:SetText("BL: ?")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = { noComponents = true }
        return
    end

    -- 2.11: compact label. Full breakdown remains in the hover tooltip.
    fs:SetText(string.format("%sBL: %d|r", colorFor(score),
        math.floor(score + 0.5)))
    entryFrame[SCORE_FRAME_KEY .. "_ctx"] = {
        score = score, breakdown = breakdown, fromLeader = fromLeader,
    }
end

----------------------------------------------------------------------------
-- iterate RCLootFrame entries (defensive; module shape has varied)
----------------------------------------------------------------------------

local function forEachEntry(lootFrame, fn)
    if not lootFrame then return end
    -- Newer RCLootCouncil: EntryManager keeps the live entries.
    local em = lootFrame.EntryManager
    if em and em.entries then
        for _, e in pairs(em.entries) do
            if e.frame then fn(e, e.frame) end
        end
        return
    end
    -- Older shape: lootFrame.entries[] each with .frame.
    if lootFrame.entries then
        for _, e in pairs(lootFrame.entries) do
            if type(e) == "table" then
                fn(e, e.frame or e)
            end
        end
        return
    end
    -- Last resort: scan numbered children "RCLootFrameEntry%d".
    for i = 1, 30 do
        local f = _G["RCLootFrameEntry" .. i]
        if not f then break end
        fn(f, f)
    end
end

----------------------------------------------------------------------------
-- hooks
----------------------------------------------------------------------------

local function refreshAll(addon, lootFrame)
    forEachEntry(lootFrame, function(entry, frame)
        renderEntry(addon, entry, frame)
    end)
end

function LF:Hook(addon, RC)
    if self.hooked then return true end
    local lootFrame = RC:GetModule("RCLootFrame", true)
    if not lootFrame then return false end

    self.addon     = addon
    self.lootFrame = lootFrame
    self.resolver  = ns.RCCompat and ns.RCCompat:GetResolver() or nil
    self.hooked    = true

    -- Refresh whenever the frame redraws or items get added.
    local function wrap(name)
        if type(lootFrame[name]) == "function" then
            hooksecurefunc(lootFrame, name, function()
                refreshAll(addon, lootFrame)
            end)
        end
    end
    wrap("Update")
    wrap("Show")
    wrap("AddItem")
    wrap("ReceiveLootTable")
    wrap("OnEnable")

    -- Also do an initial pass in case the frame is already up.
    refreshAll(addon, lootFrame)

    -- 4.11: re-render the transparency label when the color mode changes.
    if ns.Theme and ns.Theme.RegisterColorModeConsumer then
        ns.Theme:RegisterColorModeConsumer(function()
            if ns.LootFrame and ns.LootFrame.Refresh then
                pcall(function() ns.LootFrame:Refresh() end)
            end
        end)
    end

    return true
end

-- Called whenever the synced settings change (e.g. leader toggles
-- transparency mid-raid) to re-render whatever's on screen.
function LF:Refresh()
    if self.lootFrame then refreshAll(self.addon, self.lootFrame) end
end
