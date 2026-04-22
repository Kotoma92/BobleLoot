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
    if not entry then return nil end
    -- Try a handful of common shapes.
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
        if not ctx or not ctx.score then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Boble Loot — your score")
        GameTooltip:AddDoubleLine("Score", string.format("%.1f / 100", ctx.score),
            1, 1, 1, 1, 1, 1)
        if ctx.fromLeader then
            GameTooltip:AddLine("|cff80c0ffSent by raid leader (authoritative).|r")
        end
        if ctx.breakdown then
            GameTooltip:AddLine(" ")
            local order = ns.Scoring.COMPONENT_ORDER
            local labels = ns.Scoring.COMPONENT_LABEL
            for _, key in ipairs(order) do
                local v = ctx.breakdown[key]
                if v then
                    GameTooltip:AddDoubleLine(
                        labels[key] or key,
                        string.format("%.2f x %.0f%%", v.value,
                            (v.effectiveWeight or v.weight) * 100),
                        0.9, 0.9, 0.9, 1, 1, 1)
                end
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

    local data = addon:GetData()
    local key  = lookupChar(data)
    local iid  = entryItemID(entry)
    if not key or not iid then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
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
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end

    fs:SetText(string.format("%sYour score: %d|r", colorFor(score),
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
    return true
end

-- Called whenever the synced settings change (e.g. leader toggles
-- transparency mid-raid) to re-render whatever's on screen.
function LF:Refresh()
    if self.lootFrame then refreshAll(self.addon, self.lootFrame) end
end
