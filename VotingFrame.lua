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
local DEFAULT_COMPONENT_ORDER = { "sim", "bis", "history", "attendance", "mplus" }
local function getComponentOrder()
    return (ns.Scoring and ns.Scoring.COMPONENT_ORDER) or DEFAULT_COMPONENT_ORDER
end
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
-- Keyed by (session, itemID) so stale data from a previous item is evicted
-- even if RCLootCouncil reuses the same session slot for a different item.
local _sessionStats = {}   -- { session = N, itemID = I, median = X, max = Y }

local function computeSessionStats(rcVoting, addon, session, tableData)
    local itemID  = getItemIDForSession(rcVoting, session)

    -- Return cached value if same (session, itemID).
    if _sessionStats.session == session
       and _sessionStats.itemID  == itemID
       and _sessionStats.median ~= nil then
        return _sessionStats.median, _sessionStats.max
    end

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

    -- 2.10: also build a name->score map for O(1) lookup in doCellUpdate
    -- and store the sorted scores list for isConflict(). Reuses the
    -- simRef/histRef already computed above — no second traversal.
    local nameToScore = {}
    if names then
        for _, n in ipairs(names) do
            local s = computeScoreForRow(rcVoting, addon, session, n, simRef, histRef)
            if s then nameToScore[n] = s end
        end
    end

    _sessionStats = {
        session      = session,
        itemID       = itemID,
        median       = median,
        max          = max,
        sortedScores = scores,    -- already sorted ascending
        nameToScore  = nameToScore,
    }
    return median, max
end

-- 2.10: Returns true when `score` is within `threshold` of any other score
-- in the sorted list. Uses a linear scan — O(k) where k = number of
-- candidates within threshold, which is nearly always 0-2 in practice.
local function isConflict(stats, score, threshold)
    if not stats or not stats.sortedScores or #stats.sortedScores < 2 then
        return false
    end
    for _, s in ipairs(stats.sortedScores) do
        if s ~= score and math.abs(s - score) <= threshold then
            return true
        end
    end
    return false
end

local FRESHNESS_WARN_SECS  = 72 * 3600       -- 72 hours
local FRESHNESS_DANGER_SECS = 7 * 24 * 3600  -- 7 days

-- Returns nil (fresh), "warning", or "danger" based on dataset age.
local function datasetFreshnessState()
    local d = _G.BobleLoot_Data
    if not d or not d.generatedAtTimestamp then return nil end
    local age = time() - d.generatedAtTimestamp
    if age >= FRESHNESS_DANGER_SECS then return "danger" end
    if age >= FRESHNESS_WARN_SECS   then return "warning" end
    return nil
end

-- Format age in a human-readable string: "3 days 4 hours" etc.
local function formatAge(secs)
    local days  = math.floor(secs / 86400)
    local hours = math.floor((secs % 86400) / 3600)
    if days > 0 then
        return string.format("%d day%s %d hour%s",
            days,  days  == 1 and "" or "s",
            hours, hours == 1 and "" or "s")
    end
    return string.format("%d hour%s", hours, hours == 1 and "" or "s")
end

-- score    : number | nil   (nil = Scoring:Compute returned nil)
-- inDataset: bool           (true = character row exists in dataset)
-- median   : number | nil   (session median across all scored candidates)
-- max      : number | nil   (session maximum across all scored candidates)
-- conflict : bool | nil     (2.10: true = within conflictThreshold of another candidate)
local function formatScore(score, inDataset, median, max, conflict)
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
    -- 2.10: build the ~ conflict prefix in Theme.muted color.
    local prefix = ""
    if conflict then
        local m = ns.Theme and ns.Theme.muted or {0.55, 0.55, 0.55, 1}
        prefix = string.format("|cff%02x%02x%02x~|r",
            math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255))
    end
    local c = (ns.Theme and ns.Theme.ScoreColorRelative)
              and ns.Theme.ScoreColorRelative(score, median, max)
              or  (ns.Theme and ns.Theme.ScoreColor and ns.Theme.ScoreColor(score))
    if c then
        return prefix .. string.format("|cff%02x%02x%02x%d|r",
            math.floor(c[1]*255), math.floor(c[2]*255), math.floor(c[3]*255),
            math.floor(score + 0.5))
    end
    -- Fallback if Theme not yet loaded (should not happen in practice).
    local hex
    if score >= 70 then     hex = "40ff40"
    elseif score >= 40 then hex = "ffd040"
    else                    hex = "ff5050"
    end
    return prefix .. string.format("|cff%s%d|r", hex, math.floor(score + 0.5))
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

-- Expose for LootFrame.lua's transparency tooltip.
VF.formatRaw = formatRaw

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

    local s, breakdown = addon:GetScore(itemID, name, {
        simReference     = simRef,
        historyReference = histRef,
    })

    -- Title + separator
    tt:AddLine("|cffddddddBoble Loot|r")
    tt:AddLine("|cff444444" .. string.rep("\xe2\x80\x94", 26) .. "|r")

    -- Name + total score
    tt:AddDoubleLine(
        name or "?",
        s and string.format("%.1f / 100", s) or "|cffff7070no data|r",
        1, 0.82, 0,   1, 1, 1)

    if not s then
        tt:AddLine("|cffff7070No scoreable components for this candidate/item.|r")
        return
    end

    tt:AddLine(" ")

    -- Column header row (muted)
    tt:AddDoubleLine(
        "|cff666666Component           (raw stat)|r",
        "|cff666666wt%    norm   =  pts|r",
        1, 1, 1,  1, 1, 1)

    local sumContrib   = 0
    local activeCount  = 0
    local totalConfigW = 0
    local order  = ns.Scoring.COMPONENT_ORDER
    local labels = ns.Scoring.COMPONENT_LABEL
    local weights = addon.db and addon.db.profile and addon.db.profile.weights or {}

    for _, key in ipairs(order) do
        totalConfigW = totalConfigW + (weights[key] or 0)
    end

    for _, key in ipairs(order) do
        local e = breakdown[key]
        if e then
            activeCount  = activeCount + 1
            sumContrib   = sumContrib + (e.contribution or 0)
            local rawStr = formatRaw(key, e)
            local left   = string.format("%s |cff666666(%s)|r",
                               labels[key] or key, rawStr)
            local right  = string.format(
                "|cffcccccc%2.0f%%|r  |cff6699ff%.2f|r  |cff888888=|r  |cffffffff%4.1f|r",
                (e.effectiveWeight or 0) * 100,
                e.value or 0,
                e.contribution or 0)
            tt:AddDoubleLine(left, right, 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end

    -- Excluded components
    local excluded = {}
    for _, key in ipairs(order) do
        if not breakdown[key] then
            table.insert(excluded, labels[key] or key)
        end
    end

    tt:AddLine(" ")

    -- Renormalization caveat: show only when 2+ components are excluded.
    if #excluded >= 2 then
        tt:AddLine("|cff808080Excluded (no data): "
            .. table.concat(excluded, ", ") .. "|r")
        -- activeWeightSum = sum of configured weights for active components
        local activeWeightSum = 0
        for _, key in ipairs(order) do
            if breakdown[key] then
                activeWeightSum = activeWeightSum + (weights[key] or 0)
            end
        end
        if totalConfigW > 0 and activeWeightSum < totalConfigW then
            local pct = math.floor(activeWeightSum / totalConfigW * 100 + 0.5)
            tt:AddLine(string.format(
                "|cff808080Score over %d%% of configured weights.|r", pct))
        end
    elseif #excluded == 1 then
        -- One excluded: mention it but no caveat line.
        tt:AddLine("|cff666666Excluded (no data): "
            .. table.concat(excluded, ", ") .. "|r")
    end

    -- Raid context footer
    if sessionMedian or sessionMax then
        tt:AddLine(" ")
        local parts = {}
        if sessionMedian then
            table.insert(parts,
                string.format("Median |cffffffff%d|r", math.floor(sessionMedian + 0.5)))
        end
        if sessionMax then
            table.insert(parts,
                string.format("Max |cffffffff%d|r", math.floor(sessionMax + 0.5)))
        end
        if s then
            table.insert(parts,
                string.format("This: |cffffffff%d|r", math.floor(s + 0.5)))
        end
        tt:AddLine("|cffaaaaaa" .. table.concat(parts, " | ") .. "|r")
    end
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

    local itemID   = getItemIDForSession(rcVoting, session)

    -- Evict stats cache when (session, itemID) changes.
    if _sessionStats.session ~= session or _sessionStats.itemID ~= itemID then
        _sessionStats = {}
    end

    local names    = bidderNames(rcVoting, session, data)
    local simRef   = simReferenceFor(addon, itemID, names)
    local histRef  = historyReferenceFor(addon, names)

    local score              = computeScoreForRow(rcVoting, addon, session, name, simRef, histRef)
    local inDs               = isInDataset(addon, name)
    local median, max        = computeSessionStats(rcVoting, addon, session, data)

    -- conflictThreshold: set in Settings > Tuning > "Display" section (2.10).
    -- Default 5 points. Both candidates within threshold get the ~ prefix.
    local threshold = (addon.db and addon.db.profile and addon.db.profile.conflictThreshold) or 5
    local conflict  = score and isConflict(_sessionStats, score, threshold) or false

    cellFrame.text:SetText(formatScore(score, inDs, median, max, conflict))

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
        GameTooltip:AddLine("|cff666666Shift-click to compare vs top candidate|r")
        GameTooltip:Show()
    end)
    cellFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Right-click on score cell: open the pinnable explain panel (roadmap 2.9).
    -- This handler is scoped to the score cell only; 2E's conflict indicator
    -- modifies the text content via the SetText() call above and does not
    -- touch this script slot.
    cellFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() then
            if not (ns.ComparePopout and ns.ComparePopout.Open) then return end
            if not itemID then return end

            -- Find the top-ranked candidate by score in the current data set.
            local topName, topScore
            for _, row in ipairs(data or {}) do
                if row.name then
                    local s = computeScoreForRow(rcVoting, addon, session,
                                                 row.name, simRef, histRef)
                    if s and (not topScore or s > topScore) then
                        topScore = s
                        topName  = row.name
                    end
                end
            end

            -- If the clicked candidate IS the top candidate, compare against
            -- the second-ranked instead (avoids a trivially identical popout).
            local nameB = topName
            if topName == name then
                local secondName, secondScore
                for _, row in ipairs(data or {}) do
                    if row.name and row.name ~= name then
                        local s = computeScoreForRow(rcVoting, addon, session,
                                                     row.name, simRef, histRef)
                        if s and (not secondScore or s > secondScore) then
                            secondScore = s
                            secondName  = row.name
                        end
                    end
                end
                nameB = secondName or topName
            end

            -- Single-candidate session guard.
            if not nameB or nameB == name then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("BobleLoot \226\128\148 Compare")
                GameTooltip:AddLine(
                    "Need at least two scored candidates to compare.", 1, 0.5, 0.5)
                GameTooltip:Show()
                C_Timer.After(2, function() GameTooltip:Hide() end)
                return
            end

            -- Retrieve item link for the title bar.
            local iLink
            if rcVoting.GetLootTable then
                local lt = rcVoting:GetLootTable()
                if lt and lt[session] then iLink = lt[session].link end
            end

            local med, mx = computeSessionStats(rcVoting, addon, session, data)
            ns.ComparePopout:Open(name, nameB, itemID, iLink, {
                simReference     = simRef,
                historyReference = histRef,
                sessionMedian    = med,
                sessionMax       = mx,
            })
        elseif button == "RightButton" then
            GameTooltip:Hide()
            if ns.ExplainPanel and ns.ExplainPanel.Open then
                local med, mx = computeSessionStats(rcVoting, addon, session, data)
                ns.ExplainPanel:Open(itemID, name, {
                    simReference     = simRef,
                    historyReference = histRef,
                    sessionMedian    = med,
                    sessionMax       = mx,
                })
            end
        end
    end)
    -- EnableMouse so the OnMouseDown fires (lib-st cells may not have this by default).
    cellFrame:EnableMouse(true)
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

    -- Freshness badge on the Score column header.
    -- We find the header row of the lib-st table and attach a FontString
    -- to the cell that corresponds to our SCORE_COL column.
    local function refreshFreshnessBadge()
        local state = datasetFreshnessState()
        local badge = VF._freshnessBadge
        if not badge then return end

        if not state then
            badge:SetText("")
            badge:SetScript("OnEnter", nil)
            badge:SetScript("OnLeave", nil)
            return
        end

        local t  = ns.Theme
        local c  = (state == "danger") and (t and t.danger or {1, 0.31, 0.31, 1})
                                        or  (t and t.warning or {1, 0.82, 0, 1})
        badge:SetText(string.format("|cff%02x%02x%02x!|r",
            math.floor(c[1]*255), math.floor(c[2]*255), math.floor(c[3]*255)))

        badge:SetScript("OnEnter", function(self)
            local d   = _G.BobleLoot_Data
            local age = d and d.generatedAtTimestamp
                        and formatAge(time() - d.generatedAtTimestamp)
                        or  "unknown time"
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Boble Loot \xe2\x80\x94 dataset age")
            GameTooltip:AddLine(string.format(
                "Dataset generated %s ago.", age), 1, 1, 1)
            GameTooltip:AddLine(
                "Run tools/wowaudit.py to refresh.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Attach badge FontString to the st header frame if accessible.
    -- lib-st exposes the header row as st.header; each cell is st.header.cols[i].
    local st = rcVoting.frame and rcVoting.frame.st
    if st and st.header then
        -- Find which column index is ours.
        local colIdx
        for i, col in ipairs(rcVoting.scrollCols) do
            if col.colName == SCORE_COL then colIdx = i; break end
        end
        if colIdx and st.header.cols and st.header.cols[colIdx] then
            local headerCell = st.header.cols[colIdx]
            local badge = headerCell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            badge:SetPoint("TOPRIGHT", headerCell, "TOPRIGHT", 0, 0)
            badge:SetText("")
            VF._freshnessBadge = badge
            refreshFreshnessBadge()
        end
    end

    -- Store refreshFreshnessBadge so it can be called after data reloads.
    VF.refreshFreshnessBadge = refreshFreshnessBadge

    self.hooked = true
    addon:Print("hooked into RCLootCouncil voting frame.")
    return true
end
