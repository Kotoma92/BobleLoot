# Batch 2A — Scoring Maturity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the scoring pipeline with spec-aware sim selection, role-based history weighting, tier preset bundles, and vault/BOE loot categorization so scoring reflects each character's actual main-spec sim, membership status, and the full picture of gear received.

**Architecture:** `wowaudit.py` extracts `mainspec` and `role` from the WoWAudit `/characters` API response and emits them into `BobleLoot_Data.lua`; `Scoring.lua` uses `mainspec` to pick the right spec's sim value and multiplies each character's history component by the per-role weight from profile settings. A new `tools/tiers/` directory ships JSON preset files (starting with `tww-s3.json`) keyed to tier-specific numbers; the `--tier` CLI flag loads a preset and overrides the corresponding `wowaudit.py` arguments before the run begins. `LootHistory.lua` gains a `vault` category fed by `C_WeeklyRewards` vault-selection events and RC's existing BOE-award log entries, with a configurable per-category weight defaulting to `0.5x` a normal drop; `UI/SettingsPanel.lua`'s Tuning tab gains per-role history-weight sliders.

**Tech Stack:** Python 3, pytest (existing harness), Lua (WoW 10.x API)

**Roadmap items covered:**

> **2.1 `[Data]` Spec-aware sim selection**
> Today `_best_wishlist_score` in `wowaudit.py` takes max across all specs, so a Holy Paladin with a Retribution wishlist has their sim dominated by Ret scores on Strength plate. Add `mainspec` field to the data file (from WoWAudit's role/spec field) and use only the matching spec's sim by default, with a tuning toggle to revert to max-across-specs.
> Keep the fetch logic behind one clean function signature so a future Raidbots swap is a small refactor (deferred pluggable-source-chain work reduces to this seam).

> **2.2 `[Data]` Role field + per-role history weight multiplier**
> Trial raiders with no loot history currently score impossibly high on the history component. Add a `role` field to the data file (`raider` / `trial` / `bench`) populated from WoWAudit's member status. Expose a per-role history-weight multiplier in the Tuning tab (default `trial = 0.5x`) so trial players have reduced history influence.

> **2.3 `[Data]` Cross-tier decay via `--tier` preset**
> `lootMinIlvl` currently requires manual tuning every tier. Ship a bundled `tools/tiers/<tier>.json` map of `ilvlFloor`, `mplusCap`, `historyDays`, `softFloor`, and BiS path per tier name. Add `--tier TWW-S3` flag that applies the preset without the raid leader needing to memorize the numbers on patch day.

> **2.4 `[Data]` BOE and Great Vault loot in history**
> BOE drops and Vault selections are currently invisible to loot history, so a raider who bought two BiS pieces or vaulted a trinket looks identical to a fresh player. Audit both sources (RC BOE logs, `C_WeeklyRewards` for vault) and add a `vault` category in `LootHistory` with configurable weight (default 0.5x a normal drop).

**Dependencies:** Batch 1 fully merged (1A wowaudit.py hardening, 1B simsKnown, 1E Settings panel with BuildTuningTab).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tools/wowaudit.py` | Modify | Add `_mainspec_sim_score()`, extend `fetch_rows` to extract `mainspec`/`role` from roster, emit both fields in `build_lua`, add `--tier` and `--spec-aware` / `--no-spec-aware` args |
| `tools/tiers/tww-s3.json` | Create | TWW Season 3 preset: `ilvlFloor`, `mplusCap`, `historyDays`, `softFloor`, `bisPath` |
| `tools/tiers/tww-s2.json` | Create | TWW Season 2 historical preset (reference/rollback target) |
| `tools/tests/test_wowaudit.py` | Modify | New test classes for `_mainspec_sim_score`, `role` extraction, `--tier` preset loading, and `build_lua` `mainspec`/`role` emission |
| `tools/tests/fixtures/characters_with_spec.json` | Create | Fixture: characters with `main_spec` / `status` fields for new tests |
| `tools/schemas/wowaudit_v1.json` | Modify | Add optional `main_spec`, `status` to `characters_response` schema |
| `Scoring.lua` | Modify | Consume `char.mainspec` to select spec-aware sim; apply per-role history multiplier from profile |
| `Data/BobleLoot_Data.example.lua` | Modify | Add `mainspec` and `role` fields to the example character block |
| `LootHistory.lua` | Modify | Add `vault` category; hook `C_WeeklyRewards` for vault selections; classify BOE RC entries; apply per-category vault weight |
| `UI/SettingsPanel.lua` | Modify | Add per-role history-weight sliders in `BuildTuningTab`; add spec-aware toggle in Tuning tab |
| `Core.lua` | Modify | Add AceDB defaults for `roleHistoryWeights`, `vaultWeight`, `specAwareSimSelection` |

---

## Tasks

### Task 1 — Extend `_best_wishlist_score` to a spec-aware variant

**Files:**
- Modify `tools/wowaudit.py` (around line 361, `_best_wishlist_score` function)
- Test: extend `tools/tests/test_wowaudit.py`

The existing `_best_wishlist_score` stays unchanged (it remains the default for convert-mode and as the `--no-spec-aware` fallback). A new sibling `_mainspec_sim_score(item, mainspec)` picks only the spec whose key matches `mainspec`; if no match it returns `None` so callers can fall back to the max.

- [ ] **1.1** Open `tools/wowaudit.py`. After the `_best_wishlist_score` function (currently at line ~361), add the following function:

  ```python
  def _mainspec_sim_score(item: dict, mainspec: str | None) -> float | None:
      """Return the sim percentage for the character's main spec only.

      Args:
          item: A wishlist item dict as returned by the WoWAudit API.
          mainspec: The spec name to match, e.g. ``"Holy"`` or ``"Protection"``.
              Case-insensitive prefix match is used so ``"holy"`` matches
              ``"Holy Paladin"`` if wowaudit ever returns a combined label.

      Returns:
          The percentage float for the matching spec, or ``None`` when the
          spec is not found in ``score_by_spec``.  Returns ``None`` (not 0.0)
          so callers can fall back to ``_best_wishlist_score`` rather than
          silently scoring zero.
      """
      if not mainspec:
          return None
      sbs = item.get("score_by_spec")
      if not isinstance(sbs, dict):
          return None
      target = mainspec.lower()
      for spec_key, spec_data in sbs.items():
          if not isinstance(spec_key, str):
              continue
          if spec_key.lower().startswith(target) or target.startswith(spec_key.lower()):
              if isinstance(spec_data, dict):
                  p = spec_data.get("percentage")
                  if isinstance(p, (int, float)):
                      return float(p)
      return None
  ```

- [ ] **1.2** Add tests at the bottom of the `_best_wishlist_score` test section in `tools/tests/test_wowaudit.py`:

  ```python
  # ---------------------------------------------------------------------------
  # Task 2A-1 — _mainspec_sim_score
  # ---------------------------------------------------------------------------

  def test_mainspec_sim_score_exact_match():
      item = {
          "score_by_spec": {
              "Holy": {"percentage": 3.5},
              "Protection": {"percentage": 1.2},
          }
      }
      assert wa._mainspec_sim_score(item, "Holy") == 3.5


  def test_mainspec_sim_score_case_insensitive():
      item = {"score_by_spec": {"Holy": {"percentage": 2.7}}}
      assert wa._mainspec_sim_score(item, "holy") == 2.7


  def test_mainspec_sim_score_no_match_returns_none():
      item = {"score_by_spec": {"Fire": {"percentage": 4.0}}}
      assert wa._mainspec_sim_score(item, "Frost") is None


  def test_mainspec_sim_score_none_mainspec_returns_none():
      item = {"score_by_spec": {"Fire": {"percentage": 4.0}}}
      assert wa._mainspec_sim_score(item, None) is None


  def test_mainspec_sim_score_empty_item_returns_none():
      assert wa._mainspec_sim_score({}, "Holy") is None


  def test_mainspec_sim_score_negative_allowed():
      """Negative (downgrade) values are returned as-is; caller decides what to do."""
      item = {"score_by_spec": {"Frost": {"percentage": -1.0}}}
      assert wa._mainspec_sim_score(item, "Frost") == -1.0


  def test_mainspec_sim_score_prefix_match():
      """'Holy Paladin' as key is matched by mainspec='Holy'."""
      item = {"score_by_spec": {"Holy Paladin": {"percentage": 5.5}}}
      assert wa._mainspec_sim_score(item, "Holy") == 5.5
  ```

- [ ] **1.3** Run `pytest tools/tests/test_wowaudit.py -k "mainspec_sim_score" -v` from the repo root and confirm all 7 new tests pass:

  ```
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_exact_match
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_case_insensitive
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_no_match_returns_none
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_none_mainspec_returns_none
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_empty_item_returns_none
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_negative_allowed
  PASSED tools/tests/test_wowaudit.py::test_mainspec_sim_score_prefix_match
  ```

- [ ] **1.4** Commit: `feat(python): add _mainspec_sim_score for spec-aware wishlist lookup`

---

### Task 2 — Extract `mainspec` and `role` from the roster API response

**Files:**
- Modify `tools/wowaudit.py` (`fetch_rows`, `_full_name`, row assembly ~line 540)
- Create `tools/tests/fixtures/characters_with_spec.json`
- Modify `tools/tests/test_wowaudit.py`

WoWAudit's `/characters` response includes `main_spec` (the character's primary spec name as a string, e.g. `"Holy"`) and `status` (member status string: `"raider"`, `"trial"`, `"bench"`, `"social"`, etc.). Both are optional fields — absent means we emit sensible defaults.

- [ ] **2.1** Create `tools/tests/fixtures/characters_with_spec.json`:

  ```json
  [
    {
      "id": 1,
      "name": "Boble",
      "realm": "Stormrage",
      "main_spec": "Holy",
      "status": "raider"
    },
    {
      "id": 2,
      "name": "Kotoma",
      "realm": "Twisting Nether",
      "main_spec": "Protection",
      "status": "trial"
    },
    {
      "id": 3,
      "name": "Benchman",
      "realm": "Stormrage",
      "main_spec": "Fury",
      "status": "bench"
    },
    {
      "id": 4,
      "name": "NoSpec",
      "realm": "Stormrage"
    }
  ]
  ```

- [ ] **2.2** In `tools/wowaudit.py`, locate the `# --- assemble rows ---` block (around line 540). In the row-assembly loop, after the existing `mplus_dungeons` and `attendance` keys, add extraction of `mainspec` and `role`:

  ```python
  # Determine role from WoWAudit member status.
  # "raider" / "trial" / "bench" are first-class; anything else
  # (social, unknown, absent) maps to "raider" as a safe default
  # so scoring is never accidentally suppressed for a real raider
  # whose API field uses an unfamiliar label.
  _ROLE_MAP = {
      "trial": "trial",
      "bench": "bench",
  }
  ```

  Place `_ROLE_MAP` as a module-level constant just above `fetch_rows`.

  Then in the per-character row assembly loop:

  ```python
  raw_status  = c.get("status") or ""
  row["role"]     = _ROLE_MAP.get(raw_status.lower(), "raider")
  row["mainspec"] = (c.get("main_spec") or "").strip() or None
  ```

  Place these two lines immediately after `"attendance": attendance_by_id.get(cid, 0)` in the row dict.

- [ ] **2.3** Update `tools/schemas/wowaudit_v1.json` — add `main_spec` and `status` as optional properties to the `characters_response` item schema:

  ```json
  "main_spec": { "type": ["string", "null"] },
  "status":    { "type": ["string", "null"] }
  ```

  These go inside the existing `"properties"` block of the `characters_response` array item, alongside `"id"`, `"name"`, and `"realm"`.

- [ ] **2.4** Add tests to `tools/tests/test_wowaudit.py` in a new section:

  ```python
  # ---------------------------------------------------------------------------
  # Task 2A-2 — mainspec / role extraction from roster
  # ---------------------------------------------------------------------------

  def test_fetch_rows_extracts_mainspec_and_role(monkeypatch):
      def fake_http(path, key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters_with_spec.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return {"characters": []}
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _, _ = wa.fetch_rows("key", None)
      by_name = {r["character"]: r for r in rows}

      assert by_name["Boble-Stormrage"]["mainspec"] == "Holy"
      assert by_name["Boble-Stormrage"]["role"]     == "raider"
      assert by_name["Kotoma-TwistingNether"]["mainspec"] == "Protection"
      assert by_name["Kotoma-TwistingNether"]["role"]     == "trial"
      assert by_name["Benchman-Stormrage"]["role"]        == "bench"


  def test_fetch_rows_missing_spec_gives_none(monkeypatch):
      def fake_http(path, key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters_with_spec.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return {"characters": []}
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _, _ = wa.fetch_rows("key", None)
      by_name = {r["character"]: r for r in rows}
      # NoSpec character has no main_spec field
      assert by_name["NoSpec-Stormrage"]["mainspec"] is None
      assert by_name["NoSpec-Stormrage"]["role"] == "raider"


  def test_role_map_unknown_status_defaults_to_raider():
      """An unrecognised status string maps to 'raider', not 'trial' or 'bench'."""
      assert wa._ROLE_MAP.get("social", "raider") == "raider"
      assert wa._ROLE_MAP.get("", "raider")        == "raider"
  ```

- [ ] **2.5** Run `pytest tools/tests/test_wowaudit.py -k "extracts_mainspec or missing_spec or role_map" -v` and confirm the 3 new tests pass.

- [ ] **2.6** Commit: `feat(python): extract mainspec and role fields from WoWAudit roster`

---

### Task 3 — Emit `mainspec`, `role`, and spec-aware sims in `build_lua`

**Files:**
- Modify `tools/wowaudit.py` (`build_lua` function ~line 202)
- Modify `Data/BobleLoot_Data.example.lua`
- Modify `tools/tests/test_wowaudit.py`

The Lua data file gains two new per-character fields: `mainspec = "Holy"` and `role = "raider"`. For API-mode runs where `--spec-aware` is in effect (default), `sims` and `simsKnown` are populated using `_mainspec_sim_score` instead of `_best_wishlist_score`; the fallback to max-across-specs is applied when `_mainspec_sim_score` returns `None` for a given item.

- [ ] **3.1** In `build_lua`, inside the per-row loop (after the `attendance` / `mplusDungeons` lines), add emission of `mainspec` and `role`. The `mainspec` value comes from `row.get("mainspec")` and the `role` comes from `row.get("role", "raider")`:

  ```python
  # mainspec and role — only emit if present (convert-mode CSVs won't
  # have these columns; that's fine, Scoring.lua treats absent = raider).
  mainspec_val = row.get("mainspec")
  role_val     = row.get("role", "raider")
  if mainspec_val:
      out.append(f'            mainspec      = "{_lua_escape(mainspec_val)}",')
  out.append(f'            role          = "{_lua_escape(role_val)}",')
  ```

  Insert these lines immediately after the `mplusDungeons` emission line.

- [ ] **3.2** Also extend `build_lua`'s signature to accept a `spec_aware: bool = True` parameter. Thread this flag through the sim-assignment logic so that when `spec_aware=True` and the row contains a `mainspec` key, sims are built using `_mainspec_sim_score` first, falling back to `_best_wishlist_score` when the spec is not found for a given item.

  The current sim-assignment block in `build_lua` (which reads from `row[f"sim_{iid}"]`) is CSV-mode only — API-mode sim values land in `row[f"sim_{iid}"]` through `sims_by_id` already, so the spec-awareness pivot happens in `fetch_rows` before rows are assembled. However the `build_lua` function is also called from tests with raw rows. The cleanest separation is:

  - `fetch_rows` passes `mainspec` per character into the row dict (done in Task 2).
  - A new helper `_resolve_sims_for_row(row, wishlist_items, spec_aware)` is added. In API mode, `fetch_rows` calls this helper to populate `sim_<iid>` columns with the correct per-spec value. In convert mode, the existing CSV column logic is unchanged because CSVs have no `score_by_spec` structure.
  - The full spec-aware sim resolution is optional (flag `--no-spec-aware` reverts to max-across-specs behaviour for the whole run).

  For `build_lua` itself, the function does not need to know about spec-awareness — it just emits whatever `sim_<iid>` values are in the row. The `spec_aware` parameter is therefore on `fetch_rows` and forwarded into the wishlist iteration loop.

  In `fetch_rows`, locate the wishlist-item loop (around line 528):

  ```python
  # Current line in fetch_rows (Batch 1):
  score = _best_wishlist_score(item)
  ```

  Replace with:

  ```python
  char_mainspec = None  # set per character outside the item loop
  # (see step 3.3 for the outer loop change)
  if spec_aware:
      score = _mainspec_sim_score(item, char_mainspec)
      if score is None:
          score = _best_wishlist_score(item)
  else:
      score = _best_wishlist_score(item)
  ```

- [ ] **3.3** In the `fetch_rows` function, the wishlist-characters outer loop currently iterates over `wl_chars`. Each character dict has an `id`; we already have `roster` with `main_spec` per character. Build a `mainspec_by_id` lookup alongside `sims_by_id`:

  ```python
  mainspec_by_id: dict[int, str | None] = {}
  for c in roster:
      if isinstance(c, dict):
          cid = c.get("id")
          if isinstance(cid, int):
              raw = c.get("main_spec") or ""
              mainspec_by_id[cid] = raw.strip() or None
  ```

  Then in the wishlist-item loop, just before iterating `encounters`, set:

  ```python
  char_mainspec = mainspec_by_id.get(cid)
  ```

  And use `char_mainspec` in the spec-aware score selection from step 3.2.

- [ ] **3.4** Add `spec_aware: bool = True` as a parameter of `fetch_rows`. Pass it through from `main()` based on a new `--no-spec-aware` flag (see Task 5 for the argparse additions).

- [ ] **3.5** Add tests for `build_lua` `mainspec`/`role` emission:

  ```python
  # ---------------------------------------------------------------------------
  # Task 2A-3 — build_lua emits mainspec and role fields
  # ---------------------------------------------------------------------------

  def test_build_lua_emits_mainspec_when_present():
      rows = [
          {"character": "Boble-Stormrage", "attendance": 95.0,
           "mplus_dungeons": 30, "mainspec": "Holy", "role": "raider"},
      ]
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
      assert 'mainspec      = "Holy"' in lua
      assert 'role          = "raider"' in lua


  def test_build_lua_emits_role_defaults_to_raider():
      rows = [
          {"character": "Boble-Stormrage", "attendance": 95.0,
           "mplus_dungeons": 30},
      ]
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
      assert 'role          = "raider"' in lua


  def test_build_lua_omits_mainspec_when_absent():
      """Convert-mode rows without mainspec key do not emit a mainspec line."""
      rows = [
          {"character": "Boble-Stormrage", "attendance": 95.0, "mplus_dungeons": 30},
      ]
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
      assert "mainspec" not in lua


  def test_build_lua_trial_role_emitted():
      rows = [
          {"character": "NewGuy-Realm", "attendance": 60.0,
           "mplus_dungeons": 5, "mainspec": "Frost", "role": "trial"},
      ]
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
      assert 'role          = "trial"' in lua


  def test_fetch_rows_spec_aware_uses_mainspec_sim(monkeypatch):
      """With spec_aware=True, per-spec sim score is preferred over max."""

      def fake_http(path, key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return [{"id": 1, "name": "Boble", "realm": "Stormrage",
                       "main_spec": "Holy", "status": "raider"}]
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return {
                  "characters": [{
                      "id": 1,
                      "instances": [{
                          "difficulties": [{
                              "wishlist": {
                                  "encounters": [{
                                      "items": [{
                                          "id": 212401,
                                          "score_by_spec": {
                                              "Holy":       {"percentage": 2.5},
                                              "Protection": {"percentage": 8.0},
                                          },
                                          "wishes": [],
                                      }]
                                  }]
                              }
                          }]
                      }]
                  }]
              }
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _, _ = wa.fetch_rows("key", None, spec_aware=True)
      row = rows[0]
      # Holy = 2.5, Protection = 8.0; spec_aware should pick Holy (2.5)
      assert row.get("sim_212401") == 2.5


  def test_fetch_rows_no_spec_aware_uses_max(monkeypatch):
      """With spec_aware=False, max across specs is used."""

      def fake_http(path, key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return [{"id": 1, "name": "Boble", "realm": "Stormrage",
                       "main_spec": "Holy", "status": "raider"}]
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return {
                  "characters": [{
                      "id": 1,
                      "instances": [{
                          "difficulties": [{
                              "wishlist": {
                                  "encounters": [{
                                      "items": [{
                                          "id": 212401,
                                          "score_by_spec": {
                                              "Holy":       {"percentage": 2.5},
                                              "Protection": {"percentage": 8.0},
                                          },
                                          "wishes": [],
                                      }]
                                  }]
                              }
                          }]
                      }]
                  }]
              }
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _, _ = wa.fetch_rows("key", None, spec_aware=False)
      row = rows[0]
      # spec_aware=False: max across specs = 8.0
      assert row.get("sim_212401") == 8.0
  ```

- [ ] **3.6** Run `pytest tools/tests/test_wowaudit.py -k "2A-3 or emits_mainspec or emits_role or spec_aware" -v` and confirm all 8 tests pass.

- [ ] **3.7** Update `Data/BobleLoot_Data.example.lua` — add `mainspec` and `role` to the example character block:

  ```lua
  ["Examplechar-Examplerealm"] = {
      attendance    = 100.0,
      mplusDungeons = 0,
      mainspec      = "Holy",
      role          = "raider",
      bis      = { [12345] = true },
      sims     = { [12345] = 1.23 },
      simsKnown = { [12345] = true },
  },
  ```

- [ ] **3.8** Commit: `feat(python): emit mainspec/role in build_lua; spec-aware sim selection in fetch_rows`

---

### Task 4 — `Scoring.lua` consumes `mainspec` and applies per-role history multiplier

**Files:**
- Modify `Scoring.lua`

`Scoring.lua` currently computes `historyComponent` without any role-awareness. After this task it reads `char.role` (defaulting to `"raider"` when absent) and multiplies the history component value by the per-role weight from `profile.roleHistoryWeights`. The spec-aware data is already baked into `char.sims` by `wowaudit.py`, so `Scoring.lua` does not need to reselect specs at runtime — the selection already happened at data-generation time. The one Scoring.lua change for spec-awareness is informational: when `char.mainspec` is present, it is passed through in the breakdown so tooltips can display it.

- [ ] **4.1** In `Scoring.lua`, locate `historyComponent` (around line 68). After its existing return statement, no changes to the function body are needed — the multiplier is applied at the call site in `Scoring:Compute`. In `Scoring:Compute`, find the line:

  ```lua
  local histVal, histRaw = historyComponent(char, historyCap, historyReference)
  ```

  Replace it with:

  ```lua
  local histVal, histRaw = historyComponent(char, historyCap, historyReference)
  -- Per-role history multiplier: trial/bench players have reduced history
  -- influence so they don't score impossibly high due to zero history.
  if histVal ~= nil then
      local roleWeights = (profile.roleHistoryWeights) or {}
      local charRole    = (char.role) or "raider"
      local roleMult    = roleWeights[charRole]
      if type(roleMult) == "number" then
          -- Multiplier < 1 reduces influence; > 1 amplifies.
          -- Clamp to [0, 2] to guard against accidental extreme values.
          roleMult = math.max(0, math.min(2, roleMult))
          -- The history component returns a 0..1 value where 1 = best
          -- (no loot received). A trial raider with zero history gets
          -- histVal=1.0 which scores perfectly. Multiplying by < 1
          -- pulls their history value toward the mid-point (0.5).
          -- Formula: 0.5 + (histVal - 0.5) * roleMult
          -- When roleMult=1.0 this is a no-op.
          histVal = 0.5 + (histVal - 0.5) * roleMult
          histVal = math.max(0, math.min(1, histVal))
      end
  end
  ```

- [ ] **4.2** In `Scoring:Compute`, find the `components` table construction. Add `mainspec` to the `sim` component entry so it is available for display in tooltips:

  ```lua
  sim = { value = simVal, raw = simRaw, reference = simReference,
          mainspec = char.mainspec },
  ```

- [ ] **4.3** Manual verification (in-game): Load the addon with a data file containing `role = "trial"` for one character. Verify in the tooltip that their history component is visibly lower than an equivalent `role = "raider"` character with the same `itemsReceived`. Set `trial` weight to 0 and confirm history reads as 0.5 (midpoint). Set weight to 1.0 and confirm history component is unchanged.

- [ ] **4.4** Commit: `feat(lua): apply per-role history multiplier in Scoring:Compute`

---

### Task 5 — Tier preset files and `--tier` CLI flag

**Files:**
- Create `tools/tiers/tww-s3.json`
- Create `tools/tiers/tww-s2.json`
- Modify `tools/wowaudit.py` (`main()` argparse + tier loading helper)
- Modify `tools/tests/test_wowaudit.py`

A tier preset is a JSON file with five keys. All keys are optional in the file (missing keys mean "keep the default/CLI value"). The `--tier` flag is a name that maps to a file at `tools/tiers/<name>.json` (case-insensitive lookup, hyphens normalised). Preset values are applied before argparse defaults are resolved but after explicit CLI args, so explicit CLI overrides always win.

- [ ] **5.1** Create `tools/tiers/tww-s3.json`:

  ```json
  {
    "_comment": "The War Within Season 3 preset — adjust numbers at tier release.",
    "ilvlFloor":   636,
    "mplusCap":    160,
    "historyDays": 84,
    "softFloor":   6,
    "bisPath":     null
  }
  ```

  `bisPath` is `null` meaning "use --bis if provided or none" — not every guild manages a BiS file in the repo.

- [ ] **5.2** Create `tools/tiers/tww-s2.json`:

  ```json
  {
    "_comment": "The War Within Season 2 — historical reference preset.",
    "ilvlFloor":   610,
    "mplusCap":    130,
    "historyDays": 84,
    "softFloor":   5,
    "bisPath":     null
  }
  ```

- [ ] **5.3** Add a module-level `TIERS_DIR` constant and `_load_tier_preset` function to `tools/wowaudit.py`, just below the existing `DEFAULT_OUT` / `REQUIRED_COLS` constants block:

  ```python
  TIERS_DIR = Path(__file__).resolve().parent / "tiers"

  def _load_tier_preset(tier_name: str) -> dict:
      """Load a tier preset JSON file from ``tools/tiers/``.

      The file is looked up as ``tools/tiers/<tier_name>.json`` with
      case-insensitive matching and hyphens normalised to lower case.

      Args:
          tier_name: e.g. ``"TWW-S3"`` or ``"tww-s3"``.

      Returns:
          Dict with any subset of keys: ``ilvlFloor``, ``mplusCap``,
          ``historyDays``, ``softFloor``, ``bisPath``.

      Raises:
          SystemExit: If no matching preset file is found.
      """
      normalised = tier_name.strip().lower()
      candidate  = TIERS_DIR / f"{normalised}.json"
      if not candidate.is_file():
          available = sorted(p.stem for p in TIERS_DIR.glob("*.json"))
          sys.exit(
              f"Tier preset '{tier_name}' not found. "
              f"Available: {', '.join(available) or '(none)'}. "
              f"Preset files live in tools/tiers/."
          )
      try:
          with candidate.open(encoding="utf-8") as f:
              return json.load(f)
      except (json.JSONDecodeError, OSError) as exc:
          sys.exit(f"Failed to load tier preset '{tier_name}': {exc}")
  ```

- [ ] **5.4** In `main()`, add a `--tier` argument and the preset-application logic. Insert after the existing `ap.add_argument("--history-cap", ...)` line:

  ```python
  ap.add_argument(
      "--tier",
      default=None,
      metavar="NAME",
      help=(
          "Apply a named tier preset from tools/tiers/<NAME>.json. "
          "Sets ilvlFloor, mplusCap, historyDays, softFloor, and optionally "
          "bisPath. Example: --tier TWW-S3. "
          "Explicit --mplus-cap / --history-cap / --loot-min-ilvl values "
          "always override the preset."
      ),
  )
  ap.add_argument(
      "--loot-min-ilvl",
      type=int,
      default=None,
      help=(
          "Minimum item level for loot history entries. "
          "Overrides the tier preset's ilvlFloor if both are specified."
      ),
  )
  ap.add_argument(
      "--no-spec-aware",
      action="store_true",
      default=False,
      help=(
          "Revert sim selection to max-across-all-specs (pre-2.1 behaviour). "
          "Default is spec-aware: only the character's main spec's sim is used."
      ),
  )
  ```

  Then after `args = ap.parse_args()`, apply the tier preset before computing derived values:

  ```python
  # Apply tier preset (values are only used as defaults if the
  # corresponding explicit CLI argument was not provided).
  tier_preset: dict = {}
  if args.tier is not None:
      tier_preset = _load_tier_preset(args.tier)

  def _preset(key: str, cli_val, default):
      """Return cli_val if it was explicitly set, else preset value, else default."""
      if cli_val is not None:
          return cli_val
      if key in tier_preset and tier_preset[key] is not None:
          return tier_preset[key]
      return default

  # Resolve loot min ilvl (used later in main for the run report / Lua header).
  loot_min_ilvl = _preset("ilvlFloor", args.loot_min_ilvl, 0)
  # Resolve history days override.
  history_days_override = _preset("historyDays", None, None)
  # Resolve soft floor (history cap).
  soft_floor_override = _preset("softFloor", None, None)
  ```

  Also resolve `mplus_cap` from the preset when not provided on the CLI:

  ```python
  if args.mplus_cap is not None:
      mplus_cap = args.mplus_cap
  else:
      preset_mplus = tier_preset.get("mplusCap")
      if preset_mplus is not None:
          mplus_cap = int(preset_mplus)
      else:
          mplus_cap = max(args.mplus_cap_per_week,
                          args.mplus_cap_per_week * max(weeks_in_season, 1))
  ```

  Emit `loot_min_ilvl` and `history_days_override` into the Lua file by passing them to `build_lua`. Add these as new optional parameters to `build_lua` (default `None`):

  ```python
  lua = build_lua(
      rows, bis, args.sim_cap, mplus_cap, args.history_cap,
      team_url,
      fetch_warnings if not args.wowaudit else None,
      loot_min_ilvl=loot_min_ilvl,
      history_days=history_days_override,
      tier_name=args.tier,
  )
  ```

- [ ] **5.5** Update `build_lua` signature and body to accept and emit the new fields:

  ```python
  def build_lua(
      rows: list[dict],
      bis: dict[str, list[int]],
      sim_cap: float,
      mplus_cap: int,
      history_cap: int,
      team_url: str | None = None,
      fetch_warnings: list[str] | None = None,
      loot_min_ilvl: int = 0,
      history_days: int | None = None,
      tier_name: str | None = None,
  ) -> str:
  ```

  In the header block of `build_lua`, add emission lines after `historyCap`:

  ```python
  if tier_name:
      out.append(f'    tierPreset  = "{_lua_escape(tier_name)}",')
  if loot_min_ilvl:
      out.append(f"    lootMinIlvl = {loot_min_ilvl},")
  if history_days is not None:
      out.append(f"    historyDays = {history_days},")
  ```

  `LootHistory.lua` already reads `profile.lootMinIlvl` from AceDB profile, not from the data file; these data-file fields serve as documentation/display in the Data tab only. `Scoring.lua` reads `data.historyCap` via the existing `historyCap` field — `history_days` is an optional supplement for future use and displayed in the Data tab.

- [ ] **5.6** Add tier preset tests:

  ```python
  # ---------------------------------------------------------------------------
  # Task 2A-5 — tier preset loading
  # ---------------------------------------------------------------------------

  def test_load_tier_preset_tww_s3():
      preset = wa._load_tier_preset("TWW-S3")
      assert preset["ilvlFloor"] == 636
      assert preset["mplusCap"]  == 160


  def test_load_tier_preset_case_insensitive():
      preset = wa._load_tier_preset("tww-s3")
      assert preset["mplusCap"] == 160


  def test_load_tier_preset_unknown_exits(monkeypatch):
      import sys
      with pytest.raises(SystemExit):
          wa._load_tier_preset("totally-fake-tier-xyz")


  def test_load_tier_preset_tww_s2():
      preset = wa._load_tier_preset("TWW-S2")
      assert preset["ilvlFloor"] == 610


  def test_build_lua_emits_tier_preset_name():
      rows = [{"character": "Boble-Stormrage", "attendance": 95.0, "mplus_dungeons": 30}]
      lua = wa.build_lua(
          rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
          tier_name="TWW-S3",
      )
      assert 'tierPreset  = "TWW-S3"' in lua


  def test_build_lua_emits_loot_min_ilvl():
      rows = [{"character": "Boble-Stormrage", "attendance": 95.0, "mplus_dungeons": 30}]
      lua = wa.build_lua(
          rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
          loot_min_ilvl=636,
      )
      assert "lootMinIlvl = 636" in lua


  def test_build_lua_omits_loot_min_ilvl_when_zero():
      rows = [{"character": "Boble-Stormrage", "attendance": 95.0, "mplus_dungeons": 30}]
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5, loot_min_ilvl=0)
      assert "lootMinIlvl" not in lua
  ```

- [ ] **5.7** Run `pytest tools/tests/test_wowaudit.py -k "tier" -v` and confirm all 7 tier tests pass.

- [ ] **5.8** Commit: `feat(python): add --tier preset flag and tools/tiers/ directory`

---

### Task 6 — AceDB defaults for new profile keys

**Files:**
- Modify `Core.lua`

Three new profile keys must have defaults before Scoring.lua and SettingsPanel.lua can safely read them on a fresh install.

- [ ] **6.1** In `Core.lua`, locate the `DB_DEFAULTS` table (around line 19). Inside `profile = {`, add the following after the existing `lootWeights` block:

  ```lua
  -- Per-role history weight multiplier (2.2).
  -- 1.0 = no adjustment, 0.5 = half influence, 0.0 = history excluded.
  roleHistoryWeights = {
      raider = 1.0,
      trial  = 0.5,
      bench  = 0.5,
  },
  -- Vault and BOE loot weight relative to a normal awarded drop (2.4).
  vaultWeight = 0.5,
  -- Whether sim selection uses character's main spec (true) or max
  -- across all specs (false). Default true per 2.1 design.
  specAwareSimSelection = true,
  ```

- [ ] **6.2** Also bump `BobleLoot.version` to `"1.2.0-dev"` (reflects Batch 2 work in progress). This is in `Core.lua` around line 16:

  ```lua
  BobleLoot.version = "1.2.0-dev"
  ```

- [ ] **6.3** Commit: `feat(lua): AceDB defaults for roleHistoryWeights, vaultWeight, specAwareSimSelection`

---

### Task 7 — Per-role history-weight sliders in `BuildTuningTab`

**Files:**
- Modify `UI/SettingsPanel.lua`

The Tuning tab already has five sliders. Add a "Role modifiers" subsection below the existing controls with three read-only-labelled sliders: Raider, Trial, Bench. Each maps to `profile.roleHistoryWeights.<role>`. The sliders sit below the existing loot history window slider (which ends around y = -266 in the current layout).

- [ ] **7.1** In `UI/SettingsPanel.lua`, locate `BuildTuningTab`. After the closing of the `MakeSlider` for "Loot history window" (around line 775 based on Batch 1 numbering), add the following subsection. The y-values continue downward from −266:

  ```lua
  -- Role history weight multipliers (Batch 2.2).
  -- Heading label.
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
  ```

  Note: `T` is already available as `local T = ns.Theme` at the top of `BuildTuningTab`. `ScheduleLootHistoryApply` is the debounce helper already defined at module scope in `SettingsPanel.lua`.

- [ ] **7.2** Extend the card height to accommodate the new controls. The card `SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)` causes the card to fill the body frame; no explicit height is needed since the body fills the tab panel. Verify the scroll position is sufficient by checking that `MakeSection`'s inner frame is tall enough — if the inner frame uses a fixed height, extend it by ~140px.

- [ ] **7.3** Manual verification (in-game):
  - Open `/bl` settings, go to Tuning tab.
  - Confirm three new sliders appear below "Loot history window": Raider, Trial, Bench.
  - Drag Trial slider to 0.0. Reload UI. Confirm slider reads 0.0 on next open (AceDB persistence check).
  - Set Trial back to 0.5. Open voting frame on any item. Confirm a trial raider's score tooltip shows reduced history influence compared to a raider with the same items received. (Requires a live data file with `role = "trial"` for a character.)

- [ ] **7.4** Commit: `feat(lua): per-role history-weight sliders in BuildTuningTab`

---

### Task 8 — BOE classification in `LootHistory`

**Files:**
- Modify `LootHistory.lua`

RC logs BOE items when they are awarded (the "give to" flow in RC's BOE distribution frame). These entries appear in `RCLootCouncilLootDB` with a response string containing `"boe"` or `"bind on equip"`. Currently these entries fall through to `nil` return in `classify()` and are silently dropped. After this task they are classified as `vault` category with the `vaultWeight` multiplier.

- [ ] **8.1** In `LootHistory.lua`, locate `CATEGORY_PATTERNS` (around line 61). Add a new entry at the top (most specific first) so BOE responses are caught before `mainspec` would swallow them:

  ```lua
  local CATEGORY_PATTERNS = {
      { key = "bis",      patterns = { "^bis$", "best in slot", "%(bis%)" } },
      { key = "major",    patterns = { "major" } },
      { key = "minor",    patterns = { "minor", "small upgrade" } },
      { key = "mainspec", patterns = { "mainspec", "main%-spec", "main spec",
                                       "need", "upgrade" } },
      -- BOE distributions are tracked as "vault" category (same weight,
      -- configurable). Tested after the normal upgrade categories so a
      -- response of "Major upgrade (BOE)" still reads as "major".
      { key = "vault",    patterns = { "boe", "bind on equip", "bind%-on%-equip" } },
  }
  ```

- [ ] **8.2** Update `DEFAULT_WEIGHTS` to include `vault`:

  ```lua
  local DEFAULT_WEIGHTS = { bis = 1.5, major = 1.0, mainspec = 1.0, minor = 0.5, vault = 0.5 }
  ```

- [ ] **8.3** Update `effectiveWeights` to read `vaultWeight` from the profile:

  ```lua
  local function effectiveWeights(profile)
      local w = profile.lootWeights or {}
      return {
          bis      = w.bis      or DEFAULT_WEIGHTS.bis,
          major    = w.major    or DEFAULT_WEIGHTS.major,
          mainspec = w.mainspec or DEFAULT_WEIGHTS.mainspec,
          minor    = w.minor    or DEFAULT_WEIGHTS.minor,
          vault    = (profile.vaultWeight ~= nil) and profile.vaultWeight
                     or DEFAULT_WEIGHTS.vault,
      }
  end
  ```

- [ ] **8.4** Update `CountItemsReceived` — expand the `row.counts` initialiser to include `vault`:

  ```lua
  local row = { total = 0, counts = { bis = 0, major = 0, mainspec = 0, minor = 0, vault = 0 } }
  ```

- [ ] **8.5** Manual verification (in-game): Award a BOE item using RC's distribution flow so it lands in `RCLootCouncilLootDB` with a response containing "boe". Then `/bl lootdb` and confirm the character's vault/BOE entry is counted. In the score tooltip, `itemsReceivedBreakdown.vault` should be > 0.

- [ ] **8.6** Commit: `feat(lua): classify BOE RC entries as vault category in LootHistory`

---

### Task 9 — `C_WeeklyRewards` vault selection hook

**Files:**
- Modify `LootHistory.lua`
- Modify `Core.lua` (event registration)

When a player clicks "collect" on a Great Vault slot in-game, `WEEKLY_REWARDS_ITEM_GRABBED` fires. We hook this event on the leader's client and create a synthetic loot entry in a local `BobleLootDB.profile.vaultEntries` list. `LH:Apply` then merges these synthetic entries with the RC history before computing.

- [ ] **9.1** In `LootHistory.lua`, add a new function `LH:RecordVaultSelection` that accepts `(addon, playerName, itemLink, ilvl)` and appends a synthetic entry:

  ```lua
  -- Record a Great Vault selection as a synthetic loot history entry.
  -- Called from Core.lua's WEEKLY_REWARDS_ITEM_GRABBED handler.
  function LH:RecordVaultSelection(addon, playerName, itemLink, ilvl)
      local profile = addon.db.profile
      profile.vaultEntries = profile.vaultEntries or {}
      local entry = {
          player   = playerName,
          link     = itemLink,
          ilvl     = ilvl,
          response = "vault",
          time     = time(),
      }
      table.insert(profile.vaultEntries, entry)
      -- Kick off a debounced re-apply so the score updates promptly.
      if ns.SettingsPanel and ns.SettingsPanel.ScheduleLootHistoryApply then
          ns.SettingsPanel.ScheduleLootHistoryApply()
      end
  end
  ```

- [ ] **9.2** Modify `LH:CountItemsReceived` to accept an additional optional `extraEntries` table argument (a list of synthetic entries in the same format as RC entries, keyed the same way as `rcLootDB`):

  ```lua
  function LH:CountItemsReceived(rcLootDB, days, weights, minIlvl, extraEntries)
  ```

  At the top of the function, build a merged view: create a shallow-copy of `rcLootDB` then append extra entries per player:

  ```lua
  -- Merge synthetic entries (vault selections) into a copy of rcLootDB
  -- so we do not mutate RC's own SavedVariables.
  local merged = {}
  if type(rcLootDB) == "table" then
      for name, entries in pairs(rcLootDB) do
          if type(entries) == "table" then
              merged[name] = {}
              for _, e in ipairs(entries) do
                  merged[name][#merged[name] + 1] = e
              end
          end
      end
  end
  if type(extraEntries) == "table" then
      for _, e in ipairs(extraEntries) do
          local name = e.player
          if type(name) == "string" and name ~= "" then
              merged[name] = merged[name] or {}
              merged[name][#merged[name] + 1] = e
          end
      end
  end
  ```

  Then replace the loop body's `rcLootDB` reference with `merged`:

  ```lua
  for name, entries in pairs(merged) do
  ```

- [ ] **9.3** In `LH:Apply`, pass `profile.vaultEntries` (or `{}`) as `extraEntries`:

  ```lua
  local rows = self:CountItemsReceived(db, days, weights, minIlvl,
                                        profile.vaultEntries or {})
  ```

- [ ] **9.4** In `Core.lua`, in `BobleLoot:OnEnable()`, register the vault event after the LootHistory setup block:

  ```lua
  -- Great Vault collection tracking (Batch 2.4).
  if C_WeeklyRewards then
      self:RegisterEvent("WEEKLY_REWARDS_ITEM_GRABBED", "OnVaultItemGrabbed")
  end
  ```

  Add the handler function to `Core.lua`:

  ```lua
  function BobleLoot:OnVaultItemGrabbed(event, itemLocation)
      -- itemLocation is a C_Item.ItemLocation. Resolve name and ilvl.
      local playerName = UnitName("player")
      local realm      = GetRealmName and GetRealmName() or ""
      realm = realm:gsub("%s+", "")
      local fullName   = (playerName and realm ~= "") and (playerName .. "-" .. realm)
                         or playerName or "Unknown"
      local link  = (itemLocation and C_Item and C_Item.GetItemLink)
                    and C_Item.GetItemLink(itemLocation) or nil
      local ilvl  = (itemLocation and C_Item and C_Item.GetCurrentItemLevel)
                    and C_Item.GetCurrentItemLevel(itemLocation) or nil
      if ns.LootHistory and ns.LootHistory.RecordVaultSelection then
          ns.LootHistory:RecordVaultSelection(self, fullName, link, ilvl)
      end
  end
  ```

- [ ] **9.5** Add `vaultEntries = {}` to `DB_DEFAULTS.profile` in `Core.lua` (alongside `roleHistoryWeights`):

  ```lua
  vaultEntries = {},
  ```

- [ ] **9.6** Manual verification (in-game):
  - On a character, open the Great Vault (requires a Wednesday after a week of activity, or use a test environment where vault is available).
  - Click "Collect" on a slot. The `WEEKLY_REWARDS_ITEM_GRABBED` event fires.
  - Type `/bl lootdb`. Confirm the character's vault entry appears in matched counts.
  - In the voting frame for an item, the history score tooltip should show `vault: 1` in `itemsReceivedBreakdown` for that character.

  Alternative verification without a live vault: use the `/run` console to manually call `ns.LootHistory:RecordVaultSelection(BobleLoot, "YourName-YourRealm", nil, 639)` and confirm the same via `/bl lootdb`.

- [ ] **9.7** Commit: `feat(lua): hook C_WeeklyRewards for vault selection tracking in LootHistory`

---

### Task 10 — Vault weight slider in `BuildLootDBTab`

**Files:**
- Modify `UI/SettingsPanel.lua`

The LootDB tab already has four category-weight sliders (bis, major, mainspec, minor). Add a fifth row for the vault/BOE category, and a sixth for the new vault configuration.

- [ ] **10.1** In `UI/SettingsPanel.lua`, locate `BuildLootDBTab` (around line 820 in Batch 1). Find the `CAT_ROWS` table:

  ```lua
  local CAT_ROWS = {
      { key = "bis",      label = "BiS",                         y = -4   },
      { key = "major",    label = "Major upgrade",               y = -50  },
      { key = "mainspec", label = "Mainspec / Need",             y = -96  },
      { key = "minor",    label = "Minor upgrade",               y = -142 },
  }
  ```

  Add the vault row at the bottom:

  ```lua
  local CAT_ROWS = {
      { key = "bis",      label = "BiS",                         y = -4   },
      { key = "major",    label = "Major upgrade",               y = -50  },
      { key = "mainspec", label = "Mainspec / Need",             y = -96  },
      { key = "minor",    label = "Minor upgrade",               y = -142 },
      { key = "vault_sep", label = nil, y = nil },   -- separator marker, handled below
  }
  ```

  Actually, the vault weight reads from `profile.vaultWeight` (a scalar float), not from `profile.lootWeights.vault`. Add it as a separate slider below the `CAT_ROWS` loop, after the loop closes:

  ```lua
  -- Vault / BOE weight (reads from profile.vaultWeight, not lootWeights).
  local vaultLabel = inner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  vaultLabel:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -192)
  vaultLabel:SetText("Vault selections & BOE awards")
  vaultLabel:SetTextColor(T.c.muted.r, T.c.muted.g, T.c.muted.b)

  MakeSlider(inner, {
      label = "Vault / BOE weight",
      min = 0, max = 2, step = 0.1, isPercent = false,
      width = 280, x = 4, y = -208,
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
  ```

  Also adjust the card's `BOTTOMRIGHT` anchor upward if needed to reveal the new content (or remove the explicit bottom anchor so the card grows to fit its parent scroll).

- [ ] **10.2** Remove the stray `{ key = "vault_sep", ... }` line added in step 10.1 above — that was a placeholder note. The final `CAT_ROWS` table should have exactly four entries unchanged from Batch 1; the vault slider is separate as described.

- [ ] **10.3** Manual verification (in-game):
  - Open `/bl` → LootDB tab.
  - Confirm a "Vault / BOE weight" slider appears below the Minor upgrade slider.
  - Drag to 1.0 and confirm a vault/BOE entry in history receives the same weight as a normal drop.
  - Drag to 0.0 and confirm vault entries contribute zero to the score.

- [ ] **10.4** Commit: `feat(lua): vault/BOE weight slider in BuildLootDBTab`

---

### Task 11 — Update `Data/BobleLoot_Data.example.lua` with tier preset fields

**Files:**
- Modify `Data/BobleLoot_Data.example.lua`

The example file currently shows the Batch 1 schema. Extend it to illustrate the new top-level fields a `--tier TWW-S3` run would emit, and the new per-character fields.

- [ ] **11.1** Replace the current `Data/BobleLoot_Data.example.lua` content with:

  ```lua
  -- EXAMPLE data file. Copy to BobleLoot_Data.lua or generate via tools/wowaudit.py.
  -- The real BobleLoot_Data.lua is gitignored because it contains your guild's roster data.
  --
  -- To generate with TWW Season 3 defaults:
  --   py tools/wowaudit.py --tier TWW-S3
  BobleLoot_Data = {
      generatedAt          = "1970-01-01T00:00:00Z",
      generatedAtTimestamp = 0,
      teamUrl     = "https://wowaudit.com/eu/<region>/<realm>/<team>",
      simCap      = 5.0,
      mplusCap    = 160,
      historyCap  = 6,
      -- Optional fields emitted by --tier:
      tierPreset  = "TWW-S3",
      lootMinIlvl = 636,
      historyDays = 84,
      characters  = {
          ["Examplechar-Examplerealm"] = {
              attendance    = 100.0,
              mplusDungeons = 0,
              -- mainspec: character's primary spec (from WoWAudit roster).
              -- Used by Scoring.lua to select the correct sim column.
              -- Absent in convert-mode (CSV) runs.
              mainspec      = "Holy",
              -- role: "raider" | "trial" | "bench" (from WoWAudit member status).
              -- Drives the per-role history weight multiplier in Scoring.lua.
              role          = "raider",
              bis      = { [12345] = true },
              sims     = { [12345] = 1.23 },
              -- simsKnown lists every itemID for which a sim result was
              -- fetched, including items whose result was 0%. This allows
              -- Scoring.lua to distinguish "sim was zero" from "item was
              -- never simmed" — see Batch 1B plan for rationale.
              simsKnown = { [12345] = true },
          },
      },
  }
  ```

- [ ] **11.2** Commit: `docs(data): update BobleLoot_Data.example.lua with Batch 2A schema`

---

### Task 12 — Full test suite pass and final tidy

**Files:**
- `tools/tests/test_wowaudit.py` (review only)
- `tools/wowaudit.py` (review only)

- [ ] **12.1** Run the full test suite and confirm all tests pass, total count >= 54 + new tests:

  ```
  pytest tools/ -v --tb=short 2>&1 | tail -30
  ```

  Expected final line:
  ```
  ===== N passed in X.XXs =====
  ```
  where N >= 79 (54 existing + 25 new across Tasks 1–5).

- [ ] **12.2** Confirm no regressions on the existing 54 tests by checking the output for any `FAILED` lines.

- [ ] **12.3** Run a dry-run of `wowaudit.py --tier TWW-S3 --use-cache` against a local cache (if present) to confirm the tier preset is loaded and printed in the run report. If no cache is available, confirm `_load_tier_preset("TWW-S3")` returns the correct dict in a Python REPL:

  ```python
  import sys; sys.path.insert(0, "tools")
  import importlib.util
  spec = importlib.util.spec_from_file_location("wa", "tools/wowaudit.py")
  wa = importlib.util.module_from_spec(spec); spec.loader.exec_module(wa)
  print(wa._load_tier_preset("TWW-S3"))
  # Expected: {'_comment': '...', 'ilvlFloor': 636, 'mplusCap': 160, ...}
  ```

- [ ] **12.4** Commit: `test(python): final Batch 2A suite; 79+ tests green`

---

## Manual Verification Checklist

The following scenarios must be validated in-game with a real or test data file before merging to `main`.

### 2.1 Spec-aware sim selection

- [ ] Generate a data file with `py tools/wowaudit.py --api-key KEY` (spec-aware default). For a Holy Paladin on the roster, confirm the emitted `sims` value for a Spirit-stat item matches the Holy spec's percentage, not the higher Protection percentage.
- [ ] Re-generate with `--no-spec-aware`. Confirm the emitted value is now the max across specs.
- [ ] In-game, load the spec-aware data file and open the voting frame for the Spirit item. The sim component in the tooltip should reflect the Holy-spec value.
- [ ] Verify `char.mainspec` appears correctly in the score tooltip's sim row label (if the tooltip UI surfaces it from `breakdown.sim.mainspec`).

### 2.2 Role field + per-role history weight

- [ ] Generate a data file containing at least one `role = "trial"` character. `/reload` in-game.
- [ ] Open the voting frame for any item. Compare the history component between a `role = "raider"` and `role = "trial"` character with similar `itemsReceived`. The trial character's history component should be attenuated (pulled toward 0.5).
- [ ] Open `/bl` → Tuning tab. Confirm three new "Role history multipliers" sliders are visible (Raider, Trial, Bench).
- [ ] Set Trial to 0.0. Reopen voting frame. Confirm the trial character's history component reads exactly 0.5 regardless of their loot history.
- [ ] Set Trial to 1.0. Confirm the trial character's history component equals a raider's with the same data.
- [ ] Set Trial back to 0.5. Confirm the value persists across `/reload`.

### 2.3 Cross-tier `--tier` preset

- [ ] Run `py tools/wowaudit.py --tier TWW-S3 --api-key KEY`. Confirm the run report includes "M+ cap : 160" and the generated Lua contains `tierPreset = "TWW-S3"` and `lootMinIlvl = 636`.
- [ ] Run `py tools/wowaudit.py --tier TWW-S3 --mplus-cap 90 --api-key KEY`. Confirm explicit `--mplus-cap` overrides the preset (run report shows "M+ cap : 90").
- [ ] Run `py tools/wowaudit.py --tier NONEXISTENT` without a valid preset file. Confirm a `SystemExit` with a message listing available presets.
- [ ] Open `/bl` → Data tab. Confirm the `tierPreset` value is displayed (if the Data tab surfaces `BobleLoot_Data.tierPreset`).

### 2.4 BOE drops + Great Vault in history

- [ ] Award a BOE item via RC's distribution flow. Check `/bl lootdb` for the receiving character. Confirm `vault: 1` appears in their breakdown.
- [ ] In the voting frame, the character's history score tooltip should show `Vault / BOE: 1 × 0.5 = 0.5 pts contributed`.
- [ ] Manually trigger a vault entry via `/run ns.LootHistory:RecordVaultSelection(BobleLoot, "YourName-Realm", nil, 639)`. Reload UI. Confirm entry persists in `BobleLootDB.profile.vaultEntries` (check with `/run print(#BobleLoot.db.profile.vaultEntries)`).
- [ ] Open `/bl` → LootDB tab. Confirm the "Vault / BOE weight" slider is present. Set to 0.0. Confirm vault entries no longer contribute to the score. Set back to 0.5. Confirm contribution returns.
- [ ] On a Wednesday (vault available), collect an item from the Great Vault. Confirm `OnVaultItemGrabbed` fires (add a temporary `print("vault grabbed")` in `Core.lua` if needed for verification). Confirm entry lands in `profile.vaultEntries`.

---

## Rollback Notes

Each commit in this plan is self-contained and revertible:

| Commit | Revert impact |
|---|---|
| `feat(python): add _mainspec_sim_score` | Purely additive to `wowaudit.py`. Old data files are unaffected. |
| `feat(python): extract mainspec and role fields` | Rows gain two keys. `build_lua` only emits them when present. Old convert-mode CSVs unchanged. |
| `feat(python): emit mainspec/role in build_lua; spec-aware sims` | Data file gains optional fields. `Scoring.lua` checks `char.mainspec` and `char.role` with safe `or` defaults. Old data files without these fields score identically to before. |
| `feat(lua): apply per-role history multiplier` | Guarded behind `profile.roleHistoryWeights`; when key absent (old profiles) the AceDB default (raider=1.0, trial=0.5, bench=0.5) applies. Behaviour for existing `raider` characters is unchanged (multiplier=1.0 is identity). |
| `feat(python): add --tier preset flag` | New CLI flag; existing invocations without `--tier` are unaffected. `_load_tier_preset` is only called when `args.tier is not None`. |
| `feat(lua): AceDB defaults for new profile keys` | Additive. Old profiles with missing keys fall through to the new defaults on next login. No migration needed. |
| `feat(lua): per-role history-weight sliders in BuildTuningTab` | UI-only addition. Removing the sliders reverts to profile defaults controlling the weights. |
| `feat(lua): classify BOE entries as vault category` | `classify()` change is backward-compatible: BOE entries previously returned `nil` (excluded). Reverting restores prior behaviour. |
| `feat(lua): hook C_WeeklyRewards for vault selection` | `profile.vaultEntries` accumulates but is never sent over the wire or read by RC. `LH:CountItemsReceived` falls back to `{}` when not present. |
| `feat(lua): vault/BOE weight slider in BuildLootDBTab` | Additive slider. Removing it leaves `profile.vaultWeight` at its AceDB default (0.5). |
| `docs(data): update example.lua` | Documentation only. |

---

## Coordination Notes

The following files touched by this plan may conflict with other Batch 2 plans. Merge order must be coordinated:

| File | This plan (2A) | Conflicting plan | Resolution |
|---|---|---|---|
| `Scoring.lua` | Adds `roleHistoryWeights` multiplier and `mainspec` to breakdown | **2B** (runtime correctness): may modify `Scoring:Compute` call sites or the `components` table | **2B merges after 2A**. 2B implementer must carry forward the `histVal` multiplier block and `mainspec` in the sim component entry. |
| `Core.lua` | Adds AceDB defaults, `OnVaultItemGrabbed` handler | **2B**: adds `PARTY_LEADER_CHANGED` handler, `BobleLootSyncDB.schemaVersion` bump | No structural conflict; both add new event handlers and DB keys. Merge order is irrelevant as long as both diff-apply cleanly. Review for duplicate `OnEnable` guard blocks. |
| `LootHistory.lua` | Adds `vault` category, `RecordVaultSelection`, `CountItemsReceived` extraEntries | **2B**: no known LootHistory changes per the cross-plan boundary note. | No conflict expected. |
| `UI/SettingsPanel.lua` | Adds role-weight sliders to Tuning tab, vault slider to LootDB tab | **2D** (score explanation panel): adds new panel, unlikely to touch `BuildTuningTab`. **2E** (voting/transparency nits): touches `LootFrame.lua` and `VotingFrame.lua`, not `SettingsPanel.lua`. | No conflict expected. 2D and 2E do not modify existing tabs. |
| `tools/wowaudit.py` | Significant additions (new args, functions, schema) | **No other Batch 2 plan touches `wowaudit.py`**. | No conflict. |
| `tools/tests/test_wowaudit.py` | Adds ~25 new test functions | No other Batch 2 plan adds tests here per boundary notes. | No conflict. |
| `Data/BobleLoot_Data.example.lua` | Updated schema | No other plan touches the example file. | No conflict. |
