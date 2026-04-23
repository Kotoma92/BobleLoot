# Batch 3D — Council Decision UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two council decision-support surfaces — a shift-click side-by-side candidate comparison popout (3.9) and a ghost-weights toggle button on the score column header (3.10) — that let the raid leader answer "why is A ranked above B?" and "would Farm weights change the call?" without leaving the RC voting frame.

**Architecture:** A new `UI/ComparePopout.lua` module owns the single-instance comparison frame (480x320 min, movable and resizable, strata HIGH, BackdropTemplate chrome matching Batch 2D's ExplainPanel conventions but fully independent). `VotingFrame.lua` receives a shift-click handler wired into the existing `doCellUpdate` cell scripts, a ghost-weights toggle button anchored to the score column header, and an alternate rendering path that calls `Scoring:ComputeAll` (or falls back to per-candidate `Scoring:Compute`) with a swapped weight table when ghost mode is active. `Core.lua` grows two new `DB_DEFAULTS` entries (`ghostPresets` and `comparePos`). `UI/SettingsPanel.lua` receives a small Ghost Presets section inside the Tuning tab.

**Tech Stack:** Lua 5.1 (WoW 10.x environment), raw `BackdropTemplate` frames (same pattern as `UI/SettingsPanel.lua` and Batch 2D's `UI/ExplainPanel.lua`), `ns.Theme` palette, `ns.Scoring.COMPONENT_ORDER` / `COMPONENT_LABEL`, `VF.formatRaw`, `ns.Scoring:ComputeAll` (3B) or graceful per-candidate fallback.

**Roadmap items covered:**

> **3.9 `[UI]` Side-by-side candidate comparison popout**
>
> Shift-click on a score cell opens a resizable movable AceGUI frame
> (480x320) showing two columns — the clicked candidate and the
> currently-sorted-top candidate. Each component rendered as a bar scaled
> to its full weight. Differential (`+7.2 pts`) highlighted on the row
> with the largest gap. Directly answers "why is A ranked above B?"
> without mental arithmetic.

> **3.10 `[UI]` Ghost weights preview button**
>
> Small button anchored to the score column header. Toggles rendering
> under an alternate weight preset (default "Farm" — tunable in Settings).
> Recomputation is local and instant; no network traffic. Two-second
> sanity check of "would our farm weights change the call?"

**Dependencies:**
- Batch 1D — `ns.Scoring.COMPONENT_ORDER`, `ns.Scoring.COMPONENT_LABEL`, `VF.formatRaw`, `doCellUpdate` per-render pass, `_sessionStats` cache, `bidderNames`, `simReferenceFor`, `historyReferenceFor`.
- Batch 1E — `ns.Theme` palette (`accent`, `bgBase`, `bgTitleBar`, `bgSurface`, `borderNormal`, `borderAccent`, `muted`, `white`, `danger`, `success`), `Theme.ApplyBackdrop`, `SettingsPanel.lua` chrome conventions (movable titlebar, cyan underline, hover-red close button, position persistence).
- Batch 2D (style reference only) — `UI/ExplainPanel.lua` is the chrome template. Do NOT import from it; replicate the shell pattern independently in `UI/ComparePopout.lua`.
- Batch 3B — `ns.Scoring:ComputeAll(itemID)` returning a sorted `{ name, score, breakdown }` list. If not yet merged, ghost-weights re-render falls back to iterating `bidderNames` and calling `Scoring:Compute` individually (documented in Task 7).

---

## File Structure

```
UI/
  ComparePopout.lua       -- NEW — comparison popout module (3.9)
VotingFrame.lua           -- MODIFIED — shift-click handler; ghost-weights button;
                          --            ghost alternate render path
Core.lua                  -- MODIFIED — DB_DEFAULTS: ghostPresets, comparePos
UI/SettingsPanel.lua      -- MODIFIED — Ghost Presets editor section in Tuning tab
BobleLoot.toc             -- MODIFIED — add UI/ComparePopout.lua load line
```

No new external libraries required. `BackdropTemplate` is a Blizzard built-in. All scoring primitives are already in `Scoring.lua`.

---

## Task 1 — DB schema: add `comparePos` and `ghostPresets` in `Core.lua`

**Files:** `Core.lua`

AceDB merges `DB_DEFAULTS` at first load, so new keys appear automatically on existing installs without a migration. Add both entries in the same commit.

- [ ] 1.1 Open `Core.lua` on the working branch (based on `release/v1.1.0`). Locate the `DB_DEFAULTS` table — the `panelPos` and `lastTab` entries near the end of the `profile` block. After `panelPos` add:

  ```lua
  comparePos = { point = "CENTER", x = 0, y = 80 },
  ```

- [ ] 1.2 Immediately after `comparePos`, add the `ghostPresets` block:

  ```lua
  ghostPresets = {
      -- "prog" mirrors the user's live weights at first load.
      -- Seeded at startup from db.profile.weights if weights differ.
      prog = {
          sim        = 0.40,
          bis        = 0.20,
          history    = 0.15,
          attendance = 0.15,
          mplus      = 0.10,
      },
      -- "farm" preset: history-heavy for loot-equity-focused decisions.
      farm = {
          sim        = 0.30,
          bis        = 0.10,
          history    = 0.40,
          attendance = 0.15,
          mplus      = 0.05,
      },
      -- activeGhostPreset: which preset the toggle button applies.
      activeGhostPreset = "farm",
  },
  ```

  Note: `prog` weights are seeded here as the v1.1.0 defaults. `OnEnable` (Task 2) will overwrite `ghostPresets.prog` with the current `db.profile.weights` so they stay in sync with whatever the user configured.

- [ ] 1.3 In `BobleLoot:OnEnable()`, after the existing module `Setup` calls, add a one-time sync of live weights into the prog preset:

  ```lua
  -- Keep the "prog" ghost preset in sync with the user's current weights
  -- so it accurately mirrors their live configuration on first load.
  local gp = self.db.profile.ghostPresets
  local lw = self.db.profile.weights
  if gp and lw then
      for k, v in pairs(lw) do
          gp.prog[k] = v
      end
  end
  ```

- [ ] 1.4 In-game verification: `/reload`, then:
  ```
  /run print(BobleLoot.db.profile.comparePos.point)
  /run print(BobleLoot.db.profile.ghostPresets.farm.history)
  /run print(BobleLoot.db.profile.ghostPresets.activeGhostPreset)
  ```
  Expected output: `CENTER`, `0.4`, `farm`.

- [ ] 1.5 Commit: `feat(Core): add comparePos and ghostPresets to DB_DEFAULTS`

---

## Task 2 — Create `UI/ComparePopout.lua` — frame shell

**Files:** `UI/ComparePopout.lua` (new)

Build the outer frame using the same shell conventions as `UI/SettingsPanel.lua` and Batch 2D's `ExplainPanel.lua`: dark `bgBase` backdrop, `borderNormal` edge, `bgTitleBar` titlebar with cyan underline, hover-red close button, movable via titlebar drag, position saved to `addon.db.profile.comparePos`, `SetClampedToScreen(true)`, strata `HIGH`. Panel title format: `"BobleLoot — <A> vs <B> on [Item]"`.

- [ ] 2.1 Create `UI/ComparePopout.lua`:

  ```lua
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
  ```

- [ ] 2.2 Add `BuildFrame()`:

  ```lua
  local function BuildFrame()
      if _built then return end
      _built = true
  
      local T = ns.Theme
  
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
      titleText:SetText("BobleLoot — Compare")
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
  ```

- [ ] 2.3 Add public API stubs (Open/Close/IsShown/Setup — content filled in Task 4):

  ```lua
  function CP:Setup(addon)
      _addon = addon
  end
  
  function CP:Close()
      if _frame then _frame:Hide() end
  end
  
  function CP:IsShown()
      return _frame and _frame:IsShown() or false
  end
  
  -- Open is implemented in Task 4 after bar rendering helpers exist.
  ```

- [ ] 2.4 In-game verification (after TOC wired in Task 3): `/run ns = select(2, ...) ns.ComparePopout:Open("A-Realm","B-Realm",0,nil,{})` — bare frame should appear at screen center, be movable, closeable with X and Escape.

- [ ] 2.5 Commit: `feat(ComparePopout): add frame shell with titlebar, chrome, position persistence`

---

## Task 3 — TOC: register `UI/ComparePopout.lua`

**Files:** `BobleLoot.toc`

- [ ] 3.1 Open `BobleLoot.toc`. After the `UI\Theme.lua` line and before `UI\SettingsPanel.lua`, add:

  ```
  UI\ComparePopout.lua
  ```

  `ComparePopout.lua` must load after `Theme.lua` (it uses `ns.Theme`) and before `VotingFrame.lua` is ever called, which is guaranteed since TOC load order places all `UI\` files before game events fire.

- [ ] 3.2 Also add `ComparePopout:Setup` call in `Core.lua:OnEnable()`, alongside the other module setups:

  ```lua
  if ns.ComparePopout and ns.ComparePopout.Setup then
      ns.ComparePopout:Setup(self)
  end
  ```

- [ ] 3.3 In-game verification: `/reload` produces no Lua errors. `/run print(ns.ComparePopout)` prints a table reference.

- [ ] 3.4 Commit: `feat(toc): register UI/ComparePopout.lua load and Setup wiring`

---

## Task 4 — Comparison bar rendering in `ComparePopout.lua`

**Files:** `UI/ComparePopout.lua`

Each component row renders as two horizontal bars side-by-side — one for candidate A (left column), one for candidate B (right column). Bars are scaled relative to the component's full configured weight (not relative to each other), so a bar filling 100% of the allotted width means "this candidate's contribution equals the maximum possible from this component." The differential label (`+7.2 pts`) is rendered on the row with the largest absolute gap and highlighted in `Theme.accent` cyan.

Bar width formula for candidate X on component `k`:
```
barWidth = (colWidth - 2*COL_PAD) * (contribution_k / maxContribution_k)
```
where `maxContribution_k = weight_k * 100` (the component's ceiling in score-points terms, since a fully-valued component contributes `weight * 100` points before renormalization).

- [ ] 4.1 Add helper `BuildBarRow(content, yOffset, label, contribA, contribB, maxContrib, isLargestGap)` that creates one row's UI objects and returns them:

  ```lua
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
          bg:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, yOffset)
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
      local bgA, fillA, ptsA = makeBar(content, 0,     contribA, colorA)
      bgA:SetPoint("TOPLEFT", content, "TOPLEFT", COL_PAD, yOffset - 16)
      -- Right column offset
      local bgB, fillB, ptsB = makeBar(content, halfW + COL_PAD,
                                        contribB, colorB)
      bgB:SetPoint("TOPLEFT", content, "TOPLEFT", halfW + COL_PAD, yOffset - 16)
  
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
          diffLabel:SetPoint("TOP", content, "TOP",
                             halfW * 0.5 - (halfW * 0.5), yOffset - 16)
          -- Center it horizontally at the column boundary
          diffLabel:SetPoint("CENTER", content, "TOPLEFT",
                             halfW, yOffset - 16 - BAR_H * 0.5)
      end
  
      return BAR_H + BAR_GAP + 16  -- total row height (label + bar + gap)
  end
  ```

- [ ] 4.2 Add `RenderCompare(nameA, nameB, itemID, opts)` which scores both candidates and delegates to `BuildBarRow`:

  ```lua
  local function ClearBarRows(content)
      -- Destroy all children except _frame._titleText (not a child of content).
      -- WoW has no DestroyChildren; we keep a pool list and hide/nil.
      -- Simplest correct approach: recreate the content frame each Open call.
      -- We do this by hiding and re-parenting in Open().
  end
  
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
  
      -- Destroy previous content by replacing the content frame.
      local content = _frame._content
      -- Wipe child objects: simplest reliable approach in WoW Lua.
      for _, obj in ipairs(_frame._barRows or {}) do
          if obj.Hide then obj:Hide() end
      end
      _frame._barRows = {}
  
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
          sfs:SetText(score and string.format("%.1f / 100", score) or "|cffaaaaaa—|r")
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
  ```

- [ ] 4.3 Implement `CP:Open(nameA, nameB, itemID, itemLink, opts)`:

  ```lua
  function CP:Open(nameA, nameB, itemID, itemLink, opts)
      BuildFrame()
  
      -- Update title: "BobleLoot — <A> vs <B> on [Item]"
      local T = ns.Theme
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
  ```

- [ ] 4.4 In-game verification: run a test session with 5 candidates → shift-click score cell on candidate A → popout opens. Both columns render with bars, component labels on the left, contribution values (pts) beside each bar. Confirm the differential line appears on the row with the biggest gap. Close and shift-click a different candidate → same frame reused, content refreshed.

- [ ] 4.5 Commit: `feat(ComparePopout): render side-by-side contribution bars with gap differential`

---

## Task 5 — VotingFrame: shift-click handler for comparison popout

**Files:** `VotingFrame.lua`

The shift-click handler must identify the "top-ranked" candidate (the one with the highest score in the current session) so it can pass `nameB` to `ComparePopout:Open`. The top candidate is the first row in the sorted lib-st table — accessible via `table.data[1].name` after sorting, or by iterating `data` and finding the max score.

- [ ] 5.1 Inside `doCellUpdate`, immediately after the existing `cellFrame:SetScript("OnLeave", ...)` block, add the shift-click handler. All closure variables (`name`, `itemID`, `simRef`, `histRef`, `rcVoting`, `addon`, `session`, `data`) are already in scope:

  ```lua
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
      end
  end)
  ```

- [ ] 5.2 Add a tooltip hint on `OnEnter` (append to existing `fillScoreTooltip` call block) so the shift-click affordance is discoverable:

  ```lua
  -- Append to the existing OnEnter block inside doCellUpdate, after
  -- GameTooltip:Show():
  GameTooltip:AddLine("|cff666666Shift-click to compare vs top candidate|r")
  GameTooltip:Show()  -- re-call to resize after extra line
  ```

  Locate the existing `GameTooltip:Show()` call inside the `OnEnter` script and add the hint line immediately before it.

- [ ] 5.3 In-game verification: shift-click a non-top candidate → popout shows that candidate (A) vs the top scorer (B). Shift-click the top candidate itself → popout shows the top scorer vs second scorer. Verify normal left-click (no shift) does not open the popout.

- [ ] 5.4 Commit: `feat(VotingFrame): add shift-click handler to open comparison popout`

---

## Task 6 — Ghost-weights state and `VF.ghostMode` flag

**Files:** `VotingFrame.lua`

Ghost weights are a pure display flag — no DB mutation during toggle, no network. The active state lives in a module-level variable in `VotingFrame.lua` so `doCellUpdate` can read it on every render pass.

- [ ] 6.1 Near the top of `VotingFrame.lua`, after the `local VF = {}` declaration, add:

  ```lua
  -- Ghost-weights preview state (3.10).
  -- When true, doCellUpdate uses VF._ghostWeights instead of db.profile.weights.
  VF.ghostMode    = false
  VF._ghostWeights = nil  -- populated from ghostPresets.farm (or activeGhostPreset)
                           -- when the toggle button is pressed.
  ```

- [ ] 6.2 Add `VF.SetGhostMode(active)` — called by the toggle button (Task 7):

  ```lua
  function VF.SetGhostMode(active)
      VF.ghostMode = active
      if active then
          local addon = VF.addon
          if addon and addon.db then
              local gp      = addon.db.profile.ghostPresets
              local preset  = gp and gp[gp.activeGhostPreset or "farm"]
              VF._ghostWeights = preset or gp and gp.farm
          end
      else
          VF._ghostWeights = nil
      end
      -- Invalidate the session stats cache so scores recompute.
      _sessionStats = {}
      -- Force a refresh of the lib-st table.
      local rcVoting = VF.rcVoting
      if rcVoting and rcVoting.frame and rcVoting.frame.st then
          pcall(function() rcVoting.frame.st:Refresh() end)
      end
  end
  ```

- [ ] 6.3 In `doCellUpdate`, locate the line:

  ```lua
  local score = computeScoreForRow(rcVoting, addon, session, name, simRef, histRef)
  ```

  Replace it with:

  ```lua
  local score
  if VF.ghostMode and VF._ghostWeights then
      -- Ghost-weights path: temporarily substitute the alternate preset.
      local profile = addon.db.profile
      local savedW  = profile.weights
      profile.weights = VF._ghostWeights
      score = computeScoreForRow(rcVoting, addon, session, name, simRef, histRef)
      profile.weights = savedW
  else
      score = computeScoreForRow(rcVoting, addon, session, name, simRef, histRef)
  end
  ```

  This is safe because `computeScoreForRow` calls `addon:GetScore` which reads `profile.weights` synchronously — no coroutines or deferred execution involved. The swap is restored before the next Lua instruction.

- [ ] 6.4 Apply the same ghost-weights substitution in `sortFn` so the sort order also reflects the ghost preset:

  Locate inside `sortFn`:
  ```lua
  local sa = computeScoreForRow(rcVoting, addon, session, a.name, simRef, histRef) or -1
  local sb = computeScoreForRow(rcVoting, addon, session, b.name, simRef, histRef) or -1
  ```

  Replace with:
  ```lua
  local function ghostScore(rowName)
      if VF.ghostMode and VF._ghostWeights then
          local savedW = addon.db.profile.weights
          addon.db.profile.weights = VF._ghostWeights
          local s = computeScoreForRow(rcVoting, addon, session,
                                        rowName, simRef, histRef) or -1
          addon.db.profile.weights = savedW
          return s
      end
      return computeScoreForRow(rcVoting, addon, session,
                                 rowName, simRef, histRef) or -1
  end
  local sa = ghostScore(a.name)
  local sb = ghostScore(b.name)
  ```

- [ ] 6.5 Commit: `feat(VotingFrame): add ghost-weights display flag and doCellUpdate alternate render path`

---

## Task 7 — Ghost-weights toggle button on the score column header

**Files:** `VotingFrame.lua`

A small button is attached to the score column header cell immediately after the existing freshness badge. When ghost mode is active, the header cell gains a cyan `"[Farm]"` suffix label and the button text changes to `"Prog"`. Clicking again reverts.

The 3B dependency (`ComputeAll`) is mentioned in the module comment but is not required at runtime — the ghost path in Task 6 already works via the weight-swap technique on `Scoring:Compute`. If `ComputeAll` is available, it can be used in a future pass; document the seam.

- [ ] 7.1 In `VF:Hook`, locate the existing freshness-badge attachment block that ends with:

  ```lua
  VF.refreshFreshnessBadge = refreshFreshnessBadge
  ```

  Immediately after that line, add the ghost-weights button:

  ```lua
  -- ── Ghost-weights toggle button (3.10) ───────────────────────────
  -- Anchor: top-right of the score column header cell, left of the
  -- freshness badge (which is already TOPRIGHT).
  if colIdx and st.header.cols and st.header.cols[colIdx] then
      local headerCell = st.header.cols[colIdx]
      local T = ns.Theme

      local ghostBtn = CreateFrame("Button", nil, headerCell)
      ghostBtn:SetSize(34, 14)
      -- Sit to the left of the freshness badge; badge is at TOPRIGHT.
      ghostBtn:SetPoint("TOPRIGHT", headerCell, "TOPRIGHT", -8, -2)

      local T = ns.Theme
      local btnTex = ghostBtn:CreateTexture(nil, "BACKGROUND")
      btnTex:SetAllPoints()
      btnTex:SetColorTexture(0.12, 0.12, 0.16, 0.9)

      local btnLabel = ghostBtn:CreateFontString(nil, "OVERLAY")
      btnLabel:SetFont(T.fontBody, T.sizeSmall, "OUTLINE")
      btnLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      btnLabel:SetAllPoints()
      btnLabel:SetJustifyH("CENTER")
      btnLabel:SetText("Farm")
      VF._ghostBtnLabel = btnLabel

      -- Visual indicator on the header cell when ghost mode is active.
      local ghostActiveLine = headerCell:CreateTexture(nil, "OVERLAY")
      ghostActiveLine:SetPoint("BOTTOMLEFT",  headerCell, "BOTTOMLEFT",  0, 0)
      ghostActiveLine:SetPoint("BOTTOMRIGHT", headerCell, "BOTTOMRIGHT", 0, 0)
      ghostActiveLine:SetHeight(2)
      ghostActiveLine:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
      ghostActiveLine:Hide()
      VF._ghostActiveLine = ghostActiveLine

      local function updateGhostButtonState()
          if VF.ghostMode then
              btnLabel:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
              btnLabel:SetText("Prog")  -- click to return to Prog weights
              ghostActiveLine:Show()
          else
              btnLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
              btnLabel:SetText("Farm")  -- click to preview Farm weights
              ghostActiveLine:Hide()
          end
      end
      VF._updateGhostButtonState = updateGhostButtonState

      ghostBtn:SetScript("OnClick", function()
          VF.SetGhostMode(not VF.ghostMode)
          updateGhostButtonState()
      end)

      ghostBtn:SetScript("OnEnter", function(self)
          GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
          GameTooltip:AddLine("BobleLoot \226\128\148 Ghost Weights")
          if VF.ghostMode then
              GameTooltip:AddLine(
                  "Previewing Farm weights. Click to return to Prog weights.",
                  1, 1, 1)
          else
              local addon = VF.addon
              local preset = "farm"
              if addon and addon.db then
                  preset = addon.db.profile.ghostPresets.activeGhostPreset
                           or "farm"
              end
              GameTooltip:AddLine(string.format(
                  "Preview how current candidates rank under %s weights " ..
                  "(your Prog weights are unchanged).", preset:gsub("^%l", string.upper)),
                  1, 1, 1)
          end
          GameTooltip:AddLine("|cff666666No network traffic. Display only.|r")
          GameTooltip:Show()
      end)
      ghostBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

      VF._ghostBtn = ghostBtn
  end
  ```

  Note: `T` is re-declared as a local inside the block because it may not be in scope at the call site. The `local T = ns.Theme` inside the `if` block shadows the outer one safely.

- [ ] 7.2 Note on 3B `ComputeAll` seam: if `ns.Scoring.ComputeAll` is available when `VF.SetGhostMode` fires, an enhanced path could call it once for all candidates rather than scoring each row individually on every `doCellUpdate` pass. The weight-swap approach in Task 6 is correct and sufficient for v1.3. Document this seam with a comment in `VF.SetGhostMode`:

  ```lua
  -- 3B seam: if ns.Scoring.ComputeAll(itemID, altWeights) is available,
  -- a single pre-pass could cache all ghost scores here and avoid the
  -- per-cell weight swap. The current approach is correct; optimize in
  -- a follow-up when 3B is merged.
  ```

- [ ] 7.3 In-game verification: with an active voting session, click the "Farm" button — all score cells re-render with Farm weights, column header gets the cyan underline, button label changes to "Prog". Click again — scores return to Prog weights, underline hides.

- [ ] 7.4 Commit: `feat(VotingFrame): add ghost-weights toggle button to score column header`

---

## Task 8 — Settings panel: Ghost Presets editor in Tuning tab

**Files:** `UI/SettingsPanel.lua`

The ghost presets section lives inside the existing **Tuning** tab (the one that already holds loot weights and loot-equity sliders). It is a small card with five weight sliders for the "Farm" preset and a preset-selector row showing which preset the ghost button uses. A "Prog" preset card is read-only (it mirrors live weights) to make the contrast obvious.

Decision rationale: placing presets in the Tuning tab avoids adding a sixth tab and keeps all weight-related controls together. A separate Presets tab would be justified only if there were more than two presets or per-preset enable/disable toggles — neither is in scope for v1.3.

- [ ] 8.1 Open `UI/SettingsPanel.lua`. Locate the Tuning tab builder function (the one that creates the `tuning` body frame). After its last existing section card (the loot-history section), add a new Ghost Presets section:

  ```lua
  -- ── Ghost Presets section ────────────────────────────────────────
  do
      local ghostCard, ghostInner = MakeSection(tuningBody, "Ghost Weights Preset")
      ghostCard:SetPoint("TOPLEFT",  tuningBody, "TOPLEFT",  8, -yOff)
      ghostCard:SetPoint("TOPRIGHT", tuningBody, "TOPRIGHT", -8, -yOff)
      ghostCard:SetHeight(170)
      ghostInner:SetHeight(150)

      local note = ghostInner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      local T    = ns.Theme
      note:SetFont(T.fontBody, T.sizeSmall)
      note:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      note:SetPoint("TOPLEFT", ghostInner, "TOPLEFT", 0, -2)
      note:SetText("Farm preset — used when the ghost-weights button is active.")

      -- Five weight sliders for ghostPresets.farm.*
      local KEYS   = { "sim", "bis", "history", "attendance", "mplus" }
      local LABELS = { sim="Sim", bis="BiS", history="History",
                       attendance="Attendance", mplus="M+" }
      local sliderY = -16
      for _, k in ipairs(KEYS) do
          local key = k  -- upvalue
          MakeSlider(ghostInner, {
              label    = LABELS[key],
              min      = 0, max = 1, step = 0.01,
              isPercent = true,
              width    = 220, x = 0, y = sliderY,
              get = function()
                  return (addon.db.profile.ghostPresets.farm[key] or 0)
              end,
              set = function(v)
                  addon.db.profile.ghostPresets.farm[key] = v
                  -- If ghost mode is currently active, refresh.
                  if ns.VotingFrame and ns.VotingFrame.ghostMode then
                      ns.VotingFrame.SetGhostMode(true)
                  end
              end,
          })
          sliderY = sliderY - 26
      end
  
      -- Active preset label (non-interactive; ghost button always uses "farm" in v1.3)
      local activeLbl = ghostInner:CreateFontString(nil, "OVERLAY",
                                                    "GameFontNormalSmall")
      activeLbl:SetFont(T.fontBody, T.sizeSmall)
      activeLbl:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
      activeLbl:SetPoint("BOTTOMLEFT", ghostCard, "BOTTOMLEFT", 8, 6)
      activeLbl:SetText("Ghost button applies: Farm preset")
  
      yOff = yOff + 178  -- advance the tuning tab cursor
  end
  ```

  Note: `yOff` is the vertical cursor used throughout the Tuning tab builder. Confirm the exact variable name in the existing tab code and replace if different.

- [ ] 8.2 In-game verification: open Settings, navigate to Tuning tab, scroll to bottom — Ghost Weights Preset card is visible with five sliders. Adjust "History" slider → close Settings → click ghost-weights button → confirm new Farm history weight is reflected in the re-rendered scores. Adjust back to default.

- [ ] 8.3 Commit: `feat(SettingsPanel): add Ghost Presets editor card to Tuning tab`

---

## Task 9 — Integration testing via `TestRunner.lua`

**Files:** `TestRunner.lua` (add a new named test block; no structural changes)

`TestRunner.lua` already contains manual in-session test helpers. Add a dedicated block for 3D features.

- [ ] 9.1 Add the following test block at the end of `TestRunner.lua` before any trailing `end` that closes the file:

  ```lua
  -- ── Batch 3D: ComparePopout + Ghost Weights tests ────────────────────
  
  BobleLoot.Test3D = {}
  
  -- Opens the comparison popout with two hardcoded names for layout testing.
  -- Call from chat: /run BobleLoot.Test3D.OpenCompare()
  function BobleLoot.Test3D.OpenCompare()
      local cp = ns.ComparePopout
      if not cp then
          print("|cffff5555BobleLoot Test3D:|r ComparePopout module not loaded.")
          return
      end
      -- Use the first two characters from the dataset as test subjects.
      local data = BobleLoot:GetData()
      local nameA, nameB
      if data and data.characters then
          for n in pairs(data.characters) do
              if not nameA then nameA = n
              elseif not nameB then nameB = n
              end
              if nameA and nameB then break end
          end
      end
      nameA = nameA or "TestA-Realm"
      nameB = nameB or "TestB-Realm"
      local itemID = BobleLoot.db.profile.testItemCount
                     and BobleLoot.db.profile.testUseDatasetItems
                     and (function()
                         -- Grab any itemID from the dataset.
                         local d = BobleLoot:GetData()
                         if d and d.characters then
                             for _, c in pairs(d.characters) do
                                 if c.sims then
                                     for id in pairs(c.sims) do return id end
                                 end
                             end
                         end
                         return 0
                     end)() or 0
      print(string.format(
          "|cff33D9F2BobleLoot Test3D:|r Opening popout: %s vs %s on item %d",
          nameA, nameB, itemID or 0))
      cp:Open(nameA, nameB, itemID, nil, {})
  end
  
  -- Toggles ghost mode and prints the active state.
  -- Call from chat: /run BobleLoot.Test3D.ToggleGhost()
  function BobleLoot.Test3D.ToggleGhost()
      local VF = ns.VotingFrame
      if not VF then
          print("|cffff5555BobleLoot Test3D:|r VotingFrame module not loaded.")
          return
      end
      VF.SetGhostMode(not VF.ghostMode)
      print(string.format(
          "|cff33D9F2BobleLoot Test3D:|r Ghost mode is now: %s (preset: %s)",
          VF.ghostMode and "ACTIVE" or "OFF",
          (BobleLoot.db.profile.ghostPresets.activeGhostPreset or "farm")))
  end
  ```

- [ ] 9.2 In-game verification sequence (run in order with a 5-candidate test session active):

  a. `/run BobleLoot.Test3D.OpenCompare()` — popout opens, two columns of bars visible, one differential label highlighted.
  b. Shift-click candidate A in RC voting frame → popout refreshes to A vs top candidate.
  c. Close popout; shift-click candidate B → same frame instance reused (verify by checking no new Frame was created — `print(BobleLoot.Test3D._lastFrame == ns.ComparePopout._frame)` is always true).
  d. `/run BobleLoot.Test3D.ToggleGhost()` → all score cells change; column header shows cyan underline and "Prog" label.
  e. Open Settings → Tuning → adjust Farm history slider → toggle ghost off and on → confirm score change reflects the new slider value.
  f. `/run BobleLoot.Test3D.ToggleGhost()` again → scores return to Prog weights, underline hides.

- [ ] 9.3 Commit: `test(TestRunner): add Test3D block for ComparePopout and ghost-weights verification`

---

## Task 10 — Edge cases and defensive guards

**Files:** `UI/ComparePopout.lua`, `VotingFrame.lua`

- [ ] 10.1 **Single-candidate session guard.** If the session has only one candidate, `nameB` in the shift-click handler will be `nil` or equal to `nameA`. Add:

  ```lua
  -- In the shift-click OnMouseDown block, before cp:Open():
  if not nameB or nameB == name then
      -- Only one candidate or no comparison possible — show a tooltip hint.
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("BobleLoot — Compare")
      GameTooltip:AddLine(
          "Need at least two scored candidates to compare.", 1, 0.5, 0.5)
      GameTooltip:Show()
      C_Timer.After(2, function() GameTooltip:Hide() end)
      return
  end
  ```

- [ ] 10.2 **Ghost mode clears on session end.** When the RC voting frame closes, ghost mode should reset so the next session starts in Prog mode. Hook `ADDON_LOADED` is already handled; add a reset in the voting frame's existing `OnHide`-equivalent callback, or register on RC's `RCLootCouncil_VotingEnd` event if exposed:

  ```lua
  -- At the bottom of VF:Hook(), after the freshness badge block:
  if rcVoting.frame then
      rcVoting.frame:HookScript("OnHide", function()
          if VF.ghostMode then
              VF.SetGhostMode(false)
              if VF._updateGhostButtonState then
                  VF._updateGhostButtonState()
              end
          end
      end)
  end
  ```

- [ ] 10.3 **ComparePopout missing score guard.** If either candidate has no score (not in dataset or sim-excluded), render their column with `"—"` bars and a muted "no data" label. This is already handled by `scoreFor()` returning `nil` which causes `bdA`/`bdB` to be nil; the `(bdA and bdA[k] and bdA[k].contribution) or 0` expression safely defaults to zero bars.

- [ ] 10.4 **Theme not yet loaded.** Both modules guard with `local T = ns.Theme` at usage sites. If Theme is nil (only possible if TOC ordering is broken), both modules should print a one-time error and return early rather than erroring:

  ```lua
  -- At the top of BuildFrame() in ComparePopout.lua:
  local T = ns.Theme
  if not T then
      print("|cffff5555BobleLoot ComparePopout:|r Theme not loaded — check TOC order.")
      return
  end
  ```

- [ ] 10.5 Commit: `fix(ComparePopout,VotingFrame): add defensive guards for single-candidate, ghost reset, and nil Theme`

---

## Task 11 — Final audit and TOC version bump

**Files:** `BobleLoot.toc`, `Core.lua`

- [ ] 11.1 Confirm `BobleLoot.toc` has `UI\ComparePopout.lua` in the correct load position (after `UI\Theme.lua`, before any load-time RC hooks).

- [ ] 11.2 Bump version in `Core.lua` from `"1.1.0"` to `"1.3.0"` (or `"1.2.x"` if Batch 2 has not yet shipped — coordinate with Kotoma92):

  ```lua
  BobleLoot.version = "1.3.0"
  ```

- [ ] 11.3 Bump `## Version:` in `BobleLoot.toc` to match.

- [ ] 11.4 Commit: `chore: bump version to 1.3.0 for Batch 3D release`

---

## Manual Verification Checklist

Run all steps with RCLootCouncil active and a test session open (use TestRunner's existing `StartTest` helper to spawn 5 candidates).

### Comparison Popout (3.9)

- [ ] Shift-click score cell on a non-top candidate → popout opens. Title reads `"BobleLoot — <A> vs <B> on [Item]"` with correct names.
- [ ] Both columns render bars for all five components. Bar widths visually reflect contribution magnitudes (a higher contribution = longer bar).
- [ ] One row shows a differential label (`+N.N pts`). The differential is on the row with the numerically largest absolute gap between A and B.
- [ ] If A has the highest score, shift-clicking A opens A vs B (second-ranked). Shift-click B → B vs A (top candidate).
- [ ] Close popout. Shift-click a different candidate → same frame reused (not a new window). Title and bars refresh to the new comparison.
- [ ] Drag popout to a corner. Close it (X button). Reopen → appears at the saved corner position, not CENTER.
- [ ] Press Escape while popout is focused → popout closes.
- [ ] Popout does not cover the RC voting frame's default position (popout spawns at CENTER+80y offset by default).
- [ ] Single-candidate session: shift-click → tooltip hint appears briefly instead of popout.

### Ghost Weights (3.10)

- [ ] With a voting session open, the score column header shows a small "Farm" button.
- [ ] Hover over the button → tooltip reads: `"Preview how current candidates rank under Farm weights (your Prog weights are unchanged)."` and `"No network traffic. Display only."`
- [ ] Click "Farm" button → all score cells rerender. Column header gains a cyan underline. Button label changes to "Prog".
- [ ] Scores in ghost mode match a manual calculation using Farm weights (`sim=0.30, bis=0.10, history=0.40, attendance=0.15, mplus=0.05`).
- [ ] Click "Prog" → scores return to Prog weights. Cyan underline hides.
- [ ] Open Settings → Tuning tab → scroll to Ghost Weights Preset card → adjust Farm history weight → close Settings → activate ghost mode → scores reflect the new history weight.
- [ ] Ghost mode resets to Prog when the RC voting frame closes (verified by closing the RC loot frame and reopening → button shows "Farm", no cyan underline).
- [ ] Ghost mode does not mutate `addon.db.profile.weights` — verify with `/run print(BobleLoot.db.profile.weights.history)` before and after toggling (value unchanged, should remain `0.15`).

---

## Design Notes

### Why a single-instance popout (not a new window per shift-click)

Multiple simultaneous comparison windows would create visual clutter during a live council discussion and add memory overhead proportional to the number of shift-clicks. The council's decision flow is sequential — compare A vs B, decide, move on. A single reused instance with immediate refresh on each shift-click matches this flow and avoids any "which window is current?" confusion. Position is persisted so the leader can park it in a predictable screen corner.

### Why ghost toggle is not a preset dropdown

A dropdown implies multiple presets of equal standing with comparable UI complexity for each. For v1.3, the use case is a single binary question: "under our post-progression weights, does the call change?" Two presets (Prog = live weights, Farm = history-heavy) answer this directly. A dropdown would add three-to-four more click targets and require per-preset naming UX with no additional decision value. If multiple ghost presets become a requested feature post-v1.3, the `ghostPresets` DB table already supports arbitrary keys — adding a dropdown selector at that point is a small incremental change.

### Preset storage location (Tuning tab vs. separate Presets tab)

Ghost Presets are stored in the Tuning tab for two reasons. First, proximity: the Prog weights are already in the Weights tab; the Farm preset is the only other weight configuration the user edits. Keeping them adjacent (one tab over) reduces context-switching. Second, surface area: five sliders and one label do not justify a full tab with a tab bar entry. A dedicated Presets tab would be three-quarters empty in v1.3. If Batch 4's colorblind palette or export/import work adds per-preset visual theming, a Presets tab becomes justified at that point.

### `ghostPresets.prog` seeding strategy

The `prog` preset is seeded from the user's live `db.profile.weights` on every `OnEnable`. This means it is always current — even if the user adjusts their Prog weights in the Weights tab, the next `/reload` realigns `ghostPresets.prog`. The consequence is that `ghostPresets.prog` is not independently editable in v1.3, which is intentional: "Prog" means "what I am currently using," not a separately maintained configuration.

---

## Coordination Notes

### 3B dependency (`ComputeAll`) — graceful fallback

The ghost-weights re-render in Task 6 uses a per-cell weight-swap technique on `Scoring:Compute`. This is correct and self-contained regardless of whether 3B's `ComputeAll` has shipped. When 3B lands, `VF.SetGhostMode` can be upgraded to call `ComputeAll(itemID, VF._ghostWeights)` once per toggle and cache results in a `_ghostScoreCache` table, eliminating repeated weight-swaps across `doCellUpdate` cells. The seam is documented in `VF.SetGhostMode` (Task 6 step 7.2) and requires no changes to the public API.

### 2D chrome style parity

`UI/ComparePopout.lua` deliberately replicates the chrome conventions from Batch 2D's `UI/ExplainPanel.lua` (dark `bgBase`, `bgTitleBar`, cyan underline, hover-red close button, `SetClampedToScreen`, strata `HIGH`, position persistence via `db.profile`). It does **not** import from `ExplainPanel.lua` — it stands as an independent module to avoid a hidden coupling between two distinct UI surfaces with different content lifecycles. Future refactors can extract a shared `UI/PanelShell.lua` factory if a third panel type is needed.

### 3E toast optional integration

Batch 3E's toast notification system (item 3.12) would pair naturally with ghost-weights activation: a green toast reading `"Preview mode: Farm weights"` on toggle-on and a neutral toast on toggle-off. This is documented as an optional stretch for 3E's implementer. The ghost-mode activation point is `VF.SetGhostMode(true)` — 3E can hook there or call `ns.Toast:Show(...)` directly after `VF.SetGhostMode` returns. No changes to 3D code are required for this integration; 3E owns the coordination.

### Cross-plan 3C (RC schema-drift)

3C adds `LH:DetectSchemaVersion` and a Settings panel warning banner when RC schema detection fails. ComparePopout and ghost-weights have no dependency on `LootHistory` reads — the comparison and ghost paths both go through `Scoring:Compute` which reads `BobleLoot_Data`, not RC's SavedVars. No coordination required.
