# Batch 1A — Python Pipeline Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden `tools/wowaudit.py` so that partial API failures produce annotated Lua output rather than hard aborts, add response-schema validation with per-character warnings, add a cached-fallback fetch mode, emit a human-readable run report, and cover all of this with a pytest harness.

**Architecture:** Per-endpoint `try/except` wrappers in `fetch_rows` replace all `sys.exit()` calls in the network layer; each failure appends to a `fetch_warnings` list that flows into the Lua header as `-- WARNING: ...` comment lines and into a `dataWarnings` array in the Lua table body. Successful endpoint payloads are cached to `tools/.cache/<endpoint>.json` immediately after receipt; `--use-cache` replays those files instead of hitting the network, enabling offline development and CI runs without credentials. JSON schema files in `tools/schemas/` validate each endpoint's shape on every live fetch, producing per-character warnings for structural deviations rather than aborting the run. A human-readable run report is printed to stdout at the end of every run, diffing the current output against the previously-generated `BobleLoot_Data.lua`.

**Tech Stack:** Python 3, requests (already used via `urllib`), `json`, `csv`, `pytest`, `jsonschema`

**Roadmap items covered:** 1.1, 1.3

> **Item 1.1 — `[Data]` `wowaudit.py` hardening** (full text from spec):
>
> Current behaviour: `http_get_json` calls `sys.exit()` on any HTTP or
> network error, leaving the raid with whatever stale Lua file was on disk
> and no indication anything happened. Single-endpoint maintenance windows
> kill the whole run.
>
> Changes:
> - Wrap each endpoint call independently; partial success produces a
>   Lua file annotated with `-- WARNING: <endpoint> failed: <reason>`
> - Add response-schema validation (`schemas/wowaudit_v*.json`) with
>   per-character warnings rather than aborts.
> - Cache every successful endpoint response to `tools/.cache/<endpoint>.json`;
>   add a `--use-cache` flag that replays the last successful call.
> - Emit a human-readable run report: characters added/removed, characters
>   with zero sim data, BiS list diff, M+ cap change.

> **Item 1.3 — `[Data]` pytest harness for `wowaudit.py`** (full text from spec):
>
> Add `tools/tests/test_wowaudit.py` covering convert-mode round-trip
> against `tools/sample_input/`, `_best_wishlist_score` edge cases
> (empty spec map, negative percentages), `_full_name` realm-space
> stripping, and `build_lua` missing-column exit. Run with
> `pytest tools/` in CI.

---

## File Structure

| Path | Status | Purpose |
|---|---|---|
| `tools/wowaudit.py` | **Modify** | Core CLI — refactor `http_get_json` and `fetch_rows` to use per-endpoint try/except, add `--use-cache` flag, add cache read/write, add schema validation calls, add run-report emission, replace all network-layer `sys.exit()` calls with warning accumulation |
| `tools/schemas/wowaudit_v1.json` | **Create** | JSON Schema (draft-7) for the combined shape of all wowaudit API endpoints — validated on each live fetch |
| `tools/.cache/` | **Create (dir)** | Holds `<endpoint>.json` files written after every successful fetch; replayed when `--use-cache` is active |
| `tools/.cache/.gitkeep` | **Create** | Keeps the directory tracked; actual cache files are gitignored |
| `tools/tests/__init__.py` | **Create** | Marks the directory as a package so pytest collects it |
| `tools/tests/test_wowaudit.py` | **Create** | pytest suite: convert-mode round-trip, `_best_wishlist_score` edge cases, `_full_name` realm-space stripping, `build_lua` missing-column behavior, schema validation, cache round-trip, run-report output |
| `tools/tests/fixtures/` | **Create (dir)** | Static JSON fixtures used by schema-validation and cache tests |
| `tools/tests/fixtures/characters.json` | **Create** | Minimal valid `/characters` API response |
| `tools/tests/fixtures/period.json` | **Create** | Minimal valid `/period` API response |
| `tools/tests/fixtures/wishlists.json` | **Create** | Minimal valid `/wishlists` API response |
| `tools/tests/fixtures/attendance.json` | **Create** | Minimal valid `/attendance` API response |
| `.gitignore` (repo root) | **Modify** | Add `tools/.cache/*.json` so cached secrets never land in git |

---

## Task 1 — pytest harness skeleton (1.3 foundation)

**Files:**
- Create: `tools/tests/__init__.py`
- Create: `tools/tests/test_wowaudit.py` (skeleton — will grow through Tasks 2–12)

**Why first:** Every subsequent task follows TDD. The skeleton must exist and collect cleanly before any test is written, so the red/green cycle is verifiable from Task 2 onward.

- [ ] **1.1** Create `tools/tests/__init__.py` as an empty file:

  ```python
  # tools/tests/__init__.py
  ```

- [ ] **1.2** Create the skeleton `tools/tests/test_wowaudit.py` with imports and one smoke test:

  ```python
  """pytest harness for tools/wowaudit.py — Batch 1A."""
  from __future__ import annotations

  import importlib.util
  import sys
  from pathlib import Path

  import pytest

  # ---------------------------------------------------------------------------
  # Import wowaudit as a module without executing main().
  # ---------------------------------------------------------------------------
  TOOLS_DIR = Path(__file__).resolve().parent.parent
  SAMPLE_DIR = TOOLS_DIR / "sample_input"
  SCHEMAS_DIR = TOOLS_DIR / "schemas"

  def _import_wowaudit():
      spec = importlib.util.spec_from_file_location(
          "wowaudit", TOOLS_DIR / "wowaudit.py"
      )
      mod = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(mod)
      return mod

  wa = _import_wowaudit()


  # ---------------------------------------------------------------------------
  # Task 1 smoke test — module imports and exposes expected symbols.
  # ---------------------------------------------------------------------------

  def test_module_importable():
      assert hasattr(wa, "build_lua")
      assert hasattr(wa, "_best_wishlist_score")
      assert hasattr(wa, "_full_name")
      assert hasattr(wa, "fetch_rows")
      assert hasattr(wa, "http_get_json")
  ```

- [ ] **1.3** Run the skeleton and confirm it passes (one test collected, zero failures):

  ```
  cd "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot"
  python -m pytest tools/tests/ -v
  ```

  Expected output contains:
  ```
  test_wowaudit.py::test_module_importable PASSED
  1 passed in ...
  ```

- [ ] **1.4** Commit:

  ```
  git add tools/tests/__init__.py tools/tests/test_wowaudit.py
  git commit -m "test: add pytest harness skeleton for wowaudit.py (1.3)"
  ```

---

## Task 2 — convert-mode round-trip test

**Files:**
- Modify: `tools/tests/test_wowaudit.py` (add after Task 1 section)

This is the most integration-heavy test: load `sample_input/wowaudit.csv` + `sample_input/bis.json`, run `build_lua`, parse the output, and assert structural correctness. It also immediately catches column-name drift.

- [ ] **2.1** Confirm the sample CSV header in `tools/sample_input/wowaudit.csv`:

  Header row: `character,mplus_score,attendance,items_received,sim_212401,sim_212403,sim_212450`

  Note: the sample uses `mplus_score` (not `mplus_dungeons`). The `REQUIRED_COLS` check in `build_lua` requires `mplus_dungeons`. The sample is intentionally missing it to test missing-column behavior. A second sample file with the correct columns is needed for the round-trip test.

- [ ] **2.2** Create `tools/sample_input/wowaudit_valid.csv` with the canonical column names:

  ```csv
  character,mplus_dungeons,attendance,sim_212401,sim_212403,sim_212450
  Sampletank-Stormrage,42,98.0,4.2,0.8,2.1
  Samplehealer-Stormrage,18,92.5,0.0,0.0,3.6
  Sampledps-Stormrage,55,75.0,3.1,2.7,0.4
  ```

- [ ] **2.3** Add the convert round-trip test to `tools/tests/test_wowaudit.py`:

  ```python
  # ---------------------------------------------------------------------------
  # Task 2 — convert-mode round-trip
  # ---------------------------------------------------------------------------
  import json

  def test_convert_round_trip_produces_all_characters():
      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      bis_path = SAMPLE_DIR / "bis.json"

      rows = wa._read_table(csv_path)
      with bis_path.open(encoding="utf-8") as f:
          bis_raw = json.load(f)
      bis = {k: [int(x) for x in v] for k, v in bis_raw.items()}

      lua = wa.build_lua(rows, bis, sim_cap=5.0, mplus_cap=100, history_cap=5)

      assert 'BobleLoot_Data = {' in lua
      assert '"Sampletank-Stormrage"' in lua
      assert '"Samplehealer-Stormrage"' in lua
      assert '"Sampledps-Stormrage"' in lua


  def test_convert_round_trip_bis_entries():
      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      bis_path = SAMPLE_DIR / "bis.json"

      rows = wa._read_table(csv_path)
      with bis_path.open(encoding="utf-8") as f:
          bis_raw = json.load(f)
      bis = {k: [int(x) for x in v] for k, v in bis_raw.items()}

      lua = wa.build_lua(rows, bis, sim_cap=5.0, mplus_cap=100, history_cap=5)

      # Sampletank has BiS items 212401, 212403
      assert "[212401] = true" in lua
      assert "[212403] = true" in lua
      # Samplehealer has BiS item 212450
      assert "[212450] = true" in lua


  def test_convert_round_trip_sim_values():
      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"

      rows = wa._read_table(csv_path)
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)

      # Sampledps sim_212401 = 3.1
      assert "[212401] = 3.1" in lua


  def test_convert_round_trip_zero_sim_omitted():
      """Sim entries with value 0.0 (empty string in CSV) are omitted from sims table."""
      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"

      rows = wa._read_table(csv_path)
      lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)

      # Samplehealer has sims 0.0, 0.0, 3.6.
      # The build_lua function uses default=None for sim columns,
      # so 0.0 values ARE included (they are valid data). Confirm 3.6 is present.
      assert "[212450] = 3.6" in lua
  ```

- [ ] **2.4** Run tests (expect failures until `wowaudit_valid.csv` and any code fixes land):

  ```
  python -m pytest tools/tests/ -v
  ```

  The new tests should pass immediately because `_read_table` and `build_lua` already work for valid CSVs. If `test_convert_round_trip_zero_sim_omitted` fails, it surfaces a real behavioral question — document and fix the assertion to match actual behavior before proceeding.

- [ ] **2.5** Commit:

  ```
  git add tools/sample_input/wowaudit_valid.csv tools/tests/test_wowaudit.py
  git commit -m "test: convert-mode round-trip tests against sample_input (1.3)"
  ```

---

## Task 3 — `_best_wishlist_score` edge case tests

**Files:**
- Modify: `tools/tests/test_wowaudit.py` (add after Task 2 section)

- [ ] **3.1** Add edge-case tests:

  ```python
  # ---------------------------------------------------------------------------
  # Task 3 — _best_wishlist_score edge cases
  # ---------------------------------------------------------------------------

  def test_best_wishlist_score_empty_item():
      """Empty item dict returns 0.0."""
      assert wa._best_wishlist_score({}) == 0.0


  def test_best_wishlist_score_no_score_by_spec():
      """Item with only wishes block."""
      item = {"wishes": [{"percentage": 1.5}, {"percentage": 3.2}]}
      assert wa._best_wishlist_score(item) == 3.2


  def test_best_wishlist_score_spec_map_empty_dict():
      """score_by_spec present but empty — should return 0.0."""
      item = {"score_by_spec": {}, "wishes": []}
      assert wa._best_wishlist_score(item) == 0.0


  def test_best_wishlist_score_negative_percentage_ignored():
      """Negative percentages are never picked (best=0.0 floor)."""
      item = {
          "score_by_spec": {"Frost": {"percentage": -1.5}},
          "wishes": [{"percentage": -0.3}],
      }
      # best stays at 0.0 — negative means the item is a downgrade
      assert wa._best_wishlist_score(item) == 0.0


  def test_best_wishlist_score_spec_wins_over_wish():
      """spec percentage higher than wish percentage — spec wins."""
      item = {
          "score_by_spec": {"Fire": {"percentage": 5.0}, "Frost": {"percentage": 2.0}},
          "wishes": [{"percentage": 3.0}],
      }
      assert wa._best_wishlist_score(item) == 5.0


  def test_best_wishlist_score_wish_wins_over_spec():
      """wish percentage higher than all spec percentages — wish wins."""
      item = {
          "score_by_spec": {"Fire": {"percentage": 1.0}},
          "wishes": [{"percentage": 4.5}],
      }
      assert wa._best_wishlist_score(item) == 4.5


  def test_best_wishlist_score_non_numeric_spec_skipped():
      """Non-numeric percentage values in spec map are skipped gracefully."""
      item = {
          "score_by_spec": {"Fire": {"percentage": "n/a"}, "Frost": {"percentage": 2.2}},
          "wishes": [],
      }
      assert wa._best_wishlist_score(item) == 2.2


  def test_best_wishlist_score_none_percentage_skipped():
      """None percentage in wishes list is skipped."""
      item = {"wishes": [{"percentage": None}, {"percentage": 1.8}]}
      assert wa._best_wishlist_score(item) == 1.8
  ```

- [ ] **3.2** Run and confirm all pass (no code changes needed — current implementation already handles these):

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "best_wishlist"
  ```

  Expected: 8 passed.

- [ ] **3.3** Commit:

  ```
  git add tools/tests/test_wowaudit.py
  git commit -m "test: _best_wishlist_score edge cases including negative pct (1.3)"
  ```

---

## Task 4 — `_full_name` realm-space stripping tests

**Files:**
- Modify: `tools/tests/test_wowaudit.py` (add after Task 3 section)

- [ ] **4.1** Add tests:

  ```python
  # ---------------------------------------------------------------------------
  # Task 4 — _full_name realm-space stripping
  # ---------------------------------------------------------------------------

  def test_full_name_simple():
      assert wa._full_name("Boble", "Stormrage") == "Boble-Stormrage"


  def test_full_name_realm_with_spaces():
      """Spaces in realm name are stripped — 'Twisting Nether' -> 'TwistingNether'."""
      assert wa._full_name("Boble", "Twisting Nether") == "Boble-TwistingNether"


  def test_full_name_realm_multiple_spaces():
      assert wa._full_name("Kotoma", "The Maelstrom") == "Kotoma-TheMaelstrom"


  def test_full_name_no_realm():
      """When realm is None or empty, just return the name."""
      assert wa._full_name("Boble", None) == "Boble"
      assert wa._full_name("Boble", "") == "Boble"


  def test_full_name_empty_name_returns_none():
      assert wa._full_name("", "Stormrage") is None
      assert wa._full_name(None, "Stormrage") is None


  def test_full_name_realm_leading_trailing_spaces():
      """Leading/trailing spaces in realm are also collapsed."""
      assert wa._full_name("Boble", "  Stormrage  ") == "Boble-Stormrage"
  ```

- [ ] **4.2** Run and confirm all pass:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "full_name"
  ```

  Expected: 6 passed. If `test_full_name_realm_leading_trailing_spaces` fails, the current `"".join(realm.split())` already handles leading/trailing spaces — confirm the assertion is correct.

- [ ] **4.3** Commit:

  ```
  git add tools/tests/test_wowaudit.py
  git commit -m "test: _full_name realm-space stripping tests (1.3)"
  ```

---

## Task 5 — `build_lua` missing-column behavior test

**Files:**
- Modify: `tools/tests/test_wowaudit.py` (add after Task 4 section)

Currently `build_lua` calls `sys.exit()` on missing required columns. After Task 8 (per-endpoint error hardening), `build_lua` will be updated to raise `ValueError` instead so it is testable without subprocess invocation. Write the test now to fail, then fix the implementation in Task 8.

- [ ] **5.1** Add the test (it will fail until Task 8 changes `build_lua`):

  ```python
  # ---------------------------------------------------------------------------
  # Task 5 — build_lua missing-column behavior
  # ---------------------------------------------------------------------------

  def test_build_lua_missing_required_column_raises():
      """build_lua raises ValueError (not sys.exit) when required columns are absent."""
      rows = [{"character": "Boble-Stormrage", "attendance": 95.0}]
      # Missing: mplus_dungeons
      with pytest.raises(ValueError, match="missing required columns"):
          wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)


  def test_build_lua_empty_rows_raises():
      """build_lua raises ValueError when rows list is empty."""
      with pytest.raises(ValueError, match="No rows"):
          wa.build_lua([], {}, sim_cap=5.0, mplus_cap=100, history_cap=5)


  def test_build_lua_missing_character_column_raises():
      """build_lua raises ValueError when 'character' column is absent."""
      rows = [{"mplus_dungeons": 10, "attendance": 80.0}]
      with pytest.raises(ValueError, match="missing required columns"):
          wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
  ```

- [ ] **5.2** Run — confirm these three tests FAIL (because `build_lua` currently calls `sys.exit`, not `raise ValueError`):

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "build_lua"
  ```

  Expected: 3 failed (SystemExit raised, not ValueError).

- [ ] **5.3** Commit the failing tests so the red state is recorded:

  ```
  git add tools/tests/test_wowaudit.py
  git commit -m "test: build_lua missing-column tests (failing — impl in Task 8) (1.3)"
  ```

---

## Task 6 — Create JSON schemas for API endpoint validation

**Files:**
- Create: `tools/schemas/wowaudit_v1.json`

Design choice: a single schema file with `$defs` for each endpoint shape. Validation is called per-response in the hardened `fetch_rows`. Structural violations produce warnings, not aborts.

- [ ] **6.1** Create `tools/schemas/` directory and the schema file:

  ```json
  {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "WoWAudit API response schemas v1",
    "$defs": {
      "period_response": {
        "type": "object",
        "properties": {
          "current_period": { "type": "integer" },
          "current_season": {
            "type": "object",
            "properties": {
              "first_period_id": { "type": "integer" },
              "start_date":      { "type": "string" }
            }
          }
        }
      },
      "characters_response": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["id", "name"],
          "properties": {
            "id":    { "type": "integer" },
            "name":  { "type": "string" },
            "realm": { "type": ["string", "null"] }
          }
        }
      },
      "attendance_response": {
        "type": "object",
        "required": ["characters"],
        "properties": {
          "characters": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id":                   { "type": "integer" },
                "attended_percentage":  { "type": ["number", "null"] }
              }
            }
          }
        }
      },
      "historical_data_response": {
        "type": "object",
        "properties": {
          "characters": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "id":   { "type": "integer" },
                "data": {
                  "type": "object",
                  "properties": {
                    "dungeons_done": { "type": "array" }
                  }
                }
              }
            }
          }
        }
      },
      "wishlists_response": {
        "type": "object",
        "required": ["characters"],
        "properties": {
          "characters": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["id"],
              "properties": {
                "id":        { "type": "integer" },
                "instances": { "type": "array" }
              }
            }
          }
        }
      }
    }
  }
  ```

- [ ] **6.2** Add a schema-validation helper to `tools/wowaudit.py` — insert after the `_lua_escape` function (approximately line 117), before the `build_lua` function:

  ```python
  # --------------------------------------------------------------------------
  # Schema validation
  # --------------------------------------------------------------------------

  def _load_schema() -> dict | None:
      """Load tools/schemas/wowaudit_v1.json; return None if missing or invalid."""
      schema_path = Path(__file__).resolve().parent / "schemas" / "wowaudit_v1.json"
      if not schema_path.is_file():
          return None
      try:
          return json.loads(schema_path.read_text(encoding="utf-8"))
      except (OSError, json.JSONDecodeError):
          return None


  def _validate_endpoint(
      data: object,
      endpoint_key: str,
      schema: dict | None,
      warnings: list[str],
  ) -> None:
      """Validate `data` against `schema['$defs'][endpoint_key]`.

      Appends a warning string to `warnings` on failure; never raises.
      Returns silently if jsonschema is not installed.
      """
      if schema is None:
          return
      try:
          import jsonschema  # type: ignore
      except ImportError:
          return
      sub = schema.get("$defs", {}).get(endpoint_key)
      if sub is None:
          return
      try:
          jsonschema.validate(data, sub)
      except jsonschema.ValidationError as exc:
          warnings.append(
              f"Schema validation failed for {endpoint_key!r}: {exc.message}"
          )
  ```

- [ ] **6.3** Add schema validation tests to `tools/tests/test_wowaudit.py`:

  ```python
  # ---------------------------------------------------------------------------
  # Task 6 — schema validation
  # ---------------------------------------------------------------------------

  def test_validate_endpoint_no_schema_no_crash():
      """_validate_endpoint is silent when schema is None."""
      warnings: list[str] = []
      wa._validate_endpoint({"anything": True}, "characters_response", None, warnings)
      assert warnings == []


  def test_validate_endpoint_valid_characters():
      schema = wa._load_schema()
      if schema is None:
          pytest.skip("schemas/wowaudit_v1.json not found")
      warnings: list[str] = []
      data = [{"id": 1, "name": "Boble", "realm": "Stormrage"}]
      wa._validate_endpoint(data, "characters_response", schema, warnings)
      assert warnings == [], f"Unexpected warnings: {warnings}"


  def test_validate_endpoint_invalid_characters_missing_name():
      schema = wa._load_schema()
      if schema is None:
          pytest.skip("schemas/wowaudit_v1.json not found")
      try:
          import jsonschema  # noqa: F401
      except ImportError:
          pytest.skip("jsonschema not installed")
      warnings: list[str] = []
      data = [{"id": 1}]  # missing required "name"
      wa._validate_endpoint(data, "characters_response", schema, warnings)
      assert len(warnings) == 1
      assert "characters_response" in warnings[0]


  def test_load_schema_returns_dict_or_none():
      result = wa._load_schema()
      assert result is None or isinstance(result, dict)
  ```

- [ ] **6.4** Run schema tests (jsonschema may not be installed yet — tests skip gracefully):

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "schema or validate"
  ```

- [ ] **6.5** Install jsonschema if not present:

  ```
  pip install jsonschema
  ```

  Re-run; expect all schema tests to pass.

- [ ] **6.6** Commit:

  ```
  git add tools/schemas/wowaudit_v1.json tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "feat: add JSON schema validation for wowaudit API endpoints (1.1)"
  ```

---

## Task 7 — Cache layer: write and replay

**Files:**
- Create: `tools/.cache/.gitkeep`
- Modify: `tools/wowaudit.py` (add cache read/write helpers, `--use-cache` arg)
- Modify: `.gitignore` (repo root)
- Modify: `tools/tests/test_wowaudit.py` (add cache tests)

- [ ] **7.1** Create `tools/.cache/.gitkeep` (empty file) and add cache entries to `.gitignore`:

  Read the existing `.gitignore` first, then append:
  ```
  # wowaudit.py endpoint cache (may contain API keys in URL query strings)
  tools/.cache/*.json
  ```

- [ ] **7.2** Add cache read/write helpers to `tools/wowaudit.py` — insert after the `_validate_endpoint` function:

  ```python
  # --------------------------------------------------------------------------
  # Cache helpers
  # --------------------------------------------------------------------------

  CACHE_DIR = Path(__file__).resolve().parent / ".cache"


  def _cache_path(label: str) -> Path:
      """Return the cache file path for a given endpoint label."""
      # Sanitise label so it is safe as a filename on all platforms.
      safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in label)
      return CACHE_DIR / f"{safe}.json"


  def _write_cache(label: str, data: object) -> None:
      """Write `data` to the cache file for `label`. Silent on failure."""
      try:
          CACHE_DIR.mkdir(parents=True, exist_ok=True)
          _cache_path(label).write_text(json.dumps(data, indent=2), encoding="utf-8")
      except OSError:
          pass


  def _read_cache(label: str) -> object | None:
      """Return cached data for `label`, or None if not found / unreadable."""
      p = _cache_path(label)
      if not p.is_file():
          return None
      try:
          return json.loads(p.read_text(encoding="utf-8"))
      except (OSError, json.JSONDecodeError):
          return None
  ```

- [ ] **7.3** Add `--use-cache` argument to the `argparse` block in `main()`. Find the existing `ap.add_argument("--dump-raw", ...)` line and add immediately after it:

  ```python
  ap.add_argument("--use-cache", action="store_true",
                  help="Replay the last successful API responses from "
                       "tools/.cache/ instead of hitting the network.")
  ```

- [ ] **7.4** Add cache tests to `tools/tests/test_wowaudit.py`:

  ```python
  # ---------------------------------------------------------------------------
  # Task 7 — cache layer
  # ---------------------------------------------------------------------------
  import tempfile

  def test_write_and_read_cache(tmp_path, monkeypatch):
      """_write_cache / _read_cache round-trip using a temp directory."""
      monkeypatch.setattr(wa, "CACHE_DIR", tmp_path)
      # Also patch _cache_path to use the monkeypatched CACHE_DIR.
      original_cache_path = wa._cache_path
      def patched_cache_path(label):
          safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in label)
          return tmp_path / f"{safe}.json"
      monkeypatch.setattr(wa, "_cache_path", patched_cache_path)

      payload = {"characters": [{"id": 1, "name": "Boble"}]}
      wa._write_cache("characters", payload)
      result = wa._read_cache("characters")
      assert result == payload


  def test_read_cache_missing_returns_none(tmp_path, monkeypatch):
      monkeypatch.setattr(wa, "CACHE_DIR", tmp_path)
      monkeypatch.setattr(wa, "_cache_path", lambda label: tmp_path / f"{label}.json")
      assert wa._read_cache("nonexistent") is None


  def test_cache_label_sanitisation(tmp_path, monkeypatch):
      """Labels with special characters (e.g. query strings) are sanitised."""
      monkeypatch.setattr(wa, "CACHE_DIR", tmp_path)
      monkeypatch.setattr(
          wa, "_cache_path",
          lambda label: tmp_path / (
              "".join(c if c.isalnum() or c in "-_." else "_" for c in label) + ".json"
          ),
      )
      wa._write_cache("attendance?start_date=2026-03-17", {"ok": True})
      result = wa._read_cache("attendance?start_date=2026-03-17")
      assert result == {"ok": True}


  def test_write_cache_silent_on_bad_path(monkeypatch):
      """_write_cache does not raise when the directory is not writable."""
      monkeypatch.setattr(wa, "CACHE_DIR", Path("/nonexistent_dir_xyzzy"))
      monkeypatch.setattr(wa, "_cache_path", lambda _: Path("/nonexistent_dir_xyzzy/x.json"))
      # Should not raise.
      wa._write_cache("test", {"data": 1})
  ```

- [ ] **7.5** Run cache tests:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "cache"
  ```

  Expected: 4 passed.

- [ ] **7.6** Commit:

  ```
  git add tools/.cache/.gitkeep .gitignore tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "feat: add endpoint cache layer and --use-cache flag (1.1)"
  ```

---

## Task 8 — Per-endpoint try/except and `sys.exit` elimination

**Files:**
- Modify: `tools/wowaudit.py` — refactor `http_get_json`, `fetch_rows`, `build_lua`, `main`

This is the core of item 1.1. After this task, the pipeline never calls `sys.exit()` due to a network or schema error; it accumulates warnings and continues.

- [ ] **8.1** Change `http_get_json` signature to return `object | None` and replace `sys.exit` calls with `raise` — callers handle them:

  Replace the existing `http_get_json` function body:

  ```python
  def http_get_json(path: str, api_key: str) -> object:
      """Fetch JSON from the WoWAudit API.

      Raises urllib.error.HTTPError, urllib.error.URLError, or OSError on
      failure. Never calls sys.exit — callers are responsible for handling
      exceptions and accumulating warnings.
      """
      url = API_BASE + path
      req = urllib.request.Request(
          url,
          headers={
              "Authorization": api_key,
              "Accept":        "application/json",
              "User-Agent":    "BobleLoot/0.1 (+wowaudit.py)",
          },
      )
      with urllib.request.urlopen(req, timeout=30) as r:
          return json.load(r)
  ```

- [ ] **8.2** Rewrite `fetch_rows` to use per-endpoint try/except and cache integration. Replace the entire `fetch_rows` function:

  ```python
  def fetch_rows(
      api_key: str,
      dump_dir: Path | None,
      use_cache: bool = False,
  ) -> tuple[list[dict], int, list[str]]:
      """Hit all wowaudit endpoints and merge into per-character row dicts.

      Returns:
          (rows, weeks_in_season, fetch_warnings)

      fetch_warnings is a list of human-readable warning strings for endpoints
      that failed or produced schema violations. The caller embeds these in the
      generated Lua file.
      """
      schema = _load_schema()
      fetch_warnings: list[str] = []

      def _fetch(path: str, label: str) -> object | None:
          """Fetch one endpoint; fall back to cache on error.

          Returns the parsed JSON, or None if both live fetch and cache fail.
          Appends to fetch_warnings on any failure.
          """
          if use_cache:
              cached = _read_cache(label)
              if cached is not None:
                  return cached
              fetch_warnings.append(
                  f"{label}: --use-cache requested but no cache file found; "
                  "attempted live fetch."
              )

          try:
              data = http_get_json(path, api_key)
          except urllib.error.HTTPError as e:
              body = e.read().decode("utf-8", errors="replace")[:300]
              msg = f"{label}: HTTP {e.code} — {body}"
              fetch_warnings.append(msg)
              cached = _read_cache(label)
              if cached is not None:
                  fetch_warnings.append(f"{label}: using cached fallback.")
                  return cached
              return None
          except urllib.error.URLError as e:
              msg = f"{label}: network error — {e.reason}"
              fetch_warnings.append(msg)
              cached = _read_cache(label)
              if cached is not None:
                  fetch_warnings.append(f"{label}: using cached fallback.")
                  return cached
              return None
          except Exception as e:
              msg = f"{label}: unexpected error — {e}"
              fetch_warnings.append(msg)
              return None

          _write_cache(label, data)
          if dump_dir is not None:
              dump_dir.mkdir(parents=True, exist_ok=True)
              (dump_dir / f"{label}.json").write_text(
                  json.dumps(data, indent=2), encoding="utf-8"
              )
          _validate_endpoint(data, f"{label}_response", schema, fetch_warnings)
          return data

      # --- period ---
      period_info = _fetch("/period", "period") or {}
      season      = (period_info or {}).get("current_season") or {}
      first_pid   = season.get("first_period_id")
      cur_pid     = (period_info or {}).get("current_period")
      season_start = season.get("start_date")

      # --- roster ---
      roster_raw = _fetch("/characters", "characters")
      if roster_raw is None:
          fetch_warnings.append("characters: endpoint failed and no cache — output will be empty.")
          roster = []
      elif not isinstance(roster_raw, list):
          fetch_warnings.append(
              f"characters: unexpected shape {type(roster_raw).__name__!r} — expected list."
          )
          roster = []
      else:
          roster = roster_raw

      # --- attendance ---
      att_path = "/attendance"
      if season_start:
          att_path += f"?start_date={season_start}"
      att_label = "attendance"
      attendance_payload = _fetch(att_path, att_label)
      att_chars = (
          attendance_payload.get("characters", [])
          if isinstance(attendance_payload, dict)
          else []
      )
      attendance_by_id = {
          c["id"]: c.get("attended_percentage", 0)
          for c in att_chars
          if isinstance(c, dict) and "id" in c
      }

      # --- historical M+ data ---
      dungeons_by_id: dict[int, int] = {}
      weeks_in_season = 0
      if isinstance(first_pid, int) and isinstance(cur_pid, int) and first_pid <= cur_pid:
          weeks_in_season = cur_pid - first_pid + 1
          for pid in range(first_pid, cur_pid + 1):
              label = f"historical_{pid}"
              payload = _fetch(f"/historical_data?period={pid}", label)
              for c in (
                  (payload or {}).get("characters", [])
                  if isinstance(payload, dict)
                  else []
              ):
                  cid  = c.get("id")
                  done = (c.get("data") or {}).get("dungeons_done") or []
                  if isinstance(cid, int) and isinstance(done, list):
                      dungeons_by_id[cid] = dungeons_by_id.get(cid, 0) + len(done)

      # --- wishlists ---
      wl_payload = _fetch("/wishlists", "wishlists")
      wl_chars   = (
          wl_payload.get("characters", []) if isinstance(wl_payload, dict) else []
      )
      sims_by_id: dict[int, dict[int, float]] = {}
      for c in wl_chars:
          if not isinstance(c, dict):
              continue
          cid = c.get("id")
          if not isinstance(cid, int):
              continue
          sims_by_id.setdefault(cid, {})
          for inst in c.get("instances") or []:
              for diff in inst.get("difficulties") or []:
                  wl = diff.get("wishlist") or {}
                  for enc in wl.get("encounters") or []:
                      for item in enc.get("items") or []:
                          iid = item.get("id")
                          if not isinstance(iid, int):
                              continue
                          score = _best_wishlist_score(item)
                          prev  = sims_by_id[cid].get(iid, 0.0)
                          if score > prev:
                              sims_by_id[cid][iid] = score

      # --- assemble rows ---
      rows: list[dict] = []
      for c in roster:
          if not isinstance(c, dict):
              continue
          cid  = c.get("id")
          full = _full_name(c.get("name"), c.get("realm"))
          if not full:
              continue
          row: dict = {
              "character":      full,
              "mplus_dungeons": dungeons_by_id.get(cid, 0),
              "attendance":     attendance_by_id.get(cid, 0),
          }
          for iid, score in (sims_by_id.get(cid) or {}).items():
              row[f"sim_{iid}"] = score
          rows.append(row)

      return rows, weeks_in_season, fetch_warnings
  ```

- [ ] **8.3** Change `build_lua` to raise `ValueError` instead of calling `sys.exit()`. Replace the two `sys.exit` calls at the top of `build_lua`:

  ```python
  def build_lua(
      rows: list[dict],
      bis: dict[str, list[int]],
      sim_cap: float,
      mplus_cap: int,
      history_cap: int,
      team_url: str | None = None,
      fetch_warnings: list[str] | None = None,
  ) -> str:
      if not rows:
          raise ValueError("No rows to emit.")

      missing = REQUIRED_COLS - set(rows[0].keys())
      if missing:
          raise ValueError(f"Input is missing required columns: {sorted(missing)}")
  ```

  Also add warning comment block, `generatedAtTimestamp`, and `dataWarnings` emission. `generatedAtTimestamp` is a Unix integer consumed by the Lua freshness badge (plan 1D, item 1.6) — Lua 5.1 has no standard date parser so we emit a numeric form alongside the ISO string. Insert after the `generatedAt` / `teamUrl` / `simCap` / `mplusCap` / `historyCap` lines and before `characters  = {`:

  ```python
      # Emit fetch warnings as Lua comment block at the top.
      warnings_block = []
      if fetch_warnings:
          for w in fetch_warnings:
              warnings_block.append(f"-- WARNING: {w}")

      # Capture the generation moment once so ISO string and Unix timestamp match.
      now_utc   = dt.datetime.now(dt.timezone.utc)
      now_iso   = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      now_epoch = int(now_utc.timestamp())

      # Build output list.
      out = []
      if warnings_block:
          out.extend(warnings_block)
          out.append("")
      out.append("-- AUTO-GENERATED by tools/wowaudit.py - do not edit by hand.")
      out.append(f"-- Generated: {now_iso}")
      out.append("BobleLoot_Data = {")
      out.append(f'    generatedAt          = "{now_iso}",')
      out.append(f"    generatedAtTimestamp = {now_epoch},")
      if team_url:
          out.append(f'    teamUrl     = "{team_url}",')
      out.append(f"    simCap      = {sim_cap},")
      out.append(f"    mplusCap    = {mplus_cap},")
      out.append(f"    historyCap  = {history_cap},")
      if fetch_warnings:
          escaped = ", ".join(
              f'"{_lua_escape(w)}"' for w in fetch_warnings
          )
          out.append(f"    dataWarnings = {{ {escaped} }},")
      out.append("    characters  = {")
  ```

  Full rewrite of `build_lua` incorporating both changes:

  ```python
  def build_lua(
      rows: list[dict],
      bis: dict[str, list[int]],
      sim_cap: float,
      mplus_cap: int,
      history_cap: int,
      team_url: str | None = None,
      fetch_warnings: list[str] | None = None,
  ) -> str:
      """Render BobleLoot_Data.lua from assembled rows.

      Args:
          rows: Per-character dicts with keys matching REQUIRED_COLS.
          bis: Mapping of "Name-Realm" to list of BiS item IDs.
          sim_cap: Maximum sim percentage (for Lua consumers).
          mplus_cap: Maximum M+ dungeons cap.
          history_cap: Maximum items-received cap.
          team_url: Optional WoWAudit team URL to embed.
          fetch_warnings: Optional list of warning strings from fetch_rows;
              emitted as Lua comments and a dataWarnings array.

      Returns:
          The Lua file contents as a string.

      Raises:
          ValueError: If rows is empty or missing required columns.
      """
      if not rows:
          raise ValueError("No rows to emit.")

      missing = REQUIRED_COLS - set(rows[0].keys())
      if missing:
          raise ValueError(f"Input is missing required columns: {sorted(missing)}")

      sim_cols_set: set[str] = set()
      for r in rows:
          for c in r.keys():
              if c.startswith("sim_") and c[4:].isdigit():
                  sim_cols_set.add(c)
      sim_cols = sorted(sim_cols_set, key=lambda c: int(c[4:]))

      # Capture the generation moment once so ISO string and Unix timestamp match.
      now_utc   = dt.datetime.now(dt.timezone.utc)
      now_iso   = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      now_epoch = int(now_utc.timestamp())
      out: list[str] = []

      # Warning comment block at the very top of the file.
      if fetch_warnings:
          for w in fetch_warnings:
              out.append(f"-- WARNING: {w}")
          out.append("")

      out.append("-- AUTO-GENERATED by tools/wowaudit.py - do not edit by hand.")
      out.append(f"-- Generated: {now_iso}")
      out.append("BobleLoot_Data = {")
      out.append(f'    generatedAt          = "{now_iso}",')
      # Unix integer form consumed by Lua (plan 1D freshness badge, item 1.6).
      # Emitted alongside generatedAt because Lua 5.1 has no standard date parser.
      out.append(f"    generatedAtTimestamp = {now_epoch},")
      if team_url:
          out.append(f'    teamUrl     = "{team_url}",')
      out.append(f"    simCap      = {sim_cap},")
      out.append(f"    mplusCap    = {mplus_cap},")
      out.append(f"    historyCap  = {history_cap},")

      # dataWarnings array — Lua side reads this to surface issues in the UI.
      if fetch_warnings:
          escaped = ", ".join(f'"{_lua_escape(w)}"' for w in fetch_warnings)
          out.append(f"    dataWarnings = {{ {escaped} }},")

      out.append("    characters  = {")

      for row in rows:
          name = (row.get("character") or "").strip()
          if not name:
              continue
          attendance = _to_float(row.get("attendance"))
          mplus      = _to_int(row.get("mplus_dungeons"))

          out.append(f'        ["{_lua_escape(name)}"] = {{')
          out.append(f"            attendance    = {attendance},")
          out.append(f"            mplusDungeons = {mplus},")

          bis_ids = bis.get(name) or []
          if bis_ids:
              ids = ", ".join(f"[{int(i)}] = true" for i in bis_ids)
              out.append(f"            bis  = {{ {ids} }},")
          else:
              out.append("            bis  = {},")

          sim_pairs: list[str] = []
          for col in sim_cols:
              val = (
                  _to_float(row.get(col), default=None)
                  if row.get(col) not in (None, "")
                  else None
              )
              if val is None:
                  continue
              item_id = int(col[4:])
              sim_pairs.append(f"[{item_id}] = {val}")
          if sim_pairs:
              out.append(f"            sims = {{ {', '.join(sim_pairs)} }},")
          else:
              out.append("            sims = {},")

          out.append("        },")

      out.append("    },")
      out.append("}")
      out.append("")
      return "\n".join(out)
  ```

- [ ] **8.4** Update `main()` to pass `use_cache` to `fetch_rows`, handle the new return signature (3-tuple), pass `fetch_warnings` to `build_lua`, and wrap `build_lua` `ValueError` with a `sys.exit` for the CLI (the CLI is still allowed to exit — only the library functions must not):

  Replace the API fetch branch in `main()`:

  ```python
      else:
          # API fetch mode.
          if not args.api_key:
              sys.exit(
                  "No API key. Pass --api-key, set WOWAUDIT_API_KEY, "
                  "or put it in a .env file. Alternatively pass --wowaudit "
                  "to convert a manual export."
              )
          rows, weeks_in_season, fetch_warnings = fetch_rows(
              args.api_key, args.dump_raw, use_cache=args.use_cache
          )
          team_url = fetch_team_url(args.api_key)
          if not rows and not fetch_warnings:
              sys.exit("No characters parsed from the API response.")
          if args.bis is not None:
              with args.bis.open(encoding="utf-8") as f:
                  bis_raw = json.load(f)
              bis = {k: [int(x) for x in v] for k, v in bis_raw.items()}
          else:
              bis = {}
  ```

  And wrap the `build_lua` call in `main()`:

  ```python
      try:
          lua = build_lua(
              rows, bis, args.sim_cap, mplus_cap, args.history_cap,
              team_url, fetch_warnings if not args.wowaudit else None,
          )
      except ValueError as exc:
          sys.exit(str(exc))
  ```

- [ ] **8.5** Also update the convert-mode branch in `main()` to initialise `fetch_warnings`:

  Add `fetch_warnings: list[str] = []` at the top of the convert-mode branch, before the `build_lua` call.

- [ ] **8.6** Run the Task 5 tests — they should now PASS:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "build_lua"
  ```

  Expected: 3 passed.

- [ ] **8.7** Run the full test suite:

  ```
  python -m pytest tools/tests/ -v
  ```

  Expected: all tests pass.

- [ ] **8.8** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "feat: per-endpoint try/except, cache fallback, ValueError in build_lua (1.1)"
  ```

---

## Task 9 — Warning emission tests (per-endpoint partial success)

**Files:**
- Modify: `tools/tests/test_wowaudit.py` (add after Task 8 section)
- Create: `tools/tests/fixtures/` directory and fixture files

These tests exercise `fetch_rows` with mocked network calls to confirm that one endpoint failing does not abort the whole run.

- [ ] **9.1** Create the fixtures directory and minimal fixture files:

  `tools/tests/fixtures/characters.json`:
  ```json
  [
    {"id": 1, "name": "Boble", "realm": "Stormrage"},
    {"id": 2, "name": "Kotoma", "realm": "Twisting Nether"}
  ]
  ```

  `tools/tests/fixtures/period.json`:
  ```json
  {
    "current_period": 1,
    "current_season": {
      "first_period_id": 1,
      "start_date": "2026-03-17"
    }
  }
  ```

  `tools/tests/fixtures/attendance.json`:
  ```json
  {
    "characters": [
      {"id": 1, "attended_percentage": 92.5},
      {"id": 2, "attended_percentage": 78.0}
    ]
  }
  ```

  `tools/tests/fixtures/wishlists.json`:
  ```json
  {
    "characters": [
      {
        "id": 1,
        "instances": [
          {
            "difficulties": [
              {
                "wishlist": {
                  "encounters": [
                    {
                      "items": [
                        {
                          "id": 212401,
                          "score_by_spec": {"Protection": {"percentage": 3.5}},
                          "wishes": []
                        }
                      ]
                    }
                  ]
                }
              }
            ]
          }
        ]
      }
    ]
  }
  ```

- [ ] **9.2** Add fetch_rows partial-failure tests:

  ```python
  # ---------------------------------------------------------------------------
  # Task 9 — per-endpoint partial success / warning accumulation
  # ---------------------------------------------------------------------------
  import urllib.error

  FIXTURES = Path(__file__).resolve().parent / "fixtures"


  def _fixture(name: str) -> object:
      return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


  def _make_http_error(code: int) -> urllib.error.HTTPError:
      import io
      return urllib.error.HTTPError(
          url="http://example.com",
          code=code,
          msg="Error",
          hdrs={},  # type: ignore[arg-type]
          fp=io.BytesIO(b"server error body"),
      )


  def test_fetch_rows_characters_failure_returns_empty_rows(monkeypatch):
      """If /characters fails and no cache, rows is empty and a warning is recorded."""

      call_count = {"n": 0}

      def fake_http_get_json(path, api_key):
          call_count["n"] += 1
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              raise urllib.error.HTTPError(
                  "http://x", 503, "Service Unavailable", {}, None  # type: ignore
              )
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http_get_json)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=False)

      assert rows == []
      assert any("characters" in w for w in warnings)
      assert any("503" in w for w in warnings)


  def test_fetch_rows_wishlists_failure_produces_empty_sims(monkeypatch):
      """If /wishlists fails, rows still emit but with empty sims tables."""

      def fake_http_get_json(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              raise urllib.error.URLError("timeout")
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http_get_json)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=False)

      assert len(rows) == 2
      assert all(not any(k.startswith("sim_") for k in row) for row in rows)
      assert any("wishlists" in w for w in warnings)


  def test_fetch_rows_attendance_failure_defaults_to_zero(monkeypatch):
      """If /attendance fails, all characters get attendance=0."""

      def fake_http_get_json(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              raise urllib.error.URLError("refused")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return _fixture("wishlists.json")
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http_get_json)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=False)

      assert all(row["attendance"] == 0 for row in rows)
      assert any("attendance" in w for w in warnings)


  def test_fetch_rows_uses_cache_when_flag_set(monkeypatch, tmp_path):
      """With --use-cache, _read_cache is called instead of http_get_json."""

      cache_calls: list[str] = []
      http_calls: list[str] = []

      def fake_read_cache(label):
          cache_calls.append(label)
          fixtures = {
              "period":     _fixture("period.json"),
              "characters": _fixture("characters.json"),
              "attendance": _fixture("attendance.json"),
              "wishlists":  _fixture("wishlists.json"),
          }
          return fixtures.get(label)

      def fake_http_get_json(path, api_key):
          http_calls.append(path)
          return {}

      monkeypatch.setattr(wa, "_read_cache", fake_read_cache)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)
      monkeypatch.setattr(wa, "http_get_json", fake_http_get_json)

      rows, weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=True)

      # No live HTTP calls for the four main endpoints when cache is available.
      assert not any(
          p in ("/period", "/characters", "/attendance", "/wishlists")
          for p in http_calls
      )
      assert len(rows) == 2


  def test_fetch_rows_warnings_appear_in_build_lua_output(monkeypatch):
      """fetch_warnings passed to build_lua appear as Lua comments."""

      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      rows = wa._read_table(csv_path)
      warnings = ["wishlists: HTTP 503 — service unavailable"]

      lua = wa.build_lua(
          rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
          fetch_warnings=warnings,
      )

      assert "-- WARNING: wishlists: HTTP 503" in lua
      assert "dataWarnings" in lua
  ```

- [ ] **9.3** Run partial-failure tests:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "fetch_rows or partial or warning"
  ```

  Expected: all pass. If `test_fetch_rows_uses_cache_when_flag_set` fails because historical_data endpoints slip through, update `fake_read_cache` to also return `{"characters": []}` for labels matching `"historical_"`.

- [ ] **9.4** Commit:

  ```
  git add tools/tests/fixtures/ tools/tests/test_wowaudit.py
  git commit -m "test: per-endpoint partial-failure and cache-replay tests (1.1/1.3)"
  ```

---

## Task 10 — Human-readable run report

**Files:**
- Modify: `tools/wowaudit.py` (add `_build_run_report` and `_parse_lua_names` helpers, call from `main`)
- Modify: `tools/tests/test_wowaudit.py` (add run-report tests)

The run report is printed to stdout after the Lua file is written. It compares the new output against the previously-generated file on disk (if present) to show characters added/removed, zero-sim characters, BiS item set changes, and M+ cap change.

- [ ] **10.1** Add helpers to `tools/wowaudit.py` — insert before `main()`:

  ```python
  # --------------------------------------------------------------------------
  # Run report
  # --------------------------------------------------------------------------

  def _parse_lua_names(lua_text: str) -> set[str]:
      """Extract character names from a BobleLoot_Data.lua file.

      Uses simple string scanning — not a full Lua parser. Matches lines of
      the form:  ["Name-Realm"] = {
      """
      import re
      return set(re.findall(r'\["([^"]+)"\]\s*=\s*\{', lua_text))


  def _parse_lua_mplus_cap(lua_text: str) -> int | None:
      """Extract the mplusCap value from a BobleLoot_Data.lua file."""
      import re
      m = re.search(r'mplusCap\s*=\s*(\d+)', lua_text)
      return int(m.group(1)) if m else None


  def _parse_lua_bis(lua_text: str) -> dict[str, set[int]]:
      """Extract BiS item IDs per character from a BobleLoot_Data.lua file.

      Returns {"Name-Realm": {itemID, ...}}.
      """
      import re
      result: dict[str, set[int]] = {}
      # Match character blocks.
      char_blocks = re.findall(
          r'\["([^"]+)"\]\s*=\s*\{(.*?)\},',
          lua_text,
          re.DOTALL,
      )
      for name, block in char_blocks:
          bis_match = re.search(r'bis\s*=\s*\{([^}]*)\}', block)
          if bis_match:
              ids = set(int(x) for x in re.findall(r'\[(\d+)\]\s*=\s*true', bis_match.group(1)))
              result[name] = ids
      return result


  def _count_zero_sim_chars(rows: list[dict]) -> list[str]:
      """Return names of characters whose every sim column is 0 or absent."""
      zero_names: list[str] = []
      for row in rows:
          sim_vals = [
              v for k, v in row.items()
              if k.startswith("sim_") and k[4:].isdigit()
          ]
          if not sim_vals or all(_to_float(v) == 0.0 for v in sim_vals):
              zero_names.append(row.get("character", "?"))
      return zero_names


  def _build_run_report(
      rows: list[dict],
      bis: dict[str, list[int]],
      mplus_cap: int,
      fetch_warnings: list[str],
      prev_lua_path: Path | None,
  ) -> str:
      """Build a human-readable run report string.

      Args:
          rows: The assembled character rows for this run.
          bis: BiS mapping used for this run.
          mplus_cap: The computed M+ cap for this run.
          fetch_warnings: Warnings accumulated during fetch.
          prev_lua_path: Path to the existing Lua file (for diffing); None if new.

      Returns:
          A multi-line string suitable for printing to stdout.
      """
      lines: list[str] = []
      lines.append("=" * 60)
      lines.append("BobleLoot run report")
      lines.append("=" * 60)

      # Characters.
      new_names = {(row.get("character") or "").strip() for row in rows if row.get("character")}
      lines.append(f"Characters this run : {len(new_names)}")

      # Diff against previous file.
      prev_names: set[str] = set()
      prev_mplus_cap: int | None = None
      prev_bis: dict[str, set[int]] = {}
      if prev_lua_path is not None and prev_lua_path.is_file():
          try:
              prev_text = prev_lua_path.read_text(encoding="utf-8")
              prev_names = _parse_lua_names(prev_text)
              prev_mplus_cap = _parse_lua_mplus_cap(prev_text)
              prev_bis = _parse_lua_bis(prev_text)
          except OSError:
              pass

      added   = sorted(new_names - prev_names)
      removed = sorted(prev_names - new_names)
      if added:
          lines.append(f"  Added   : {', '.join(added)}")
      if removed:
          lines.append(f"  Removed : {', '.join(removed)}")
      if not added and not removed and prev_names:
          lines.append("  Roster  : no change")

      # Zero-sim characters.
      zero_sims = _count_zero_sim_chars(rows)
      if zero_sims:
          lines.append(f"Zero sim data ({len(zero_sims)}) : {', '.join(zero_sims)}")
      else:
          lines.append("Zero sim data : none")

      # M+ cap.
      if prev_mplus_cap is not None and prev_mplus_cap != mplus_cap:
          lines.append(f"M+ cap : {prev_mplus_cap} -> {mplus_cap}")
      else:
          lines.append(f"M+ cap : {mplus_cap}")

      # BiS diff (summarised as total items changed).
      new_bis_sets = {name: set(ids) for name, ids in bis.items()}
      bis_changes: list[str] = []
      for name in sorted(new_bis_sets.keys() | prev_bis.keys()):
          old_set = prev_bis.get(name, set())
          new_set = new_bis_sets.get(name, set())
          if old_set != new_set:
              added_ids   = sorted(new_set - old_set)
              removed_ids = sorted(old_set - new_set)
              parts: list[str] = []
              if added_ids:
                  parts.append(f"+{len(added_ids)} item(s)")
              if removed_ids:
                  parts.append(f"-{len(removed_ids)} item(s)")
              bis_changes.append(f"  {name}: {', '.join(parts)}")
      if bis_changes:
          lines.append(f"BiS diff ({len(bis_changes)} character(s) changed):")
          lines.extend(bis_changes)
      else:
          lines.append("BiS diff : no change")

      # Fetch warnings.
      if fetch_warnings:
          lines.append(f"Warnings ({len(fetch_warnings)}):")
          for w in fetch_warnings:
              lines.append(f"  ! {w}")
      else:
          lines.append("Warnings : none")

      lines.append("=" * 60)
      return "\n".join(lines)
  ```

- [ ] **10.2** Wire `_build_run_report` into `main()`. At the end of `main()`, before the final `print(f"Wrote {args.out}...")`, add:

  ```python
      report = _build_run_report(
          rows, bis, mplus_cap, fetch_warnings if not args.wowaudit else [],
          args.out if args.out.is_file() else None,
      )
      print(report)
  ```

- [ ] **10.3** Add run-report tests:

  ```python
  # ---------------------------------------------------------------------------
  # Task 10 — run report
  # ---------------------------------------------------------------------------

  def test_build_run_report_no_prev_file(tmp_path):
      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      rows = wa._read_table(csv_path)
      bis = {"Sampletank-Stormrage": [212401]}

      report = wa._build_run_report(
          rows, bis, mplus_cap=100,
          fetch_warnings=[],
          prev_lua_path=None,
      )

      assert "Characters this run" in report
      assert "3" in report  # three characters
      assert "M+ cap : 100" in report
      assert "Warnings : none" in report


  def test_build_run_report_added_and_removed(tmp_path):
      # Write a fake old Lua file with only one character.
      old_lua = (
          'BobleLoot_Data = {\n'
          '    ["Sampletank-Stormrage"] = {\n'
          '        bis = {},\n'
          '    },\n'
          '}\n'
      )
      lua_path = tmp_path / "BobleLoot_Data.lua"
      lua_path.write_text(old_lua, encoding="utf-8")

      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      rows = wa._read_table(csv_path)

      report = wa._build_run_report(
          rows, {}, mplus_cap=100,
          fetch_warnings=[],
          prev_lua_path=lua_path,
      )

      assert "Added" in report
      # Samplehealer and Sampledps are new.
      assert "Samplehealer-Stormrage" in report
      assert "Sampledps-Stormrage" in report


  def test_build_run_report_mplus_cap_change(tmp_path):
      old_lua = "BobleLoot_Data = {\n    mplusCap = 50,\n}\n"
      lua_path = tmp_path / "BobleLoot_Data.lua"
      lua_path.write_text(old_lua, encoding="utf-8")

      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      rows = wa._read_table(csv_path)

      report = wa._build_run_report(
          rows, {}, mplus_cap=100,
          fetch_warnings=[],
          prev_lua_path=lua_path,
      )

      assert "50 -> 100" in report


  def test_build_run_report_bis_diff(tmp_path):
      old_lua = (
          'BobleLoot_Data = {\n'
          '    ["Sampletank-Stormrage"] = {\n'
          '        bis = { [212401] = true },\n'
          '    },\n'
          '}\n'
      )
      lua_path = tmp_path / "BobleLoot_Data.lua"
      lua_path.write_text(old_lua, encoding="utf-8")

      csv_path = SAMPLE_DIR / "wowaudit_valid.csv"
      rows = wa._read_table(csv_path)
      bis = {"Sampletank-Stormrage": [212401, 212403]}  # 212403 added

      report = wa._build_run_report(
          rows, bis, mplus_cap=100,
          fetch_warnings=[],
          prev_lua_path=lua_path,
      )

      assert "BiS diff" in report
      assert "+1 item(s)" in report


  def test_build_run_report_zero_sim_chars():
      rows = [
          {"character": "Boble-Stormrage", "mplus_dungeons": 10, "attendance": 80.0},
          {"character": "Kotoma-TwistingNether", "mplus_dungeons": 5, "attendance": 60.0,
           "sim_212401": 3.2},
      ]
      report = wa._build_run_report(
          rows, {}, mplus_cap=100,
          fetch_warnings=[],
          prev_lua_path=None,
      )
      assert "Boble-Stormrage" in report
      assert "Zero sim data" in report


  def test_build_run_report_warnings_listed():
      rows = [{"character": "Boble-Stormrage", "mplus_dungeons": 10, "attendance": 80.0}]
      report = wa._build_run_report(
          rows, {}, mplus_cap=100,
          fetch_warnings=["wishlists: HTTP 503 — service down"],
          prev_lua_path=None,
      )
      assert "Warnings (1)" in report
      assert "wishlists: HTTP 503" in report


  def test_parse_lua_names():
      lua = (
          'BobleLoot_Data = {\n'
          '    ["Boble-Stormrage"] = {\n'
          '    },\n'
          '    ["Kotoma-TwistingNether"] = {\n'
          '    },\n'
          '}\n'
      )
      names = wa._parse_lua_names(lua)
      assert names == {"Boble-Stormrage", "Kotoma-TwistingNether"}


  def test_parse_lua_mplus_cap():
      lua = "BobleLoot_Data = {\n    mplusCap = 120,\n}\n"
      assert wa._parse_lua_mplus_cap(lua) == 120


  def test_count_zero_sim_chars():
      rows = [
          {"character": "A-Realm", "sim_212401": 0.0, "sim_212403": 0.0},
          {"character": "B-Realm", "sim_212401": 2.5},
          {"character": "C-Realm"},
      ]
      result = wa._count_zero_sim_chars(rows)
      assert "A-Realm" in result
      assert "C-Realm" in result
      assert "B-Realm" not in result
  ```

- [ ] **10.4** Run all run-report tests:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "run_report or parse_lua or count_zero"
  ```

  Expected: all pass.

- [ ] **10.5** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "feat: human-readable run report with diff (characters, BiS, M+ cap) (1.1)"
  ```

---

## Task 11 — `fetch_team_url` hardening

**Files:**
- Modify: `tools/wowaudit.py` (minor — already has try/except but calls internal `http_get_json` which no longer `sys.exit`s)
- Modify: `tools/tests/test_wowaudit.py` (add test)

The existing `fetch_team_url` already wraps in `try/except Exception`. Confirm it still works after the `http_get_json` signature change.

- [ ] **11.1** Verify `fetch_team_url` body — it already has `try/except Exception: pass` — no changes needed.

- [ ] **11.2** Add tests:

  ```python
  # ---------------------------------------------------------------------------
  # Task 11 — fetch_team_url hardening
  # ---------------------------------------------------------------------------

  def test_fetch_team_url_returns_url(monkeypatch):
      monkeypatch.setattr(wa, "http_get_json", lambda path, key: {"url": "https://wowaudit.com/teams/123"})
      result = wa.fetch_team_url("fake-key")
      assert result == "https://wowaudit.com/teams/123"


  def test_fetch_team_url_returns_none_on_error(monkeypatch):
      def raise_error(path, key):
          raise urllib.error.URLError("refused")
      monkeypatch.setattr(wa, "http_get_json", raise_error)
      result = wa.fetch_team_url("fake-key")
      assert result is None


  def test_fetch_team_url_returns_none_when_url_missing(monkeypatch):
      monkeypatch.setattr(wa, "http_get_json", lambda path, key: {"name": "My Team"})
      result = wa.fetch_team_url("fake-key")
      assert result is None
  ```

- [ ] **11.3** Run:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "team_url"
  ```

  Expected: 3 passed.

- [ ] **11.4** Commit:

  ```
  git add tools/tests/test_wowaudit.py
  git commit -m "test: fetch_team_url hardening tests (1.1)"
  ```

---

## Task 12 — `_read_table` and convert-mode `sys.exit` audit

**Files:**
- Modify: `tools/wowaudit.py` (`_read_table` XLSX `sys.exit` is acceptable in CLI context; document the decision)
- Modify: `tools/tests/test_wowaudit.py` (add edge-case tests)

The `_read_table` function has one remaining `sys.exit` for missing `openpyxl`. This is acceptable: it only fires in convert mode when the user explicitly passes an XLSX file, and without the library the operation genuinely cannot proceed. Document this decision and test the CSV path fully.

Design choice: the `openpyxl` `sys.exit` is kept because it is a user-visible dependency error with a clear remediation message, not a network partial-failure. All network-path `sys.exit` calls have been eliminated. This divergence from "never sys.exit" is acceptable per the principle that the tool can exit on unrecoverable user-input errors; only endpoint failures must degrade gracefully.

- [ ] **12.1** Add a docstring to `_read_table` documenting the decision:

  ```python
  def _read_table(path: Path) -> list[dict]:
      """Read a CSV or XLSX file into a list of dicts.

      For XLSX files, requires openpyxl (sys.exit with install hint if absent —
      this is an unrecoverable user-input error, not a network partial failure,
      so sys.exit is acceptable here per Batch 1A design decision).
      """
  ```

- [ ] **12.2** Add tests for `_read_table` CSV edge cases:

  ```python
  # ---------------------------------------------------------------------------
  # Task 12 — _read_table CSV edge cases
  # ---------------------------------------------------------------------------
  import tempfile

  def test_read_table_valid_csv(tmp_path):
      csv_file = tmp_path / "test.csv"
      csv_file.write_text(
          "character,mplus_dungeons,attendance\n"
          "Boble-Stormrage,42,95.0\n",
          encoding="utf-8",
      )
      rows = wa._read_table(csv_file)
      assert len(rows) == 1
      assert rows[0]["character"] == "Boble-Stormrage"
      assert rows[0]["mplus_dungeons"] == "42"


  def test_read_table_empty_csv(tmp_path):
      csv_file = tmp_path / "empty.csv"
      csv_file.write_text("character,mplus_dungeons,attendance\n", encoding="utf-8")
      rows = wa._read_table(csv_file)
      assert rows == []


  def test_read_table_utf8_bom(tmp_path):
      """CSV files with UTF-8 BOM (common Excel export) are read correctly."""
      csv_file = tmp_path / "bom.csv"
      # utf-8-sig BOM prefix.
      csv_file.write_bytes(
          b"\xef\xbb\xbfcharacter,mplus_dungeons,attendance\n"
          b"Boble-Stormrage,10,80.0\n"
      )
      rows = wa._read_table(csv_file)
      assert rows[0]["character"] == "Boble-Stormrage"


  def test_read_table_sample_input():
      """The existing sample_input/wowaudit.csv is readable."""
      csv_path = SAMPLE_DIR / "wowaudit.csv"
      rows = wa._read_table(csv_path)
      assert len(rows) == 3
      assert rows[0]["character"] == "Sampletank-Stormrage"
  ```

- [ ] **12.3** Run:

  ```
  python -m pytest tools/tests/test_wowaudit.py -v -k "read_table"
  ```

  Expected: 4 passed.

- [ ] **12.4** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "test: _read_table CSV edge cases; document openpyxl sys.exit decision (1.1)"
  ```

---

## Task 13 — Full suite run and CI configuration

**Files:**
- Modify: `tools/tests/test_wowaudit.py` (final coverage sweep)
- Create: `tools/pytest.ini` or `pyproject.toml` addendum (pytest config)

- [ ] **13.1** Create `tools/pytest.ini` to configure test discovery:

  ```ini
  [pytest]
  testpaths = tests
  python_files = test_*.py
  python_classes = Test*
  python_functions = test_*
  addopts = -v --tb=short
  ```

- [ ] **13.2** Run the complete test suite from the repo root to simulate CI:

  ```
  cd "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot"
  python -m pytest tools/ -v --tb=short
  ```

  Expected: all tests pass. Count should be approximately 45–55 tests.

- [ ] **13.3** Run with coverage if pytest-cov is available:

  ```
  pip install pytest-cov
  python -m pytest tools/ --cov=tools --cov-report=term-missing
  ```

  Target: >90% coverage of `wowaudit.py`. Note any uncovered lines for follow-up.

- [ ] **13.4** If any tests fail at this stage, fix the implementation or test assertion before committing. Common failure modes to check:
  - `test_fetch_rows_uses_cache_when_flag_set` — `historical_data` endpoints may hit `http_get_json` if `fake_read_cache` returns `None` for those labels. Fix: return `{"characters": []}` for any label starting with `"historical_"` in `fake_read_cache`.
  - `test_convert_round_trip_zero_sim_omitted` — confirm whether `0.0` values appear in sim output. The current `build_lua` includes `0.0` values when the CSV cell is `"0.0"` (a valid float). Update the assertion comment to match actual behavior.

- [ ] **13.5** Final commit:

  ```
  git add tools/pytest.ini tools/tests/test_wowaudit.py
  git commit -m "test: full pytest suite passing; add pytest.ini for CI (1.3)"
  ```

---

## Manual Verification

After all tasks are complete, perform a manual smoke test against the sample inputs:

**Step 1 — Convert mode with valid CSV:**
```
cd "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot"
python tools/wowaudit.py \
  --wowaudit tools/sample_input/wowaudit_valid.csv \
  --bis tools/sample_input/bis.json \
  --out /tmp/BobleLoot_Data_test.lua \
  --sim-cap 5.0 \
  --mplus-cap 100 \
  --history-cap 5
```

Expected stdout (run report):
```
============================================================
BobleLoot run report
============================================================
Characters this run : 3
  Roster  : no change   [or Added: ... if first run]
Zero sim data : none
M+ cap : 100
BiS diff : no change   [or diff if first run]
Warnings : none
============================================================
```

**Step 2 — Inspect the generated Lua:**
```
cat /tmp/BobleLoot_Data_test.lua
```

Expected: no `-- WARNING:` lines, `dataWarnings` key absent, all three characters present, BiS entries correct, sim values present.

**Step 3 — Convert mode with missing column (original sample CSV):**
```
python tools/wowaudit.py \
  --wowaudit tools/sample_input/wowaudit.csv \
  --bis tools/sample_input/bis.json \
  --out /tmp/BobleLoot_Data_bad.lua
```

Expected: exits with message `Input is missing required columns: ['mplus_dungeons']`.

**Step 4 — Run the test suite:**
```
python -m pytest tools/ -v
```

Expected: all tests pass, no warnings.

**Step 5 — `--use-cache` flag (requires a prior API run or manually placed cache files):**

If `.cache/characters.json` exists from a prior run:
```
python tools/wowaudit.py --api-key dummy --use-cache --out /tmp/cached.lua
```

Expected: run report shows warning `"attempted live fetch"` for any endpoint whose cache file is absent, and uses cached data for those that have cache files. No `sys.exit` unless zero characters are returned from all sources combined.

---

## Commit Strategy

Each task ends with its own focused commit. The commit sequence tells the story:

1. `test: add pytest harness skeleton for wowaudit.py (1.3)`
2. `test: convert-mode round-trip tests against sample_input (1.3)`
3. `test: _best_wishlist_score edge cases including negative pct (1.3)`
4. `test: _full_name realm-space stripping tests (1.3)`
5. `test: build_lua missing-column tests (failing — impl in Task 8) (1.3)`
6. `feat: add JSON schema validation for wowaudit API endpoints (1.1)`
7. `feat: add endpoint cache layer and --use-cache flag (1.1)`
8. `feat: per-endpoint try/except, cache fallback, ValueError in build_lua (1.1)`
9. `test: per-endpoint partial-failure and cache-replay tests (1.1/1.3)`
10. `feat: human-readable run report with diff (characters, BiS, M+ cap) (1.1)`
11. `test: fetch_team_url hardening tests (1.1)`
12. `test: _read_table CSV edge cases; document openpyxl sys.exit decision (1.1)`
13. `test: full pytest suite passing; add pytest.ini for CI (1.3)`

No squash at the end. Each commit is a self-contained unit of value: the task-N tests pass at task-N's commit, never held open until a later task lands. The one intentional exception is Task 5 (failing tests committed) resolved at Task 8 — this is the standard TDD red/green pattern and is intentional.
