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

    -- Skip the heading FontString entirely when the title is blank
    -- (used by banner cards that draw their own message). Otherwise
    -- the heading + inner padding eats 32px of the card for nothing.
    local hasTitle = type(title) == "string" and title ~= ""
    if hasTitle then
        local heading = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        heading:SetFont(T.fontBody, T.sizeHeading, "OUTLINE")
        heading:SetTextColor(T.accent[1], T.accent[2], T.accent[3], T.accent[4])
        heading:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -6)
        heading:SetText(title)
    end

    -- Inner content region starts below the heading. With a heading the
    -- 32px top inset gives a first slider at y=-4 room for its label,
    -- which MakeSlider anchors ABOVE the slider track and which extends
    -- ~14px upward. Without a heading we only need a small chrome inset.
    local inner = CreateFrame("Frame", nil, card)
    inner:SetPoint("TOPLEFT",     card, "TOPLEFT",  6, hasTitle and -32 or -6)
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
                -- Show/hide the all-disabled notice.
                updateAllDisabledLbl()
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
                -- Show/hide the all-disabled notice.
                updateAllDisabledLbl()
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

    -- All-components-disabled notice (shown only when countEnabled == 0).
    local allDisabledLbl = exInner:CreateFontString(nil, "OVERLAY")
    allDisabledLbl:SetFont(T.fontBody, T.sizeSmall)
    allDisabledLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    allDisabledLbl:SetText("All components disabled \xe2\x80\x94 enable at least one.")
    allDisabledLbl:SetPoint("TOPLEFT", exDetailLbl, "BOTTOMLEFT", 0, -4)
    allDisabledLbl:Hide()

    local function updateAllDisabledLbl()
        if not addon then return end
        if countEnabled(addon.db.profile.weightsEnabled) == 0 then
            allDisabledLbl:Show()
        else
            allDisabledLbl:Hide()
        end
    end

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

    -- 4.11: re-run example row when color mode changes.
    if ns.Theme and ns.Theme.RegisterColorModeConsumer then
        ns.Theme:RegisterColorModeConsumer(function()
            if activeTab == "weights" then
                refreshExampleRow()
            end
        end)
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
        updateAllDisabledLbl()
    end)
end

function BuildTuningTab(parent)
    local T = ns.Theme

    local body = CreateFrame("Frame", nil, parent)
    body:SetAllPoints(parent)
    body:Hide()
    tabBodies["tuning"] = body

    local card, inner = MakeSection(body, "Scoring tuning")
    card:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -6)
    card:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, -6)
    -- Deepest control: synth slider track at inner y=-460. Inner top is
    -- now offset 32 below card top (was 22), so card needs +10 to keep
    -- the same usable inner height.
    card:SetHeight(538)

    -- Track control references for conditional show/hide.
    local simCapSld, mplusCapSld, histCapSld, synthWeightSld

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
    roleLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])

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

    -- Synthetic history weight slider (roadmap 4.2).
    -- Allows tuning how much catalyst/tier-token entries count relative to
    -- a normal RC boss-drop (1.0 = equal weight, 0.75 = default, 0 = exclude).
    local synthLabel = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Pushed down from -428 to -428: needs ~16px clearance above the
    -- MakeSlider 'Synth weight' label which sits above the track at -460.
    synthLabel:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -428)
    synthLabel:SetText("Synthetic history (catalyst/token) weight")
    synthLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])

    -- No `local` — the outer forward-decl on line 751 owns this binding
    -- so the OnShow refresh below can restore the slider value.
    synthWeightSld = MakeSlider(inner, {
        label   = "Synth weight",
        min     = 0,
        max     = 2.0,
        step    = 0.05,
        isPercent = false,
        width   = 220,
        x       = 4,
        y       = -460,
        get = function()
            return (addon and addon.db.profile.synthWeight) or 0.75
        end,
        set = function(v)
            if addon then
                addon.db.profile.synthWeight = v
                ScheduleLootHistoryApply()
            end
        end,
    })

    -- ── Display section (2.10 + 4.11) ────────────────────────────────────────
    local dispCard, dispInner = MakeSection(body, "Display")
    dispCard:SetPoint("TOPLEFT",  card, "BOTTOMLEFT",  0, -8)
    dispCard:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -8)
    -- Inner at 22 header + 6 bottom pad = 28 chrome. Need to fit:
    -- conflictSld (lbl + track ≈ 36px), conflictHint (~28px wrapped),
    -- colorModeLbl (14), colorModeHint (~28px wrapped), colorModeDropdown
    -- (28). Total ≈ 144 inner → 172 outer with margins.
    dispCard:SetHeight(190)

    -- Conflict threshold slider (integer 0-20).
    local conflictSld = MakeSlider(dispInner, {
        label = "Conflict threshold (points)",
        min   = 0,
        max   = 20,
        step  = 1,
        isPercent = false,
        width = 280,
        x = 4, y = -4,
        get = function()
            return (addon and addon.db.profile.conflictThreshold) or 5
        end,
        set = function(v)
            if addon then
                addon.db.profile.conflictThreshold = math.floor(v)
            end
        end,
    })

    -- Override MakeSlider's default "%.1f" readout with a clean integer.
    conflictSld:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        if addon then addon.db.profile.conflictThreshold = v end
        conflictSld._valLbl:SetText(tostring(v))
    end)
    conflictSld._valLbl:SetText(
        tostring((addon and addon.db.profile.conflictThreshold) or 5))

    -- Hint text below the slider.
    local conflictHint = dispInner:CreateFontString(nil, "OVERLAY")
    conflictHint:SetFont(T.fontBody, T.sizeSmall)
    conflictHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    conflictHint:SetPoint("TOPLEFT", conflictSld, "BOTTOMLEFT", 0, -4)
    conflictHint:SetWidth(480)
    conflictHint:SetText(
        "When two candidates' scores are within this many points, "
        .. "both cells show a ~ prefix. Set to 0 to disable.")

    -- ── Color mode dropdown (4.11) ────────────────────────────────────────
    -- Color-mode label sits below conflictHint with 12px clearance.
    -- Hint text wraps so we put it BELOW the dropdown (not between label
    -- and dropdown, where the dropdown chrome would overlap it).
    local colorModeLbl = dispInner:CreateFontString(nil, "OVERLAY")
    colorModeLbl:SetFont(T.fontBody, T.sizeBody)
    colorModeLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
    colorModeLbl:SetPoint("TOPLEFT", dispInner, "TOPLEFT", 4, -68)
    colorModeLbl:SetText("Color mode")

    -- Color mode options in display order.
    local COLOR_MODE_OPTIONS = {
        { value = "default",     label = "Default (red/amber/green)" },
        { value = "deuter",      label = "Deuteranopia / Protanopia (orange/blue)" },
        { value = "highcontrast",label = "High Contrast (filled background)" },
    }

    local colorModeDropdown = CreateFrame("Frame", "BobleLootColorModeDropdown",
        dispInner, "UIDropDownMenuTemplate")
    -- Drop offset y=+6 vertically centres the dropdown's button text
    -- against the colorModeLbl baseline (UIDropDownMenuTemplate has 6px
    -- of internal top chrome above the visible button).
    colorModeDropdown:SetPoint("TOPLEFT", colorModeLbl, "TOPLEFT", 80, 6)
    UIDropDownMenu_SetWidth(colorModeDropdown, 240)

    -- Hint sits below the dropdown so its chrome can't overlap text.
    local colorModeHint = dispInner:CreateFontString(nil, "OVERLAY")
    colorModeHint:SetFont(T.fontBody, T.sizeSmall)
    colorModeHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    colorModeHint:SetPoint("TOPLEFT", colorModeLbl, "BOTTOMLEFT", 0, -28)
    colorModeHint:SetWidth(480)
    colorModeHint:SetText(
        "Default = red/amber/green.  Deuter/Protan = orange/blue.  "
        .. "High Contrast = filled cell background, white text.")

    local function RefreshColorModeDropdown()
        local current = (addon and addon.db.profile.colorMode) or "default"
        UIDropDownMenu_SetSelectedValue(colorModeDropdown, current)
        -- Update button text to match selected label.
        for _, opt in ipairs(COLOR_MODE_OPTIONS) do
            if opt.value == current then
                UIDropDownMenu_SetText(colorModeDropdown, opt.label)
                break
            end
        end
    end

    UIDropDownMenu_Initialize(colorModeDropdown, function(self, level, menuList)
        for _, opt in ipairs(COLOR_MODE_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text     = opt.label
            info.value    = opt.value
            info.func     = function(item)
                if not addon then return end
                local mode = item.value
                addon.db.profile.colorMode = mode
                UIDropDownMenu_SetSelectedValue(colorModeDropdown, mode)
                UIDropDownMenu_SetText(colorModeDropdown, item:GetText())
                -- Apply mode immediately — changes are visible at once.
                if ns.Theme and ns.Theme.ApplyColorMode then
                    ns.Theme:ApplyColorMode(mode)
                end
            end
            info.checked  = ((addon and addon.db.profile.colorMode) or "default") == opt.value
            info.keepShownOnClick = false
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- ── Score trend tracking (3.8) ────────────────────────────────────────
    local trendCard, trendInner = MakeSection(body, "Score trend tracking")
    trendCard:SetPoint("TOPLEFT",  dispCard, "BOTTOMLEFT",  0, -8)
    trendCard:SetPoint("TOPRIGHT", dispCard, "BOTTOMRIGHT", 0, -8)
    trendCard:SetHeight(110)

    local trackTog = MakeToggle(trendInner, {
        label   = "Track per-night score trends (leader only)",
        x       = 4,
        y       = -4,
        get     = function() return (addon and addon.db.profile.trackTrends) ~= false end,
        set     = function(v)
            if addon then addon.db.profile.trackTrends = v and true or false end
        end,
    })

    local trendHint = trendInner:CreateFontString(nil, "OVERLAY")
    trendHint:SetFont(T.fontBody, T.sizeSmall)
    trendHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    trendHint:SetPoint("TOPLEFT", trendInner, "TOPLEFT", 26, -22)
    trendHint:SetWidth(480)
    trendHint:SetText(
        "When enabled, the leader's client records each player's computed score "
        .. "after every voting session. Used to show score trends in tooltips and "
        .. "the Explain panel after four or more weeks of data.")

    local trendWindowSld = MakeSlider(trendInner, {
        label  = "Trend window (days)",
        x      = 4,
        y      = -50,
        min    = 7,
        max    = 90,
        step   = 1,
        width  = 220,
        get    = function() return (addon and addon.db.profile.trendHistoryDays) or 28 end,
        set    = function(v)
            if addon then addon.db.profile.trendHistoryDays = math.floor(v) end
        end,
    })

    -- ── Ghost Presets section ────────────────────────────────────────
    local ghostCard, ghostInner = MakeSection(body, "Ghost Weights Preset")
    ghostCard:SetPoint("TOPLEFT",  trendCard, "BOTTOMLEFT",  0, -8)
    ghostCard:SetPoint("TOPRIGHT", trendCard, "BOTTOMRIGHT", 0, -8)
    ghostCard:SetHeight(180)
    ghostInner:SetHeight(160)

    local T2 = ns.Theme
    local ghostNote = ghostInner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ghostNote:SetFont(T2.fontBody, T2.sizeSmall)
    ghostNote:SetTextColor(T2.muted[1], T2.muted[2], T2.muted[3])
    ghostNote:SetPoint("TOPLEFT", ghostInner, "TOPLEFT", 0, -2)
    ghostNote:SetText("Farm preset \xe2\x80\x94 used when the ghost-weights button is active.")

    -- Five weight sliders for ghostPresets.farm.*
    local GHOST_KEYS   = { "sim", "bis", "history", "attendance", "mplus" }
    local GHOST_LABELS = { sim="Sim", bis="BiS", history="History",
                           attendance="Attendance", mplus="M+" }
    -- Start sliders at -28 so the first slider's "Sim" label (which sits
    -- above the slider track) clears ghostNote text.
    local ghostSliderY = -28
    for _, k in ipairs(GHOST_KEYS) do
        local key = k  -- upvalue
        MakeSlider(ghostInner, {
            label    = GHOST_LABELS[key],
            min      = 0, max = 1, step = 0.01,
            isPercent = true,
            width    = 220, x = 0, y = ghostSliderY,
            get = function()
                if not addon then return 0 end
                local gp = addon.db.profile.ghostPresets
                return (gp and gp.farm and gp.farm[key]) or 0
            end,
            set = function(v)
                if not addon then return end
                local gp = addon.db.profile.ghostPresets
                if gp and gp.farm then
                    gp.farm[key] = v
                end
                -- If ghost mode is currently active, refresh.
                if ns.VotingFrame and ns.VotingFrame.ghostMode then
                    ns.VotingFrame.SetGhostMode(true)
                end
            end,
        })
        ghostSliderY = ghostSliderY - 26
    end

    -- Active preset label (non-interactive; ghost button always uses "farm" in v1.3)
    local activeLbl = ghostInner:CreateFontString(nil, "OVERLAY",
                                                  "GameFontNormalSmall")
    activeLbl:SetFont(T2.fontBody, T2.sizeSmall)
    activeLbl:SetTextColor(T2.accent[1], T2.accent[2], T2.accent[3])
    activeLbl:SetPoint("BOTTOMLEFT", ghostCard, "BOTTOMLEFT", 8, 6)
    activeLbl:SetText("Ghost button applies: Farm preset")

    -- Refresh state on tab show.
    body:SetScript("OnShow", function()
        if not addon then return end
        local oc = addon.db.profile.overrideCaps
        if simCapSld   then simCapSld:SetEnabled(oc)   end
        if mplusCapSld then mplusCapSld:SetEnabled(oc) end
        if histCapSld  then histCapSld:SetEnabled(oc)  end
        if synthWeightSld then
            synthWeightSld:SetValue(addon.db.profile.synthWeight or 0.75)
        end
        -- 2.10: refresh conflict threshold display.
        if conflictSld then
            local ct = addon.db.profile.conflictThreshold or 5
            conflictSld:SetValue(ct)
            conflictSld._valLbl:SetText(tostring(ct))
        end
        -- 3.8: refresh trend controls.
        if trackTog then
            trackTog:SetChecked((addon.db.profile.trackTrends) ~= false)
        end
        if trendWindowSld then
            trendWindowSld:SetValue(addon.db.profile.trendHistoryDays or 28)
        end
        -- 4.11: refresh color mode dropdown.
        RefreshColorModeDropdown()
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

    -- Vault / BOE weight (reads from profile.vaultWeight, not lootWeights).
    -- Sits clear of the min-ilvl slider above (track at y=-188..-204).
    local vaultLabel = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vaultLabel:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -234)
    vaultLabel:SetText("Vault selections & BOE awards")
    vaultLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])

    MakeSlider(inner, {
        label = "Vault / BOE weight",
        min = 0, max = 2, step = 0.1, isPercent = false,
        width = 280, x = 4, y = -252,
        get = function()
            return (addon and addon.db.profile.vaultWeight) or 0.5
        end,
        set = function(v)
            if addon then
                addon.db.profile.vaultWeight = v
                ScheduleLootHistoryApply()
            end
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

    -- Muted hint shown when RC loot DB has no entries at all (4.12 row 28).
    local scanHintLbl = statusInner:CreateFontString(nil, "OVERLAY")
    scanHintLbl:SetFont(T.fontBody, T.sizeSmall)
    scanHintLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    scanHintLbl:SetPoint("TOPLEFT", statusLbl, "BOTTOMLEFT", 0, -4)
    scanHintLbl:SetWidth(480)
    scanHintLbl:SetText("|cff888888No RC loot history found.|r")
    scanHintLbl:Hide()

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
                -- Show/hide the empty-hint depending on scan count.
                if (lh.lastScanned or 0) == 0 then
                    scanHintLbl:Show()
                else
                    scanHintLbl:Hide()
                end
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
            -- 4.12: show the empty-hint when scan found nothing.
            if (lh.lastScanned or 0) == 0 then
                scanHintLbl:Show()
            else
                scanHintLbl:Hide()
            end
        else
            statusLbl:SetText("|cffaaaaaaLoot history not yet applied.|r")
            scanHintLbl:Hide()
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

    -- ── RC-not-detected banner (4.10) ─────────────────────────────────────
    -- Shown when TryHookRC never succeeded after the 10-second grace period.
    -- Auto-hides when BobleLoot_RCDetected fires (RC loaded later in session).
    -- Hidden by default; shown via BobleLoot_RCMissing AceEvent.
    -- 4.12 audit: banner text verified to match roadmap 4.10 canonical wording.
    -- RC version-compat line (below) reads live state via RCCompat:GetStatus(),
    -- so it never shows stale data. Layout order: banner → schema → info → actions
    -- → RC integration → transparency — matches 4.12 Task 12.3 spec.

    -- Layout strategy: chain every card top-down with `_layoutDataCards()`
    -- so banners, info, actions, RC integration, and transparency stack
    -- without overlap regardless of which banners are visible. The previous
    -- mixed TOPLEFT/BOTTOMLEFT anchoring caused 112px+ overlap between the
    -- actions and RC integration cards.

    local rcBannerCard, rcBannerInner = MakeSection(body, "")
    rcBannerCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -6)
    rcBannerCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, -6)
    rcBannerCard:SetHeight(RC_BANNER_H)
    T.ApplyBackdrop(rcBannerCard, "bgSurface", "borderNormal")
    rcBannerCard:Hide()  -- hidden until BobleLoot_RCMissing fires

    local rcBannerLbl = rcBannerInner:CreateFontString(nil, "OVERLAY")
    rcBannerLbl:SetFont(T.fontBody, T.sizeBody, "OUTLINE")
    rcBannerLbl:SetPoint("TOPLEFT",  rcBannerInner, "TOPLEFT",  6, -4)
    rcBannerLbl:SetPoint("TOPRIGHT", rcBannerInner, "TOPRIGHT", -6, -4)
    -- Roadmap-specified literal text, including the WoW color escape sequence:
    rcBannerLbl:SetText(
        "|cffff5555RCLootCouncil not detected. "
        .. "Score column will appear once RC loads.|r")

    -- Card heights (used by the layout chain). All bumped by 10 from the
    -- pre-MakeSection-padding-fix values to keep usable inner space the
    -- same now that inner is inset 10px further from the card top.
    local RC_BANNER_H    = 54
    local DRIFT_BANNER_H = 62
    local INFO_H         = 96
    local ACT_H          = 80
    local RC_INTEG_H     = 74
    -- transCard height is set when it's built below.

    -- Visibility tracking flags for the two banners.
    local _rcBannerVisible     = false
    local _schemaCardVisible   = false

    -- Forward-declared so _layoutDataCards (defined below) can see them.
    -- Each is assigned by its own MakeSection block later in this function.
    local infoCard, actCard, rcCard, transCard

    -- Single source of truth for vertical card placement on the Data tab.
    -- Re-anchors every card top-down with a fixed 8px gap based on which
    -- banners are currently shown.
    local function _layoutDataCards()
        local y = -6
        if _rcBannerVisible then
            y = y - RC_BANNER_H - 8
        end
        if _schemaCardVisible then
            y = y - DRIFT_BANNER_H - 8
        end
        if infoCard then
            infoCard:ClearAllPoints()
            infoCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, y)
            infoCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, y)
            y = y - INFO_H - 8
        end
        if actCard then
            actCard:ClearAllPoints()
            actCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, y)
            actCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, y)
            y = y - ACT_H - 8
        end
        if rcCard then
            rcCard:ClearAllPoints()
            rcCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, y)
            rcCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, y)
            y = y - RC_INTEG_H - 8
        end
        if transCard then
            transCard:ClearAllPoints()
            transCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, y)
            transCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, y)
        end
    end

    -- Listen for RC detection events fired by Core.lua Task 2.
    if addon then
        addon:RegisterMessage("BobleLoot_RCMissing", function()
            _rcBannerVisible = true
            rcBannerCard:Show()
            _layoutDataCards()
        end)
        addon:RegisterMessage("BobleLoot_RCDetected", function()
            _rcBannerVisible = false
            rcBannerCard:Hide()
            _layoutDataCards()
        end)
    end

    -- ── RC schema warning banner ──────────────────────────────────────
    -- Visible only when rcSchemaDetected.status ~= "ok".
    -- Reads the stored verdict written by LootHistory:DetectSchemaVersion.

    local POPUP_SCHEMA_DETAIL = "BOBLELOOT_SCHEMA_DRIFT_DETAIL"

    local schemaCard, schemaInner = MakeSection(body, "RCLootCouncil compatibility")
    -- Anchored below rcBannerCard when visible. The actual TOPLEFT/TOPRIGHT
    -- points are set by _layoutDataCards every time visibility changes.
    schemaCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -6 - RC_BANNER_H - 8)
    schemaCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, -6 - RC_BANNER_H - 8)
    schemaCard:SetHeight(DRIFT_BANNER_H)
    schemaCard:Hide()  -- shown conditionally in OnShow

    local schemaLbl = schemaInner:CreateFontString(nil, "OVERLAY")
    schemaLbl:SetFont(T.fontBody, T.sizeBody)
    schemaLbl:SetPoint("TOPLEFT", schemaInner, "TOPLEFT", 4, -2)
    schemaLbl:SetWidth(380)
    schemaLbl:SetText(
        "RCLootCouncil schema mismatch \xe2\x80\x94 history may be incomplete. "
        .. "Run |cffffffff/bl lootdb|r for details.")

    local schemaDetailBtn = MakeButton(schemaInner, "View details",
        function()
            if not StaticPopupDialogs[POPUP_SCHEMA_DETAIL] then
                StaticPopupDialogs[POPUP_SCHEMA_DETAIL] = {
                    text         = "RC schema drift detail (Ctrl+C to copy):",
                    button1      = OKAY,
                    hasEditBox   = true,
                    editBoxWidth = 420,
                    OnShow = function(self)
                        local v2 = addon and addon.db
                                   and addon.db.profile
                                   and addon.db.profile.rcSchemaDetected
                        local l2 = {}
                        if v2 then
                            l2[#l2+1] = string.format(
                                "Status: %s  |  Check #%d  |  RC v%s",
                                v2.status, v2.version or 0, v2.rcVersion or "?")
                            l2[#l2+1] = string.format(
                                "Checked: %s",
                                v2.checkedAt and date("%Y-%m-%d %H:%M:%S", v2.checkedAt) or "?")
                            l2[#l2+1] = "Source: " .. (v2.sourceUsed or "?")
                            if v2.missingFields and #v2.missingFields > 0 then
                                l2[#l2+1] = "Missing field groups:"
                                for _, f in ipairs(v2.missingFields) do
                                    l2[#l2+1] = "  - " .. f end
                            else
                                l2[#l2+1] = "All expected field groups confirmed present."
                            end
                        else
                            l2[#l2+1] = "No detection result stored. Run /bl lootdb."
                        end
                        local eb = self.editBox or self.EditBox
                        if eb then
                            eb:SetText(table.concat(l2, "\n"))
                            eb:SetFocus()
                            eb:HighlightText()
                        end
                    end,
                    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
                    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
                    timeout      = 0,
                    whileDead    = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
            end
            StaticPopup_Show(POPUP_SCHEMA_DETAIL)
        end, { width = 100, height = 20, x = 388, y = -4 })

    -- ── Dataset info card ─────────────────────────────────────────────
    -- infoCard / actCard / rcCard / transCard are positioned by
    -- _layoutDataCards. Each carries its own fixed height so the layout
    -- function can chain them top-down with consistent 8px gaps.
    local infoInner
    infoCard, infoInner = MakeSection(body, "Dataset info")
    infoCard:SetHeight(INFO_H)

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
    local actInner
    actCard, actInner = MakeSection(body, "Actions")
    actCard:SetHeight(ACT_H)

    -- Broadcast button.
    MakeButton(actInner, "Broadcast to raid",
        function()
            if ns.Sync and ns.Sync.BroadcastNow then
                ns.Sync:BroadcastNow(addon)
                addon:Print("announced dataset to raid.")
            end
        end, { width = 150, height = 22, x = 4, y = -4 })

    -- Import dataset button (roadmap 4.3).
    -- Opens the /bl importpaste StaticPopup paste dialog.
    local importBtn = MakeButton(actInner, "Import Dataset (Paste JSON)",
        function()
            StaticPopup_Show("BOBLELOOT_IMPORT_PASTE")
        end, { width = 200, height = 22, x = 4, y = -34 })

    importBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Import Dataset from JSON", 1, 1, 1)
        GameTooltip:AddLine(
            "Run wowaudit.py --export bundle.json on any machine, "
            .. "copy the file contents, and paste here. No API key required.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    importBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

    -- ── RC integration card (item 4.8 + 4.9) ─────────────────────────
    -- Always visible. Shows the detected RC version (green/yellow/red) and
    -- the "Write score into RC Note field" toggle.
    local rcInner
    rcCard, rcInner = MakeSection(body, "RC Integration")
    rcCard:SetHeight(RC_INTEG_H)

    -- RC version info line (item 4.8). Refreshed in OnShow.
    local rcVersionLine = rcInner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rcVersionLine:SetPoint("TOPLEFT", rcInner, "TOPLEFT", 4, -4)
    rcVersionLine:SetWidth(480)
    rcVersionLine:SetJustifyH("LEFT")
    rcVersionLine:SetWordWrap(false)

    -- "Write score into RC Note field" toggle (item 4.9).
    local noteToggle = MakeToggle(rcInner, {
        label   = "Write score into RC Note field",
        x = 4, y = -24,
        get = function()
            return addon and addon.db.profile.writeRCNote ~= false
        end,
        set = function(v)
            if addon then addon.db.profile.writeRCNote = v and true or false end
        end,
    })

    -- ── Transparency card ─────────────────────────────────────────────
    -- Height accommodates: transTog (y=-4), transHintLbl (y=-28),
    -- suppressTog (y=-58), suppressHint (y=-76) + 2-line wrap + padding.
    -- +10 vs prior fix to absorb MakeSection's deeper inner offset.
    local transInner
    transCard, transInner = MakeSection(body, "Transparency mode")
    transCard:SetHeight(130)

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

    -- Tooltip on the disabled transparency toggle explaining why it is greyed.
    if transTog and transTog.HookScript then
        transTog:HookScript("OnEnter", function(self)
            if UnitIsGroupLeader("player") then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("|cffddddddBoble Loot \xe2\x80\x94 Transparency|r")
            GameTooltip:AddLine(
                "Only the raid leader can toggle transparency mode.",
                0.53, 0.53, 0.53)
            GameTooltip:Show()
        end)
        transTog:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- 2.11: player-side opt-out — always editable regardless of leadership.
    local suppressTog = MakeToggle(transInner, {
        label = "Hide score label on my screen (overrides leader setting)",
        x = 4, y = -58,
        get = function()
            return (addon and addon.db.profile.suppressTransparencyLabel) or false
        end,
        set = function(v)
            if not addon then return end
            addon.db.profile.suppressTransparencyLabel = v and true or false
            -- Immediately re-render the loot frame if it is open.
            if ns.LootFrame and ns.LootFrame.Refresh then
                ns.LootFrame:Refresh()
            end
        end,
    })

    local suppressHint = transInner:CreateFontString(nil, "OVERLAY")
    suppressHint:SetFont(T.fontBody, T.sizeSmall)
    suppressHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    suppressHint:SetPoint("TOPLEFT", transInner, "TOPLEFT", 26, -76)
    suppressHint:SetWidth(480)
    suppressHint:SetText(
        "Your choice. Does not affect what the leader or other raiders see. "
        .. "Saved per character.")

    -- OnShow re-reads leader state (leadership can change while panel is open).
    body:SetScript("OnShow", function()
        -- 4.10: sync RC-not-detected banner with current hook state.
        -- If the panel is opened after the 10s timer fired and RC is still missing,
        -- show the banner (the AceEvent would have fired to a BuildDataTab not yet called
        -- if the panel was never opened before the timer).
        if not BobleLoot._rcHooked then
            _rcBannerVisible = true
            rcBannerCard:Show()
        else
            _rcBannerVisible = false
            rcBannerCard:Hide()
        end

        -- RC schema banner visibility.
        local verdict = addon and addon.db
                         and addon.db.profile
                         and addon.db.profile.rcSchemaDetected
        if verdict and verdict.status ~= "ok" then
            local T2 = ns.Theme
            local col = (verdict.status == "degraded") and T2.warning or T2.danger
            schemaLbl:SetTextColor(col[1], col[2], col[3])
            schemaCard:Show()
            _schemaCardVisible = true
        else
            schemaCard:Hide()
            _schemaCardVisible = false
        end

        -- Re-anchor every card top-down based on current banner visibility.
        _layoutDataCards()

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

        -- 2.11: always refresh suppress toggle from profile (per-character).
        if suppressTog then
            suppressTog:SetChecked(
                (addon and addon.db.profile.suppressTransparencyLabel) or false)
        end

        -- RC version info line (item 4.8). Refresh on every tab-show so it
        -- reflects post-load state (Detect() may have run after BuildDataTab).
        if not ns.RCCompat then
            rcVersionLine:SetText("|cffff5555RCCompat module not loaded.|r")
        else
            local detected, resolverName, _, matchType = ns.RCCompat:GetStatus()
            local testedList = {}
            for v in pairs(ns.RCCompat.TESTED_VERSIONS) do
                testedList[#testedList + 1] = "v" .. v .. ".x"
            end
            table.sort(testedList)
            local testedStr = table.concat(testedList, ", ")

            local colorCode
            if matchType == "tested" then
                colorCode = "|cff40ff40"      -- green: version is in TESTED_VERSIONS
            elseif matchType == "untested-major" then
                colorCode = "|cffffd040"      -- yellow: newer than tested
            else
                colorCode = "|cffff5050"      -- red: unknown / fallback
            end

            rcVersionLine:SetText(string.format(
                "%sTested on RC %s, detected %s (resolver: %s)|r",
                colorCode, testedStr, detected, resolverName))
        end

        -- Note toggle: reflect current profile value (may have changed externally).
        if noteToggle then
            noteToggle:SetChecked(
                addon and addon.db.profile.writeRCNote ~= false or false)
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

    -- Reason label (shown when button is disabled). Word-wraps to up to
    -- two lines; runBtn sits 28px below the label baseline so a 2-line
    -- reason cannot overlap the button.
    local reasonLbl = inner:CreateFontString(nil, "OVERLAY")
    reasonLbl:SetFont(T.fontBody, T.sizeSmall)
    reasonLbl:SetTextColor(T.warning[1], T.warning[2], T.warning[3])
    reasonLbl:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -108)
    reasonLbl:SetWidth(460)
    reasonLbl:SetText("")

    -- Run button — pushed down from -120 to -140 to clear two-line reason.
    local runBtn = MakeButton(inner, "Run test session",
        function()
            if not (ns.TestRunner and ns.TestRunner.Run) then return end
            ns.TestRunner:Run(addon,
                (addon.db.profile.testItemCount or 5),
                (addon.db.profile.testUseDatasetItems ~= false))
        end, { width = 150, height = 24, x = 4, y = -140 })

    -- Tooltip on the button itself when it is disabled — surfaces the reason
    -- even when the player doesn't notice the amber label below the button.
    runBtn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then return end   -- no tooltip needed when enabled
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("|cffddddddBoble Loot \xe2\x80\x94 Test Session|r")
        local RCAceAddon2 = LibStub and LibStub("AceAddon-3.0", true)
        local RC2
        if RCAceAddon2 then
            local ok2, r2 = pcall(function()
                return RCAceAddon2:GetAddon("RCLootCouncil", true)
            end)
            RC2 = ok2 and r2 or nil
        end
        if not RC2 then
            GameTooltip:AddLine(
                "RCLootCouncil must be loaded to run a test session.",
                1, 0.8, 0.2)
        elseif IsInGroup() and not UnitIsGroupLeader("player") then
            GameTooltip:AddLine(
                "You must be the group leader (or solo) to start a test session.",
                1, 0.8, 0.2)
        end
        GameTooltip:Show()
    end)
    runBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
