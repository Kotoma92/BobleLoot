# Batch 4D — UI Polish: RC Banner + Colorblind Palette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface a prominent "RC not detected" warning banner in the Settings panel Data tab when RCLootCouncil is absent after a 10-second startup grace period, and add a colorblind-safe "Color mode" dropdown to the Display group that atomically swaps the score-to-color palette across every consumer surface.

**Architecture:** Color modes are implemented as alternate palette variant tables held inside `UI/Theme.lua`; a `Theme:SetColorMode(mode)` function swaps the active lookup tables atomically and then fires a consumer callback list so that every surface (VotingFrame, LootFrame, ComparePopout, Toast, SettingsPanel example row, freshness badge) redraws without a reload. The RC-not-detected banner is a single deferred check — `Core:OnEnable` schedules a `C_Timer.After(10, ...)` that evaluates `TryHookRC`'s stored success flag; if RC was never hooked, an `BobleLoot_RCMissing` AceEvent is fired. `SettingsPanel.lua` listens for that event to show the banner and also auto-hides it when `ADDON_LOADED` fires RC later in the session.

**Tech Stack:** Lua (WoW 10.x), `UI/Theme.lua` palette module, AceDB profile persistence, AceEvent-3.0, `C_Timer.After` for the deferred grace-period check.

**Roadmap items covered:**

> **4.10 `[UI]` "RC not detected" warning banner**
>
> After a 10-second startup grace period, if RC is not hooked, show a
> prominent banner in the Settings panel's Data tab reading
> `"|cffff5555RCLootCouncil not detected. Score column will appear once
> RC loads.|r"` — replacing the current "No data file loaded" message
> which is a different condition.
>
> Replaces what was originally spec'd as standalone-without-RC mode
> (cut — see Non-goals #1).

> **4.11 `[UI]` Colorblind-safe palette**
>
> Add a "Color mode" dropdown in the Settings panel's Display group:
>
> - **Default** — current red/yellow/green ramp.
> - **Deuter/Protan** — orange-to-blue (`#FF8C00` low, `#4D94FF` high).
> - **High Contrast** — white text on coloured backgrounds rather than
>   coloured text on default background.
>
> Applies to score cells, transparency label, toast system, and
> comparison popout bars. Stored per-profile via AceDB.

**Dependencies:**
- Batch 1E (`UI/Theme.lua`, `UI/SettingsPanel.lua`): palette constants, `ScoreColor`, `ScoreColorRelative`, `ApplyBackdrop`, `MakeSection`, `MakeButton`, `BuildTuningTab`, `BuildDataTab`.
- Batch 2E (`UI/SettingsPanel.lua`): Display group section inside `BuildTuningTab`, already containing the conflict-threshold slider. The color-mode dropdown is appended to that same Display card.
- Batch 3D (`UI/ComparePopout.lua`): consumes `Theme.ScoreColor` for the differential highlight bar; must register as a color-mode consumer.
- Batch 3E (`UI/Toast.lua`): uses `ns.Theme.success`, `warning`, `danger` for tint; `Theme:SetColorMode` must update these references. Toast must register as a consumer.
- Batch 4C (RC version-compat, planned): its RC-version info line lives in the Data tab directly below the banner cluster. The vertical order is documented in the coordination notes at the bottom.
- Batch 4E (empty/error states audit, planned): the RC-not-detected banner is one of the states 4E audits. This plan's implementation satisfies 4E's checklist items for the Data tab.

---

## Why colorblind modes are not "a theme switcher"

Roadmap Non-goal #8 states "No theme switcher." The distinction matters:

- A **theme switcher** changes the panel chrome, accent colors, typography, or overall visual identity. That scope was explicitly cut.
- **Colorblind palette modes** change only the score-to-color mapping — the functional data encoding, not the decorative framing. `Theme.accent`, `Theme.bgBase`, `Theme.borderNormal`, title bar colors, button styles, and all panel chrome are untouched by `SetColorMode`. Only `Theme.success`, `Theme.warning`, `Theme.danger`, and the `ScoreColor`/`ScoreColorRelative` functions are re-pointed.

This matches the WoW addon community norm: colorblind options are accessibility settings, not cosmetic themes.

---

## File Structure

Files modified:

```
UI/Theme.lua             -- ColorMode variant tables; SetColorMode; ApplyColorMode;
                         --   consumer registration list
UI/SettingsPanel.lua     -- Display group: add color-mode dropdown (Task 4)
                         -- Data tab: add RC-not-detected banner (Task 5)
                         --   register as color-mode consumer (Task 6)
Core.lua                 -- DB_DEFAULTS: colorMode = "default" (Task 1)
                         -- OnEnable: 10s deferred check + BobleLoot_RCMissing event (Task 2)
                         -- OnAddonLoaded: fire BobleLoot_RCDetected on late RC load (Task 2)
VotingFrame.lua          -- register as color-mode consumer (Task 6)
LootFrame.lua            -- register as color-mode consumer (Task 6)
UI/ComparePopout.lua     -- register as color-mode consumer (Task 6)  [Batch 3D file]
UI/Toast.lua             -- register as color-mode consumer (Task 6)  [Batch 3E file]
BobleLoot.toc            -- no changes (all files already in TOC from prior batches)
```

No new files. No new external libraries. No TOC changes needed because all affected files were already registered by Batches 1E, 3D, and 3E.

---

## Task 1 — `Core.lua`: add `colorMode` to `DB_DEFAULTS`

**Files:** `Core.lua`

AceDB merges `DB_DEFAULTS` at first load. Adding `colorMode` is a non-breaking additive change — existing installs get the default value `"default"` on the next `/reload`.

- [ ] 1.1 Open `Core.lua`. Locate the `DB_DEFAULTS.profile` table. Find the bottom of the profile block (after `historyCap`, `conflictThreshold`, `suppressTransparencyLabel`, and similar keys from prior batches).

- [ ] 1.2 Add the following line immediately after the `conflictThreshold` line (or after whatever the last numeric display tuning key is):

  ```lua
          colorMode = "default",          -- 4.11: "default"|"deuter"|"highcontrast"
  ```

- [ ] 1.3 Verify: grep `colorMode` in `Core.lua` — exactly one hit.

**Verification:** `/reload` in-game. Run:
```
/run print(BobleLoot.db.profile.colorMode)
```
Expected output: `default`.

**Commit:** `feat(Core): add colorMode to DB_DEFAULTS profile`

---

## Task 2 — `Core.lua`: 10-second deferred RC check + AceEvents

**Files:** `Core.lua`

`TryHookRC` already runs at `OnEnable` and registers `ADDON_LOADED` if RC is not present. This task adds a 10-second timer that fires `BobleLoot_RCMissing` if RC was still not hooked, and modifies `OnAddonLoaded` to fire `BobleLoot_RCDetected` when RC loads late. `SettingsPanel.lua` (Task 5) will listen to both events to show/hide the banner.

A module-level flag `BobleLoot._rcHooked` tracks whether `TryHookRC` ever returned true so the timer check does not need to call `TryHookRC` a second time (which would register duplicate hooks).

- [ ] 2.1 Add a module-level flag immediately before or after `BobleLoot.version`:

  ```lua
  BobleLoot._rcHooked = false   -- set true when TryHookRC succeeds
  ```

- [ ] 2.2 In `BobleLoot:TryHookRC`, at the bottom of the function where `return hookedAny` is, change to:

  ```lua
      if hookedAny then
          BobleLoot._rcHooked = true
      end
      return hookedAny
  ```

- [ ] 2.3 In `BobleLoot:OnEnable`, after the existing `if not self:TryHookRC() then ... end` block, add the deferred check:

  ```lua
      -- 4.10: after 10-second grace period, warn UI if RC never loaded.
      C_Timer.After(10, function()
          if not BobleLoot._rcHooked then
              BobleLoot:SendMessage("BobleLoot_RCMissing")
          end
      end)
  ```

  Note: `SendMessage` is from AceEvent-3.0, which is already mixed into `BobleLoot` via the `NewAddon` call in `Core.lua`. The event name `BobleLoot_RCMissing` follows the same `BobleLoot_` prefix convention used by `BobleLoot_SyncWarning`, `BobleLoot_SchemaDriftWarning`, etc.

- [ ] 2.4 In `BobleLoot:OnAddonLoaded`, in the branch where `TryHookRC` succeeds, add:

  ```lua
  function BobleLoot:OnAddonLoaded(_, name)
      if name == "RCLootCouncil" then
          if self:TryHookRC() then
              self:UnregisterEvent("ADDON_LOADED")
              -- 4.10: inform banner to auto-hide.
              self:SendMessage("BobleLoot_RCDetected")
          end
      end
  end
  ```

  The `BobleLoot_RCDetected` event is fired only once per session (the first time RC loads successfully). If RC was already hooked at startup, `ADDON_LOADED` was never registered and this function never runs — the banner was never shown in the first place.

- [ ] 2.5 Verify no existing `BobleLoot_RCMissing` or `BobleLoot_RCDetected` event names conflict with other modules: grep both names across the entire addon directory. Expected: zero existing hits before this task.

**Verification:**
- With RC loaded: `/reload` → 10 seconds pass → no `BobleLoot_RCMissing` fires (confirm by temporarily adding a listener: `/run BobleLoot:RegisterMessage("BobleLoot_RCMissing", function() print("FIRED") end)`).
- With RC disabled: `/reload` → after 10 seconds the event fires.

**Commit:** `feat(Core): 10s RC-hook grace period; fire BobleLoot_RCMissing/RCDetected events`

---

## Task 3 — `UI/Theme.lua`: color-mode variant tables + `SetColorMode` + consumer list

**Files:** `UI/Theme.lua`

This is the central change for item 4.11. The existing `Theme.success`, `Theme.warning`, `Theme.danger` entries and the `Theme.ScoreColor`/`Theme.ScoreColorRelative` functions are the targets of the mode swap. The strategy is:

1. Store the Default variant values as named constants.
2. Store the Deuteranopia/Protanopia variant and High Contrast variant as tables.
3. `Theme:SetColorMode(mode)` overwrites the live `Theme.success`, `Theme.warning`, `Theme.danger` references in place (so all existing consumers that captured `ns.Theme.success` as a local reference at build time still work — they must re-read `ns.Theme.success` at render time, which is the existing pattern in all current consumers).
4. `Theme:SetColorMode` also re-assigns `Theme.ScoreColor` and `Theme.ScoreColorRelative` to mode-specific implementations.
5. After swapping, call each registered consumer callback so surfaces that cache colors in widget state (vertex colors, backdrop colors) get a chance to redraw.

**Hex-to-RGBA conversions used in this task:**

| Color name          | Hex       | r      | g      | b      |
|---------------------|-----------|--------|--------|--------|
| Deuter low (orange) | #FF8C00   | 1.000  | 0.549  | 0.000  |
| Deuter high (blue)  | #4D94FF   | 0.302  | 0.580  | 1.000  |

High Contrast mode does not change success/warning/danger hues — it changes the *application pattern* (cell background filled, text always white). The hue constants remain the Default red/green/amber; `Theme.hcMode` flag tells consumers to apply them as backgrounds rather than text colors.

- [ ] 3.1 After the existing semantic color block (after `Theme.muted` and `Theme.white`), add the variant constant tables and the active-mode state. Insert immediately below `Theme.white`:

  ```lua
  -- ── Color-mode variants ────────────────────────────────────────────────
  -- Each variant table mirrors the semantic color keys that change between modes.
  -- Theme:SetColorMode swaps the live Theme.success/warning/danger/etc. references.

  local COLOR_MODES = {
      default = {
          -- Standard red/yellow/green ramp (existing palette values).
          success  = { 0.10, 0.80, 0.30, 1.00 },  -- green  #19CC4D
          warning  = { 1.00, 0.65, 0.00, 1.00 },  -- amber  #FFA600
          danger   = { 0.90, 0.20, 0.20, 1.00 },  -- red    #E63333
          hcMode   = false,
      },
      deuter = {
          -- Orange-to-blue: accessible for deuteranopia and protanopia.
          -- Low (danger):   #FF8C00 orange
          -- Mid (warning):  midpoint between orange and blue  ~#A48E80 (unused; computed)
          -- High (success): #4D94FF blue
          success  = { 0.302, 0.580, 1.000, 1.00 },  -- blue   #4D94FF
          warning  = { 0.900, 0.550, 0.150, 1.00 },  -- intermediate amber-orange
          danger   = { 1.000, 0.549, 0.000, 1.00 },  -- orange #FF8C00
          hcMode   = false,
      },
      highcontrast = {
          -- Same hues as default; hcMode=true tells consumers to fill cell background
          -- with the score color and render text as white for maximum luminance contrast.
          success  = { 0.10, 0.80, 0.30, 1.00 },
          warning  = { 1.00, 0.65, 0.00, 1.00 },
          danger   = { 0.90, 0.20, 0.20, 1.00 },
          hcMode   = true,
      },
  }

  -- Consumer callback list. Each entry is a zero-argument function called by
  -- Theme:ApplyColorMode after swapping the live palette references.
  local _colorModeConsumers = {}

  -- Current mode name (matches a key in COLOR_MODES).
  Theme.currentMode = "default"

  -- High-contrast flag: true when current mode fills cell backgrounds.
  -- Consumers check this to decide text-vs-background coloring strategy.
  Theme.hcMode = false
  ```

- [ ] 3.2 Add `Theme:RegisterColorModeConsumer(fn)` immediately after the block above:

  ```lua
  --- Register a callback that fires when the color mode is changed.
  -- @param fn  zero-argument function; called after palette tables are swapped.
  function Theme:RegisterColorModeConsumer(fn)
      if type(fn) == "function" then
          _colorModeConsumers[#_colorModeConsumers + 1] = fn
      end
  end
  ```

- [ ] 3.3 Add `Theme:SetColorMode(mode)`:

  ```lua
  --- Swap the active palette to the given mode and notify all consumers.
  -- @param mode  "default" | "deuter" | "highcontrast"
  --              Unknown values are silently ignored (mode stays unchanged).
  function Theme:SetColorMode(mode)
      local variant = COLOR_MODES[mode]
      if not variant then return end

      -- Overwrite the live semantic color references in-place.
      -- Consumers that read ns.Theme.success etc. at render time see the new values.
      Theme.success = variant.success
      Theme.warning = variant.warning
      Theme.danger  = variant.danger
      Theme.hcMode  = variant.hcMode
      Theme.currentMode = mode

      -- Re-assign ScoreColor and ScoreColorRelative to mode-specific implementations.
      if mode == "deuter" then
          Theme.ScoreColor         = Theme._ScoreColorDeuter
          Theme.ScoreColorRelative = Theme._ScoreColorRelativeDeuter
      elseif mode == "highcontrast" then
          -- HC uses same thresholds as default; hcMode flag drives the visual change.
          Theme.ScoreColor         = Theme._ScoreColorDefault
          Theme.ScoreColorRelative = Theme._ScoreColorRelativeDefault
      else
          Theme.ScoreColor         = Theme._ScoreColorDefault
          Theme.ScoreColorRelative = Theme._ScoreColorRelativeDefault
      end

      -- Notify all registered consumers.
      for _, fn in ipairs(_colorModeConsumers) do
          local ok, err = pcall(fn)
          if not ok then
              -- Never let a broken consumer silently swallow the mode swap.
              -- scriptErrors 1 will surface this in the error dialog.
              error("BobleLoot Theme consumer error: " .. tostring(err), 2)
          end
      end
  end

  --- Convenience alias — called by SettingsPanel dropdown and OnEnable restore.
  function Theme:ApplyColorMode(mode)
      return self:SetColorMode(mode)
  end
  ```

- [ ] 3.4 Rename the existing `Theme.ScoreColor` function to `Theme._ScoreColorDefault` and the existing `Theme.ScoreColorRelative` to `Theme._ScoreColorRelativeDefault`. Then create the Deuter variants and assign the live `Theme.ScoreColor` pointer:

  ```lua
  -- ── Score-color implementations (mode-specific) ───────────────────────

  -- Default (red/amber/green). Renamed from the Batch 1E original.
  function Theme._ScoreColorDefault(score)
      if score == nil then return Theme.muted end
      if score >= 70 then return Theme.success  end
      if score >= 40 then return Theme.warning  end
      return Theme.danger
  end

  function Theme._ScoreColorRelativeDefault(score, median, max)
      if score == nil then return Theme.muted end
      if median == nil or max == nil or max <= median then
          return Theme._ScoreColorDefault(score)
      end
      if score >= max then
          return { Theme.success[1], Theme.success[2], Theme.success[3], Theme.success[4] }
      end
      local function lerp(a, b, t) return a + (b - a) * t end
      local function mix(c1, c2, t)
          return {
              lerp(c1[1], c2[1], t),
              lerp(c1[2], c2[2], t),
              lerp(c1[3], c2[3], t),
              lerp(c1[4] or 1, c2[4] or 1, t),
          }
      end
      if score >= median then
          local t = (score - median) / (max - median)
          return mix(Theme.warning, Theme.success, t)
      else
          local t = (median > 0) and (score / median) or 0
          return mix(Theme.danger, Theme.warning, t)
      end
  end

  -- Deuteranopia/Protanopia (orange-to-blue). Same threshold logic; different palette.
  function Theme._ScoreColorDeuter(score)
      -- Reuse the same threshold structure but with the deuter semantic colors,
      -- which have been swapped into Theme.success/warning/danger by SetColorMode.
      return Theme._ScoreColorDefault(score)
  end

  function Theme._ScoreColorRelativeDeuter(score, median, max)
      -- Same interpolation math; deuter palette is already live in Theme.success etc.
      return Theme._ScoreColorRelativeDefault(score, median, max)
  end

  -- Assign the live pointers to Default implementations initially.
  -- SetColorMode re-assigns these on mode change.
  Theme.ScoreColor         = Theme._ScoreColorDefault
  Theme.ScoreColorRelative = Theme._ScoreColorRelativeDefault
  ```

  Note: Because `_ScoreColorDeuter` delegates to `_ScoreColorDefault`, and `_ScoreColorDefault` reads `Theme.success/warning/danger` at call time (not at definition time), the deuter variant works correctly — `SetColorMode("deuter")` first overwrites `Theme.success/warning/danger` with the orange/blue values, then assigns `Theme.ScoreColor = Theme._ScoreColorDeuter`, so subsequent calls to `Theme.ScoreColor(score)` return orange or blue as appropriate.

- [ ] 3.5 Verify: `UI/Theme.lua` still defines `Theme.ScoreColor` and `Theme.ScoreColorRelative` as its final exported functions (the live pointer assignments at the bottom of step 3.4). The old bodies of `Theme.ScoreColor` and `Theme.ScoreColorRelative` from Batch 1E are now the `_ScoreColorDefault` / `_ScoreColorRelativeDefault` implementations — confirm no duplicate function definitions remain.

- [ ] 3.6 Grep for all calls to `Theme.ScoreColor(` and `Theme.ScoreColorRelative(` in the codebase. Confirm that all call sites read `ns.Theme.ScoreColor(...)` rather than caching the function reference at module load time. If any file does `local scFn = ns.Theme.ScoreColor` at file scope, update it to call `ns.Theme.ScoreColor(...)` inline at render time. Expected files to check: `VotingFrame.lua`, `LootFrame.lua`, `UI/SettingsPanel.lua` (example score row).

**Verification:**
```
/run ns = select(2, ...); print(ns.Theme.ScoreColor(85))
-- Expected: references Theme.success = green table
/run BobleLoot.db.profile.colorMode = "deuter"; ns.Theme:SetColorMode("deuter"); print(ns.Theme.ScoreColor(85))
-- Expected: references Theme.success = blue table {0.302, 0.580, 1.0, 1.0}
/run print(ns.Theme.hcMode)
-- Expected: false (deuter mode)
```

**Commit:** `feat(Theme): color-mode variant tables, SetColorMode, consumer callback list`

---

## Task 4 — `UI/SettingsPanel.lua`: color-mode dropdown in Display group

**Files:** `UI/SettingsPanel.lua`

Batch 2E added a "Display" section card inside `BuildTuningTab`, anchored below the main "Scoring tuning" card. It contains the conflict-threshold slider. This task appends a "Color mode" dropdown below that slider inside the same Display card.

WoW does not ship a standard dropdown widget in the `OptionsSliderTemplate`/`InterfaceOptionsCheckButtonTemplate` family that is suitable for three mutually-exclusive options without AceConfig. The standard pattern for a small option set is `UIDropDownMenu`: `CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")` with `UIDropDownMenu_SetWidth`, `UIDropDownMenu_Initialize`, `UIDropDownMenu_SetSelectedValue`.

- [ ] 4.1 In `BuildTuningTab`, locate the Display section card (`dispCard`, `dispInner`) added by Batch 2E. Increase the card height to accommodate a second row (dropdown + label). Change:

  ```lua
  dispCard:SetHeight(70)
  ```
  to:
  ```lua
  dispCard:SetHeight(120)
  ```

  If the Batch 2E card height is hard-coded elsewhere adjust only the single `SetHeight` call inside `BuildTuningTab`.

- [ ] 4.2 After the conflict-threshold slider block inside `dispInner`, add:

  ```lua
  -- ── Color mode dropdown (4.11) ────────────────────────────────────────
  local colorModeLbl = dispInner:CreateFontString(nil, "OVERLAY")
  colorModeLbl:SetFont(T.fontBody, T.sizeBody)
  colorModeLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
  colorModeLbl:SetPoint("TOPLEFT", dispInner, "TOPLEFT", 4, -52)
  colorModeLbl:SetText("Color mode")

  local colorModeHint = dispInner:CreateFontString(nil, "OVERLAY")
  colorModeHint:SetFont(T.fontBody, T.sizeSmall)
  colorModeHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
  colorModeHint:SetPoint("TOPLEFT", colorModeLbl, "BOTTOMLEFT", 0, -2)
  colorModeHint:SetWidth(340)
  colorModeHint:SetText(
      "Default = red/amber/green.  Deuter/Protan = orange/blue.  "
      .. "High Contrast = filled cell background, white text.")

  -- Color mode options in display order.
  local COLOR_MODE_OPTIONS = {
      { value = "default",     label = "Default (red/amber/green)" },
      { value = "deuter",      label = "Deuteranopia / Protanopia (orange/blue)" },
      { value = "highcontrast",label = "High Contrast (filled background)" },
  }

  local colorModeDropdown = CreateFrame("Frame", "BobleLootColorModeDropdown",
      dispInner, "UIDropDownMenuTemplate")
  colorModeDropdown:SetPoint("TOPLEFT", colorModeLbl, "TOPLEFT", 110, 4)
  UIDropDownMenu_SetWidth(colorModeDropdown, 240)

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
  ```

- [ ] 4.3 In the existing `BuildTuningTab` body `OnShow` handler, add a refresh call for the dropdown:

  ```lua
      -- 4.11: refresh color mode dropdown.
      RefreshColorModeDropdown()
  ```

- [ ] 4.4 Verify: no `BobleLootColorModeDropdown` global name conflicts with other BobleLoot frames (grep `BobleLootColorMode` in the project — should have zero hits before this task).

**Verification (manual):**
- `/bl config` → Tuning tab → Display section → "Color mode" dropdown is present with three options.
- Select "Deuteranopia / Protanopia" → score cells in the voting frame immediately shift to orange/blue.
- `/reload` → Tuning tab → dropdown reads the persisted value.

**Commit:** `feat(SettingsPanel): color-mode dropdown in Display group (4.11)`

---

## Task 5 — `UI/SettingsPanel.lua`: RC-not-detected banner in Data tab

**Files:** `UI/SettingsPanel.lua`

The Data tab already has a schema-drift warning banner from Batch 3C at the very top, followed by the dataset info card (`infoCard`). This task adds a second banner — the RC-not-detected banner — positioned above the drift banner (i.e., at absolute top of the Data tab body, y = -6). The vertical order in the Data tab from top to bottom is:

1. **RC-not-detected banner** (this task, 4.10) — shown only when RC hook failed after 10s
2. **Schema-drift banner** (Batch 3C) — shown only when `rcSchemaDetected.status ~= "ok"`
3. **Dataset info card** (`infoCard`) — always visible, pushed down as banners appear
4. **RC version info line** (Batch 4C, planned) — inside or adjacent to the info card
5. **Actions card**, **Transparency card**

When both banners are visible (RC missing AND schema drift on a weird install), both stack with the info card shifted down accordingly. The RC-not-detected banner has priority because it is the more critical failure state.

Banner text (verbatim from roadmap):
```
|cffff5555RCLootCouncil not detected. Score column will appear once RC loads.|r
```

This banner is NOT the same as "No data file loaded" (which is the existing red text inside `infoCard` when `_G.BobleLoot_Data` is nil). The two conditions are independent: RC can be missing with a valid data file, or the data file can be missing while RC runs. Do not repurpose the `infoLbl` text — the banner is a separate UI element.

- [ ] 5.1 In `BuildDataTab`, before the existing schema-drift banner block (Batch 3C) or if 3C has not yet landed, before the `infoCard` creation, insert the RC-not-detected banner:

  ```lua
  -- ── RC-not-detected banner (4.10) ─────────────────────────────────────
  -- Shown when TryHookRC never succeeded after the 10-second grace period.
  -- Auto-hides when BobleLoot_RCDetected fires (RC loaded later in session).
  -- Hidden by default; shown via BobleLoot_RCMissing AceEvent.

  local rcBannerCard, rcBannerInner = MakeSection(body, "")
  rcBannerCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -6)
  rcBannerCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, -6)
  rcBannerCard:SetHeight(44)
  -- Use danger border to draw the eye.
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

  -- Track banner visibility so infoCard offset logic is correct.
  local _rcBannerVisible = false

  -- Height constants for offset math.
  local RC_BANNER_H    = 52   -- banner card height + gap
  local DRIFT_BANNER_H = 60   -- Batch 3C banner height + gap (may not exist yet)

  -- Helper: recompute infoCard's TOPLEFT based on which banners are visible.
  -- Called whenever either banner's visibility changes.
  local function _repositionDataCards()
      local offset = -6
      if _rcBannerVisible then offset = offset - RC_BANNER_H end
      -- Check if Batch 3C's drift banner is also visible.
      -- If the drift banner frame exists and is shown, account for its height too.
      -- (schemaCard is a local in BuildDataTab; if 3C hasn't landed, it won't exist.)
      -- Use a pcall-guarded approach: schemaCard is referenced by closure if it exists.
      if _schemaCardVisible then offset = offset - DRIFT_BANNER_H end
      infoCard:SetPoint("TOPLEFT", body, "TOPLEFT", 6, offset)
  end
  -- _schemaCardVisible is declared below next to the schema-drift banner logic.
  -- If Batch 3C has not yet landed, default to false.
  local _schemaCardVisible = false
  ```

  Note: the `_schemaCardVisible` variable must be declared before `_repositionDataCards` uses it, even though it is populated by the Batch 3C OnShow block. If Batch 3C has already been implemented, integrate by replacing both banner's `infoCard` push logic with a shared `_repositionDataCards()` call.

- [ ] 5.2 Register as a listener for `BobleLoot_RCMissing` and `BobleLoot_RCDetected` inside `BuildDataTab`, after the banner frame is constructed:

  ```lua
  -- Listen for RC detection events fired by Core.lua Task 2.
  -- AceEvent messages are broadcast via addon:SendMessage / addon:RegisterMessage.
  -- SettingsPanel uses the addon reference captured in SP:Setup.
  if addon then
      addon:RegisterMessage("BobleLoot_RCMissing", function()
          _rcBannerVisible = true
          rcBannerCard:Show()
          _repositionDataCards()
          -- Also fire once-per-session Toast (via BobleLoot_RCMissing, which
          -- Toast.lua also listens to in Task 6 — no duplicate call needed here).
      end)
      addon:RegisterMessage("BobleLoot_RCDetected", function()
          _rcBannerVisible = false
          rcBannerCard:Hide()
          _repositionDataCards()
      end)
  end
  ```

  Important: `RegisterMessage` is an AceEvent method. `addon` is the `BobleLoot` object passed to `SP:Setup`. Because `BuildDataTab` is called lazily from `BuildFrames` (which is called from `SP:Open`), and `addon` is set during `SP:Setup` (which is called from `Core:OnInitialize`), `addon` is always non-nil by the time `BuildDataTab` runs.

- [ ] 5.3 In the body `OnShow` handler at the bottom of `BuildDataTab`, add a banner state refresh at the top of the callback (before the existing `updateInfoLabel()` call):

  ```lua
      -- 4.10: sync banner visibility with the current RC hook state.
      -- If the panel was opened after the 10s timer fired, show the banner
      -- if RC is still not hooked; hide it if it was hooked since.
      if addon and not BobleLoot._rcHooked then
          -- Check if enough time has passed that the timer would have fired.
          -- We cannot know here whether the timer has fired, but showing the
          -- banner on panel open after the fact is conservative and correct.
          -- The BobleLoot_RCMissing event takes care of it if the panel was
          -- open during the timer fire; this handles the case where the panel
          -- is opened after the timer already fired.
          --
          -- TryHookRC can be called again here as a synchronous check
          -- (it is idempotent — it won't double-register hooks if they
          -- already failed because RC returned nil).
          local alreadyHooked = BobleLoot._rcHooked
          if not alreadyHooked then
              _rcBannerVisible = true
              rcBannerCard:Show()
          end
      else
          _rcBannerVisible = false
          rcBannerCard:Hide()
      end
      _repositionDataCards()
  ```

- [ ] 5.4 Confirm the banner text exactly matches the roadmap literal (the `|cffff5555` color escape renders red in-game):
  - `|cffff5555` = RGB(255, 85, 85) = the spec's `#ff5555`.
  - `|r` closes the color.
  - Full visible text: `RCLootCouncil not detected. Score column will appear once RC loads.`

**Verification:**
- RC loaded → open Data tab → banner invisible, info card at default y=-6.
- RC disabled → `/reload` → wait 10s → open Data tab → banner visible in red, info card pushed down by 52px.
- Still with RC disabled → enable RC while panel is open → `BobleLoot_RCDetected` fires → banner disappears, info card returns to default position.

**Commit:** `feat(SettingsPanel): RC-not-detected banner in Data tab (4.10)`

---

## Task 6 — Register color-mode consumers across all surfaces

**Files:** `VotingFrame.lua`, `LootFrame.lua`, `UI/ComparePopout.lua`, `UI/Toast.lua`, `UI/SettingsPanel.lua`

Each consumer registers a zero-argument callback with `ns.Theme:RegisterColorModeConsumer(fn)`. The callback must be registered after `ns.Theme` is guaranteed to exist (i.e., not at file-scope top-level, but inside an `OnEnable`, `Setup`, or `Hook` function that runs after all `UI/` files have loaded). The load order from Batch 1E's TOC is:

```
UI\Theme.lua          → ns.Theme available from here onward
UI\Toast.lua          → registers in Toast:Setup
UI\HistoryViewer.lua
UI\SettingsPanel.lua  → registers in BuildWeightsTab (example row) and BuildDataTab
UI\MinimapButton.lua
```

`VotingFrame.lua` and `LootFrame.lua` load before `UI\Theme.lua` in the current TOC. Their consumer registration must happen inside their `Hook(addon, RC)` function, which is called from `Core:OnEnable` — after all UI files have loaded.

**Sub-task 6A — `VotingFrame.lua`**

The voting frame uses `Theme.ScoreColor` / `Theme.ScoreColorRelative` via the `formatScore` helper and `doCellUpdate`. When HC mode is active, `doCellUpdate` must also set the cell background color.

- [ ] 6A.1 In `VotingFrame.lua`, inside the `Hook(addon, RC)` function (after the hook registration), add:

  ```lua
      -- 4.11: re-render all visible score cells when the color mode changes.
      if ns.Theme and ns.Theme.RegisterColorModeConsumer then
          ns.Theme:RegisterColorModeConsumer(function()
              -- Trigger a full cell refresh by calling the existing update path.
              -- The simplest safe approach: if the voting frame is currently visible,
              -- call the same refresh that fires on every RCVF update.
              -- doCellUpdate is a local function; expose a module-level trigger or
              -- replicate the session-stats invalidation pattern.
              --
              -- Safe approach: invalidate _sessionStats cache so the next render
              -- pass recomputes with the new palette. The cells will redraw on the
              -- next frame event or the next RCVF scroll.
              _sessionStats = {}
              -- For immediate visual update if the frame is visible:
              if rcVoting and rcVoting.frame and rcVoting.frame:IsShown() then
                  -- Trigger a scroll table refresh if the RC voting frame is open.
                  -- RC's scrolling table updates via :Refresh() on its lib-st widget.
                  if rcVoting.scrollTable and rcVoting.scrollTable.Refresh then
                      pcall(function() rcVoting.scrollTable:Refresh() end)
                  end
              end
          end)
      end
  ```

  Note: `_sessionStats` is a module-level upvalue in `VotingFrame.lua`. Clearing it to `{}` causes `doCellUpdate` to recompute colors on the next render. The `pcall` around the scroll table refresh is defensive — RC's internal API is not guaranteed stable.

- [ ] 6A.2 In `doCellUpdate`, add High Contrast cell-background logic immediately after the existing `cellFrame.text:SetTextColor(...)` call:

  ```lua
      -- 4.11: High Contrast mode fills the cell background.
      if ns.Theme and ns.Theme.hcMode and c then
          -- Fill the cell background with the score color.
          -- cellFrame must have been created with BackdropTemplate (verify with RC's
          -- cell factory — if not, skip the backdrop and rely on text color only).
          if cellFrame.SetBackdropColor then
              cellFrame:SetBackdropColor(c[1], c[2], c[3], 0.85)
          end
          -- Override text to white for maximum contrast.
          cellFrame.text:SetTextColor(1, 1, 1, 1)
      elseif cellFrame.SetBackdropColor then
          -- Restore transparent background when not in HC mode.
          cellFrame:SetBackdropColor(0, 0, 0, 0)
      end
  ```

**Sub-task 6B — `LootFrame.lua`**

`LootFrame.lua` uses `Theme.ScoreColor` in the transparency label (`"BL: 74"`). The consumer callback re-renders the label by calling the existing `LootFrame:Refresh()` if the frame is visible.

- [ ] 6B.1 In `LootFrame.lua`, inside the `Hook(addon, RC)` function, add:

  ```lua
      if ns.Theme and ns.Theme.RegisterColorModeConsumer then
          ns.Theme:RegisterColorModeConsumer(function()
              if ns.LootFrame and ns.LootFrame.Refresh then
                  pcall(function() ns.LootFrame:Refresh() end)
              end
          end)
      end
  ```

**Sub-task 6C — `UI/ComparePopout.lua`** (Batch 3D file)

The comparison popout draws per-component bars using `Theme.ScoreColor`. The consumer callback calls a `ComparePopout:Redraw()` method (or the equivalent refresh path already defined in Batch 3D) if the frame is visible.

- [ ] 6C.1 In `UI/ComparePopout.lua`, inside `CP:Setup(addon)`, add:

  ```lua
      if ns.Theme and ns.Theme.RegisterColorModeConsumer then
          ns.Theme:RegisterColorModeConsumer(function()
              if ns.ComparePopout and ns.ComparePopout.IsShown
                  and ns.ComparePopout:IsShown() then
                  -- Re-open with same arguments to redraw bars.
                  -- Batch 3D exposes CP._lastArgs = {nameA, nameB, itemID, ...}
                  -- for exactly this case.
                  if ns.ComparePopout._lastArgs then
                      pcall(function()
                          ns.ComparePopout:Open(table.unpack(ns.ComparePopout._lastArgs))
                      end)
                  end
              end
          end)
      end
  ```

  Note: Batch 3D's `CP:Open(...)` must save its arguments to `CP._lastArgs` for this pattern to work. If Batch 3D did not implement `_lastArgs`, add that persistence in the same commit:

  ```lua
  -- Inside CP:Open(nameA, nameB, itemID, itemLink, opts):
  CP._lastArgs = { nameA, nameB, itemID, itemLink, opts }
  ```

**Sub-task 6D — `UI/Toast.lua`** (Batch 3E file)

Toast uses `ns.Theme.success`, `warning`, `danger` for the left-edge stripe color. After a mode swap, the *next* toast shown picks up the new colors automatically (because it reads `T.success` etc. at `Show` time). No special consumer callback is needed for future toasts. However, if a toast is *currently visible* when the mode is swapped, its stripe color should update. The consumer callback updates the live stripe color.

Additionally, Toast must fire once per session when `BobleLoot_RCMissing` fires.

- [ ] 6D.1 In `UI/Toast.lua`, inside `Toast:Setup(addonArg)`, add the color-mode consumer:

  ```lua
      -- 4.11: update live toast stripe color on mode change.
      if ns.Theme and ns.Theme.RegisterColorModeConsumer then
          ns.Theme:RegisterColorModeConsumer(function()
              -- If a toast is currently visible, update its stripe.
              -- _toastLevel is a module-level local tracking the current level.
              if frame and frame:IsShown() and _toastLevel then
                  local col = (T and T[_toastLevel == "error" and "danger" or _toastLevel])
                              or T.warning
                  if frame._stripe then
                      frame._stripe:SetColorTexture(col[1], col[2], col[3], 1)
                  end
              end
          end)
      end
  ```

  Add `_toastLevel` as a module-level local in `Toast.lua` (alongside `holdTimer`, `textLabel`, etc.):

  ```lua
  local _toastLevel   -- "success"|"warning"|"error" — current or last shown level
  ```

  In `Toast:Show(message, level)`, assign `_toastLevel = level` before the animation begins.

- [ ] 6D.2 In `Toast:Setup(addonArg)`, add the `BobleLoot_RCMissing` listener (once per session):

  ```lua
      -- 4.10: show a toast once per session if RC is missing at startup.
      -- The 10-second timer in Core.lua fires BobleLoot_RCMissing via AceEvent.
      local _rcMissingToastShown = false
      addonArg:RegisterMessage("BobleLoot_RCMissing", function()
          if not _rcMissingToastShown then
              _rcMissingToastShown = true
              Toast:Show("RCLootCouncil not detected \xe2\x80\x94 score column unavailable.", "error")
          end
      end)
  ```

  The `\xe2\x80\x94` is the UTF-8 encoding of an em dash (U+2014), consistent with the existing em-dash usage in `SettingsPanel.lua`'s title text.

**Sub-task 6E — `UI/SettingsPanel.lua`** (example score row in Weights tab)

The Weights tab example score row calls `ns.Theme.ScoreColor(score)` to color the example score label. The consumer callback calls `refreshExampleRow()` (a local function in `BuildWeightsTab`) if the Weights tab is active.

- [ ] 6E.1 In `BuildWeightsTab`, after defining `refreshExampleRow`, add:

  ```lua
      -- 4.11: re-run example row when color mode changes.
      if ns.Theme and ns.Theme.RegisterColorModeConsumer then
          ns.Theme:RegisterColorModeConsumer(function()
              if activeTab == "weights" then
                  refreshExampleRow()
              end
          end)
      end
  ```

  Note: `activeTab` is the module-level local in `SettingsPanel.lua` that tracks the currently active tab name.

**Verification for Task 6:**
- Open voting frame with RC running. Switch color mode to "Deuter" via Settings → Tuning → Display. Confirm score cells immediately turn orange/blue without a `/reload`.
- Switch to "High Contrast". Confirm score cells show filled backgrounds with white text.
- Switch back to "Default". Confirm score cells return to red/amber/green text on transparent background.
- While a toast is visible, switch color mode → confirm the stripe color updates.

**Commit:** `feat: register color-mode consumers in VotingFrame, LootFrame, ComparePopout, Toast, SettingsPanel (4.11)`

---

## Task 7 — `Core.lua`: restore color mode on `OnEnable`

**Files:** `Core.lua`

After AceDB loads `db.profile.colorMode` from SavedVariables, the live `ns.Theme` palette must be set to match. This happens in `OnEnable` after all UI modules are loaded.

- [ ] 7.1 In `BobleLoot:OnEnable`, after the existing module Setup calls and after the `TryHookRC` call, add:

  ```lua
      -- 4.11: restore color mode from saved profile.
      if ns.Theme and ns.Theme.ApplyColorMode then
          local savedMode = self.db.profile.colorMode or "default"
          if savedMode ~= "default" then
              -- Only call if non-default; default is already the initial state.
              ns.Theme:ApplyColorMode(savedMode)
          end
      end
  ```

  The guard `savedMode ~= "default"` avoids calling `ApplyColorMode` (and firing all consumer callbacks) on a fresh load where the palette is already correct. On existing installs that chose "deuter" or "highcontrast" in a previous session, the swap happens after `OnEnable` — which is after UI frames are built for modules that do lazy initialization (`SettingsPanel` is not built until first open; `VotingFrame` is not hooked until `TryHookRC` succeeds). This is safe because the consumer callbacks for VotingFrame and LootFrame only fire if the respective RC frames are visible, and they cannot be visible before `OnEnable` completes.

  However: Toast, SettingsPanel example row, and ComparePopout register their consumers inside `Setup`/`BuildDataTab`/`BuildWeightsTab`. The Toast consumer is registered in `Toast:Setup(addon)` — called from `OnEnable`. The SettingsPanel consumers are registered inside the lazy `BuildFrames()` call, which runs on first panel open. The `ApplyColorMode` call in `OnEnable` fires consumers that are registered at that moment — Toast will receive the callback; SettingsPanel will not (because `BuildFrames` has not been called yet). This is acceptable: the SettingsPanel example row only needs to show the correct color when the tab is opened (it runs `refreshExampleRow()` in its `OnShow` handler which reads `ns.Theme.ScoreColor` at call time, not from a cached reference).

- [ ] 7.2 Verify: change `colorMode` to `"deuter"` in SavedVariables manually (edit `BobleLootDB.lua` in WTF), log in → score cells in the voting frame should show orange/blue without any manual toggle.

**Commit:** `feat(Core): restore saved color mode in OnEnable (4.11)`

---

## Task 8 — TOC load order verification

**Files:** `BobleLoot.toc`

No new files were added in this batch. Verify the existing TOC load order satisfies all dependencies introduced by Tasks 1–7:

- [ ] 8.1 Confirm `UI\Theme.lua` loads before `UI\Toast.lua` (Toast:Setup reads `ns.Theme`).
- [ ] 8.2 Confirm `UI\Toast.lua` loads before `UI\SettingsPanel.lua` (SettingsPanel's `BuildDataTab` sends to Toast via AceEvent — no direct reference, so load order doesn't matter for that; but Toast:Setup must be called before the 10s timer fires, which is guaranteed since both happen in `OnEnable`).
- [ ] 8.3 Confirm `UI\ComparePopout.lua` (Batch 3D) is listed before `UI\SettingsPanel.lua` (both loaded after `Theme.lua` — either order works since consumers are registered in Setup/Hook functions, not at file scope).
- [ ] 8.4 No new `<Script>` tags needed. No `embeds.xml` changes. Confirm by running `/reload` and checking that no "module not found" Lua errors appear.

**Commit:** `chore(toc): verify load order for Batch 4D (no changes needed)`

If no changes are needed, skip this commit.

---

## Manual Verification Checklist

The following checklist covers the full scope of items 4.10 and 4.11. No Lua test framework is available; all steps are performed in-game with `/console scriptErrors 1` enabled.

### RC-not-detected banner (4.10)

- [ ] **H1 — RC loaded at startup:** `/reload` with RC enabled. Wait 15 seconds. Open Settings → Data tab. Banner is not visible. Info card is at default vertical position (y=-6 relative to tab body top).

- [ ] **H2 — RC disabled at startup:** Disable RC in the Blizzard addon manager. `/reload`. Wait 12 seconds. A toast appears briefly reading "RCLootCouncil not detected — score column unavailable." in red. Open Settings → Data tab. Banner reads `|cffff5555RCLootCouncil not detected. Score column will appear once RC loads.|r` in red text. Info card is pushed down by ~52px.

- [ ] **H3 — Data tab opened before 10s timer fires:** Disable RC. `/reload`. Immediately open Settings → Data tab (within 2 seconds). Banner is NOT yet visible. Wait 12 seconds total from the reload. Banner appears automatically (via `BobleLoot_RCMissing` event handler) without re-opening the tab.

- [ ] **H4 — RC loads late (ADDON_LOADED path):** Disable RC. `/reload`. Wait 12 seconds (banner appears). Re-enable RC via the addon manager and do NOT reload. Instead, use the Blizzard "Load addon" button (if available on the server) or simulate by running `/run LoadAddOn("RCLootCouncil")`. The `ADDON_LOADED` event fires, `TryHookRC` succeeds, `BobleLoot_RCDetected` fires → banner hides automatically.

- [ ] **H5 — Coexistence with drift banner (3C):** With RC disabled AND schema drift simulated (per Batch 3C Task 6 procedure), both banners appear stacked. RC-not-detected banner is on top; schema drift banner is below; info card is pushed down by the combined height of both.

- [ ] **H6 — Toast fires only once per session:** Disable RC. `/reload`. Wait 12 seconds. Toast fires once. Trigger `BobleLoot_RCMissing` manually via `/run BobleLoot:SendMessage("BobleLoot_RCMissing")`. No second toast appears (`_rcMissingToastShown = true` guard).

- [ ] **H7 — "No data file loaded" message unaffected:** With RC loaded but `BobleLoot_Data.lua` absent (rename the file), `/reload`. Open Settings → Data tab. `infoCard` shows "No dataset loaded." in red. RC-not-detected banner does not appear.

### Color mode (4.11)

- [ ] **C1 — Default mode (no change from 1.x behavior):** Fresh install. Open Settings → Tuning → Display. "Color mode" dropdown reads "Default (red/amber/green)". Score cells in voting frame show red/amber/green. Example score row in Weights tab colors correctly. Freshness badge uses `Theme.warning` (amber) for stale data.

- [ ] **C2 — Switch to Deuter/Protan:** Select "Deuteranopia / Protanopia" from dropdown. Immediately (no reload): score cells shift to orange for low scores, blue for high scores. Toast stripe (if a toast fires) is orange/blue. ComparePopout bars (if open) redraw in orange/blue. Example score row in Weights tab updates.

- [ ] **C3 — Switch to High Contrast:** Select "High Contrast". Score cells show: cell background filled with red/amber/green (opaque, ~85% alpha) and text is white (`1,1,1,1`). Text is readable against the filled background.

- [ ] **C4 — Persistence across reload:** Set mode to "deuter". `/reload`. Open Tuning → Display → dropdown reads "Deuteranopia / Protanopia". Score cells immediately show orange/blue (mode was restored in `OnEnable`).

- [ ] **C5 — Return to Default:** Select "Default". Score cells return to red/amber/green text on transparent background. Cell backgrounds in HC mode are cleared (backdrop color reset to transparent).

- [ ] **C6 — Freshness badge consumer:** Set mode to "deuter". The freshness badge in score cells (Batch 1D, amber = stale, red = very stale) uses `Theme.warning` and `Theme.danger`. With deuter mode active, `Theme.warning` is now the intermediate orange-orange and `Theme.danger` is `#FF8C00`. Confirm badge colors updated.

- [ ] **C7 — VotingFrame consumer fires on mode change while frame is open:** Open the RC voting frame (or a test session). Switch color mode in Settings. Confirm the voting frame cells update immediately without closing/reopening.

- [ ] **C8 — scriptErrors 1 active, no Lua errors on any mode switch:** With `/console scriptErrors 1`, perform rapid switching between all three modes several times. No Lua error dialog appears.

---

## Palette Variant Reference Table

Exact RGBA values (r, g, b all in 0–1 range, a = 1.00) for each color mode and score band.

### Score band boundaries

| Band     | Threshold        |
|----------|-----------------|
| High     | score >= 70      |
| Mid      | 40 <= score < 70 |
| Low      | score < 40       |

### Default mode

| Band | Semantic name | Hex     | r     | g     | b     |
|------|---------------|---------|-------|-------|-------|
| High | success       | #19CC4D | 0.100 | 0.800 | 0.300 |
| Mid  | warning       | #FFA600 | 1.000 | 0.650 | 0.000 |
| Low  | danger        | #E63333 | 0.900 | 0.200 | 0.200 |

### Deuteranopia / Protanopia mode

| Band | Semantic name | Hex     | r     | g     | b     | Notes                         |
|------|---------------|---------|-------|-------|-------|-------------------------------|
| High | success       | #4D94FF | 0.302 | 0.580 | 1.000 | Blue — high score, cool hue   |
| Mid  | warning       | ~#E68026 | 0.900 | 0.550 | 0.150 | Intermediate amber-orange     |
| Low  | danger        | #FF8C00 | 1.000 | 0.549 | 0.000 | Orange — low score, warm hue  |

The deuteranopia palette uses exclusively the luminance difference between warm (orange) and cool (blue) to encode score level, entirely avoiding the red-green axis that deuteranopia and protanopia observers cannot distinguish.

### High Contrast mode

| Band | Semantic name | Hex     | r     | g     | b     | Application                    |
|------|---------------|---------|-------|-------|-------|-------------------------------|
| High | success       | #19CC4D | 0.100 | 0.800 | 0.300 | Cell background fill; text = white |
| Mid  | warning       | #FFA600 | 1.000 | 0.650 | 0.000 | Cell background fill; text = white |
| Low  | danger        | #E63333 | 0.900 | 0.200 | 0.200 | Cell background fill; text = white |

High Contrast uses the same hues as Default but inverts the contrast strategy: instead of colored text on a dark/transparent background (low luminance contrast for accessibility), it fills the cell background with the full-saturation color and renders text in solid white (`1, 1, 1, 1`). This produces a WCAG-compliant luminance contrast ratio for all three bands (green background + white text exceeds 4.5:1).

### `ScoreColorRelative` in deuter mode

`_ScoreColorRelativeDeuter` uses the same two-segment linear interpolation as the Default variant, but interpolates between `Theme.danger` (orange, #FF8C00) at the low end and `Theme.success` (blue, #4D94FF) at the high end, with `Theme.warning` (intermediate orange-amber) as the midpoint at the session median. The interpolation math is identical; only the palette endpoints differ.

---

## Consumer Registration Pattern

### How `RegisterColorModeConsumer` works

`Theme:RegisterColorModeConsumer(fn)` appends `fn` to the module-level `_colorModeConsumers` table inside `UI/Theme.lua`. When `Theme:SetColorMode(mode)` is called:

1. Live semantic color references (`Theme.success`, `Theme.warning`, `Theme.danger`, `Theme.hcMode`) are overwritten atomically.
2. `Theme.ScoreColor` and `Theme.ScoreColorRelative` are re-pointed to mode-specific implementations.
3. Every entry in `_colorModeConsumers` is called in registration order.

### Registration timing requirement

Consumers must call `RegisterColorModeConsumer` AFTER `ns.Theme` is available (i.e., after `UI/Theme.lua` has loaded) AND they must do so in a function body that runs at or after `Core:OnEnable` (not at file scope, since `ns.Theme` may be `nil` when the file first loads if the TOC load order places the consumer file before `UI/Theme.lua`).

| Consumer         | Registration site                     | Timing guarantee                              |
|------------------|---------------------------------------|-----------------------------------------------|
| `VotingFrame`    | Inside `VotingFrame:Hook(addon, RC)`  | Called from `Core:OnEnable` — after all loads |
| `LootFrame`      | Inside `LootFrame:Hook(addon, RC)`    | Called from `Core:OnEnable` — after all loads |
| `ComparePopout`  | Inside `ComparePopout:Setup(addon)`   | Called from `Core:OnEnable` — after all loads |
| `Toast`          | Inside `Toast:Setup(addon)`           | Called from `Core:OnEnable` — after all loads |
| `SettingsPanel` (example row) | Inside `BuildWeightsTab()` | Called lazily on first panel open — safe because mode swap fires consumers at that point; the next panel open re-reads `ns.Theme.ScoreColor` in `refreshExampleRow` anyway |
| `SettingsPanel` (Data tab) | `BobleLoot_RCMissing` / `BobleLoot_RCDetected` listeners in `BuildDataTab()` | Not a color-mode consumer; listens to AceEvents |

### Correct consumer pattern (template)

```lua
-- Inside a Setup or Hook function — never at file scope:
if ns.Theme and ns.Theme.RegisterColorModeConsumer then
    ns.Theme:RegisterColorModeConsumer(function()
        -- Re-read ns.Theme.success/warning/danger/ScoreColor at call time.
        -- Do NOT cache: local col = ns.Theme.success -- WRONG if cached at file load.
        -- Correct:      local col = ns.Theme.success -- OK if read inside this callback.
        if myFrame and myFrame:IsShown() then
            myFrame:Redraw()
        end
    end)
end
```

### Consumers must read colors at render time, not at registration time

Any consumer that caches `local col = ns.Theme.success` at the time `RegisterColorModeConsumer` is called will get a stale color reference after a mode switch. All consumers in this batch are written to read `ns.Theme.success` etc. inside the callback body (at mode-switch time) or inside their render function (at frame-draw time). The `_ScoreColorDefault` and `_ScoreColorDeuter` implementations read `Theme.success/warning/danger` at call time, not at definition time — this is the key property that makes the live-swap work without per-consumer color caches.

---

## Coordination Notes

### 4.10 (RC banner) and 4B (Import dataset, Data tab additions)

Batch 4B adds an "Import dataset" action to the Data tab's Actions card. The Actions card (`actCard`) is anchored below the info card (`infoCard`) with a fixed offset. When the RC-not-detected banner pushes `infoCard` down, `actCard` follows automatically because it is anchored to `infoCard`'s bottom edge (via `body:BOTTOMLEFT` at a fixed y offset). No additional offset logic is needed for `actCard`.

Batch 4B's executor should confirm: the import button (likely added to `actCard` or a new sub-card) is anchored to an existing `actCard` anchor, not to a hard-coded y offset from the body top. If 4B adds a new card below `actCard`, that card also follows automatically.

### 4.10 (RC banner) and 4C (RC version info line, planned)

Batch 4C (planned, not yet written) adds an RC version info line in the Data tab reading "Tested on RC %s, detected %s" with color-coded status. Per the task instructions the vertical order is:

```
[RC-not-detected banner]    ← this plan (4.10), y = -6 from body top
[Schema-drift banner]       ← Batch 3C
[Dataset info card]         ← Batch 1E (infoCard)
[RC version info line]      ← Batch 4C, inside or appended to infoCard
[generatedAt line]          ← already inside infoCard
[Actions card]
[Transparency card]
```

Batch 4C's executor should add the RC version info line inside `infoCard` (below the existing `generatedAt` line), not as a new top-level card. This keeps the info card as the single source for all RC-related metadata, with only the two warning banners appearing above it when abnormal conditions exist.

### 4.11 (color mode) and 4E (empty/error states audit, planned)

Batch 4E (planned, not yet written) audits every UI surface for designed empty/error states. The color-mode consumer pattern intersects with 4E in one way: in High Contrast mode, the cell background fill must still handle the `—` (missing-data dash) state correctly.

The `—` cell state (Batch 1D) does not call `Theme.ScoreColor`; it sets `cellFrame.text:SetTextColor(T.muted[1], T.muted[2], T.muted[3])`. In HC mode, the cell background should remain transparent for the `—` state (no score color to fill with). The `doCellUpdate` HC logic in Task 6A.2 is already conditional on `c` being non-nil (`if ns.Theme.hcMode and c then`), so the `—` path is unaffected.

Batch 4E's executor should add a checklist item: "Score cell in HC mode with missing data (`—`) — background transparent, text muted grey."

### Non-goal boundary: this is not a theme switcher

The color-mode implementation deliberately leaves untouched: `Theme.accent`, `Theme.accentDim`, `Theme.gold`, `Theme.muted`, `Theme.white`, all `Theme.bg*` surface colors, all `Theme.border*` colors, all font constants, panel chrome, tab styling, title bar, minimap icon, and any other decorative elements. `SetColorMode` modifies exactly three semantic color entries (`success`, `warning`, `danger`), one boolean flag (`hcMode`), and two function pointers (`ScoreColor`, `ScoreColorRelative`). This is the minimum set required to fulfill the accessibility goal without crossing into cosmetic theme territory.
