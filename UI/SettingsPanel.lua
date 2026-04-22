--[[ UI/SettingsPanel.lua
     Custom settings panel for BobleLoot.
     Shell: top-level frame, title bar, tab bar, scroll-frame body.
     Tab builders are appended below this shell section.

     Public API:
       ns.SettingsPanel:Setup(addon)     -- called in Core:OnInitialize
       ns.SettingsPanel:Toggle()         -- open or close
       ns.SettingsPanel:Open()           -- open, switch to last tab
       ns.SettingsPanel:OpenTab(name)    -- "weights"|"tuning"|"lootdb"|"data"|"test"
       ns.SettingsPanel:Refresh()        -- re-read db.profile, update all controls
]]

local ADDON_NAME, ns = ...
local SP = {}
ns.SettingsPanel = SP

local addon   -- set by Setup
local frame   -- top-level Frame (nil until BuildFrames)
local built   -- bool: have we called BuildFrames yet?

local PANEL_W   = 560
local PANEL_H   = 420
local TITLEBAR_H = 28
local TABBAR_H   = 32
local BODY_H     = PANEL_H - TITLEBAR_H - TABBAR_H  -- 360

local TAB_NAMES  = { "weights", "tuning", "lootdb", "data", "test" }
local TAB_LABELS = { weights="Weights", tuning="Tuning",
                     lootdb="Loot DB", data="Data", test="Test" }

local tabs       = {}  -- tab button frames keyed by name
local tabBodies  = {}  -- content frames keyed by name
local activeTab  = nil

-- ── Local widget helpers ───────────────────────────────────────────────
--
-- These are intentionally local (not on ns) — the panel is compact enough
-- that a cross-file widget factory adds no value.

local function MakeSection(parent, title)
    local T = ns.Theme
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    T.ApplyBackdrop(card, "bgSurface", "borderNormal")

    local heading = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    heading:SetFont(T.fontBody, T.sizeHeading, "OUTLINE")
    heading:SetTextColor(T.accent[1], T.accent[2], T.accent[3], T.accent[4])
    heading:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -6)
    heading:SetText(title)

    -- Inner content region starts below the heading.
    local inner = CreateFrame("Frame", nil, card)
    inner:SetPoint("TOPLEFT",     card, "TOPLEFT",  6, -22)
    inner:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -6, 6)

    return card, inner
end

local function MakeToggle(parent, opts)
    -- opts = { label, get, set, width, x, y }
    local T = ns.Theme
    local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)

    -- The template creates a text child; relabel it.
    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetFont(T.fontBody, T.sizeBody)
    lbl:SetTextColor(T.white[1], T.white[2], T.white[3])
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetText(opts.label or "")

    cb:SetChecked(opts.get())
    cb:SetScript("OnClick", function(self)
        opts.set(self:GetChecked())
    end)

    -- Cyan check texture override.
    local ck = cb:GetCheckedTexture()
    if ck then ck:SetVertexColor(T.accent[1], T.accent[2], T.accent[3]) end

    cb._label = lbl
    return cb
end

local function MakeSlider(parent, opts)
    -- opts = { label, min, max, step, get, set, isPercent, width, x, y }
    local T = ns.Theme
    local w = opts.width or 260

    local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
    s:SetWidth(w)
    s:SetHeight(16)
    s:SetMinMaxValues(opts.min, opts.max)
    s:SetValueStep(opts.step or 1)
    s:SetValue(opts.get())
    s:SetObeyStepOnDrag(true)

    -- Suppress the default "Low" / "High" template text.
    local low  = s:GetRegions()  -- first region is Low text in template
    -- Safer: find named children.
    if _G[s:GetName() .. "Low"]  then _G[s:GetName() .. "Low"]:SetText("") end
    if _G[s:GetName() .. "High"] then _G[s:GetName() .. "High"]:SetText("") end
    if _G[s:GetName() .. "Text"] then _G[s:GetName() .. "Text"]:SetText("") end

    -- Cyan track tint.
    local thumb = s:GetThumbTexture()
    if thumb then
        thumb:SetVertexColor(T.accent[1], T.accent[2], T.accent[3])
    end

    -- Label to the left.
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(T.fontBody, T.sizeBody)
    lbl:SetTextColor(T.white[1], T.white[2], T.white[3])
    lbl:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
    lbl:SetText(opts.label or "")

    -- Value readout to the right.
    local valLbl = parent:CreateFontString(nil, "OVERLAY")
    valLbl:SetFont(T.fontBody, T.sizeBody)
    valLbl:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    valLbl:SetPoint("LEFT", s, "RIGHT", 6, 0)
    valLbl:SetWidth(46)

    local function updateVal(v)
        if opts.isPercent then
            valLbl:SetText(string.format("%.0f%%", v * 100))
        else
            valLbl:SetText(string.format("%.1f", v))
        end
    end
    updateVal(opts.get())

    s:SetScript("OnValueChanged", function(self, v)
        -- Snap to step boundary.
        if opts.step and opts.step > 0 then
            v = math.floor(v / opts.step + 0.5) * opts.step
        end
        opts.set(v)
        updateVal(v)
    end)

    s._label  = lbl
    s._valLbl = valLbl
    s._opts   = opts
    return s
end

local function MakeButton(parent, text, onClick, opts)
    local T = ns.Theme
    opts = opts or {}
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetText(text)
    btn:SetWidth(opts.width or 160)
    btn:SetHeight(opts.height or 22)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
    btn:SetScript("OnClick", onClick)
    if opts.danger then
        btn:GetNormalTexture():SetVertexColor(
            T.danger[1], T.danger[2], T.danger[3])
    end
    return btn
end

-- ── Tab switching ─────────────────────────────────────────────────────

local function SwitchTab(name)
    if not tabs[name] then return end
    activeTab = name
    if addon then addon.db.profile.lastTab = name end

    local T = ns.Theme
    for _, n in ipairs(TAB_NAMES) do
        local tb = tabs[n]
        local body = tabBodies[n]
        if n == name then
            tb:SetBackdropColor(T.bgTabActive[1], T.bgTabActive[2],
                T.bgTabActive[3], T.bgTabActive[4])
            tb._text:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
            if tb._underline then tb._underline:Show() end
            if body then body:Show() end
        else
            tb:SetBackdropColor(T.bgBase[1], T.bgBase[2],
                T.bgBase[3], 0)
            tb._text:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
            if tb._underline then tb._underline:Hide() end
            if body then body:Hide() end
        end
    end

    -- Trigger OnShow for the active body (for leader re-check, etc.)
    local activeBody = tabBodies[name]
    if activeBody and activeBody:GetScript("OnShow") then
        activeBody:GetScript("OnShow")(activeBody)
    end
end

-- ── Frame construction (lazy) ─────────────────────────────────────────

local function BuildFrames()
    if built then return end
    built = true

    local T = ns.Theme

    -- ── Outer frame ──────────────────────────────────────────────────
    frame = CreateFrame("Frame", "BobleLootSettingsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(PANEL_W, PANEL_H)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:Hide()

    T.ApplyBackdrop(frame, "bgBase", "borderNormal")

    -- Restore saved position or default to CENTER.
    local pos = addon and addon.db.profile.panelPos
    if pos and pos.point then
        frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    -- Save position on stop-moving.
    frame:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    frame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        -- Persist position.
        if addon then
            local point, _, _, x, y = self:GetPoint()
            addon.db.profile.panelPos = { point = point, x = x, y = y }
        end
    end)

    -- Close on Escape.
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then self:Hide() end
    end)
    frame:SetPropagateKeyboardInput(true)

    -- ── Title bar ────────────────────────────────────────────────────
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0,  0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0,  0)
    titleBar:SetHeight(TITLEBAR_H)
    T.ApplyBackdrop(titleBar, "bgTitleBar", "borderAccent")
    titleBar:EnableMouse(true)
    titleBar:SetScript("OnMouseDown", function(_, btn)
        if btn == "LeftButton" then frame:StartMoving() end
    end)
    titleBar:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if addon then
            local point, _, _, x, y = frame:GetPoint()
            addon.db.profile.panelPos = { point = point, x = x, y = y }
        end
    end)

    -- Cyan underline on title bar.
    local titleLine = titleBar:CreateTexture(nil, "OVERLAY")
    titleLine:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
    titleLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    titleLine:SetHeight(2)
    titleLine:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], T.accent[4])

    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
    titleText:SetTextColor(T.white[1], T.white[2], T.white[3])
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText("Boble Loot \226\128\148 Settings")  -- em-dash

    -- Close button (X).
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(TITLEBAR_H, TITLEBAR_H)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTxt:SetFont(T.fontTitle, T.sizeTitle + 2, "OUTLINE")
    closeTxt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    closeTxt:SetAllPoints()
    closeTxt:SetText("x")
    closeBtn:SetScript("OnEnter", function()
        closeTxt:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
    end)
    closeBtn:SetScript("OnLeave", function()
        closeTxt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    end)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- ── Tab bar ──────────────────────────────────────────────────────
    local tabBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    tabBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, -TITLEBAR_H)
    tabBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -TITLEBAR_H)
    tabBar:SetHeight(TABBAR_H)
    T.ApplyBackdrop(tabBar, "bgBase", "borderNormal")

    local tabW = PANEL_W / #TAB_NAMES  -- equal width tabs

    for i, name in ipairs(TAB_NAMES) do
        local tb = CreateFrame("Frame", nil, tabBar, "BackdropTemplate")
        tb:SetSize(tabW, TABBAR_H)
        tb:SetPoint("TOPLEFT", tabBar, "TOPLEFT", (i - 1) * tabW, 0)
        T.ApplyBackdrop(tb, "bgBase", "borderNormal")
        tb:EnableMouse(true)

        local txt = tb:CreateFontString(nil, "OVERLAY")
        txt:SetFont(T.fontBody, T.sizeBody, "OUTLINE")
        txt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
        txt:SetAllPoints()
        txt:SetJustifyH("CENTER")
        txt:SetText(TAB_LABELS[name])
        tb._text = txt

        -- 2px cyan bottom border (active tab indicator).
        local underline = tb:CreateTexture(nil, "OVERLAY")
        underline:SetPoint("BOTTOMLEFT",  tb, "BOTTOMLEFT",  2, 0)
        underline:SetPoint("BOTTOMRIGHT", tb, "BOTTOMRIGHT", -2, 0)
        underline:SetHeight(2)
        underline:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], T.accent[4])
        underline:Hide()
        tb._underline = underline

        -- Hover tint.
        tb:SetScript("OnEnter", function()
            if activeTab ~= name then
                txt:SetTextColor(T.white[1], T.white[2], T.white[3])
            end
        end)
        tb:SetScript("OnLeave", function()
            if activeTab ~= name then
                txt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
            end
        end)
        tb:SetScript("OnMouseDown", function(_, btn)
            if btn == "LeftButton" then SwitchTab(name) end
        end)

        tabs[name] = tb
    end

    -- ── Body scroll frame ────────────────────────────────────────────
    local bodyOffset = TITLEBAR_H + TABBAR_H

    local scrollFrame = CreateFrame("ScrollFrame", nil, frame,
        "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     frame, "TOPLEFT",     4, -(bodyOffset + 4))
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 4)

    -- One content child per tab, all parented to the scrollFrame's child.
    local scrollChild = CreateFrame("Frame")
    scrollChild:SetSize(PANEL_W - 26, BODY_H)
    scrollFrame:SetScrollChild(scrollChild)

    -- Build all five tab bodies now (lazy per-tab build is added here
    -- if complexity grows in the future; for now all tabs build on first
    -- panel open to keep SwitchTab simple).
    BuildWeightsTab(scrollChild)
    BuildTuningTab(scrollChild)
    BuildLootDBTab(scrollChild)
    BuildDataTab(scrollChild)
    BuildTestTab(scrollChild)

    -- Start on the last-used tab (or "weights" default).
    local startTab = (addon and addon.db.profile.lastTab) or "weights"
    if not tabs[startTab] then startTab = "weights" end
    SwitchTab(startTab)
end

-- ── Public API ────────────────────────────────────────────────────────

function SP:Setup(addonArg)
    addon = addonArg
    -- Do NOT build frames here. Lazy build on first Open/Toggle.

    -- Register Blizzard Settings API proxy (Task 12 fills this in fully;
    -- placeholder keeps Setup callable before that task lands).
end

function SP:Toggle()
    if not built then BuildFrames() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

function SP:Open()
    if not built then BuildFrames() end
    frame:Show()
    frame:Raise()
    local tab = (addon and addon.db.profile.lastTab) or "weights"
    if not tabs[tab] then tab = "weights" end
    SwitchTab(tab)
end

function SP:OpenTab(name)
    if not built then BuildFrames() end
    frame:Show()
    frame:Raise()
    SwitchTab(name)
end

function SP:Refresh()
    if not built or not frame:IsShown() then return end
    -- Each tab body's OnShow handler re-reads db.profile.
    -- Trigger the active tab's handler to update all controls.
    if activeTab and tabBodies[activeTab] then
        local body = tabBodies[activeTab]
        if body:GetScript("OnShow") then
            body:GetScript("OnShow")(body)
        end
    end
end

-- ── Tab builder stubs (replaced by Tasks 7-11) ────────────────────────
-- These stubs register empty tabBodies so SwitchTab doesn't error
-- before each task's BuildXxxTab implementation lands.

function BuildWeightsTab(parent)
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["weights"] = body
end

function BuildTuningTab(parent)
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["tuning"] = body
end

function BuildLootDBTab(parent)
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["lootdb"] = body
end

function BuildDataTab(parent)
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["data"] = body
end

function BuildTestTab(parent)
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["test"] = body
end
