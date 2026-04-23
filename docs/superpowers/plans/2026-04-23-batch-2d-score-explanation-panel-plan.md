# Batch 2D — Pinnable "Why This Score" Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a single, persistently-positioned frame that shows the full four-column score breakdown for any candidate + item pair, openable via `/bl explain <Name-Realm>` or by right-clicking a score cell in the RC voting frame, with a copy-to-chat button for council transcript use.

**Architecture:** A new `UI/ExplainPanel.lua` module owns a single lazily-constructed `Frame` (strata `HIGH`, clamped to screen, movable and resizable) that is reused across all invocations; `VotingFrame.lua` receives a small right-click handler on the score cell row; `Core.lua` receives the `explain` slash subcommand; `UI/MinimapButton.lua` receives an optional "Explain last" menu item. Rendering reuses `ns.Scoring.COMPONENT_ORDER`, `ns.Scoring.COMPONENT_LABEL`, `VF.formatRaw`, and `ns.Theme` — no duplication.

**Tech Stack:** Lua 5.1 (WoW environment), raw `BackdropTemplate` frames (same pattern as `UI/SettingsPanel.lua`), `GameTooltip` for the item-link tooltip, Blizzard `SendChatMessage` for copy-to-chat, `EasyMenu` for the minimap dropdown addition.

**Roadmap items covered:**

> **2.9 `[UI]` "Why this score" pinnable explanation panel**
>
> Tooltips disappear on mouse move; councils want to pin the breakdown
> while arguing. Add:
>
> - Slash command `/bl explain <Name-Realm>` opens a persistent
>   movable AceGUI frame for the currently selected session item.
> - Right-click on a score cell in the voting frame opens the same frame.
> - Contents: the full tooltip content (1.7) plus a copy-to-chat button
>   for council transcript use.

**Dependencies:**
- Batch 1D — `ns.Scoring.COMPONENT_ORDER`, `ns.Scoring.COMPONENT_LABEL`, `VF.formatRaw`, `fillScoreTooltip` layout conventions, session-stats pattern.
- Batch 1E — `ns.Theme` palette, `Theme.ApplyBackdrop`, `SettingsPanel.lua` frame-shell conventions (movable titlebar, cyan underline, hover-red close button, position persistence via `addon.db.profile`).

---

## File Structure

```
UI/
  ExplainPanel.lua        ← NEW — full module (shell + content renderer + copy-to-chat)
VotingFrame.lua           ← MODIFIED — add OnRightClick script on score cell row
Core.lua                  ← MODIFIED — add `explain` subcommand, update usage string,
                                        add `explainPos` to DB_DEFAULTS
UI/MinimapButton.lua      ← MODIFIED — add "Explain last" item to right-click menu
BobleLoot.toc             ← MODIFIED — add UI/ExplainPanel.lua load line
```

No new Libs are required. `BackdropTemplate` is a Blizzard built-in available in all retail clients. `SendChatMessage` is a Blizzard global API.

---

## Task 1 — DB schema: add `explainPos` default in `Core.lua`

**Files:** `Core.lua`

The panel persists its position in `BobleLootDB.profile.explainPos`. AceDB merges
defaults on first load, so adding the key here ensures it exists without migration.

- [ ] 1.1 Open `Core.lua` on the working branch (based on `release/v1.1.0`). Locate
  the `DB_DEFAULTS` table. After the existing `panelPos` entry add:

  ```lua
  explainPos = { point = "CENTER", x = 0, y = 0 },
  ```

- [ ] 1.2 In-game verification: `/reload`, then `/run print(BobleLoot.db.profile.explainPos.point)` — should print `CENTER`.

- [ ] 1.3 Commit: `feat(Core): add explainPos default to DB_DEFAULTS`

---

## Task 2 — Create `UI/ExplainPanel.lua` — frame shell

**Files:** `UI/ExplainPanel.lua` (new)

Build the outer frame using the exact same shell conventions as `UI/SettingsPanel.lua`:
dark `bgBase` backdrop, `borderNormal` edge, `bgTitleBar` titlebar with cyan underline,
hover-red close button top-right, movable via titlebar drag, position persisted to
`addon.db.profile.explainPos`, `SetClampedToScreen(true)`, strata `HIGH`.

The panel is resizable with a minimum of 480 × 360.

- [ ] 2.1 Create `UI/ExplainPanel.lua` with module boilerplate:

  ```lua
  --[[ UI/ExplainPanel.lua
       Pinnable "Why this score" explanation panel (Batch 2D).
  
       Public API:
         ns.ExplainPanel:Setup(addon)
         ns.ExplainPanel:Open(name, itemID, itemLink, opts)
           -- name     : "Name-Realm" string
           -- itemID   : number
           -- itemLink : item link string or nil
           -- opts     : { simReference, historyReference,
           --              sessionMedian, sessionMax }  (all optional)
         ns.ExplainPanel:Close()
  ]]
  
  local _, ns = ...
  local EP = {}
  ns.ExplainPanel = EP
  
  local PANEL_W     = 540
  local PANEL_H     = 400
  local MIN_W       = 480
  local MIN_H       = 360
  local TITLEBAR_H  = 28
  local FOOTER_H    = 36   -- copy-to-chat button bar
  
  local _addon
  local _frame     -- top-level Frame, nil until BuildFrame
  local _built     -- bool
  ```

- [ ] 2.2 Add `BuildFrame()` local function. Follow `SettingsPanel.lua`'s pattern:

  ```lua
  local function BuildFrame()
      if _built then return end
      _built = true
  
      local T = ns.Theme
  
      -- Outer frame
      _frame = CreateFrame("Frame", "BobleLootExplainFrame", UIParent,
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
      local pos = _addon and _addon.db.profile.explainPos
      if pos and pos.point then
          _frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
      else
          _frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
      end
  
      -- Drag + position persistence (titlebar handles the drag; see below)
      _frame:SetScript("OnMouseUp", function(self)
          self:StopMovingOrSizing()
          if _addon then
              local point, _, _, x, y = self:GetPoint()
              _addon.db.profile.explainPos = { point = point, x = x, y = y }
          end
      end)
  
      -- Close on Escape
      _frame:SetScript("OnKeyDown", function(self, key)
          if key == "ESCAPE" then self:Hide() end
      end)
      _frame:SetPropagateKeyboardInput(true)
  
      -- Resize grip (bottom-right corner)
      local grip = CreateFrame("Button", nil, _frame)
      grip:SetSize(16, 16)
      grip:SetPoint("BOTTOMRIGHT", _frame, "BOTTOMRIGHT", -2, 2)
      grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
      grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
      grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
      grip:SetScript("OnMouseDown", function() _frame:StartSizing("BOTTOMRIGHT") end)
      grip:SetScript("OnMouseUp",   function()
          _frame:StopMovingOrSizing()
          if _addon then
              local point, _, _, x, y = _frame:GetPoint()
              _addon.db.profile.explainPos = { point = point, x = x, y = y }
          end
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
          if _addon then
              local point, _, _, x, y = _frame:GetPoint()
              _addon.db.profile.explainPos = { point = point, x = x, y = y }
          end
      end)
  
      -- Cyan underline on title bar
      local titleLine = titleBar:CreateTexture(nil, "OVERLAY")
      titleLine:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
      titleLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
      titleLine:SetHeight(2)
      titleLine:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], T.accent[4])
  
      -- Title text (updated dynamically in Open)
      local titleText = titleBar:CreateFontString(nil, "OVERLAY")
      titleText:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
      titleText:SetTextColor(T.white[1], T.white[2], T.white[3])
      titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
      titleText:SetText("Boble Loot \226\128\148 Explain")
      _frame._titleText = titleText
  
      -- Close button (X) top-right
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
      closeBtn:SetScript("OnClick", function() _frame:Hide() end)
  
      -- ── Content scroll frame ─────────────────────────────────────
      -- Sits between the title bar and the footer button bar.
      local scrollFrame = CreateFrame("ScrollFrame", nil, _frame,
                                      "UIPanelScrollFrameTemplate")
      scrollFrame:SetPoint("TOPLEFT",     _frame, "TOPLEFT",  4, -(TITLEBAR_H + 4))
      scrollFrame:SetPoint("BOTTOMRIGHT", _frame, "BOTTOMRIGHT", -26, FOOTER_H + 4)
      _frame._scrollFrame = scrollFrame
  
      local content = CreateFrame("Frame", nil, scrollFrame)
      content:SetSize(PANEL_W - 30, 600)  -- height grows with text; scroll handles overflow
      scrollFrame:SetScrollChild(content)
      _frame._content = content
  
      -- ── Footer bar (copy-to-chat button) ─────────────────────────
      local footerBar = CreateFrame("Frame", nil, _frame, "BackdropTemplate")
      footerBar:SetPoint("BOTTOMLEFT",  _frame, "BOTTOMLEFT",  0, 0)
      footerBar:SetPoint("BOTTOMRIGHT", _frame, "BOTTOMRIGHT", 0, 0)
      footerBar:SetHeight(FOOTER_H)
      T.ApplyBackdrop(footerBar, "bgTitleBar", "borderNormal")
  
      local copyBtn = CreateFrame("Button", nil, footerBar, "UIPanelButtonTemplate")
      copyBtn:SetSize(130, 22)
      copyBtn:SetPoint("RIGHT", footerBar, "RIGHT", -8, 0)
      copyBtn:SetText("Copy to Chat")
      copyBtn:SetScript("OnClick", function() EP:DoCopyToChat() end)
      _frame._copyBtn = copyBtn
  
      -- Item link button (clickable text in the title bar area, updated in Open)
      -- Anchored left of the close button so it doesn't overlap.
      local itemLinkBtn = CreateFrame("Button", nil, titleBar)
      itemLinkBtn:SetSize(240, TITLEBAR_H)
      itemLinkBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
      local itemLinkTxt = itemLinkBtn:CreateFontString(nil, "OVERLAY")
      itemLinkTxt:SetFont(T.fontBody, T.sizeBody, "OUTLINE")
      itemLinkTxt:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
      itemLinkTxt:SetAllPoints()
      itemLinkTxt:SetJustifyH("RIGHT")
      itemLinkTxt:SetText("")
      itemLinkBtn:SetScript("OnEnter", function(self)
          if _frame._currentItemLink then
              GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
              GameTooltip:SetHyperlink(_frame._currentItemLink)
              GameTooltip:Show()
          end
      end)
      itemLinkBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
      itemLinkBtn:SetScript("OnClick", function()
          if _frame._currentItemLink then
              -- Shift-click inserts into chat editbox; normal click opens
              -- the Blizzard item info popup if available.
              if IsShiftKeyDown() then
                  local editBox = ChatEdit_GetActiveWindow()
                  if editBox then
                      editBox:Insert(_frame._currentItemLink)
                  end
              end
          end
      end)
      _frame._itemLinkTxt = itemLinkTxt
      _frame._itemLinkBtn = itemLinkBtn
  end
  ```

- [ ] 2.3 Add public API stubs (filled in Task 3):

  ```lua
  function EP:Setup(addonArg)
      _addon = addonArg
  end
  
  function EP:Open(name, itemID, itemLink, opts)
      BuildFrame()
      -- (content rendering added in Task 3)
      _frame:Show()
      _frame:Raise()
  end
  
  function EP:Close()
      if _frame then _frame:Hide() end
  end
  
  function EP:DoCopyToChat()
      -- (implemented in Task 5)
  end
  ```

- [ ] 2.4 In-game verification after Task 2: `/run ns = select(2, ...) or _G; if ns.ExplainPanel then ns.ExplainPanel:Open("Test-Realm", 0, nil, {}) end` — a bare panel with no content should appear, be movable, closeable with X and Escape, and sit above the RC voting frame.

---

## Task 3 — Content rendering: four-column breakdown rows

**Files:** `UI/ExplainPanel.lua`

The content area renders: candidate name header, column-header row, one row per
component, excluded-components caveat, and raid-context footer — mirroring the
Batch 1D tooltip layout but using FontStrings in a Frame instead of
`GameTooltip:AddDoubleLine`.

Design note on graceful degradation: `breakdown[key]` may be nil for any component
(same as in the tooltip). Components added by Batch 2A (`role`, `mainspec`) will
appear in `COMPONENT_ORDER` and `COMPONENT_LABEL` when 2A ships; until then they are
simply absent from the breakdown table and are listed under "Excluded (no data)" — no
special-casing required here.

- [ ] 3.1 Add a `RenderContent(name, itemID, itemLink, opts)` local function.
  It clears the `_frame._content` child and rebuilds all FontStrings:

  ```lua
  local function ClearChildren(parent)
      -- Detach and hide all children created by previous renders.
      -- We use a pool stored on _frame._rows to avoid GC churn.
      if _frame._rows then
          for _, fs in ipairs(_frame._rows) do fs:Hide() end
      end
      _frame._rows = {}
  end
  
  local function AddLine(text, r, g, b, yOff)
      -- yOff is relative to the previous line; maintained via _frame._cursorY
      local content = _frame._content
      local fs = content:CreateFontString(nil, "OVERLAY")
      fs:SetFont(ns.Theme.fontBody, ns.Theme.sizeBody)
      fs:SetTextColor(r or 1, g or 1, b or 1, 1)
      fs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, _frame._cursorY)
      fs:SetWidth(content:GetWidth() - 16)
      fs:SetJustifyH("LEFT")
      fs:SetText(text)
      _frame._cursorY = _frame._cursorY - (fs:GetStringHeight() + 2)
      table.insert(_frame._rows, fs)
      return fs
  end
  
  local function AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
      local content = _frame._content
      local T = ns.Theme
      -- Left side
      local lfs = content:CreateFontString(nil, "OVERLAY")
      lfs:SetFont(T.fontBody, T.sizeBody)
      lfs:SetTextColor(lr or 0.9, lg or 0.9, lb or 0.9, 1)
      lfs:SetPoint("TOPLEFT", content, "TOPLEFT", 8, _frame._cursorY)
      lfs:SetWidth((content:GetWidth() - 16) * 0.62)
      lfs:SetJustifyH("LEFT")
      lfs:SetText(left)
      -- Right side
      local rfs = content:CreateFontString(nil, "OVERLAY")
      rfs:SetFont(T.fontBody, T.sizeBody)
      rfs:SetTextColor(rr or 1, rg or 1, rb or 1, 1)
      rfs:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, _frame._cursorY)
      rfs:SetWidth((content:GetWidth() - 16) * 0.38)
      rfs:SetJustifyH("RIGHT")
      rfs:SetText(right)
      local lineH = math.max(lfs:GetStringHeight(), rfs:GetStringHeight()) + 2
      _frame._cursorY = _frame._cursorY - lineH
      table.insert(_frame._rows, lfs)
      table.insert(_frame._rows, rfs)
  end
  ```

- [ ] 3.2 Continue `RenderContent` with the actual rendering logic. Reuse
  `VF.formatRaw` (already exported as `ns.VotingFrame.formatRaw`) and
  `ns.Scoring.COMPONENT_ORDER` / `ns.Scoring.COMPONENT_LABEL`:

  ```lua
  local function RenderContent(name, itemID, itemLink, opts)
      opts = opts or {}
      BuildFrame()
      ClearChildren()
      _frame._cursorY = -4   -- top padding inside content
  
      local T = ns.Theme
      local addon    = _addon
      local inDs     = false
      local s, breakdown
  
      if addon and itemID and itemID > 0 then
          local data = addon:GetData()
          inDs = data and data.characters and data.characters[name] ~= nil
          if inDs then
              s, breakdown = addon:GetScore(itemID, name, {
                  simReference     = opts.simReference,
                  historyReference = opts.historyReference,
              })
          end
      end
  
      -- ── Name + total ──────────────────────────────────────────────
      if not inDs then
          AddLine(string.format("|cffaaaaaa%s|r", name or "?"),
                  T.muted[1], T.muted[2], T.muted[3])
          AddLine("|cffaaaaaa(not in BobleLoot dataset — run tools/wowaudit.py and /reload)|r",
                  T.muted[1], T.muted[2], T.muted[3])
          return
      end
  
      local scoreStr = s and string.format("%.1f / 100", s)
                         or "|cffff7070no data|r"
      AddDoubleLine(
          string.format("|cffffd700%s|r", name or "?"),
          scoreStr,
          1, 0.84, 0,   1, 1, 1)
  
      if not s then
          AddLine("|cffff7070No scoreable components for this candidate/item.|r",
                  T.danger[1], T.danger[2], T.danger[3])
          return
      end
  
      -- Separator
      AddLine("|cff444444" .. string.rep("\xe2\x80\x94", 32) .. "|r",
              0.27, 0.27, 0.27)
  
      -- Column header
      AddDoubleLine(
          "|cff666666Component               (raw stat)|r",
          "|cff666666wt%    norm   =  pts|r",
          1, 1, 1,  1, 1, 1)
  
      -- One row per component
      local order  = ns.Scoring.COMPONENT_ORDER
      local labels = ns.Scoring.COMPONENT_LABEL
      local weights = addon.db and addon.db.profile and addon.db.profile.weights or {}
      local totalConfigW = 0
      for _, key in ipairs(order) do
          totalConfigW = totalConfigW + (weights[key] or 0)
      end
  
      local excluded = {}
      for _, key in ipairs(order) do
          local e = breakdown[key]
          if e then
              local rawStr = ns.VotingFrame and ns.VotingFrame.formatRaw
                             and ns.VotingFrame.formatRaw(key, e)
                             or tostring(e.raw or "-")
              local left  = string.format("%s |cff666666(%s)|r",
                                labels[key] or key, rawStr)
              local right = string.format(
                  "|cffcccccc%2.0f%%|r  |cff6699ff%.2f|r  |cff888888=|r  |cffffffff%4.1f|r",
                  (e.effectiveWeight or 0) * 100,
                  e.value or 0,
                  e.contribution or 0)
              AddDoubleLine(left, right, 0.9, 0.9, 0.9, 1, 1, 1)
          else
              table.insert(excluded, labels[key] or key)
          end
      end
  
      -- Excluded / renorm caveat
      if #excluded > 0 then
          AddLine(" ", 1, 1, 1)
          if #excluded >= 2 then
              AddLine("|cff808080Excluded (no data): "
                      .. table.concat(excluded, ", ") .. "|r",
                      T.muted[1], T.muted[2], T.muted[3])
              local activeW = 0
              for _, key in ipairs(order) do
                  if breakdown[key] then
                      activeW = activeW + (weights[key] or 0)
                  end
              end
              if totalConfigW > 0 and activeW < totalConfigW then
                  local pct = math.floor(activeW / totalConfigW * 100 + 0.5)
                  AddLine(string.format(
                      "|cff808080Score over %d%% of configured weights.|r", pct),
                      T.muted[1], T.muted[2], T.muted[3])
              end
          else
              AddLine("|cff666666Excluded (no data): "
                      .. table.concat(excluded, ", ") .. "|r",
                      T.muted[1], T.muted[2], T.muted[3])
          end
      end
  
      -- ── Raid-context footer ───────────────────────────────────────
      local median = opts.sessionMedian
      local max    = opts.sessionMax
      if median or max then
          AddLine(" ", 1, 1, 1)
          local parts = {}
          if median then
              table.insert(parts, string.format(
                  "Median |cffffffff%d|r", math.floor(median + 0.5)))
          end
          if max then
              table.insert(parts, string.format(
                  "Max |cffffffff%d|r", math.floor(max + 0.5)))
          end
          if s then
              table.insert(parts, string.format(
                  "This: |cffffffff%d|r", math.floor(s + 0.5)))
          end
          AddLine("|cffaaaaaa" .. table.concat(parts, " | ") .. "|r",
                  T.muted[1], T.muted[2], T.muted[3])
      end
  
      -- Adjust content frame height so scroll range is accurate
      _frame._content:SetHeight(math.abs(_frame._cursorY) + 8)
  end
  ```

- [ ] 3.3 Update `EP:Open` to call `RenderContent` and store state needed by
  `DoCopyToChat`:

  ```lua
  function EP:Open(name, itemID, itemLink, opts)
      BuildFrame()
  
      -- Update item link display in title bar
      local T = ns.Theme
      if itemLink and itemLink ~= "" then
          _frame._itemLinkTxt:SetText(itemLink)
          _frame._currentItemLink = itemLink
      else
          _frame._itemLinkTxt:SetText(
              itemID and ("[Item " .. itemID .. "]") or "")
          _frame._currentItemLink = nil
      end
  
      -- Panel title: "Boble Loot — <Name> on [Item]"
      local itemLabel = itemLink or (itemID and ("[Item " .. itemID .. "]")) or "?"
      _frame._titleText:SetText(string.format(
          "Boble Loot \226\128\148 %s on %s",
          name or "?", itemLabel))
  
      -- Stash state for DoCopyToChat
      _frame._candidateName = name
      _frame._itemID        = itemID
      _frame._itemLink      = itemLink
      _frame._opts          = opts or {}
  
      RenderContent(name, itemID, itemLink, opts)
      _frame:Show()
      _frame:Raise()
  end
  ```

- [ ] 3.4 In-game verification:
  - `/bl explain Boble-Doomhammer` (with no active RC session) — panel opens,
    shows the name in the title, component rows render (or "not in dataset"
    message if the name isn't in the data file), no raid-context footer.
  - If the name is in the dataset but `itemID = 0`, score will be nil and
    the "No scoreable components" message appears — confirm graceful handling.

---

## Task 4 — Register `ExplainPanel` in `BobleLoot.toc` and `Core.lua`

**Files:** `BobleLoot.toc`, `Core.lua`

The TOC must load `UI/ExplainPanel.lua` after `VotingFrame.lua` (it calls
`ns.VotingFrame.formatRaw`) and after `UI/Theme.lua`.

- [ ] 4.1 Open `BobleLoot.toc`. After the line `UI\MinimapButton.lua` add:

  ```
  UI\ExplainPanel.lua
  ```

- [ ] 4.2 Open `Core.lua`. In `OnInitialize`, after the `SettingsPanel:Setup(self)`
  call, add:

  ```lua
  if ns.ExplainPanel and ns.ExplainPanel.Setup then
      ns.ExplainPanel:Setup(self)
  end
  ```

- [ ] 4.3 Commit: `feat(ExplainPanel): add TOC entry and OnInitialize setup hook`

---

## Task 5 — Slash command `/bl explain <Name-Realm>`

**Files:** `Core.lua`

When the RC voting frame is open, the command obtains the current session's item and
the session stats (median/max). When it is not open, it still opens the panel with
whatever score data is available, but without the raid-context footer.

- [ ] 5.1 In `Core.lua`'s `OnSlashCommand` handler, insert a new `elseif` clause
  **before** the fallthrough `else` branch:

  ```lua
  elseif input:match("^explain%s+") then
      local name = input:match("^explain%s+(.+)$")
      if not name or name == "" then
          self:Print("Usage: /bl explain <Name-Realm>")
          return
      end
      -- Trim trailing whitespace
      name = name:match("^(.-)%s*$")
  
      local itemID, itemLink, simRef, histRef, sessionMedian, sessionMax
  
      -- Try to pull current session data from the RC voting frame
      local VF = ns.VotingFrame
      if VF and VF.rcVoting and VF.addon then
          local rcVoting = VF.rcVoting
          local session  = rcVoting.GetCurrentSession
                           and rcVoting:GetCurrentSession()
                           or rcVoting.session
          if session then
              local lt = rcVoting.GetLootTable and rcVoting:GetLootTable()
              if lt and lt[session] then
                  local entry = lt[session]
                  if entry.link then
                      itemID   = tonumber(entry.link:match("item:(%d+)"))
                      itemLink = entry.link
                  end
                  itemID   = itemID or entry.id or entry.itemID
              end
              -- Session stats (median/max) come from VF's internal
              -- computeSessionStats — we expose a helper below.
              if VF.GetSessionStats then
                  sessionMedian, sessionMax = VF:GetSessionStats()
              end
          end
      end
  
      if ns.ExplainPanel and ns.ExplainPanel.Open then
          ns.ExplainPanel:Open(name, itemID or 0, itemLink, {
              simReference     = simRef,
              historyReference = histRef,
              sessionMedian    = sessionMedian,
              sessionMax       = sessionMax,
          })
      else
          self:Print("ExplainPanel not loaded.")
      end
  ```

- [ ] 5.2 Update the usage string printed in the fallthrough `else` to include
  `explain`:

  ```lua
  self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | " ..
      "/bl transparency on|off | /bl checkdata | /bl lootdb | " ..
      "/bl debugchar <Name-Realm> | /bl test [N] | " ..
      "/bl score <itemID> <Name-Realm> | /bl syncwarnings | " ..
      "/bl explain <Name-Realm>")
  ```

- [ ] 5.3 In `VotingFrame.lua`, export a `GetSessionStats` helper so `Core.lua` can
  read the cached median/max without reaching into private locals:

  ```lua
  function VF:GetSessionStats()
      return _sessionStats.median, _sessionStats.max
  end
  ```

  Add this near the other public exports (`VF.formatRaw`).

- [ ] 5.4 In-game verification:
  - `/bl explain` (no name) → prints usage.
  - `/bl explain Boble-Doomhammer` with no RC session open → panel opens,
    title shows "Boble Loot — Boble-Doomhammer on ?", no footer.
  - Same command while the RC voting frame is open on an item → panel shows
    the item link and footer.

- [ ] 5.5 Commit: `feat(Core): add /bl explain subcommand; export VF:GetSessionStats`

---

## Task 6 — Right-click handler on the score cell in `VotingFrame.lua`

**Files:** `VotingFrame.lua`

RC uses `lib-st` (ScrollingTable). `doCellUpdate` sets `OnEnter` / `OnLeave` on
`cellFrame`. Add `OnMouseUp` to detect right-click and open the panel. Use
`OnMouseUp` rather than `OnMouseDown` so a drag-to-resize is not intercepted.

- [ ] 6.1 In `doCellUpdate`, immediately after the block that sets `cellFrame:SetScript("OnLeave", ...)`, add:

  ```lua
  cellFrame:SetScript("OnMouseUp", function(self, button)
      if button == "RightButton" then
          if ns.ExplainPanel and ns.ExplainPanel.Open then
              local med, mx = computeSessionStats(rcVoting, addon, session, data)
              local iLink
              if rcVoting.GetLootTable then
                  local lt = rcVoting:GetLootTable()
                  if lt and lt[session] then
                      iLink = lt[session].link
                  end
              end
              ns.ExplainPanel:Open(name, itemID or 0, iLink, {
                  simReference     = simRef,
                  historyReference = histRef,
                  sessionMedian    = med,
                  sessionMax       = mx,
              })
          end
      end
  end)
  ```

  Note: `name`, `itemID`, `simRef`, `histRef`, `session`, `data`,
  `rcVoting`, `addon` are all already in scope inside `doCellUpdate`.

- [ ] 6.2 In-game verification:
  - Open the RC voting frame on a real or test item (use `/bl test 1`).
  - Right-click a score cell row — the Explain panel should open for that
    candidate, showing the item link in the title and the footer median/max.
  - Left-click should still show the hover tooltip normally.

- [ ] 6.3 Commit: `feat(VotingFrame): add right-click handler on score cell to open ExplainPanel`

---

## Task 7 — Copy-to-chat action

**Files:** `UI/ExplainPanel.lua`

Format: `[BL] <Name> on [Item]: sim=X bis=X hist=X att=X m+=X = <score>`

The function posts to `OFFICER` if available (player is in a guild and officer rank
has access), otherwise falls back to `PARTY`. If neither channel is joined it prints
to the chat frame with a note.

- [ ] 7.1 Implement `EP:DoCopyToChat()`:

  ```lua
  function EP:DoCopyToChat()
      if not _frame or not _frame._candidateName then return end
  
      local name   = _frame._candidateName
      local itemID = _frame._itemID or 0
      local opts   = _frame._opts or {}
  
      local s, breakdown
      if _addon and itemID > 0 then
          s, breakdown = _addon:GetScore(itemID, name, {
              simReference     = opts.simReference,
              historyReference = opts.historyReference,
          })
      end
  
      local order  = ns.Scoring and ns.Scoring.COMPONENT_ORDER
                     or { "sim", "bis", "history", "attendance", "mplus" }
      local keys   = { sim="sim", bis="bis", history="hist",
                       attendance="att", mplus="m+" }
      local parts  = {}
      if breakdown then
          for _, key in ipairs(order) do
              local e = breakdown[key]
              if e then
                  local short = keys[key] or key
                  table.insert(parts, string.format("%s=%.1f",
                      short, e.contribution or 0))
              end
          end
      end
  
      local itemLabel = _frame._itemLink
                        or (itemID > 0 and ("[Item " .. itemID .. "]"))
                        or "?"
      local scoreLabel = s and string.format("%.0f", s) or "?"
      local msg = string.format("[BL] %s on %s: %s = %s",
          name, itemLabel,
          table.concat(parts, " "),
          scoreLabel)
  
      -- Channel selection: OFFICER > PARTY > chat print
      local sent = false
      if IsInGuild() then
          -- OFFICER channel requires no explicit join; available if rank permits.
          local ok = pcall(SendChatMessage, msg, "OFFICER")
          if ok then sent = true end
      end
      if not sent and (IsInGroup() or IsInRaid()) then
          local channel = IsInRaid() and "RAID" or "PARTY"
          local ok = pcall(SendChatMessage, msg, channel)
          if ok then sent = true end
      end
      if not sent then
          -- Last resort: print to DEFAULT_CHAT_FRAME with a note.
          DEFAULT_CHAT_FRAME:AddMessage(
              "|cff33d9f2[BobleLoot]|r No officer/party channel available. "
              .. "Message would have been: " .. msg)
      end
  end
  ```

- [ ] 7.2 In-game verification:
  - Open panel for a known candidate. Click "Copy to Chat".
  - While in a group: confirm the message appears in party/raid chat with
    the correct format.
  - While in a guild but not a group: confirm message posts to officer channel
    or prints to chat frame gracefully if officer access is denied.
  - While solo: confirm the fallback chat-frame message appears with the
    formatted breakdown.

- [ ] 7.3 Commit: `feat(ExplainPanel): implement copy-to-chat with officer/party/fallback`

---

## Task 8 — MinimapButton: optional "Explain last" menu item

**Files:** `UI/MinimapButton.lua`

Decision: YES — add a menu item. The minimap button is the addon's primary quick-access
surface and "explain last candidate I looked at" is a one-click convenience that
serves the council workflow without cluttering the menu.

The item is disabled when no previous `Open` call has been made (i.e. `_frame` is nil
or `_frame._candidateName` is nil).

- [ ] 8.1 Open `UI/MinimapButton.lua`. In `MB:ShowDropdown()`, locate the separator
  line just before "Open settings". Insert a new entry before it:

  ```lua
  -- Explain last (opens ExplainPanel for the last-viewed candidate)
  {
      text = "Explain last candidate",
      notCheckable = true,
      disabled = not (ns.ExplainPanel
                      and ns.ExplainPanel.HasLast
                      and ns.ExplainPanel:HasLast()),
      func = function()
          if ns.ExplainPanel and ns.ExplainPanel.ReopenLast then
              ns.ExplainPanel:ReopenLast()
          end
      end,
  },
  ```

- [ ] 8.2 In `UI/ExplainPanel.lua`, add two helpers:

  ```lua
  --- Returns true if a previous Open call populated the frame state.
  function EP:HasLast()
      return _frame ~= nil
             and _frame._candidateName ~= nil
             and _frame._candidateName ~= ""
  end
  
  --- Re-opens the panel with whatever was last passed to Open.
  function EP:ReopenLast()
      if not self:HasLast() then return end
      _frame:Show()
      _frame:Raise()
  end
  ```

  `ReopenLast` does not re-render; it just un-hides the frame. The content
  is already populated from the last `Open` call. If a full re-render were
  needed (e.g. after a `/reload`), `HasLast` would return false because
  `_frame` is nil — a new `Open` call is required, which is correct.

- [ ] 8.3 In-game verification:
  - Open the minimap dropdown before any `Open` call — "Explain last candidate"
    should be greyed out / disabled.
  - Open the panel via right-click, close it, then open the dropdown — item
    should be enabled and clicking it should re-show the panel.

- [ ] 8.4 Commit: `feat(MinimapButton): add "Explain last candidate" menu item`

---

## Task 9 — Integration pass and position-restore smoke test

**Files:** `UI/ExplainPanel.lua`

Verify the full round-trip: open panel, move it, close it, reopen — position is
preserved from `BobleLootDB.profile.explainPos`.

- [ ] 9.1 Confirm `BuildFrame()` reads `explainPos` correctly. The `pos.point` should
  be a valid anchor string like `"CENTER"` or `"TOPLEFT"`. If it is invalid
  (corrupted save), fall back to `CENTER`:

  ```lua
  -- Inside BuildFrame(), replace the restore block with:
  local pos = _addon and _addon.db and _addon.db.profile
              and _addon.db.profile.explainPos
  local validPoints = {
      CENTER=true, TOP=true, BOTTOM=true, LEFT=true, RIGHT=true,
      TOPLEFT=true, TOPRIGHT=true, BOTTOMLEFT=true, BOTTOMRIGHT=true,
  }
  if pos and pos.point and validPoints[pos.point] then
      _frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
  else
      _frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  ```

- [ ] 9.2 Transparency toggle guard: the Explain panel shows council-side data
  (computed from the local `BobleLoot_Data` file). It is not affected by the
  transparency toggle (`addon:IsTransparencyEnabled()`). No guard is needed;
  document this explicitly with a comment near `RenderContent`:

  ```lua
  -- NOTE: ExplainPanel always renders council-side scores (from BobleLoot_Data).
  -- It is NOT affected by the transparency mode toggle, which only controls
  -- whether the leader's scores are broadcast to raiders' LootFrame.
  -- No transparency check is required here.
  ```

- [ ] 9.3 Full integration checklist in-game (all four scenarios from the spec):

  a. `/bl explain Boble-Doomhammer` with no active RC session → panel opens,
     header shows Name-Realm, components render without footer, copy-to-chat
     produces a valid message.

  b. Right-click score cell in RC voting frame → panel opens for that candidate
     + item, footer shows median/max.

  c. Open panel, drag to new position, close, reopen (same session) — position
     persists. `/reload`, reopen — position still persists.

  d. Open panel, raid leader toggles transparency mode — panel contents do not
     change.

  e. Copy-to-chat with no officer channel available → graceful fallback message
     in chat frame.

- [ ] 9.4 Commit: `feat(ExplainPanel): position-restore guard + transparency note`

---

## Task 10 — Final TOC wiring and release prep

**Files:** `BobleLoot.toc`

Confirm the full TOC load order is correct:

```
Libs\Libs.xml
Data\BobleLoot_Data.lua
Core.lua
Scoring.lua
Sync.lua
VotingFrame.lua
LootFrame.lua
RaidReminder.lua
LootHistory.lua
TestRunner.lua
UI\Theme.lua
UI\SettingsPanel.lua
UI\MinimapButton.lua
UI\ExplainPanel.lua   ← must be last; depends on VotingFrame and Theme
```

- [ ] 10.1 Verify `UI/ExplainPanel.lua` is the last entry.

- [ ] 10.2 Bump `BobleLoot.version` in `Core.lua` to `"1.2.0-dev"` to mark the
  Batch 2 development state (will be finalized at release).

- [ ] 10.3 Final `/reload` smoke test: load order error-free, no Lua errors in
  chat frame, all API stubs available (`/run print(ns.ExplainPanel)`).

- [ ] 10.4 Commit: `chore: bump version to 1.2.0-dev; confirm TOC load order`

---

## Manual Verification Checklist

Use these in-game steps to sign off before merging to `release/v1.2.0`.

- [ ] **No RC session open** — `/bl explain Boble-Doomhammer`: panel opens, title bar
  shows candidate name, item shows "?", breakdown renders, no Median/Max footer.
- [ ] **No RC session + name not in dataset** — `/bl explain Nobody-Realm`: panel
  opens with "not in BobleLoot dataset" message; no Lua error.
- [ ] **RC voting frame open** — right-click any score cell: panel opens for that
  row's candidate and the current session item; title shows item link as clickable
  text; footer shows Median/Max.
- [ ] **Item link clickable** — hover over item link text in title bar: Blizzard item
  tooltip appears. Shift-click inserts the link into the active chat editbox.
- [ ] **Position persistence** — move panel, close with X, reopen with `/bl explain`:
  panel returns to saved position. `/reload`, reopen — still correct.
- [ ] **Min size** — drag the resize grip to make the panel smaller than 480 × 360:
  frame refuses to go below minimum.
- [ ] **Single instance** — `/bl explain Boble-Doomhammer`, then
  `/bl explain OtherRaider-Realm`: same frame reuses and refreshes content;
  no second frame appears.
- [ ] **Strata** — confirm panel renders above the RC voting frame (which is
  `MEDIUM` strata); both can be visible simultaneously without z-order fight.
- [ ] **Copy to chat (officer)** — in a guild with officer permissions: click
  "Copy to Chat"; confirm formatted message in officer channel.
- [ ] **Copy to chat (party)** — in a group, not officer: confirm message goes to
  party/raid channel.
- [ ] **Copy to chat (solo)** — confirm fallback message appears in chat frame; no
  Lua error.
- [ ] **Transparency toggle** — open panel, have raid leader toggle transparency:
  panel contents do not change, no Lua error.
- [ ] **Minimap "Explain last"** — disabled before any Open call; enabled and
  functional after.
- [ ] **Escape key** — with panel focused, pressing Escape closes it; does not
  propagate to close the RC voting frame erroneously (`SetPropagateKeyboardInput(true)`
  passes Escape up to default handlers after our close).

---

## Design Notes

**Why single instance (not multiple concurrent windows)?**

Council debates involve one item at a time. Multiple windows would drift out of
sync with the current session item, misleading voters. The single-frame reuse
pattern matches how Blizzard's own inspector frames work (e.g. the character
inspect window) and avoids the frame-registry leak risk of dynamically creating
frames. The minimap "Explain last" item and the panel's own close/reopen cycle
both benefit from guaranteed frame identity.

**Why strata `HIGH`?**

RC's `RCVotingFrame` is `MEDIUM` strata. The explain panel exists precisely to sit
alongside the voting frame while a council argument is in progress — it must not
disappear behind it. `HIGH` is the appropriate level: it is above UI panels but
below `DIALOG` (which is reserved for blocking confirmation prompts). `TOOLTIP`
strata is intentionally avoided because it would suppress GameTooltip for any
frame beneath it.

**Why copy-to-chat over export-to-file?**

WoW's addon API has no general filesystem write access. File export would require
either a SavedVariable round-trip (requiring a `/reload` to commit) or a macro
text workaround, neither of which serves the "real-time council transcript" use
case. Chat is the medium the council already uses; posting to the officer channel
keeps the decision record in the same stream as the verbal discussion. The compact
`[BL] Name on [Item]: sim=X bis=X ... = 74` format is parseable, tweetable, and
fits in one chat line.

**Why `OFFICER` channel as the first target?**

The explain panel is a council tool, not a raider-facing surface. The officer
channel is the natural transcript location: it is private (raiders don't see it),
persistent in chat logs, and requires no special setup. Raiding leaders who want
the breakdown in the raid channel can copy-paste; that is a deliberate friction
that prevents score spam in the main raid channel during voting.

---

## Coordination Notes

### Batch 2A (`role` / `mainspec` fields)

Batch 2A adds `role` and `mainspec` fields to the data file and may add new
component keys (or modify how the sim component is computed per-spec). The
rendering in `RenderContent` iterates `ns.Scoring.COMPONENT_ORDER` — the same
exported constant that 2A will update when it adds new component keys. No
changes to `ExplainPanel.lua` are required for 2A's new fields to surface, as
long as 2A:

1. Adds any new component key to `COMPONENT_ORDER`.
2. Adds a human-readable entry for it in `COMPONENT_LABEL`.
3. Adds a `formatRaw` branch for it in `VotingFrame.lua`.

Until 2A ships, `role` and `mainspec` will not appear in the breakdown table and
will be silently listed under "Excluded (no data)" — the same graceful degradation
path used for any missing component. No `ExplainPanel.lua` changes needed at 2A
ship time.

If 2A adds a per-role history-weight multiplier that changes the effective weight
display, `entry.effectiveWeight` in the breakdown table will automatically reflect
the adjusted value because `Scoring:Compute` folds renormalized effective weights
into the breakdown before returning. The four-column display (`wt%`) will show the
correct renormalized percentage with no ExplainPanel changes.

### Batch 2E (conflict indicator `~` prefix + transparency compact label)

Batch 2E (items 2.10 and 2.11) introduces a conflict-threshold concept: two
candidates within a configurable point window are marked with `~`. Surfacing this
indicator in the Explain panel header ("within conflict threshold of top candidate")
is a reasonable stretch goal for 2E's implementer.

The coordination contract: if 2E exposes a `ns.VotingFrame.IsWithinConflict(name, session)` helper, then `RenderContent` can optionally prepend a one-line
notice: `|cffffaa00~ Within conflict threshold of the top-ranked candidate.|r`
placed just below the name/score line. This is optional and guarded with a nil
check — if the 2E helper does not exist, no notice appears and no error is raised.
`ExplainPanel.lua` does not need to know the threshold value itself.

```lua
-- In RenderContent, after the name/score AddDoubleLine:
if ns.VotingFrame and ns.VotingFrame.IsWithinConflict then
    local VF2 = ns.VotingFrame
    local rcV = VF2.rcVoting
    local sess = rcV and rcV.GetCurrentSession and rcV:GetCurrentSession()
    if sess and VF2:IsWithinConflict(name, sess) then
        AddLine("|cffffaa00~ Within conflict threshold of the top-ranked candidate.|r",
                1, 0.67, 0)
    end
end
```

This snippet can be added to `RenderContent` at any time; it is safe to land in 2D
before 2E ships because the nil guard keeps it inert.
