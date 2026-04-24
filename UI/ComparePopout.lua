--[[ UI/ComparePopout.lua
     Side-by-side candidate comparison popout (Batch 3D, item 3.9).

     Public API:
       ns.ComparePopout:Setup(addon)
       ns.ComparePopout:Open(nameA, nameB, itemID, itemLink, opts)
         -- nameA    : "Name-Realm" — the shift-clicked candidate
         -- nameB    : "Name-Realm" — the top-ranked candidate
         -- itemID   : number
         -- itemLink : item link string or nil
         -- opts     : { simReference, historyReference,
         --              sessionMedian, sessionMax }
       ns.ComparePopout:Close()
       ns.ComparePopout:IsShown() -> bool
]]

local _, ns = ...
local CP = {}
ns.ComparePopout = CP

local PANEL_W    = 580
local PANEL_H    = 360
local MIN_W      = 480
local MIN_H      = 320
local TITLEBAR_H = 28
local BAR_H      = 14   -- height of each component bar
local BAR_GAP    = 4    -- vertical gap between bar rows
local COL_PAD    = 12   -- left/right padding inside each candidate column
local HEADER_H   = 42   -- candidate name + score label above bars

local _addon
local _frame
local _built

local function BuildFrame()
    if _built then return end
    _built = true

    local T = ns.Theme
    if not T then
        print("|cffff5555BobleLoot ComparePopout:|r Theme not loaded — check TOC order.")
        return
    end

    _frame = CreateFrame("Frame", "BobleLootCompareFrame", UIParent,
                         "BackdropTemplate")
    _frame:SetSize(PANEL_W, PANEL_H)
    _frame:SetFrameStrata("HIGH")
    _frame:SetClampedToScreen(true)
    _frame:SetMovable(true)
    _frame:SetResizable(true)
    _frame:EnableMouse(true)
    _frame:Hide()

    if _frame.SetResizeBounds then
        _frame:SetResizeBounds(MIN_W, MIN_H)
    elseif _frame.SetMinResize then
        _frame:SetMinResize(MIN_W, MIN_H)
    end

    T.ApplyBackdrop(_frame, "bgBase", "borderNormal")

    -- Restore saved position
    local function restorePos()
        local pos = _addon and _addon.db and _addon.db.profile
                    and _addon.db.profile.comparePos
        local validPoints = {
            CENTER=true, TOP=true, BOTTOM=true, LEFT=true, RIGHT=true,
            TOPLEFT=true, TOPRIGHT=true, BOTTOMLEFT=true, BOTTOMRIGHT=true,
        }
        if pos and pos.point and validPoints[pos.point] then
            _frame:ClearAllPoints()
            _frame:SetPoint(pos.point, UIParent, pos.point,
                            pos.x or 0, pos.y or 0)
        else
            _frame:ClearAllPoints()
            _frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
        end
    end
    restorePos()
    _frame._restorePos = restorePos

    local function savePos()
        if _addon and _addon.db then
            local point, _, _, x, y = _frame:GetPoint()
            _addon.db.profile.comparePos = { point=point, x=x, y=y }
        end
    end

    _frame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        savePos()
    end)
    _frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then self:Hide() end
    end)
    _frame:SetPropagateKeyboardInput(true)

    -- Resize grip
    local grip = CreateFrame("Button", nil, _frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", _frame, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture(
        "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() _frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        _frame:StopMovingOrSizing()
        savePos()
    end)

    -- ── Title bar ────────────────────────────────────────────────
    local titleBar = CreateFrame("Frame", nil, _frame, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT",  _frame, "TOPLEFT",  0, 0)
    titleBar:SetPoint("TOPRIGHT", _frame, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLEBAR_H)
    T.ApplyBackdrop(titleBar, "bgTitleBar", "borderAccent")
    titleBar:EnableMouse(true)
    titleBar:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then _frame:StartMoving() end
    end)
    titleBar:SetScript("OnMouseUp", function()
        _frame:StopMovingOrSizing()
        savePos()
    end)

    -- Cyan underline
    local titleLine = titleBar:CreateTexture(nil, "OVERLAY")
    titleLine:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    titleLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    titleLine:SetHeight(2)
    titleLine:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)

    -- Title text
    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
    titleText:SetTextColor(T.white[1], T.white[2], T.white[3])
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText("BobleLoot \226\128\148 Compare")
    _frame._titleText = titleText

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(TITLEBAR_H, TITLEBAR_H)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTxt:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
    closeTxt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    closeTxt:SetAllPoints()
    closeTxt:SetJustifyH("CENTER")
    closeTxt:SetText("x")
    closeBtn:SetScript("OnEnter", function()
        closeTxt:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
    end)
    closeBtn:SetScript("OnLeave", function()
        closeTxt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    end)
    closeBtn:SetScript("OnClick", function() _frame:Hide() end)

    -- ── Content area ─────────────────────────────────────────────
    local content = CreateFrame("Frame", nil, _frame)
    content:SetPoint("TOPLEFT",     _frame, "TOPLEFT",     0, -TITLEBAR_H)
    content:SetPoint("BOTTOMRIGHT", _frame, "BOTTOMRIGHT", 0, 0)
    _frame._content = content
    _frame._barRows = {}   -- reusable bar row objects (cleared on each Open)
end

-- ── Bar row builder ───────────────────────────────────────────────────────

-- Clears and rebuilds all bar row frames on each Open call.
-- Returns the new row's height so callers can advance the cursor.
local function BuildBarRow(content, yOffset, label,
                            contribA, contribB, maxContrib, isLargestGap)
    local T          = ns.Theme
    local fullW      = content:GetWidth() / 2 - COL_PAD * 2
    if fullW < 1 then fullW = 200 end

    local function makeBar(parent, xOff, contrib, color)
        local bg = parent:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.1, 0.1, 0.12, 1)
        bg:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, yOffset - 16)
        bg:SetSize(fullW, BAR_H)

        local fill = parent:CreateTexture(nil, "ARTWORK")
        local fillFrac = (maxContrib > 0) and math.min(contrib / maxContrib, 1) or 0
        fill:SetColorTexture(color[1], color[2], color[3], 0.85)
        fill:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
        fill:SetSize(math.max(fillFrac * fullW, 1), BAR_H)

        local pts = parent:CreateFontString(nil, "OVERLAY",
                                            "GameFontNormalSmall")
        pts:SetFont(T.fontBody, T.sizeSmall)
        pts:SetTextColor(T.white[1], T.white[2], T.white[3])
        pts:SetPoint("LEFT", bg, "RIGHT", 4, 0)
        pts:SetText(string.format("%.1f", contrib))
        return bg, fill, pts
    end

    local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetFont(T.fontBody, T.sizeSmall)
    lbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    lbl:SetPoint("TOPLEFT", content, "TOPLEFT", 6, yOffset)
    lbl:SetText(label)

    -- Left column = candidate A (cyan), right column = candidate B (gold)
    local halfW = content:GetWidth() / 2
    local colorA = T.accent
    local colorB = T.gold
    local bgA, fillA, ptsA = makeBar(content, COL_PAD,           contribA, colorA)
    local bgB, fillB, ptsB = makeBar(content, halfW + COL_PAD,   contribB, colorB)

    -- Differential label on the row with the largest gap
    local diff = contribA - contribB
    if isLargestGap and math.abs(diff) >= 0.05 then
        local diffLabel = content:CreateFontString(nil, "OVERLAY",
                                                  "GameFontNormalSmall")
        diffLabel:SetFont(T.fontBody, T.sizeSmall, "OUTLINE")
        local sign = diff >= 0 and "+" or ""
        diffLabel:SetText(string.format("%s%.1f pts", sign, diff))
        if diff >= 0 then
            diffLabel:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
        else
            diffLabel:SetTextColor(T.warning[1], T.warning[2], T.warning[3])
        end
        -- Center it horizontally at the column boundary
        diffLabel:SetPoint("CENTER", content, "TOPLEFT",
                           halfW, yOffset - 16 - BAR_H * 0.5)
    end

    return BAR_H + BAR_GAP + 16  -- total row height (label + bar + gap)
end

-- ── Score rendering ───────────────────────────────────────────────────────

local function RenderCompare(nameA, nameB, itemID, opts)
    local T       = ns.Theme
    local addon   = _addon
    opts          = opts or {}

    -- Score both candidates using current (non-ghost) weights.
    local function scoreFor(name)
        if not (addon and itemID and itemID > 0) then return nil, nil end
        return addon:GetScore(itemID, name, {
            simReference     = opts.simReference,
            historyReference = opts.historyReference,
        })
    end

    local sA, bdA = scoreFor(nameA)
    local sB, bdB = scoreFor(nameB)

    -- Wipe previous child objects from the content frame.
    for _, obj in ipairs(_frame._barRows or {}) do
        if obj.Hide then obj:Hide() end
    end
    _frame._barRows = {}

    local content = _frame._content

    local function addRow(fs)
        _frame._barRows[#_frame._barRows + 1] = fs
    end

    -- Candidate name + total score headers
    local halfW = content:GetWidth() / 2

    local function makeHeader(name, score, xOff, color)
        local nfs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nfs:SetFont(T.fontBody, T.sizeHeading, "OUTLINE")
        nfs:SetTextColor(color[1], color[2], color[3])
        nfs:SetPoint("TOPLEFT", content, "TOPLEFT", xOff + COL_PAD, -6)
        local shortName = name:match("^(.-)%-") or name
        nfs:SetText(shortName)
        addRow(nfs)

        local sfs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        sfs:SetFont(T.fontBody, T.sizeBody)
        sfs:SetTextColor(T.white[1], T.white[2], T.white[3])
        sfs:SetPoint("TOPLEFT", content, "TOPLEFT", xOff + COL_PAD, -20)
        sfs:SetText(score and string.format("%.1f / 100", score) or "|cffaaaaaa\xe2\x80\x94|r")
        addRow(sfs)
    end

    makeHeader(nameA, sA, 0,     T.accent)
    makeHeader(nameB, sB, halfW, T.gold)

    -- Separator line
    local sep = content:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(T.borderNormal[1], T.borderNormal[2],
                        T.borderNormal[3], 0.6)
    sep:SetPoint("TOPLEFT",  content, "TOPLEFT",  0,     -HEADER_H)
    sep:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0,     -HEADER_H)
    sep:SetHeight(1)
    addRow(sep)

    -- Component rows
    local ORDER = ns.Scoring and ns.Scoring.COMPONENT_ORDER
                  or { "sim", "bis", "history", "attendance", "mplus" }
    local LABEL = ns.Scoring and ns.Scoring.COMPONENT_LABEL or {}
    local weights = (addon and addon.db and addon.db.profile.weights) or {}

    -- Find the row with the largest absolute contribution gap.
    local largestGapKey, largestGap = nil, 0
    for _, k in ipairs(ORDER) do
        local cA = (bdA and bdA[k] and bdA[k].contribution) or 0
        local cB = (bdB and bdB[k] and bdB[k].contribution) or 0
        local gap = math.abs(cA - cB)
        if gap > largestGap then
            largestGap    = gap
            largestGapKey = k
        end
    end

    local yOff = -(HEADER_H + 4)
    for _, k in ipairs(ORDER) do
        local w          = weights[k] or 0
        local maxContrib = w * 100      -- ceiling in score-point space
        local cA = (bdA and bdA[k] and bdA[k].contribution) or 0
        local cB = (bdB and bdB[k] and bdB[k].contribution) or 0
        local label = LABEL[k] or k
        local isLargest = (k == largestGapKey)
        BuildBarRow(content, yOff, label, cA, cB, maxContrib, isLargest)
        yOff = yOff - (BAR_H + BAR_GAP + 18)
    end
end

-- ── Public API ────────────────────────────────────────────────────────────

function CP:Setup(addon)
    _addon = addon

    -- 4.11: redraw bars when the color mode changes.
    if ns.Theme and ns.Theme.RegisterColorModeConsumer then
        ns.Theme:RegisterColorModeConsumer(function()
            if ns.ComparePopout and ns.ComparePopout.IsShown
                and ns.ComparePopout:IsShown() then
                if ns.ComparePopout._lastArgs then
                    pcall(function()
                        ns.ComparePopout:Open(table.unpack(ns.ComparePopout._lastArgs))
                    end)
                end
            end
        end)
    end
end

function CP:Close()
    if _frame then _frame:Hide() end
end

function CP:IsShown()
    return _frame and _frame:IsShown() or false
end

function CP:Open(nameA, nameB, itemID, itemLink, opts)
    -- 4.11: persist arguments so the color-mode consumer can redraw on mode change.
    CP._lastArgs = { nameA, nameB, itemID, itemLink, opts }

    BuildFrame()
    if not _frame then return end  -- Theme nil guard fired

    -- Update title: "BobleLoot — <A> vs <B> on [Item]"
    local shortA = (nameA or "?"):match("^(.-)%-") or nameA or "?"
    local shortB = (nameB or "?"):match("^(.-)%-") or nameB or "?"
    local itemLabel = itemLink or
                      (itemID and itemID > 0 and ("[Item "..itemID.."]")) or "?"
    _frame._titleText:SetText(string.format(
        "BobleLoot \226\128\148 %s vs %s on %s",
        shortA, shortB, itemLabel))

    RenderCompare(nameA, nameB, itemID, opts)

    if not _frame:IsShown() then
        _frame._restorePos()
    end
    _frame:Show()
    _frame:Raise()
end
