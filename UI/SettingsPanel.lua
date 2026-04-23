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

-- Coalesce rapid LootHistory:Apply calls (slider drags can fire dozens
-- of `set` callbacks per second; Apply is a full re-scan of saved
-- variable history and is expensive). Single-shot 0.5s timer; the
-- closure picks up the latest `addon` at fire time.
local _applyPending = false
local function ScheduleLootHistoryApply()
    if _applyPending then return end
    if not (ns.LootHistory and ns.LootHistory.Apply) then return end
    _applyPending = true
    C_Timer.After(0.5, function()
        _applyPending = false
        if addon and ns.LootHistory and ns.LootHistory.Apply then
            ns.LootHistory:Apply(addon)
        end
    end)
end

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
local _sliderCount = 0  -- unique-name generator for MakeSlider (see below)

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

    -- OptionsSliderTemplate uses $parent-prefixed child FontStrings (Low,
    -- High, Text). Those children inherit the slider's name; if the slider
    -- is anonymous, the global lookups below would concatenate nil and abort
    -- this whole function (breaking every subsequent tab builder). Give each
    -- slider a unique name so the children resolve.
    _sliderCount = _sliderCount + 1
    local sliderName = "BobleLootSettingsSlider" .. _sliderCount

    local s = CreateFrame("Slider", sliderName, parent, "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
    s:SetWidth(w)
    s:SetHeight(16)
    s:SetMinMaxValues(opts.min, opts.max)
    s:SetValueStep(opts.step or 1)
    s:SetValue(opts.get())
    s:SetObeyStepOnDrag(true)

    -- Suppress the default "Low" / "High" template text (nil-guarded in case
    -- the template ever changes and the children don't exist).
    local lowFS  = _G[sliderName .. "Low"]
    local highFS = _G[sliderName .. "High"]
    local textFS = _G[sliderName .. "Text"]
    if lowFS  then lowFS:SetText("")  end
    if highFS then highFS:SetText("") end
    if textFS then textFS:SetText("") end

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

    -- ── Blizzard Settings API proxy ───────────────────────────────────
    -- Registers a minimal entry in Esc -> Options -> AddOns so users who
    -- navigate menus rather than clicking the minimap icon can reach the panel.
    -- Handles three API shapes present across retail patches.

    local categoryName = "Boble Loot"

    -- 10.x Settings API (preferred).
    if Settings and Settings.RegisterCanvasLayoutCategory then
        -- Create a proxy category with a single "Open Boble Loot" button.
        local proxyFrame = CreateFrame("Frame")
        proxyFrame.name = categoryName

        local openBtn = CreateFrame("Button", nil, proxyFrame,
            "UIPanelButtonTemplate")
        openBtn:SetText("Open Boble Loot settings")
        openBtn:SetWidth(200)
        openBtn:SetHeight(24)
        openBtn:SetPoint("TOPLEFT", proxyFrame, "TOPLEFT", 16, -16)
        openBtn:SetScript("OnClick", function()
            SP:Open()
            -- Close the Blizzard Options frame so it doesn't sit on top.
            if SettingsPanel and SettingsPanel:IsShown() then
                HideUIPanel(SettingsPanel)
            end
        end)

        local category = Settings.RegisterCanvasLayoutCategory(
            proxyFrame, categoryName)
        Settings.RegisterAddOnCategory(category)
        self._blizzCategory = category

    elseif InterfaceOptions_AddCategory then
        -- Legacy pre-10.x path.
        local proxyFrame = CreateFrame("Frame")
        proxyFrame.name  = categoryName
        InterfaceOptions_AddCategory(proxyFrame)
        self._blizzProxyFrame = proxyFrame
    end
    -- If neither API is available the proxy simply doesn't register.
    -- The minimap button and /bl config slash command still work.
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
    local T = ns.Theme

    -- ── Re-export normalizeWeights from Config.lua logic ──────────────
    local WEIGHT_KEYS = { "sim", "bis", "history", "attendance", "mplus" }

    local function countEnabled(enabled)
        local n = 0
        for _, k in ipairs(WEIGHT_KEYS) do
            if enabled[k] then n = n + 1 end
        end
        return n
    end

    local function normalizeWeights(weights, enabled)
        for _, k in ipairs(WEIGHT_KEYS) do
            if not enabled[k] then weights[k] = 0 end
        end
        local sum = 0
        for _, k in ipairs(WEIGHT_KEYS) do sum = sum + (weights[k] or 0) end
        local n = countEnabled(enabled)
        if sum <= 0 then
            if n == 0 then return end
            for _, k in ipairs(WEIGHT_KEYS) do
                weights[k] = enabled[k] and (1 / n) or 0
            end
            return
        end
        for _, k in ipairs(WEIGHT_KEYS) do
            weights[k] = enabled[k] and (weights[k] / sum) or 0
        end
    end

    -- ── Body frame ────────────────────────────────────────────────────
    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["weights"] = body

    -- Section card.
    local card, inner = MakeSection(body,
        "Weights  (toggle on/off; sliders auto-normalize to 100%)")
    card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
    card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 80)

    -- Component definitions: key, display label.
    local COMPONENTS = {
        { key = "sim",        label = "WoWAudit sim upgrade" },
        { key = "bis",        label = "BiS list" },
        { key = "history",    label = "Recent items received" },
        { key = "attendance", label = "Raid attendance" },
        { key = "mplus",      label = "Mythic+ dungeons (season)" },
    }

    -- References for cross-slider refresh.
    local sliders   = {}  -- keyed by component key
    local valLabels = {}  -- keyed by component key

    local ROW_H   = 28
    local COL_LBL = 0    -- label starts here
    local COL_TOG = 112  -- toggle
    local COL_SLD = 138  -- slider
    local SLD_W   = 270

    for i, comp in ipairs(COMPONENTS) do
        local yOff = -(i - 1) * ROW_H - 4

        -- Row label.
        local lbl = inner:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(T.fontBody, T.sizeBody)
        lbl:SetTextColor(T.white[1], T.white[2], T.white[3])
        lbl:SetPoint("TOPLEFT", inner, "TOPLEFT", COL_LBL, yOff)
        lbl:SetWidth(110)
        lbl:SetText(comp.label)

        -- Enable toggle.
        local tog = MakeToggle(inner, {
            label = "",
            x = COL_TOG, y = yOff,
            get = function()
                return addon and addon.db.profile.weightsEnabled[comp.key]
            end,
            set = function(v)
                if not addon then return end
                local p = addon.db.profile
                p.weightsEnabled[comp.key] = v
                if v then
                    -- Give the newly-enabled key an equal share before renorm.
                    local n = countEnabled(p.weightsEnabled)
                    p.weights[comp.key] = (n > 0) and (1 / n) or 1
                end
                normalizeWeights(p.weights, p.weightsEnabled)
                -- Refresh all sliders so renorm is visible.
                for _, k in ipairs(WEIGHT_KEYS) do
                    if sliders[k] then
                        local enabled = p.weightsEnabled[k]
                        sliders[k]:SetEnabled(enabled)
                        sliders[k]:SetValue(p.weights[k] or 0)
                        if valLabels[k] then
                            valLabels[k]:SetText(string.format(
                                "%.0f%%", (p.weights[k] or 0) * 100))
                        end
                    end
                end
            end,
        })

        -- Weight slider.
        local sld = MakeSlider(inner, {
            label = "",
            min = 0, max = 1, step = 0.01, isPercent = true,
            width = SLD_W,
            x = COL_SLD, y = yOff - 8,
            get = function()
                return (addon and addon.db.profile.weights[comp.key]) or 0
            end,
            set = function(v)
                if not addon then return end
                local p = addon.db.profile
                p.weights[comp.key] = v
                normalizeWeights(p.weights, p.weightsEnabled)
                -- Refresh sibling sliders.
                for _, k in ipairs(WEIGHT_KEYS) do
                    if sliders[k] and k ~= comp.key then
                        sliders[k]:SetValue(p.weights[k] or 0)
                        if valLabels[k] then
                            valLabels[k]:SetText(string.format(
                                "%.0f%%", (p.weights[k] or 0) * 100))
                        end
                    end
                end
            end,
        })

        sliders[comp.key]   = sld
        valLabels[comp.key] = sld._valLbl

        -- Dim slider when component is disabled.
        local isEnabled = addon and addon.db.profile.weightsEnabled[comp.key]
        sld:SetEnabled(isEnabled ~= false)
    end

    -- ── Example score row ─────────────────────────────────────────────
    -- A synthetic character with fixed raw inputs so the user can see how
    -- weights shape a score as sliders move. Updates on every slider change
    -- via the OnShow refresh path.

    local exCard, exInner = MakeSection(body,
        "Example score (how current weights shape a result)")
    exCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6,  74)
    exCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6,  6)

    -- Fixed raw component values for the example character.
    -- Values are 0-1 normalized inputs (same scale Scoring.lua uses).
    local EXAMPLE_RAW = {
        sim        = 0.72,
        bis        = 1.00,
        history    = 0.50,
        attendance = 0.80,
        mplus      = 0.60,
    }

    local exScoreLbl = exInner:CreateFontString(nil, "OVERLAY")
    exScoreLbl:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
    exScoreLbl:SetPoint("TOPLEFT", exInner, "TOPLEFT", 4, -2)

    local exDetailLbl = exInner:CreateFontString(nil, "OVERLAY")
    exDetailLbl:SetFont(T.fontBody, T.sizeSmall)
    exDetailLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    exDetailLbl:SetPoint("TOPLEFT", exScoreLbl, "BOTTOMLEFT", 0, -2)
    exDetailLbl:SetWidth(500)

    local function refreshExampleRow()
        if not addon then return end
        local p = addon.db.profile
        local score = 0
        local parts = {}
        for _, k in ipairs(WEIGHT_KEYS) do
            local w = p.weights[k] or 0
            local r = EXAMPLE_RAW[k] or 0
            local contrib = w * r * 100
            score = score + contrib
            if w > 0 then
                parts[#parts + 1] = string.format("%s=%.1f", k, contrib)
            end
        end
        local col = ns.Theme.ScoreColor(score)
        exScoreLbl:SetTextColor(col[1], col[2], col[3])
        exScoreLbl:SetText(string.format("%.0f", score))
        exDetailLbl:SetText(
            "(synthetic inputs: sim=72%%, bis=100%%, hist=50%%, att=80%%, m+=60%%)  "
            .. table.concat(parts, "  "))
    end

    -- Refresh on tab show.
    body:SetScript("OnShow", function()
        if not addon then return end
        local p = addon.db.profile
        for _, k in ipairs(WEIGHT_KEYS) do
            if sliders[k] then
                local enabled = p.weightsEnabled[k]
                sliders[k]:SetEnabled(enabled ~= false)
                sliders[k]:SetValue(p.weights[k] or 0)
                if valLabels[k] then
                    valLabels[k]:SetText(string.format(
                        "%.0f%%", (p.weights[k] or 0) * 100))
                end
            end
        end
        refreshExampleRow()
    end)
end

function BuildTuningTab(parent)
    local T = ns.Theme

    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["tuning"] = body

    local card, inner = MakeSection(body, "Scoring tuning")
    card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
    card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

    -- Track control references for conditional show/hide.
    local simCapSld, mplusCapSld, histCapSld

    -- Partial-BiS slider.
    MakeSlider(inner, {
        label = "BiS partial credit (non-BiS items)",
        min = 0, max = 1, step = 0.05, isPercent = true,
        width = 280, x = 4, y = -4,
        get = function() return (addon and addon.db.profile.partialBiSValue) or 0.25 end,
        set = function(v)
            if addon then addon.db.profile.partialBiSValue = v end
        end,
    })

    -- Override caps toggle.
    local overrideTog = MakeToggle(inner, {
        label = "Override caps from data file",
        x = 4, y = -52,
        get = function() return (addon and addon.db.profile.overrideCaps) or false end,
        set = function(v)
            if addon then addon.db.profile.overrideCaps = v end
            -- Dim or enable the three cap sliders.
            if simCapSld  then simCapSld:SetEnabled(v)  end
            if mplusCapSld then mplusCapSld:SetEnabled(v) end
            if histCapSld  then histCapSld:SetEnabled(v)  end
        end,
    })

    -- Sim cap slider.
    simCapSld = MakeSlider(inner, {
        label = "Sim upgrade cap (% -> 100)",
        min = 0.5, max = 20, step = 0.5, isPercent = false,
        width = 280, x = 4, y = -82,
        get = function() return (addon and addon.db.profile.simCap) or 5.0 end,
        set = function(v)
            if addon then addon.db.profile.simCap = v end
        end,
    })

    -- M+ cap slider.
    mplusCapSld = MakeSlider(inner, {
        label = "M+ dungeons cap (count -> 100)",
        min = 5, max = 200, step = 1, isPercent = false,
        width = 280, x = 4, y = -128,
        get = function() return (addon and addon.db.profile.mplusCap) or 40 end,
        set = function(v)
            if addon then addon.db.profile.mplusCap = v end
        end,
    })

    -- History soft-floor slider.
    histCapSld = MakeSlider(inner, {
        label = "Loot equity soft floor",
        min = 1, max = 20, step = 1, isPercent = false,
        width = 280, x = 4, y = -174,
        get = function() return (addon and addon.db.profile.historyCap) or 5 end,
        set = function(v)
            if addon then addon.db.profile.historyCap = v end
        end,
    })

    -- Loot history window slider.
    MakeSlider(inner, {
        label = "Loot history window (days, 0 = all time)",
        min = 0, max = 180, step = 1, isPercent = false,
        width = 280, x = 4, y = -220,
        get = function() return (addon and addon.db.profile.lootHistoryDays) or 28 end,
        set = function(v)
            if addon then
                addon.db.profile.lootHistoryDays = v
                -- Mirror Config.lua behavior: re-run loot history on change
                -- (debounced — see ScheduleLootHistoryApply).
                ScheduleLootHistoryApply()
            end
        end,
    })

    -- Role history weight multipliers (Batch 2.2).
    -- Heading label.
    local T = ns.Theme
    local roleLabel = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    roleLabel:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -270)
    roleLabel:SetText("Role history multipliers  (1.0 = full, 0.5 = half, 0.0 = none)")
    roleLabel:SetTextColor(T.c.muted.r, T.c.muted.g, T.c.muted.b)

    local ROLE_ROWS = {
        { key = "raider", label = "Raider",  y = -286 },
        { key = "trial",  label = "Trial",   y = -332 },
        { key = "bench",  label = "Bench",   y = -378 },
    }
    for _, rr in ipairs(ROLE_ROWS) do
        MakeSlider(inner, {
            label      = rr.label,
            min        = 0, max = 1, step = 0.05, isPercent = false,
            width      = 220, x = 4, y = rr.y,
            get = function()
                local rw = addon and addon.db.profile.roleHistoryWeights
                return (rw and rw[rr.key]) or 1.0
            end,
            set = function(v)
                if addon then
                    addon.db.profile.roleHistoryWeights = addon.db.profile.roleHistoryWeights or {}
                    addon.db.profile.roleHistoryWeights[rr.key] = v
                    ScheduleLootHistoryApply()
                end
            end,
        })
    end

    -- Refresh state on tab show.
    body:SetScript("OnShow", function()
        if not addon then return end
        local oc = addon.db.profile.overrideCaps
        if simCapSld  then simCapSld:SetEnabled(oc)  end
        if mplusCapSld then mplusCapSld:SetEnabled(oc) end
        if histCapSld  then histCapSld:SetEnabled(oc)  end
    end)
end

function BuildLootDBTab(parent)
    local T = ns.Theme

    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["lootdb"] = body

    local card, inner = MakeSection(body,
        "Loot category weights (for 'items received')")
    card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
    card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 110)

    -- Category sliders.
    local CAT_ROWS = {
        { key = "bis",      label = "BiS",                         y = -4   },
        { key = "major",    label = "Major upgrade",               y = -50  },
        { key = "mainspec", label = "Mainspec / Need",             y = -96  },
        { key = "minor",    label = "Minor upgrade",               y = -142 },
    }

    for _, row in ipairs(CAT_ROWS) do
        MakeSlider(inner, {
            label = row.label,
            min = 0, max = 5, step = 0.1, isPercent = false,
            width = 280, x = 4, y = row.y,
            get = function()
                return (addon and addon.db.profile.lootWeights[row.key]) or 1.0
            end,
            set = function(v)
                if not addon then return end
                addon.db.profile.lootWeights[row.key] = v
                ScheduleLootHistoryApply()
            end,
        })
    end

    -- Min ilvl slider.
    MakeSlider(inner, {
        label = "Minimum item level (0 = all tracks)",
        min = 0, max = 800, step = 5, isPercent = false,
        width = 280, x = 4, y = -188,
        get = function() return (addon and addon.db.profile.lootMinIlvl) or 0 end,
        set = function(v)
            if not addon then return end
            addon.db.profile.lootMinIlvl = v
            ScheduleLootHistoryApply()
        end,
    })

    -- Status line.
    local statusCard, statusInner = MakeSection(body, "Loot history status")
    statusCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6, 104)
    statusCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

    local statusLbl = statusInner:CreateFontString(nil, "OVERLAY")
    statusLbl:SetFont(T.fontBody, T.sizeBody)
    statusLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
    statusLbl:SetPoint("TOPLEFT", statusInner, "TOPLEFT", 4, -2)
    statusLbl:SetWidth(380)

    local refreshBtn = MakeButton(statusInner, "Refresh now",
        function()
            if ns.LootHistory and ns.LootHistory.Apply then
                ns.LootHistory:Apply(addon)
                -- Update the status line immediately.
                local lh = ns.LootHistory
                statusLbl:SetText(string.format(
                    "Last scan: %d/%d matched  (source: %s)",
                    lh.lastMatched or 0,
                    lh.lastScanned or 0,
                    lh.lastSource  or "?"))
            end
        end, { width = 120, height = 20, x = 390, y = -2 })

    local function updateStatus()
        local lh = ns.LootHistory
        if lh and lh.lastMatched then
            statusLbl:SetText(string.format(
                "Last scan: %d/%d matched  (source: %s)",
                lh.lastMatched or 0,
                lh.lastScanned or 0,
                lh.lastSource  or "?"))
        else
            statusLbl:SetText("|cffaaaaaaLoot history not yet applied.|r")
        end
    end

    body:SetScript("OnShow", function()
        updateStatus()
    end)
end

function BuildDataTab(parent)
    local T = ns.Theme
    local POPUP_TEAM_URL = "BOBLELOOT_SETTINGS_TEAM_URL"

    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["data"] = body

    -- ── Dataset info card ─────────────────────────────────────────────
    local infoCard, infoInner = MakeSection(body, "Dataset info")
    infoCard:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
    infoCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 240)

    local infoLbl = infoInner:CreateFontString(nil, "OVERLAY")
    infoLbl:SetFont(T.fontBody, T.sizeBody)
    infoLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
    infoLbl:SetPoint("TOPLEFT", infoInner, "TOPLEFT", 4, -2)
    infoLbl:SetWidth(500)

    local function updateInfoLabel()
        local d = _G.BobleLoot_Data
        if not d then
            infoLbl:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
            infoLbl:SetText("|cffff5555No dataset loaded.|r")
            return
        end
        infoLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
        local count = 0
        for _ in pairs(d.characters or {}) do count = count + 1 end
        infoLbl:SetText(string.format(
            "Generated: %s\nCharacters loaded: %d\n"
            .. "Caps (data file):  M+ dungeons = %d  |  History soft floor = %d\n"
            .. "|cff888888(Sim is uncapped by design)|r",
            d.generatedAt or "?",
            count,
            d.mplusCap   or 0,
            d.historyCap or 0))
    end

    -- ── Actions card ──────────────────────────────────────────────────
    local actCard, actInner = MakeSection(body, "Actions")
    actCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6,  234)
    actCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 130)

    -- Broadcast button.
    MakeButton(actInner, "Broadcast to raid",
        function()
            if ns.Sync and ns.Sync.BroadcastNow then
                ns.Sync:BroadcastNow(addon)
                addon:Print("announced dataset to raid.")
            end
        end, { width = 150, height = 22, x = 4, y = -4 })

    -- WoWAudit team page button (hidden if teamUrl absent).
    local teamBtn = MakeButton(actInner, "Open WoWAudit team page",
        function()
            -- StaticPopup with edit box for ctrl-C copy (mirrors RaidReminder pattern).
            if not StaticPopupDialogs[POPUP_TEAM_URL] then
                StaticPopupDialogs[POPUP_TEAM_URL] = {
                    text         = "Open this URL in your browser (Ctrl+C to copy):",
                    button1      = OKAY,
                    hasEditBox   = true,
                    editBoxWidth = 340,
                    OnShow = function(self)
                        local data = _G.BobleLoot_Data
                        local url  = (data and data.teamUrl) or "https://wowaudit.com"
                        local eb = self.editBox or self.EditBox
                        if not eb then return end
                        eb:SetText(url)
                        eb:SetFocus()
                        eb:HighlightText()
                    end,
                    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
                    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
                    timeout      = 0,
                    whileDead    = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
            end
            StaticPopup_Show(POPUP_TEAM_URL)
        end, { width = 190, height = 22, x = 162, y = -4 })
    teamBtn:Hide()  -- shown conditionally in OnShow

    -- ── Transparency card ─────────────────────────────────────────────
    local transCard, transInner = MakeSection(body, "Transparency mode")
    transCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6, 124)
    transCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

    local transTog -- toggled in OnShow

    local transHintLbl = transInner:CreateFontString(nil, "OVERLAY")
    transHintLbl:SetFont(T.fontBody, T.sizeSmall)
    transHintLbl:SetPoint("TOPLEFT", transInner, "TOPLEFT", 4, -28)
    transHintLbl:SetWidth(500)

    transTog = MakeToggle(transInner, {
        label = "Enabled (raid leader only)",
        x = 4, y = -4,
        get = function()
            return addon and addon:IsTransparencyEnabled() or false
        end,
        set = function(v)
            if not addon then return end
            if not UnitIsGroupLeader("player") then return end
            addon:SetTransparencyEnabled(v, true)
        end,
    })

    -- OnShow re-reads leader state (leadership can change while panel is open).
    body:SetScript("OnShow", function()
        updateInfoLabel()

        -- Show/hide team URL button.
        local d = _G.BobleLoot_Data
        if d and d.teamUrl then teamBtn:Show() else teamBtn:Hide() end

        -- Transparency toggle enable/hint.
        local isLeader = UnitIsGroupLeader("player")
        transTog:SetEnabled(isLeader)
        transTog:SetChecked(addon and addon:IsTransparencyEnabled() or false)
        if isLeader then
            transHintLbl:SetTextColor(T.accentDim[1], T.accentDim[2], T.accentDim[3])
            transHintLbl:SetText(
                "You are the group leader. Toggling broadcasts the setting to all "
                .. "raid members who have Boble Loot installed.")
        else
            transHintLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
            transHintLbl:SetText(
                "Only the raid/group leader can change this. Current state is synced "
                .. "from the leader automatically.")
        end
    end)
end

function BuildTestTab(parent)
    local T = ns.Theme

    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["test"] = body

    local card, inner = MakeSection(body, "Test session")
    card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
    card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

    local descLbl = inner:CreateFontString(nil, "OVERLAY")
    descLbl:SetFont(T.fontBody, T.sizeSmall)
    descLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    descLbl:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -2)
    descLbl:SetWidth(500)
    descLbl:SetText(
        "Opens an RCLootCouncil test session so you can verify the Boble Loot score "
        .. "column live. Requires RCLootCouncil and group leader (or solo).")

    -- Item count slider.
    MakeSlider(inner, {
        label = "Number of items",
        min = 1, max = 20, step = 1, isPercent = false,
        width = 260, x = 4, y = -30,
        get = function() return (addon and addon.db.profile.testItemCount) or 5 end,
        set = function(v)
            if addon then addon.db.profile.testItemCount = math.floor(v) end
        end,
    })

    -- Use dataset items toggle.
    MakeToggle(inner, {
        label = "Use items from BobleLoot dataset (when available)",
        x = 4, y = -76,
        get = function()
            return (addon and addon.db.profile.testUseDatasetItems) ~= false
        end,
        set = function(v)
            if addon then addon.db.profile.testUseDatasetItems = v and true or false end
        end,
    })

    -- Reason label (shown when button is disabled).
    local reasonLbl = inner:CreateFontString(nil, "OVERLAY")
    reasonLbl:SetFont(T.fontBody, T.sizeSmall)
    reasonLbl:SetTextColor(T.warning[1], T.warning[2], T.warning[3])
    reasonLbl:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -108)
    reasonLbl:SetWidth(460)
    reasonLbl:SetText("")

    -- Run button.
    local runBtn = MakeButton(inner, "Run test session",
        function()
            if not (ns.TestRunner and ns.TestRunner.Run) then return end
            ns.TestRunner:Run(addon,
                (addon.db.profile.testItemCount or 5),
                (addon.db.profile.testUseDatasetItems ~= false))
        end, { width = 150, height = 24, x = 4, y = -120 })

    local function checkRunnable()
        -- Determine disable reason, if any.
        local RCAceAddon = LibStub and LibStub("AceAddon-3.0", true)
        local RC
        if RCAceAddon then
            local ok, r = pcall(function()
                return RCAceAddon:GetAddon("RCLootCouncil", true)
            end)
            RC = ok and r or nil
        end

        local reason = nil
        if not RC then
            reason = "RCLootCouncil is not loaded. The test session requires RC."
        elseif IsInGroup() and not UnitIsGroupLeader("player") then
            reason = "You must be the group leader (or solo) to start a test session."
        end

        if reason then
            runBtn:SetEnabled(false)
            reasonLbl:SetText(reason)
        else
            runBtn:SetEnabled(true)
            reasonLbl:SetText("")
        end
    end

    body:SetScript("OnShow", function()
        checkRunnable()
    end)
end
