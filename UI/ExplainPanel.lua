--[[ UI/ExplainPanel.lua
     Roadmap 2.9 — "Why this score" pinnable explanation panel.

     Single-instance movable AceGUI-style frame at strata HIGH.
     Displays the full four-column component breakdown for one
     (itemID, candidateName) pair, a raid-context footer, a
     renormalization caveat, and a copy-to-chat button.

     Entry points:
       ns.ExplainPanel:Open(itemID, name, opts)   -- show & populate
       ns.ExplainPanel:OpenFor(name)               -- re-uses cached itemID
       ns.ExplainPanel:Setup(addon)                -- called in Core:OnInitialize

     opts = {
       simReference     = number | nil,
       historyReference = number | nil,
       sessionMedian    = number | nil,
       sessionMax       = number | nil,
     }

     Graceful degradation:
       - mainspec / role fields on the character record are rendered
         in the footer if present; silently omitted if absent.
       - VF.formatRaw is called if VotingFrame.lua is already loaded;
         if not, a local equivalent renders raw values.
]]

local ADDON_NAME, ns = ...
local EP = {}
ns.ExplainPanel = EP

local addon         -- set by Setup
local frame         -- top-level Frame (built lazily on first Open)
local built = false

-- Last-opened context; persists so "Explain last" can re-open without args.
local _lastItemID   = nil
local _lastName     = nil
local _lastOpts     = {}

-- ── Palette shortcut ───────────────────────────────────────────────────
local function T() return ns.Theme end

-- ── Frame dimensions ──────────────────────────────────────────────────
local FRAME_W    = 480
local FRAME_H    = 360
local TITLEBAR_H = 26

-- ── Utility: hex color string from Theme color array ──────────────────
local function hexColor(c)
    return string.format("%02x%02x%02x",
        math.floor((c[1] or 0) * 255),
        math.floor((c[2] or 0) * 255),
        math.floor((c[3] or 0) * 255))
end

-- ── Local equivalent of VF.formatRaw (used when VotingFrame not loaded).
-- Real callers should prefer VF.formatRaw so they stay in sync.
local function formatRaw(key, entry)
    -- Delegate to VotingFrame's implementation if available — it is the
    -- authoritative implementation. Fall back to a local version only if
    -- VotingFrame hasn't loaded yet (should not happen in practice since
    -- VotingFrame.lua loads before UI/).
    if ns.VotingFrame and ns.VotingFrame.formatRaw then
        return ns.VotingFrame.formatRaw(key, entry)
    end
    -- Local fallback (mirrors VotingFrame.lua:formatRaw).
    local r = entry.raw
    if key == "sim" then
        if r == nil then return "-" end
        if entry.reference and entry.reference > 0 then
            return string.format("%.2f%% upgrade (best: %.2f%%)", r, entry.reference)
        end
        return string.format("%.2f%% upgrade", r)
    elseif key == "bis" then
        if r == true  then return "on BiS list" end
        if r == false then return "not on BiS (partial credit)" end
        return "no BiS list (partial credit)"
    elseif key == "history" then
        if r == nil then return "-" end
        local denom = math.max(entry.reference or 0, entry.cap or 0)
        local denomLabel
        if (entry.reference or 0) > (entry.cap or 0) then
            denomLabel = string.format("denom %d, max in raid", denom)
        elseif (entry.cap or 0) > 0 then
            denomLabel = string.format("denom %d, soft floor", denom)
        else
            denomLabel = "no denom"
        end
        local b = entry.breakdown
        if b then
            local parts = {}
            for _, k in ipairs({"bis","major","mainspec","minor"}) do
                if (b[k] or 0) > 0 then
                    parts[#parts+1] = string.format("%d %s", b[k], k)
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

-- ── Build the chat-export string for copy-to-chat ─────────────────────
-- Returns a flat string suitable for SendChatMessage.
local function buildChatExport(name, itemID, score, breakdown, sessionMedian, sessionMax)
    if not name or not itemID then return "" end
    local parts = {}
    parts[#parts+1] = string.format("[BobleLoot] %s / item %d", name, itemID)
    if score then
        parts[#parts+1] = string.format("Score: %.1f", score)
    else
        parts[#parts+1] = "Score: no data"
        return table.concat(parts, " | ")
    end

    local order  = ns.Scoring and ns.Scoring.COMPONENT_ORDER
                   or {"sim","bis","history","attendance","mplus"}
    local labels = ns.Scoring and ns.Scoring.COMPONENT_LABEL
                   or {sim="Sim",bis="BiS",history="Hist",attendance="Att",mplus="M+"}

    for _, key in ipairs(order) do
        local e = breakdown and breakdown[key]
        if e then
            parts[#parts+1] = string.format("%s=%.1fpts(%.0f%%)",
                labels[key] or key,
                e.contribution or 0,
                (e.effectiveWeight or 0) * 100)
        end
    end

    if sessionMedian or sessionMax then
        local ctx = {}
        if sessionMedian then
            ctx[#ctx+1] = string.format("Median %d", math.floor(sessionMedian + 0.5))
        end
        if sessionMax then
            ctx[#ctx+1] = string.format("Max %d", math.floor(sessionMax + 0.5))
        end
        parts[#parts+1] = table.concat(ctx, " ")
    end

    return table.concat(parts, " | ")
end

-- ── Populate the frame content for a given score context ───────────────
local _contentLines  -- FontString pool
local _chatExportStr -- filled by Populate, used by copy button

local function Populate(itemID, name, opts)
    if not built or not frame then return end
    opts = opts or {}

    _lastItemID = itemID
    _lastName   = name
    _lastOpts   = opts

    local Th = T()

    -- Build line list.
    local lines = {}  -- each: { left=str, right=str|nil, lr=..., rr=..., rg=..., rb=... }

    -- itemID = 0 (or nil) means no active voting session — give early guidance.
    if not itemID or itemID == 0 then
        if name then
            lines[#lines+1] = {
                left  = "|cff" .. hexColor(Th.white) .. name .. "|r",
                right = "|cff" .. hexColor(Th.muted) .. "no item|r",
            }
        end
        lines[#lines+1] = { left = "|cff444444" .. string.rep("\xe2\x80\x94", 28) .. "|r" }
        lines[#lines+1] = {
            left = "|cff" .. hexColor(Th.muted) .. "No scoring data for this item.|r"
        }
        lines[#lines+1] = {
            left = "|cff666666Open a voting session in RC first,|r"
        }
        lines[#lines+1] = {
            left = "|cff666666then use /bl explain <Name-Realm>.|r"
        }
        -- Skip to render; no score computation needed.
        _chatExportStr = ""
        -- Render lines.
        frame._scrollChild:SetHeight(1)
        for _, lf in ipairs(_contentLines or {}) do lf:Hide() end
        _contentLines = _contentLines or {}
        local lineH   = 14
        local yOffset = 0
        local childW  = FRAME_W - 30
        for i, lineData in ipairs(lines) do
            local lf = _contentLines[i]
            if not lf then
                lf = CreateFrame("Frame", nil, frame._scrollChild)
                lf._left  = lf:CreateFontString(nil, "OVERLAY")
                lf._left:SetFont(Th.fontBody, Th.sizeBody)
                lf._left:SetJustifyH("LEFT")
                lf._right = lf:CreateFontString(nil, "OVERLAY")
                lf._right:SetFont(Th.fontBody, Th.sizeBody)
                lf._right:SetJustifyH("RIGHT")
                _contentLines[i] = lf
            end
            lf:SetWidth(childW)
            lf:SetHeight(lineH)
            lf:SetPoint("TOPLEFT", frame._scrollChild, "TOPLEFT", 6, -yOffset)
            lf:Show()
            lf._left:SetPoint("LEFT", lf, "LEFT", 0, 0)
            lf._left:SetWidth(childW - 180)
            lf._left:SetText(lineData.left or "")
            lf._left:SetTextColor(1, 1, 1, 1)
            if lineData.right then
                lf._right:SetPoint("RIGHT", lf, "RIGHT", 0, 0)
                lf._right:SetWidth(175)
                lf._right:SetText(lineData.right)
                lf._right:SetTextColor(1, 1, 1, 1)
                lf._right:Show()
            else
                lf._right:SetText("")
                lf._right:Hide()
            end
            yOffset = yOffset + lineH
        end
        frame._scrollChild:SetHeight(math.max(yOffset + 4, FRAME_H - TITLEBAR_H - 36))
        return
    end

    local inDs = false
    local score, breakdown

    local data = addon and addon:GetData()
    if data and data.characters then
        inDs = (data.characters[name] ~= nil)
    end

    if inDs then
        score, breakdown = addon:GetScore(itemID, name, {
            simReference     = opts.simReference,
            historyReference = opts.historyReference,
        })
    end

    -- Title: name + score
    if name then
        local scoreStr
        if not inDs then
            scoreStr = "|cff" .. hexColor(Th.muted) .. "not in dataset|r"
        elseif not score then
            scoreStr = "|cff666666no data|r"
        else
            local c = Th.ScoreColorRelative
                      and Th.ScoreColorRelative(score, opts.sessionMedian, opts.sessionMax)
                      or  Th.ScoreColor(score)
            scoreStr = string.format("|cff%s%.1f / 100|r", hexColor(c), score)
        end
        lines[#lines+1] = {
            left  = "|cff" .. hexColor(Th.white) .. name .. "|r",
            right = scoreStr,
        }
    end

    -- Separator
    lines[#lines+1] = { left = "|cff444444" .. string.rep("\xe2\x80\x94", 28) .. "|r" }

    if not inDs then
        lines[#lines+1] = {
            left = string.format(
                "|cffaaaaaa%s is not in the BobleLoot dataset.|r", name or "?")
        }
        lines[#lines+1] = {
            left = "|cff888888Run tools/wowaudit.py and /reload.|r"
        }
    elseif not score then
        lines[#lines+1] = {
            left = "|cffff7070No scoreable components for this candidate/item.|r"
        }
    else
        -- Column header row
        lines[#lines+1] = {
            left  = "|cff666666Component           (raw stat)|r",
            right = "|cff666666wt%    norm   =  pts|r",
        }

        local order  = ns.Scoring and ns.Scoring.COMPONENT_ORDER
                       or {"sim","bis","history","attendance","mplus"}
        local labels = ns.Scoring and ns.Scoring.COMPONENT_LABEL
                       or {sim="Sim upgrade",bis="BiS",history="Loot received",
                           attendance="Attendance",mplus="M+ dungeons"}
        local weights = addon and addon.db and addon.db.profile
                        and addon.db.profile.weights or {}

        local excluded     = {}
        local totalConfigW = 0
        local activeWeightSum = 0

        for _, key in ipairs(order) do
            totalConfigW = totalConfigW + (weights[key] or 0)
        end

        for _, key in ipairs(order) do
            local e = breakdown[key]
            if e then
                activeWeightSum = activeWeightSum + (weights[key] or 0)
                local rawStr = formatRaw(key, e)
                local left = string.format("%s |cff666666(%s)|r",
                    labels[key] or key, rawStr)
                local right = string.format(
                    "|cffcccccc%2.0f%%|r  |cff6699ff%.2f|r  |cff888888=|r  |cffffffff%4.1f|r",
                    (e.effectiveWeight or 0) * 100,
                    e.value or 0,
                    e.contribution or 0)
                lines[#lines+1] = { left = left, right = right }
            else
                excluded[#excluded+1] = labels[key] or key
            end
        end

        lines[#lines+1] = { left = " " }

        -- Renormalization caveat
        if #excluded >= 2 then
            lines[#lines+1] = {
                left = "|cff808080Excluded (no data): "
                       .. table.concat(excluded, ", ") .. "|r"
            }
            if totalConfigW > 0 and activeWeightSum < totalConfigW then
                local pct = math.floor(activeWeightSum / totalConfigW * 100 + 0.5)
                lines[#lines+1] = {
                    left = string.format(
                        "|cff808080Score over %d%% of configured weights.|r", pct)
                }
            end
        elseif #excluded == 1 then
            lines[#lines+1] = {
                left = "|cff666666Excluded (no data): "
                       .. table.concat(excluded, ", ") .. "|r"
            }
        end

        -- Raid context footer
        if opts.sessionMedian or opts.sessionMax then
            local ctx = {}
            if opts.sessionMedian then
                ctx[#ctx+1] = string.format(
                    "Median |cffffffff%d|r",
                    math.floor(opts.sessionMedian + 0.5))
            end
            if opts.sessionMax then
                ctx[#ctx+1] = string.format(
                    "Max |cffffffff%d|r",
                    math.floor(opts.sessionMax + 0.5))
            end
            if score then
                ctx[#ctx+1] = string.format(
                    "This: |cffffffff%d|r",
                    math.floor(score + 0.5))
            end
            lines[#lines+1] = { left = " " }
            lines[#lines+1] = {
                left = "|cffaaaaaa" .. table.concat(ctx, " | ") .. "|r"
            }
        end

        -- Optional: mainspec / role fields (2A graceful degradation).
        -- These fields are added by plan 2A and may not exist yet.
        -- Render them if present; silently omit if absent.
        local charData = data and data.characters and data.characters[name]
        if charData then
            local extras = {}
            if charData.mainspec then
                extras[#extras+1] = string.format(
                    "|cffaaaaaamainspec: %s|r", charData.mainspec)
            end
            if charData.role then
                extras[#extras+1] = string.format(
                    "|cffaaaaaarole: %s|r", charData.role)
            end
            if #extras > 0 then
                lines[#lines+1] = { left = " " }
                lines[#lines+1] = { left = table.concat(extras, "  ") }
            end
        end

        -- Score trend section (4.12 / 3B). Guard: require at least 2 data
        -- points; show "No score history" when the API returns 0 or 1 entries.
        -- GetScoreTrend is defined in Batch 3B; silently omitted if absent.
        if ns.Scoring and ns.Scoring.GetScoreTrend then
            local profile = addon and addon.db and addon.db.profile
            local trend = ns.Scoring:GetScoreTrend(name, itemID,
                              (profile and profile.trendHistoryDays) or 28,
                              profile)
            lines[#lines+1] = { left = " " }
            if not trend or #trend <= 1 then
                lines[#lines+1] = {
                    left = "|cff666666No score history for this item yet.|r"
                }
            else
                -- Trend summary line (full sparkline rendering in later batches).
                local summary = ns.Scoring:GetTrendSummary and
                                ns.Scoring:GetTrendSummary(name, profile)
                if summary then
                    local sign = (summary.delta >= 0) and "+" or ""
                    lines[#lines+1] = {
                        left = string.format(
                            "|cffaaaaaaScore trend: %s%.1f over %d days|r",
                            sign, summary.delta, summary.count)
                    }
                end
            end
        end
    end

    -- Build export string (for copy-to-chat).
    _chatExportStr = buildChatExport(name, itemID, score, breakdown,
        opts.sessionMedian, opts.sessionMax)

    -- Render lines into the scroll child.
    -- We use a single multi-line FontString approach with a scrollable child.
    frame._scrollChild:SetHeight(1)  -- will grow as lines are placed

    -- Hide all pooled line frames.
    for _, lf in ipairs(_contentLines or {}) do
        lf:Hide()
    end
    _contentLines = _contentLines or {}

    local lineH   = 14
    local yOffset = 0
    local childW  = FRAME_W - 30

    for i, lineData in ipairs(lines) do
        -- Reuse or create a line frame.
        local lf = _contentLines[i]
        if not lf then
            lf = CreateFrame("Frame", nil, frame._scrollChild)
            lf._left  = lf:CreateFontString(nil, "OVERLAY")
            lf._left:SetFont(Th.fontBody, Th.sizeBody)
            lf._left:SetJustifyH("LEFT")
            lf._right = lf:CreateFontString(nil, "OVERLAY")
            lf._right:SetFont(Th.fontBody, Th.sizeBody)
            lf._right:SetJustifyH("RIGHT")
            _contentLines[i] = lf
        end

        lf:SetWidth(childW)
        lf:SetHeight(lineH)
        lf:SetPoint("TOPLEFT", frame._scrollChild, "TOPLEFT", 6, -yOffset)
        lf:Show()

        lf._left:SetPoint("LEFT",  lf, "LEFT",  0, 0)
        lf._left:SetWidth(childW - 180)
        lf._left:SetText(lineData.left or "")
        lf._left:SetTextColor(1, 1, 1, 1)

        if lineData.right then
            lf._right:SetPoint("RIGHT", lf, "RIGHT", 0, 0)
            lf._right:SetWidth(175)
            lf._right:SetText(lineData.right)
            lf._right:SetTextColor(1, 1, 1, 1)
            lf._right:Show()
        else
            lf._right:SetText("")
            lf._right:Hide()
        end

        yOffset = yOffset + lineH
    end

    -- Grow scroll child to content height.
    frame._scrollChild:SetHeight(math.max(yOffset + 4, FRAME_H - TITLEBAR_H - 36))
end

-- ── Build the persistent frame (called once) ───────────────────────────
local function BuildFrame()
    if built then return end
    built = true

    local Th = T()

    -- ── Outer frame ──────────────────────────────────────────────────
    frame = CreateFrame("Frame", "BobleLootExplainFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:EnableKeyboard(true)
    frame:Hide()

    Th.ApplyBackdrop(frame, "bgBase", "borderAccent")

    -- Default position (center).
    frame:SetPoint("CENTER", UIParent, "CENTER", 120, 0)

    -- Drag by background.
    frame:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    frame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
    end)

    -- Close on Escape.
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then self:Hide() end
    end)
    frame:SetPropagateKeyboardInput(true)

    -- ── Title bar ────────────────────────────────────────────────────
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLEBAR_H)
    Th.ApplyBackdrop(titleBar, "bgTitleBar", "borderAccent")

    -- Cyan underline.
    local titleLine = titleBar:CreateTexture(nil, "OVERLAY")
    titleLine:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    titleLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    titleLine:SetHeight(1)
    titleLine:SetColorTexture(Th.accent[1], Th.accent[2], Th.accent[3], Th.accent[4])

    -- Title label (updated on every Populate call).
    frame._titleText = titleBar:CreateFontString(nil, "OVERLAY")
    frame._titleText:SetFont(Th.fontBody, Th.sizeHeading, "OUTLINE")
    frame._titleText:SetTextColor(Th.accent[1], Th.accent[2], Th.accent[3])
    frame._titleText:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    frame._titleText:SetText("Boble Loot \226\128\148 Score Explanation")

    -- Close button.
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(TITLEBAR_H, TITLEBAR_H)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTxt:SetFont(Th.fontTitle or Th.fontBody, Th.sizeHeading + 2, "OUTLINE")
    closeTxt:SetTextColor(Th.muted[1], Th.muted[2], Th.muted[3])
    closeTxt:SetAllPoints()
    closeTxt:SetText("x")
    closeBtn:SetScript("OnEnter", function()
        closeTxt:SetTextColor(Th.danger[1], Th.danger[2], Th.danger[3])
    end)
    closeBtn:SetScript("OnLeave", function()
        closeTxt:SetTextColor(Th.muted[1], Th.muted[2], Th.muted[3])
    end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- Drag the frame by the title bar too.
    titleBar:EnableMouse(true)
    titleBar:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then frame:StartMoving() end
    end)
    titleBar:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
    end)

    -- ── Copy-to-chat button ───────────────────────────────────────────
    local copyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    copyBtn:SetText("Copy to chat")
    copyBtn:SetWidth(120)
    copyBtn:SetHeight(20)
    copyBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 6)
    copyBtn:SetScript("OnClick", function()
        if not _chatExportStr or _chatExportStr == "" then return end
        -- Determine a suitable chat channel.
        local channel = "SAY"
        if IsInRaid() then
            channel = UnitIsGroupLeader("player") and "RAID_WARNING" or "RAID"
        elseif IsInGroup() then
            channel = "PARTY"
        end
        SendChatMessage(_chatExportStr, channel)
    end)
    copyBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Copy score breakdown to chat")
        if IsInRaid() then
            local ch = UnitIsGroupLeader("player") and "Raid Warning" or "Raid"
            GameTooltip:AddLine("Sends to: " .. ch, 0.7, 0.7, 0.7)
        elseif IsInGroup() then
            GameTooltip:AddLine("Sends to: Party", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Sends to: Say (solo)", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    copyBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ── Scroll area ───────────────────────────────────────────────────
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame,
        "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     frame, "TOPLEFT",     4, -TITLEBAR_H - 4)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 32)

    local scrollChild = CreateFrame("Frame")
    scrollChild:SetWidth(FRAME_W - 30)
    scrollChild:SetHeight(FRAME_H - TITLEBAR_H - 36)
    scrollFrame:SetScrollChild(scrollChild)
    frame._scrollChild = scrollChild

    _contentLines = {}
end

-- ── Public API ────────────────────────────────────────────────────────

--- Setup is called from Core:OnInitialize.
function EP:Setup(addonArg)
    addon = addonArg
    -- Frame built lazily on first Open to keep /reload cost near zero.
end

--- Open the panel and populate it for (itemID, name).
-- opts = { simReference, historyReference, sessionMedian, sessionMax }
function EP:Open(itemID, name, opts)
    if not built then BuildFrame() end
    frame:Show()
    frame:Raise()
    if frame._titleText then
        frame._titleText:SetText(string.format(
            "Boble Loot \226\128\148 %s", name or "Score Explanation"))
    end
    Populate(itemID, name, opts)
end

--- Re-open with the last-used context (e.g. from "Explain last" dropdown).
function EP:OpenLast()
    if not _lastItemID and not _lastName then
        if addon then
            addon:Print("No score has been explained yet this session.")
        end
        return
    end
    self:Open(_lastItemID, _lastName, _lastOpts)
end

--- Open for a name only; requires a current voting session to derive itemID.
-- Used by /bl explain <Name-Realm>.
function EP:OpenFor(name, opts)
    -- Try to find the current session's item from VotingFrame.
    local itemID = nil
    if ns.VotingFrame and ns.VotingFrame.rcVoting then
        local rcV = ns.VotingFrame.rcVoting
        local session = rcV.GetCurrentSession and rcV:GetCurrentSession()
                        or rcV.session
        if session then
            -- Inline the helper logic from VotingFrame.lua.
            local lt = rcV.GetLootTable and rcV:GetLootTable()
            if lt and lt[session] then
                local entry = lt[session]
                if entry.link then
                    itemID = tonumber(entry.link:match("item:(%d+)"))
                end
                itemID = itemID or entry.id or entry.itemID
            end
        end
    end
    self:Open(itemID, name, opts or {})
end

--- Toggle the panel visibility (useful for keybind integration later).
function EP:Toggle(itemID, name, opts)
    if not built then
        self:Open(itemID, name, opts)
        return
    end
    if frame:IsShown() then
        frame:Hide()
    else
        self:Open(itemID, name, opts)
    end
end

--- Return true when the panel is currently shown.
function EP:IsShown()
    return built and frame and frame:IsShown()
end

--- Return true when at least one explain call has been made this session.
function EP:HasLast()
    return _lastItemID ~= nil or _lastName ~= nil
end
