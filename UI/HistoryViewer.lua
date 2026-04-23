--[[ UI/HistoryViewer.lua
     BobleLoot loot history viewer.
     Roadmap item 3.11.

     Public API:
       ns.HistoryViewer:Setup(addonArg)  -- called from Core:OnEnable
       ns.HistoryViewer:Open()           -- open (or focus) the viewer
       ns.HistoryViewer:Close()          -- close the viewer
       ns.HistoryViewer:Toggle()         -- open if closed, close if open
       ns.HistoryViewer:Refresh()        -- re-query and redraw the table

     Columns (left to right):
       Player      | 120px | player name (Name-Realm, truncated)
       Item        | 200px | item name; item link on GameTooltip hover
       Date        |  80px | "YYYY-MM-DD" or "MM/DD" from entry time
       Response    | 100px | "BiS", "Major", "Minor", "Mainspec"
       Weight Crd  |  80px | per-entry credit (e.g. 1.50 for BiS)

     Per-player total row at table bottom:
       Player name | colspan span | — | — | Weighted sum (bold)

     Filters:
       Player dropdown — "All players" or specific Name-Realm
       Date range slider — mirrors lootHistoryDays (7..90, step 1)

     lib-st path:   LibStub("ScrollingTable", true) non-nil → use lib-st.
     Fallback path: paginated FontString list, 20 rows per page with
                    Prev/Next buttons.

     Position persistence:
       Saved to BobleLootDB.profile.historyViewerPos on drag-stop.
       Restored in Open().
]]

local ADDON_NAME, ns = ...
local HV = {}
ns.HistoryViewer = HV

local addon
local frame
local built = false
local libST = LibStub("ScrollingTable", true)  -- nil if not available

-- Logged at load time for diagnostics (visible via /print ns.HistoryViewer._stMode).
HV._stMode = libST and "lib-st" or "fallback-fontstring"

local FRAME_W    = 620
local FRAME_H    = 460
local TITLEBAR_H = 28
local FILTER_H   = 42
local BODY_Y_OFF = TITLEBAR_H + FILTER_H
local TABLE_H    = FRAME_H - BODY_Y_OFF - 10

-- Column widths for lib-st path.
local COLS = {
    { name = "Player",     width = 120, align = "LEFT"  },
    { name = "Item",       width = 200, align = "LEFT"  },
    { name = "Date",       width =  80, align = "CENTER"},
    { name = "Response",   width = 100, align = "CENTER"},
    { name = "Wt Credit",  width =  80, align = "RIGHT" },
}

local FALLBACK_PAGE_SIZE = 20

-- State
local currentFilter = nil      -- nil = all players
local currentDays   = nil      -- nil = use db.profile.lootHistoryDays
local rawRows       = {}       -- { playerName, itemLink, date, response, credit }
local totalRows     = {}       -- { playerName, total } — one per player, sorted desc
local stTable       = nil      -- lib-st table object (lib-st path only)
local fbRows        = {}       -- FontString row frames (fallback path only)
local fbPage        = 1
local fbTotalPages  = 1

-- Dropdown state
local playerDropdown = nil
local playerList     = {}       -- ordered list of Name-Realm strings

-- ── Data loading ──────────────────────────────────────────────────────

local RESPONSE_LABEL = {
    bis      = "BiS",
    major    = "Major",
    minor    = "Minor",
    mainspec = "Mainspec",
}

-- Rebuild rawRows and totalRows from the RC loot database.
-- Applies currentFilter (player name) and currentDays (date window).
local function LoadRows()
    rawRows   = {}
    totalRows = {}

    local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    -- Reuse LootHistory's internal getRCLootDB by delegating to Apply then reading back.
    -- We don't have direct access to LootHistory's local getRCLootDB, so we call
    -- CountItemsReceived on the raw database obtained via the same path LH uses.
    -- To iterate raw entries (for the Item and Date columns) we access the merged DB
    -- the same way LootHistory does: prefer RCLootCouncilLootDB.factionrealm.
    local db
    if _G.RCLootCouncilLootDB and _G.RCLootCouncilLootDB.factionrealm then
        -- Merge all faction-realms (mirrors LootHistory.lua:mergeFactionRealms).
        db = {}
        for _, perRealm in pairs(_G.RCLootCouncilLootDB.factionrealm) do
            if type(perRealm) == "table" then
                for charName, entries in pairs(perRealm) do
                    if type(entries) == "table" then
                        local dst = db[charName] or {}
                        for _, e in ipairs(entries) do dst[#dst + 1] = e end
                        db[charName] = dst
                    end
                end
            end
        end
    elseif RC and RC.lootDB and type(RC.lootDB) == "table" then
        db = RC.lootDB
    end

    if not db then return end

    local profile = addon and addon.db and addon.db.profile
    local days    = currentDays or (profile and profile.lootHistoryDays) or 28
    local weights = (profile and profile.lootWeights)
                    or { bis = 1.5, major = 1.0, mainspec = 1.0, minor = 0.5 }
    local minIlvl = (profile and profile.lootMinIlvl) or 0
    local cutoff  = (days > 0) and (time() - days * 24 * 3600) or nil

    -- Collect per-player totals via LootHistory:CountItemsReceived if available.
    local playerTotals = {}
    if ns.LootHistory and ns.LootHistory.CountItemsReceived then
        playerTotals = ns.LootHistory:CountItemsReceived(db, days, weights, minIlvl)
    end

    -- Build raw rows for the table body.
    local function entryTime(e)
        local t = e.time or e.date or e.timestamp
        if type(t) == "number" then return t end
        if type(t) == "string" then return tonumber(t:match("(%d+)")) end
        return nil
    end
    local function entryIlvl(e)
        local v = e.ilvl or e.itemLevel or e.iLvl or e.lvl
        if type(v) == "number" and v > 0 then return v end
        return nil
    end
    local function classify(e)
        local r = e.response or e.responseID
        if type(r) ~= "string" then return nil end
        local lower = r:lower()
        -- Exclusions first
        for _, pat in ipairs({ "transmog","off%-spec","offspec","greed",
                                "disenchant","sharded?","pass","autopass","pvp",
                                "free%s*roll","fun" }) do
            if lower:find(pat) then return nil end
        end
        if lower:find("^bis$") or lower:find("best in slot") or lower:find("%(bis%)") then
            return "bis"
        end
        if lower:find("major") then return "major" end
        if lower:find("minor") or lower:find("small upgrade") then return "minor" end
        if lower:find("mainspec") or lower:find("main%-spec") or
           lower:find("need") or lower:find("upgrade") then return "mainspec" end
        return nil
    end

    local playerSet = {}
    for charName, entries in pairs(db) do
        if (not currentFilter or currentFilter == charName)
           and type(entries) == "table" then
            playerSet[charName] = true
            for _, e in ipairs(entries) do
                if type(e) == "table" then
                    local cat = classify(e)
                    if cat then
                        local t = entryTime(e)
                        local timeOk = (not cutoff) or (not t) or t >= cutoff
                        local ilvl = entryIlvl(e)
                        local ilvlOk = (minIlvl <= 0) or (ilvl == nil) or (ilvl >= minIlvl)
                        if timeOk and ilvlOk then
                            local link = e.lootWon or e.link or e.itemLink or e.string or "?"
                            local dateStr = t and date("%Y-%m-%d", t) or "?"
                            local credit = weights[cat] or 0
                            rawRows[#rawRows + 1] = {
                                playerName = charName,
                                itemLink   = link,
                                dateStr    = dateStr,
                                dateTime   = t or 0,
                                response   = RESPONSE_LABEL[cat] or cat,
                                credit     = credit,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Sort raw rows: date descending (newest first) — spec 3.11 default.
    table.sort(rawRows, function(a, b)
        return (a.dateTime or 0) > (b.dateTime or 0)
    end)

    -- Build total rows from playerTotals, sorted descending by total.
    local totList = {}
    for name, row in pairs(playerTotals) do
        if not currentFilter or currentFilter == name then
            totList[#totList + 1] = { name = name, total = row.total or 0 }
        end
    end
    table.sort(totList, function(a, b) return a.total > b.total end)
    totalRows = totList

    -- Build sorted player list for the dropdown.
    playerList = {}
    for name in pairs(playerSet) do
        playerList[#playerList + 1] = name
    end
    table.sort(playerList)
end

-- ── Frame chrome (shared with SettingsPanel style) ────────────────────

local function BuildFrame()
    if built then return end
    built = true
    local T = ns.Theme

    frame = CreateFrame("Frame", "BobleLootHistoryViewer", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    T.ApplyBackdrop(frame, "bgBase", "borderAccent")

    -- ── Title bar ──────────────────────────────────────────────────────
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLEBAR_H)
    T.ApplyBackdrop(titleBar, "bgTitleBar", "borderNormal")

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
    titleText:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText("Loot History")

    -- Cyan 1px underline beneath the title bar (matching SettingsPanel).
    local underline = frame:CreateTexture(nil, "OVERLAY")
    underline:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.8)
    underline:SetHeight(1)
    underline:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, -TITLEBAR_H)
    underline:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -TITLEBAR_H)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    closeBtn:SetScript("OnClick", function() HV:Close() end)

    -- Drag handling + position save
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if addon and addon.db then
            local p = addon.db.profile.historyViewerPos
            p.point, _, _, p.x, p.y = self:GetPoint()
        end
    end)

    -- ── Filter bar ────────────────────────────────────────────────────
    local filterY = -TITLEBAR_H - 8

    -- Player dropdown label
    local playerLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playerLabel:SetFont(T.fontBody, T.sizeBody)
    playerLabel:SetTextColor(T.white[1], T.white[2], T.white[3])
    playerLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, filterY)
    playerLabel:SetText("Player:")

    -- Player dropdown (UIDropDownMenuTemplate)
    local dropFrame = CreateFrame("Frame", "BobleLootHistoryPlayerDrop", frame,
        "UIDropDownMenuTemplate")
    dropFrame:SetPoint("LEFT", playerLabel, "RIGHT", 4, 0)
    UIDropDownMenu_SetWidth(dropFrame, 140)
    playerDropdown = dropFrame

    local function RefreshDropdown()
        UIDropDownMenu_Initialize(playerDropdown, function(self, level)
            local info = UIDropDownMenu_CreateInfo()
            -- "All" entry
            info.text = "All players"
            info.value = nil
            info.checked = (currentFilter == nil)
            info.func = function()
                currentFilter = nil
                UIDropDownMenu_SetText(playerDropdown, "All players")
                HV:Refresh()
            end
            UIDropDownMenu_AddButton(info, level)
            -- Per-player entries
            for _, name in ipairs(playerList) do
                info = UIDropDownMenu_CreateInfo()
                info.text = name
                info.value = name
                info.checked = (currentFilter == name)
                info.func = function()
                    currentFilter = name
                    UIDropDownMenu_SetText(playerDropdown, name)
                    HV:Refresh()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        local displayText = currentFilter or "All players"
        UIDropDownMenu_SetText(playerDropdown, displayText)
    end
    frame._refreshDropdown = RefreshDropdown

    -- Date-range slider (mirrors lootHistoryDays, range 7..90)
    local daysLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    daysLabel:SetFont(T.fontBody, T.sizeBody)
    daysLabel:SetTextColor(T.white[1], T.white[2], T.white[3])
    daysLabel:SetPoint("LEFT", dropFrame, "RIGHT", 24, 0)
    daysLabel:SetText("Days:")

    local sliderName = "BobleLootHistoryDaysSlider"
    local slider = CreateFrame("Slider", sliderName, frame, "OptionsSliderTemplate")
    slider:SetPoint("LEFT", daysLabel, "RIGHT", 8, 0)
    slider:SetMinMaxValues(7, 90)
    slider:SetValueStep(1)
    slider:SetWidth(120)
    slider:SetHeight(16)
    _G[sliderName .. "Low"]:SetText("7d")
    _G[sliderName .. "High"]:SetText("90d")

    local sliderValLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sliderValLabel:SetFont(T.fontBody, T.sizeSmall)
    sliderValLabel:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    sliderValLabel:SetPoint("LEFT", slider, "RIGHT", 6, 0)

    slider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val + 0.5)
        currentDays = val
        sliderValLabel:SetText(val .. "d")
        HV:Refresh()
    end)
    frame._slider = slider
    frame._sliderValLabel = sliderValLabel

    -- ── Table area ────────────────────────────────────────────────────
    local tableY = -(TITLEBAR_H + FILTER_H + 4)

    if libST then
        -- lib-st path
        stTable = libST:CreateST(COLS, math.floor(TABLE_H / 16), 16,
            { ["r"] = 0.10, ["g"] = 0.10, ["b"] = 0.12, ["a"] = 1.0 }, frame)
        stTable.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, tableY)
        stTable.frame:SetWidth(FRAME_W - 16)
        stTable:SetWidth(FRAME_W - 16)
        -- Default sort: column 3 (Date), descending.
        stTable:SortData()
    else
        -- Fallback: ScrollFrame with FontString rows.
        local sf = CreateFrame("ScrollFrame", "BobleLootHistorySF", frame)
        sf:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, tableY)
        sf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 30)
        local content = CreateFrame("Frame", nil, sf)
        content:SetSize(FRAME_W - 16, TABLE_H)
        sf:SetScrollChild(content)
        frame._sfContent = content
        frame._sf        = sf

        -- Prev / Next page buttons for fallback mode.
        local prevBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        prevBtn:SetSize(60, 20)
        prevBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 6)
        prevBtn:SetText("< Prev")
        prevBtn:SetScript("OnClick", function()
            if fbPage > 1 then fbPage = fbPage - 1; HV:_DrawFallback() end
        end)
        local nextBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        nextBtn:SetSize(60, 20)
        nextBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 6)
        nextBtn:SetText("Next >")
        nextBtn:SetScript("OnClick", function()
            if fbPage < fbTotalPages then fbPage = fbPage + 1; HV:_DrawFallback() end
        end)
        local pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pageLabel:SetFont(T.fontBody, T.sizeSmall)
        pageLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
        pageLabel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 8)
        frame._pageLabel = pageLabel
    end

    -- ── Empty-state labels (4.12) ─────────────────────────────────────
    -- Shown mutually exclusively when the row count is zero.
    -- Anchored to the frame body (below the filter bar) so they work in
    -- both the lib-st and fallback paths.
    local emptyFiltered = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyFiltered:SetFont(T.fontBody, T.sizeBody)
    emptyFiltered:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    emptyFiltered:SetText(
        "No loot entries match the current filters.\n"
        .. "Try widening the date window or check that\n"
        .. "RC loot history has been recorded.")
    emptyFiltered:SetJustifyH("CENTER")
    emptyFiltered:SetPoint("CENTER", frame, "CENTER", 0, -20)
    emptyFiltered:Hide()
    frame._emptyFiltered = emptyFiltered

    local emptyNoRC = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    emptyNoRC:SetFont(T.fontBody, T.sizeBody)
    emptyNoRC:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    emptyNoRC:SetText(
        "No loot history found.\n"
        .. "RC loot history is recorded while you are\n"
        .. "in a raid using RCLootCouncil.")
    emptyNoRC:SetJustifyH("CENTER")
    emptyNoRC:SetPoint("CENTER", frame, "CENTER", 0, -20)
    emptyNoRC:Hide()
    frame._emptyNoRC = emptyNoRC
end

-- ── lib-st data population ────────────────────────────────────────────

local function PopulateLibST()
    if not stTable then return end
    local data = {}
    for _, row in ipairs(rawRows) do
        data[#data + 1] = {
            [1] = row.playerName,
            [2] = row.itemLink,
            [3] = row.dateStr,
            [4] = row.response,
            [5] = string.format("%.2f", row.credit),
            -- Store raw dateTime for sorting.
            _dateTime = row.dateTime,
        }
    end
    -- Append per-player total rows (shown after all regular rows).
    for _, tot in ipairs(totalRows) do
        data[#data + 1] = {
            [1] = "|cff" .. string.format("%02x%02x%02x",
                  math.floor(ns.Theme.accent[1]*255),
                  math.floor(ns.Theme.accent[2]*255),
                  math.floor(ns.Theme.accent[3]*255))
                  .. tot.name .. " TOTAL|r",
            [2] = "",
            [3] = "",
            [4] = "",
            [5] = string.format("%.2f", tot.total),
            _dateTime = math.huge,  -- sort totals to the very bottom
        }
    end
    stTable:SetData(data, true)
end

-- ── Fallback FontString renderer ──────────────────────────────────────

function HV:_DrawFallback()
    if not frame or not frame._sfContent then return end
    local T = ns.Theme
    local content = frame._sfContent
    -- Clear existing rows.
    for _, r in ipairs(fbRows) do r:Hide() end
    fbRows = {}

    -- Header row
    local colWidths = { 120, 200, 80, 100, 80 }
    local colNames  = { "Player", "Item", "Date", "Response", "Wt Cr" }
    local hdrY = 0
    local x = 0
    for i, w in ipairs(colWidths) do
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetFont(T.fontBody, T.sizeSmall, "OUTLINE")
        fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
        fs:SetSize(w, 16)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, hdrY)
        fs:SetJustifyH(i >= 5 and "RIGHT" or (i == 3 and "CENTER" or "LEFT"))
        fs:SetText(colNames[i])
        fbRows[#fbRows + 1] = fs
        x = x + w
    end

    -- Data rows (paginated)
    local all = rawRows
    local pageStart = (fbPage - 1) * FALLBACK_PAGE_SIZE + 1
    local pageEnd   = math.min(fbPage * FALLBACK_PAGE_SIZE, #all)
    fbTotalPages    = math.max(1, math.ceil(#all / FALLBACK_PAGE_SIZE))
    if frame._pageLabel then
        frame._pageLabel:SetText(string.format("Page %d / %d", fbPage, fbTotalPages))
    end

    for idx = pageStart, pageEnd do
        local row = all[idx]
        local rowY = hdrY - (idx - pageStart + 1) * 16
        x = 0
        local rowData = {
            row.playerName,
            row.itemLink,
            row.dateStr,
            row.response,
            string.format("%.2f", row.credit),
        }
        for i, w in ipairs(colWidths) do
            local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetFont(T.fontBody, T.sizeSmall)
            fs:SetTextColor(T.white[1], T.white[2], T.white[3])
            fs:SetSize(w, 16)
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, rowY)
            fs:SetJustifyH(i >= 5 and "RIGHT" or (i == 3 and "CENTER" or "LEFT"))
            fs:SetText(rowData[i] or "")
            fbRows[#fbRows + 1] = fs
            x = x + w
        end
    end

    -- Total rows at the bottom of the page.
    local totalY = hdrY - (pageEnd - pageStart + 2) * 16 - 8
    for _, tot in ipairs(totalRows) do
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetFont(T.fontBody, T.sizeSmall, "OUTLINE")
        fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
        fs:SetSize(FRAME_W - 24, 16)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, totalY)
        fs:SetJustifyH("LEFT")
        fs:SetText(string.format("%s  |  Weighted total: %.2f", tot.name, tot.total))
        fbRows[#fbRows + 1] = fs
        totalY = totalY - 16
    end
end

-- ── Public API ────────────────────────────────────────────────────────

function HV:Setup(addonArg)
    addon = addonArg
end

function HV:Open()
    BuildFrame()
    -- Restore saved position.
    if addon and addon.db then
        local p = addon.db.profile.historyViewerPos
        if p and p.point then
            frame:ClearAllPoints()
            frame:SetPoint(p.point, UIParent, p.point, p.x or 0, p.y or 0)
        end
        -- Sync slider to current profile value.
        local days = addon.db.profile.lootHistoryDays or 28
        currentDays = days
        if frame._slider then
            frame._slider:SetValue(days)
        end
        if frame._sliderValLabel then
            frame._sliderValLabel:SetText(days .. "d")
        end
    end
    frame:Show()
    self:Refresh()
end

function HV:Close()
    if frame then frame:Hide() end
end

function HV:Toggle()
    if frame and frame:IsShown() then
        self:Close()
    else
        self:Open()
    end
end

function HV:Refresh()
    if not frame or not frame:IsShown() then return end
    LoadRows()
    if frame._refreshDropdown then frame._refreshDropdown() end

    -- Show the appropriate empty-state label when there are no rows (4.12).
    local hasFilters = (currentFilter ~= nil)
                       or (currentDays ~= nil
                           and currentDays < (addon and addon.db
                                              and addon.db.profile.lootHistoryDays
                                              or 28))
    if #rawRows == 0 then
        if hasFilters then
            if frame._emptyFiltered then frame._emptyFiltered:Show() end
            if frame._emptyNoRC    then frame._emptyNoRC:Hide()      end
        else
            if frame._emptyFiltered then frame._emptyFiltered:Hide() end
            if frame._emptyNoRC    then frame._emptyNoRC:Show()      end
        end
    else
        if frame._emptyFiltered then frame._emptyFiltered:Hide() end
        if frame._emptyNoRC    then frame._emptyNoRC:Hide()      end
    end

    if libST then
        PopulateLibST()
    else
        fbPage = 1
        self:_DrawFallback()
    end
end
