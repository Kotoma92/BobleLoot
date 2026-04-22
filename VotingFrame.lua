--[[ VotingFrame.lua
     Hooks RCLootCouncil's RCVotingFrame and adds a sortable Score column.

     RCLootCouncil exposes the voting frame as a module:
        RC:GetModule("RCVotingFrame")
     Its `scrollCols` array drives the lib-st scroll table. We append a
     column with a custom DoCellUpdate and a sort comparator. The
     existing RC API `RCVotingFrame:GetLootTable()` and
     `RCVotingFrame:GetCandidate(session, name)` give us the item and
     candidate data we need.
]]

local _, ns = ...
local VF = {}
ns.VotingFrame = VF

local SCORE_COL = "blScore"

-- Resolved after Scoring.lua loads; both modules are in the same TOC frame.
local function getComponentOrder() return ns.Scoring.COMPONENT_ORDER end
local function getComponentLabel() return ns.Scoring.COMPONENT_LABEL end

-- Pull the current itemID for a session safely.
local function getItemIDForSession(rcVoting, session)
    local lt = rcVoting.GetLootTable and rcVoting:GetLootTable()
    if not lt or not lt[session] then return nil end
    local entry = lt[session]
    -- RCLootCouncil stores either `link` or `string` plus `id` depending
    -- on version; try the cheap paths first.
    if entry.link then
        local id = tonumber(entry.link:match("item:(%d+)"))
        if id then return id end
    end
    return entry.id or entry.itemID
end

-- For per-item comparative sim: find the highest sim percentage across
-- the current bidders for itemID. Used as the denominator so the bidder
-- with the biggest upgrade gets value 1.0.
local function bidderNames(rcVoting, session, fallbackData)
    -- Try the documented candidate list first.
    if rcVoting.GetCandidates then
        local ok, c = pcall(rcVoting.GetCandidates, rcVoting, session)
        if ok and type(c) == "table" then
            local names = {}
            for n in pairs(c) do names[#names + 1] = n end
            if #names > 0 then return names end
        end
    end
    -- Fallback: walk the scrolling table's row data.
    if fallbackData then
        local names = {}
        for _, row in ipairs(fallbackData) do
            if row.name then names[#names + 1] = row.name end
        end
        if #names > 0 then return names end
    end
    return nil
end

local function simReferenceFor(addon, itemID, names)
    local data = addon:GetData()
    if not data or not data.characters or not itemID then return nil end
    local maxPct = 0
    if names then
        for _, n in ipairs(names) do
            local char = data.characters[n]
            if char and char.sims and char.sims[itemID] then
                if char.sims[itemID] > maxPct then maxPct = char.sims[itemID] end
            end
        end
    else
        -- No candidate list available: fall back to all loaded characters
        -- so a sensible reference still exists.
        for _, char in pairs(data.characters) do
            if char.sims and char.sims[itemID] then
                if char.sims[itemID] > maxPct then maxPct = char.sims[itemID] end
            end
        end
    end
    return (maxPct > 0) and maxPct or nil
end

-- Loot equity: highest itemsReceived across the current bidders.
-- Used as the denominator for the history component (with a soft floor)
-- so the score auto-scales with what's actually been awarded recently.
local function historyReferenceFor(addon, names)
    local data = addon:GetData()
    if not data or not data.characters then return nil end
    local maxItems = 0
    local function consider(char)
        if char and char.itemsReceived and char.itemsReceived > maxItems then
            maxItems = char.itemsReceived
        end
    end
    if names then
        for _, n in ipairs(names) do consider(data.characters[n]) end
    else
        for _, char in pairs(data.characters) do consider(char) end
    end
    return (maxItems > 0) and maxItems or nil
end

local function computeScoreForRow(rcVoting, addon, session, name, simReference, historyReference)
    local itemID = getItemIDForSession(rcVoting, session)
    if not itemID or not name then return nil end
    return addon:GetScore(itemID, name, {
        simReference     = simReference,
        historyReference = historyReference,
    })
end

-- Returns true when `name` has an entry in the current dataset.
local function isInDataset(addon, name)
    local data = addon:GetData()
    if not data or not data.characters then return false end
    return data.characters[name] ~= nil
end

-- Per-render-pass cache for session median and max. Recomputed whenever
-- doCellUpdate is called for row 1 (the first row triggers the full pass).
-- Keyed by session number so stale data from a previous item is evicted.
local _sessionStats = {}   -- { session = N, median = X, max = Y }

local function computeSessionStats(rcVoting, addon, session, tableData)
    -- Return cached value if same session.
    if _sessionStats.session == session
       and _sessionStats.median ~= nil then
        return _sessionStats.median, _sessionStats.max
    end

    local itemID  = getItemIDForSession(rcVoting, session)
    local names   = bidderNames(rcVoting, session, tableData)
    local simRef  = simReferenceFor(addon, itemID, names)
    local histRef = historyReferenceFor(addon, names)

    local scores = {}
    local data = addon:GetData()
    if data and data.characters and names then
        for _, n in ipairs(names) do
            local s = computeScoreForRow(rcVoting, addon, session, n, simRef, histRef)
            if s then scores[#scores + 1] = s end
        end
    end

    local median, max
    if #scores > 0 then
        table.sort(scores)
        max = scores[#scores]
        local mid = math.floor(#scores / 2)
        if #scores % 2 == 1 then
            median = scores[mid + 1]
        else
            median = (scores[mid] + scores[mid + 1]) / 2
        end
    end

    _sessionStats = { session = session, median = median, max = max }
    return median, max
end

-- score    : number | nil   (nil = Scoring:Compute returned nil)
-- inDataset: bool           (true = character row exists in dataset)
-- median   : number | nil   (session median across all scored candidates)
-- max      : number | nil   (session maximum across all scored candidates)
local function formatScore(score, inDataset, median, max)
    if not inDataset then
        -- Character is not in the dataset at all.
        local m = ns.Theme and ns.Theme.muted or {0.53, 0.53, 0.53, 1}
        return string.format("|cff%02x%02x%02x\xe2\x80\x94|r",
            math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255))
    end
    if not score then
        -- In dataset but Scoring:Compute returned nil (sim-weight=0 and
        -- no other data, or literally all components missing).
        return "|cff666666?|r"
    end
    -- score is a real number (including 0.0).
    local c = (ns.Theme and ns.Theme.ScoreColorRelative)
              and ns.Theme.ScoreColorRelative(score, median, max)
              or  (ns.Theme and ns.Theme.ScoreColor and ns.Theme.ScoreColor(score))
    if c then
        return string.format("|cff%02x%02x%02x%d|r",
            math.floor(c[1]*255), math.floor(c[2]*255), math.floor(c[3]*255),
            math.floor(score + 0.5))
    end
    -- Fallback if Theme not yet loaded (should not happen in practice).
    local hex
    if score >= 70 then     hex = "40ff40"
    elseif score >= 40 then hex = "ffd040"
    else                    hex = "ff5050"
    end
    return string.format("|cff%s%d|r", hex, math.floor(score + 0.5))
end

-- Format the raw underlying stat for one component.
local function formatRaw(key, entry)
    local r = entry.raw
    if key == "sim" then
        if r == nil then return "-" end
        if entry.reference and entry.reference > 0 then
            return string.format("%.2f%% upgrade (best of bidders: %.2f%%)",
                                 r, entry.reference)
        end
        return string.format("%.2f%% upgrade", r)
    elseif key == "bis" then
        if r == true then return "on BiS list" end
        if r == false then return "not on BiS (partial credit)" end
        return "no BiS list (partial credit)"
    elseif key == "history" then
        if r == nil then return "-" end
        local b = entry.breakdown
        local denom = math.max(entry.reference or 0, entry.cap or 0)
        local denomLabel
        if (entry.reference or 0) > (entry.cap or 0) then
            denomLabel = string.format("denom %d, max in raid", denom)
        elseif (entry.cap or 0) > 0 then
            denomLabel = string.format("denom %d, soft floor", denom)
        else
            denomLabel = "no denom"
        end
        if b then
            local parts = {}
            for _, k in ipairs({"bis","major","mainspec","minor"}) do
                if (b[k] or 0) > 0 then
                    table.insert(parts, string.format("%d %s", b[k], k))
                end
            end
            local detail = (#parts > 0) and (" = " .. table.concat(parts, " + ")) or ""
            return string.format("%.1f weighted%s (%s)", r, detail, denomLabel)
        end
        return string.format("%.1f items received (%s)", r, denomLabel)
    elseif key == "attendance" then
        if r == nil then return "-" end
        return string.format("%.1f%% raids attended", r)
    elseif key == "mplus" then
        if r == nil then return "-" end
        return string.format("%d dungeons done (cap %d)", r, entry.cap or 0)
    end
    return "-"
end

local function fillScoreTooltip(tt, addon, itemID, name, simRef, histRef,
                                 sessionMedian, sessionMax)
    local inDs = isInDataset(addon, name)
    if not inDs then
        tt:AddLine("|cffddddddBoble Loot|r")
        tt:AddLine(" ")
        tt:AddLine(string.format(
            "|cffaaaaaa%s is not in the BobleLoot dataset.|r", name or "?"))
        tt:AddLine("|cff888888Run tools/wowaudit.py and /reload.|r")
        return
    end
    -- ... rest of tooltip (rewritten in Task 7) ...
    local s, breakdown = addon:GetScore(itemID, name, {
        simReference     = simRef,
        historyReference = histRef,
    })
    tt:AddLine("Boble Loot")
    tt:AddDoubleLine(name or "?",
        s and string.format("%.1f / 100", s) or "|cffff7070no data|r",
        1, 0.82, 0, 1, 1, 1)
    if not s then
        tt:AddLine("|cffff7070No data for this candidate/item.|r")
        return
    end

    tt:AddLine(" ")
    tt:AddLine("|cffaaaaaaComponent          weight  norm   = pts|r")

    local sumContrib = 0
    for _, key in ipairs(getComponentOrder()) do
        local e = breakdown[key]
        if e then
            sumContrib = sumContrib + (e.contribution or 0)
            local left = string.format(
                "%s |cff888888(%s)|r",
                getComponentLabel()[key] or key,
                formatRaw(key, e))
            local right = string.format(
                "|cffcccccc%2.0f%%|r x |cffcccccc%.2f|r = |cffffffff%4.1f|r",
                (e.effectiveWeight or 0) * 100,
                e.value or 0,
                e.contribution or 0)
            tt:AddDoubleLine(left, right, 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end

    -- List components that were dropped (no data or weight 0) so the
    -- raid leader knows the renormalization is doing work.
    local missing = {}
    for _, key in ipairs(getComponentOrder()) do
        if not breakdown[key] then
            table.insert(missing, getComponentLabel()[key] or key)
        end
    end
    if #missing > 0 then
        tt:AddLine(" ")
        tt:AddLine("|cff808080Excluded (no data or weight 0): "
            .. table.concat(missing, ", ") .. "|r")
    end

    tt:AddLine(" ")
    tt:AddDoubleLine("Total", string.format("%.1f / 100", sumContrib),
        1, 0.82, 0, 1, 1, 1)
end

local function doCellUpdate(rowFrame, cellFrame, data, cols, row, realrow, column,
                            fShow, table, ...)
    if not fShow then return end
    local rowData = data and data[realrow]
    if not rowData then
        cellFrame.text:SetText("")
        return
    end
    local rcVoting = VF.rcVoting
    local addon    = VF.addon
    local name     = rowData.name
    local session  = rcVoting.GetCurrentSession and rcVoting:GetCurrentSession()
                     or (rcVoting.session)  -- legacy fallback

    -- Evict stats cache when the session number changes.
    if _sessionStats.session ~= session then
        _sessionStats = {}
    end

    local itemID   = getItemIDForSession(rcVoting, session)
    local names    = bidderNames(rcVoting, session, data)
    local simRef   = simReferenceFor(addon, itemID, names)
    local histRef  = historyReferenceFor(addon, names)

    local score              = computeScoreForRow(rcVoting, addon, session, name, simRef, histRef)
    local inDs               = isInDataset(addon, name)
    local median, max        = computeSessionStats(rcVoting, addon, session, data)
    cellFrame.text:SetText(formatScore(score, inDs, median, max))

    -- If we're the leader (and transparency is on so it matters),
    -- broadcast authoritative scores for every candidate so raiders see
    -- exactly what we see. Throttled inside Sync:SendScores.
    if itemID and addon:IsTransparencyEnabled() and ns.Sync
       and UnitIsGroupLeader and UnitIsGroupLeader("player") then
        local scores = {}
        for _, r in ipairs(data) do
            if r.name then
                local s = computeScoreForRow(rcVoting, addon, session, r.name, simRef, histRef)
                if s then scores[r.name] = s end
            end
        end
        ns.Sync:SendScores(addon, itemID, scores)
    end

    cellFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local med, mx = computeSessionStats(rcVoting, addon, session, data)
        fillScoreTooltip(GameTooltip, addon, itemID, name, simRef, histRef, med, mx)
        GameTooltip:Show()
    end)
    cellFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function sortFn(table, rowa, rowb, sortbycol)
    local a, b = table:GetRow(rowa), table:GetRow(rowb)
    local rcVoting = VF.rcVoting
    local addon    = VF.addon
    local session  = rcVoting.GetCurrentSession and rcVoting:GetCurrentSession()
                     or rcVoting.session
    local itemID = getItemIDForSession(rcVoting, session)
    local names  = bidderNames(rcVoting, session, table.data)
    local simRef = simReferenceFor(addon, itemID, names)
    local histRef = historyReferenceFor(addon, names)
    local sa = computeScoreForRow(rcVoting, addon, session, a.name, simRef, histRef) or -1
    local sb = computeScoreForRow(rcVoting, addon, session, b.name, simRef, histRef) or -1
    local col = table.cols[sortbycol]
    local direction = col.sort or col.defaultsort or "dsc"
    if direction == "asc" then return sa < sb else return sa > sb end
end

function VF:Hook(addon, RC)
    if self.hooked then return true end
    local rcVoting = RC:GetModule("RCVotingFrame", true)
    if not rcVoting or not rcVoting.scrollCols then return false end

    self.addon    = addon
    self.rcVoting = rcVoting

    -- Avoid double-insert if user reloads.
    for _, col in ipairs(rcVoting.scrollCols) do
        if col.colName == SCORE_COL then
            self.hooked = true
            return true
        end
    end

    table.insert(rcVoting.scrollCols, {
        name         = "Score",
        colName      = SCORE_COL,
        width        = 50,
        align        = "CENTER",
        DoCellUpdate = doCellUpdate,
        comparesort  = sortFn,
        defaultsort  = "dsc",
        sortnext     = 1,
    })

    -- The score column makes the inner ScrollingTable wider than the
    -- voting frame's outer container, so the column visually overflows
    -- past the right edge. Widen the frame (and any obvious child
    -- containers) by our column width + a small padding so it stays
    -- inside.
    local EXTRA = 50 + 8
    local f = rcVoting.frame
    if f then
        if f.SetWidth and f.GetWidth then
            f:SetWidth(f:GetWidth() + EXTRA)
        end
        -- RC frames usually have a `.content` Frame holding the table;
        -- some versions also have a `.title` strip we leave alone.
        if f.content and f.content.SetWidth and f.content.GetWidth then
            f.content:SetWidth(f.content:GetWidth() + EXTRA)
        end
        -- AceGUI-backed frames track their own minResize; relax it so
        -- the user can still drag-resize without snapping back narrow.
        if f.SetMinResize then
            local minW, minH = 250, 420
            if f.GetMinResize then minW, minH = f:GetMinResize() end
            f:SetMinResize(minW + EXTRA, minH)
        end
        if f.SetResizeBounds then  -- 10.x replacement for SetMinResize
            f:SetResizeBounds(250 + EXTRA, 420)
        end
    end

    -- If the frame is already built, force a column refresh.
    if rcVoting.frame and rcVoting.frame.st and rcVoting.frame.st.SetDisplayCols then
        rcVoting.frame.st:SetDisplayCols(rcVoting.scrollCols)
    end

    self.hooked = true
    addon:Print("hooked into RCLootCouncil voting frame.")
    return true
end
