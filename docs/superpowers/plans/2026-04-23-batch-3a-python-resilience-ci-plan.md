# Batch 3A — Python Resilience + CI Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `wowaudit.py` with per-character partial-success tracking, a versioned BiS directory, a wishlist-derived BiS flag, and a GitHub Actions workflow that lints and auto-refreshes data weekly.

**Architecture:** Per-character warnings are collected during wishlist ingestion and fed into the existing `fetch_warnings` list (already wired through `build_lua` into Lua comments and `dataWarnings` array from Batch 1A) — no new mechanism is added. The flat `bis.json` input is replaced by a `bis/<tier>/` directory tree where each `<class>-<spec>.json` file is a `{ "Name-Realm": [itemIDs] }` map; `--bis` detects file-vs-directory at runtime and merges accordingly for backward compatibility. `--bis-from-wishlist` derives BiS membership purely from wishlist scores above a configurable threshold, removing the need for manual JSON maintenance. A two-job GitHub Actions workflow runs on every push (`lint`: pytest + luacheck) and on a weekly cron (`refresh`: fetch + PR).

**Tech Stack:** Python 3, pytest (existing harness), jsonschema (existing), GitHub Actions (new), luacheck (new for CI, not required locally)

**Roadmap items covered:**

> **3.1 `[Data]` Per-character partial-success ingestion**
> If `/wishlists` returns data for 18 of 20 characters, the current code
> silently emits empty sims for the missing two. Track `fetch_warnings`
> and embed them as a Lua comment block at the top of
> `BobleLoot_Data.lua` so the raid leader can see which characters
> have incomplete data.

> **3.2 `[Data]` Versioned BiS directory**
> Replace the flat `bis.json` with `bis/<tier>/<class>-<spec>.json`.
> `--bis` accepts either a file (backward-compat) or a directory; merges
> all JSON files found. Each file is `{ "Name-Realm": [itemIDs] }`.
> Per-spec files make per-patch updates reviewable as single-file diffs.

> **3.3 `[Data]` `--bis-from-wishlist` flag**
> Derive BiS membership from WoWAudit wishlists — any item whose best-spec
> score exceeds a threshold (e.g. `2.0%`) is marked BiS for that character.
> Removes the most significant manual maintenance burden from the data
> pipeline.

> **3.4 `[Data]` GitHub Actions weekly refresh**
> Add `.github/workflows/refresh.yml` with:
> - **lint job** — `pytest tools/` and luacheck on all Lua files
>   (`.luacheckrc` configured for WoW globals).
> - **refresh job** — scheduled weekly, runs `wowaudit.py`, opens a PR
>   titled `chore: weekly data refresh (<date>)` with the data diff.
>   API key in GitHub Actions secret `WOWAUDIT_API_KEY`.

**Dependencies:** Batch 1 fully merged (1A hardened `wowaudit.py` + pytest harness with 54 tests, 1B `simsKnown` sentinel, endpoints wrapped in `_fetch()` with per-endpoint try/except and cache fallback, `build_lua` already accepts `fetch_warnings: list[str] | None` and emits both Lua comment block and `dataWarnings` array).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tools/wowaudit.py` | Modify | Add per-character wishlist-miss warnings (3.1); extend `--bis` for directory mode (3.2); add `--bis-from-wishlist` + `--bis-threshold` args (3.3) |
| `tools/tests/test_wowaudit.py` | Modify | New test classes for 3.1 per-character warnings, 3.2 directory merge, 3.3 wishlist-derived BiS |
| `tools/tests/fixtures/wishlists_partial.json` | Create | Fixture: wishlists response where character id=2 has no instances (simulates partial-success) |
| `tools/tests/fixtures/bis/` | Create | Sample versioned BiS directory for tests |
| `tools/tests/fixtures/bis/tww-s3/warrior-arms.json` | Create | Sample per-spec BiS file for test fixture |
| `tools/tests/fixtures/bis/tww-s3/paladin-protection.json` | Create | Second per-spec BiS file to test merge |
| `bis/` | Create | Top-level versioned BiS directory shipped with the addon |
| `bis/tww-s3/warrior-arms.json` | Create | Example tier/spec BiS file (TWW Season 3) |
| `bis/tww-s3/paladin-protection.json` | Create | Example tier/spec BiS file (TWW Season 3) |
| `bis/README.md` | Create | Update-process documentation for BiS directory |
| `.github/workflows/refresh.yml` | Create | Two-job Actions workflow: lint + weekly refresh PR |
| `.luacheckrc` | Create | Lua linter config with WoW API globals allowlist |

---

## Tasks

### Task 1 — Add per-character wishlist-miss warning (3.1, TDD first)

**Files:**
- Test: `tools/tests/test_wowaudit.py` (new class, add after existing `fetch_rows` tests)
- Create: `tools/tests/fixtures/wishlists_partial.json`
- Modify: `tools/wowaudit.py` — `fetch_rows()` wishlist ingestion block (~line 493–530 on `release/v1.1.0`)

Write the failing test first, create the fixture, then implement.

- [ ] **1.1** Create `tools/tests/fixtures/wishlists_partial.json`. Character id=1 has normal wishlist data; character id=2 has no instances (simulates the API returning a partial roster):

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
      },
      {
        "id": 2,
        "instances": []
      }
    ]
  }
  ```

- [ ] **1.2** Add a new test class to `tools/tests/test_wowaudit.py` after the existing `fetch_rows` tests (around line 493). The test patches `http_get_json` to return the partial fixture for `/wishlists` and the standard `characters.json` for `/characters` (ids 1=Boble-Stormrage, 2=Kotoma-TwistingNether):

  ```python
  # ---------------------------------------------------------------------------
  # Task 3A-1 — per-character wishlist-miss warning (item 3.1)
  # ---------------------------------------------------------------------------

  def test_fetch_rows_partial_wishlist_emits_character_warning(monkeypatch):
      """Characters present in roster but absent/empty in wishlists get a warning."""

      partial = json.loads(
          (TOOLS_DIR / "tests" / "fixtures" / "wishlists_partial.json")
          .read_text(encoding="utf-8")
      )

      def fake_http(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return partial
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=False)

      # Kotoma (id=2) has empty instances — must appear in warnings.
      assert any("Kotoma-TwistingNether" in w for w in warnings), warnings
      assert any("no wishlist data" in w.lower() for w in warnings), warnings


  def test_fetch_rows_partial_wishlist_warning_appears_in_lua(monkeypatch):
      """Per-character wishlist warnings are propagated into the Lua output."""

      partial = json.loads(
          (TOOLS_DIR / "tests" / "fixtures" / "wishlists_partial.json")
          .read_text(encoding="utf-8")
      )

      def fake_http(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return partial
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=False)
      lua = wa.build_lua(
          rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
          fetch_warnings=warnings,
      )

      assert "-- WARNING:" in lua
      assert "Kotoma-TwistingNether" in lua
      assert "dataWarnings" in lua


  def test_fetch_rows_full_wishlist_no_character_warnings(monkeypatch):
      """When all roster members have wishlist data, no per-character warnings."""

      def fake_http(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return _fixture("wishlists.json")
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      _rows, _weeks, warnings = wa.fetch_rows("fake-key", None, use_cache=False)

      # No per-character "no wishlist data" warning should appear.
      assert not any("no wishlist data" in w.lower() for w in warnings), warnings
  ```

  Note: `json` must be imported at the top of the test file — verify it is already present on `release/v1.1.0`; if not, add `import json` after the existing imports.

- [ ] **1.3** Run tests to confirm they fail (expected — implementation not yet written):

  ```
  pytest tools/tests/test_wowaudit.py -k "partial_wishlist" -v
  ```

  Expected output: `3 failed` (FAILED because `fetch_rows` does not yet emit per-character warnings).

- [ ] **1.4** In `tools/wowaudit.py`, find the wishlist ingestion block inside `fetch_rows`. After the loop that builds `sims_by_id` from `wl_chars`, and **before** the `rows` assembly loop, add the per-character warning logic. The insertion point is after the `sims_by_id` dict is fully populated. Locate the comment `# --- assemble rows ---` and insert immediately before it:

  ```python
  # --- per-character wishlist-miss warnings (item 3.1) ---
  # Build a set of character ids that appeared in the wishlists payload.
  wl_ids_with_data: set[int] = set()
  for c in wl_chars:
      if not isinstance(c, dict):
          continue
      cid = c.get("id")
      if not isinstance(cid, int):
          continue
      instances = c.get("instances") or []
      # A character counts as "having data" only if it has at least one item
      # reachable through instances → difficulties → wishlist → encounters → items.
      has_items = any(
          item
          for inst in instances
          for diff in (inst.get("difficulties") or [])
          for enc in (diff.get("wishlist") or {}).get("encounters") or []
          for item in (enc.get("items") or [])
      )
      if has_items:
          wl_ids_with_data.add(cid)

  for c in roster:
      if not isinstance(c, dict):
          continue
      cid  = c.get("id")
      full = _full_name(c.get("name"), c.get("realm"))
      if not full or not isinstance(cid, int):
          continue
      if cid not in wl_ids_with_data:
          fetch_warnings.append(
              f"{full}: no wishlist data — sims will be empty for this character."
          )
  ```

  This block runs over `roster` (already fetched) and emits one warning per character whose id never produced a wishlist item. The warnings go into the same `fetch_warnings` list that `build_lua` already consumes.

- [ ] **1.5** Re-run the tests to confirm they pass:

  ```
  pytest tools/tests/test_wowaudit.py -k "partial_wishlist" -v
  ```

  Expected output: `3 passed`.

- [ ] **1.6** Run the full test suite to confirm no regressions:

  ```
  pytest tools/ -v --tb=short 2>&1 | tail -20
  ```

  Expected: all existing tests pass; total count increases by 3.

- [ ] **1.7** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py tools/tests/fixtures/wishlists_partial.json
  git commit -m "$(cat <<'EOF'
  feat(3.1): emit per-character no-wishlist-data warnings

  Characters present in the roster but missing from the wishlists payload
  now produce a named warning in fetch_warnings, which is forwarded to the
  Lua comment block and dataWarnings array by the existing Batch 1A path.
  Three new pytest cases cover partial-success, Lua propagation, and the
  clean-run no-warning path.
  EOF
  )"
  ```

---

### Task 2 — Add `_load_bis_path()` helper and update `--bis` to accept directories (3.2, TDD first)

**Files:**
- Test: `tools/tests/test_wowaudit.py` (new class)
- Create: `tools/tests/fixtures/bis/tww-s3/warrior-arms.json`
- Create: `tools/tests/fixtures/bis/tww-s3/paladin-protection.json`
- Modify: `tools/wowaudit.py` — add `_load_bis_path()`, update `main()` BiS loading

- [ ] **2.1** Create the test fixture directory and two per-spec BiS files.

  `tools/tests/fixtures/bis/tww-s3/warrior-arms.json`:
  ```json
  {
    "Boble-Stormrage": [212401, 212405],
    "Kotoma-TwistingNether": [212401]
  }
  ```

  `tools/tests/fixtures/bis/tww-s3/paladin-protection.json`:
  ```json
  {
    "Boble-Stormrage": [212410],
    "Sprocket-Doomhammer": [212410, 212415]
  }
  ```

- [ ] **2.2** Add a new test class to `tools/tests/test_wowaudit.py`:

  ```python
  # ---------------------------------------------------------------------------
  # Task 3A-2 — versioned BiS directory loading (item 3.2)
  # ---------------------------------------------------------------------------

  BIS_FIXTURE_DIR = TOOLS_DIR / "tests" / "fixtures" / "bis"


  def test_load_bis_path_from_file(tmp_path):
      """A single JSON file is loaded as-is."""
      f = tmp_path / "flat.json"
      f.write_text(
          '{"Boble-Stormrage": [212401, 212405]}', encoding="utf-8"
      )
      result = wa._load_bis_path(f)
      assert result == {"Boble-Stormrage": [212401, 212405]}


  def test_load_bis_path_from_directory_merges_all_files():
      """All JSON files in a directory (recursive) are merged into one dict."""
      result = wa._load_bis_path(BIS_FIXTURE_DIR / "tww-s3")
      # warrior-arms contributes Boble with [212401, 212405] and Kotoma with [212401]
      # paladin-protection contributes Boble with [212410] and Sprocket with [212410, 212415]
      # Boble appears in two files — ids must be union-merged (no duplicates).
      assert set(result["Boble-Stormrage"]) == {212401, 212405, 212410}
      assert set(result["Kotoma-TwistingNether"]) == {212401}
      assert set(result["Sprocket-Doomhammer"]) == {212410, 212415}


  def test_load_bis_path_from_nested_directory_merges_recursively(tmp_path):
      """Subdirectories inside the BiS root are traversed recursively."""
      sub = tmp_path / "tier1" / "sub"
      sub.mkdir(parents=True)
      (tmp_path / "tier1" / "warrior-arms.json").write_text(
          '{"A-Realm": [100]}', encoding="utf-8"
      )
      (sub / "paladin-holy.json").write_text(
          '{"B-Realm": [200]}', encoding="utf-8"
      )
      result = wa._load_bis_path(tmp_path / "tier1")
      assert result["A-Realm"] == [100]
      assert result["B-Realm"] == [200]


  def test_load_bis_path_directory_deduplicates_ids_across_files(tmp_path):
      """The same item ID appearing in two files for one character is deduplicated."""
      (tmp_path / "a.json").write_text(
          '{"Boble-Stormrage": [212401, 212405]}', encoding="utf-8"
      )
      (tmp_path / "b.json").write_text(
          '{"Boble-Stormrage": [212405, 212410]}', encoding="utf-8"
      )
      result = wa._load_bis_path(tmp_path)
      assert sorted(result["Boble-Stormrage"]) == [212401, 212405, 212410]


  def test_load_bis_path_ignores_non_json_files(tmp_path):
      """README.md and other non-.json files in the directory are skipped."""
      (tmp_path / "warrior-arms.json").write_text(
          '{"A-Realm": [100]}', encoding="utf-8"
      )
      (tmp_path / "README.md").write_text("# BiS directory", encoding="utf-8")
      result = wa._load_bis_path(tmp_path)
      assert list(result.keys()) == ["A-Realm"]


  def test_load_bis_path_file_not_found_raises():
      """A path that does not exist raises FileNotFoundError."""
      import pytest
      with pytest.raises(FileNotFoundError):
          wa._load_bis_path(Path("/nonexistent/path/bis.json"))
  ```

- [ ] **2.3** Run tests to confirm they fail:

  ```
  pytest tools/tests/test_wowaudit.py -k "load_bis_path" -v
  ```

  Expected: `6 failed` (AttributeError — `_load_bis_path` does not yet exist).

- [ ] **2.4** Add `_load_bis_path()` to `tools/wowaudit.py`. Insert it after the `_lua_escape` helper (before the schema section, roughly line 120 on `release/v1.1.0`):

  ```python
  # --------------------------------------------------------------------------
  # BiS loading — file or directory (item 3.2)
  # --------------------------------------------------------------------------

  def _load_bis_path(path: Path) -> dict[str, list[int]]:
      """Load a BiS mapping from a single JSON file or a directory tree.

      Args:
          path: Either a ``.json`` file (``{ "Name-Realm": [itemIDs] }``)
              or a directory that is traversed recursively for all ``*.json``
              files. Files inside a directory are merged: if the same
              character appears in multiple files, their item-ID lists are
              union-merged (duplicates removed, original insertion order
              preserved within each file, then appended from later files).

      Returns:
          Merged ``{ "Name-Realm": [int, ...] }`` dict. IDs are always ``int``.

      Raises:
          FileNotFoundError: If ``path`` does not exist.
          json.JSONDecodeError: If a JSON file is malformed.
      """
      if not path.exists():
          raise FileNotFoundError(f"BiS path not found: {path}")

      if path.is_file():
          raw: dict = json.loads(path.read_text(encoding="utf-8"))
          return {k: [int(x) for x in v] for k, v in raw.items()}

      # Directory mode — collect all *.json files recursively.
      merged: dict[str, list[int]] = {}
      seen: dict[str, set[int]] = {}  # tracks dedup per character

      for json_file in sorted(path.rglob("*.json")):
          raw = json.loads(json_file.read_text(encoding="utf-8"))
          for char_name, item_ids in raw.items():
              int_ids = [int(x) for x in item_ids]
              if char_name not in merged:
                  merged[char_name] = []
                  seen[char_name] = set()
              for iid in int_ids:
                  if iid not in seen[char_name]:
                      merged[char_name].append(iid)
                      seen[char_name].add(iid)

      return merged
  ```

- [ ] **2.5** Update `main()` in `tools/wowaudit.py` to call `_load_bis_path()` instead of manually opening the JSON file. Replace both occurrences of the `with args.bis.open(...) as f: bis_raw = json.load(f); bis = ...` pattern (one in convert mode, one in API mode) with:

  ```python
  bis = _load_bis_path(args.bis)
  ```

  Update the `--bis` argparse help text to:

  ```python
  ap.add_argument(
      "--bis", type=Path, default=None,
      help=(
          "BiS source: a single JSON file ({ \"Name-Realm\": [itemIDs] }) "
          "OR a directory of per-spec JSON files (merged recursively). "
          "Required in convert mode; optional in API mode. "
          "See bis/README.md for the versioned directory layout."
      ),
  )
  ```

- [ ] **2.6** Re-run BiS tests:

  ```
  pytest tools/tests/test_wowaudit.py -k "load_bis_path" -v
  ```

  Expected: `6 passed`.

- [ ] **2.7** Run the full suite to confirm no regressions:

  ```
  pytest tools/ -v --tb=short 2>&1 | tail -20
  ```

- [ ] **2.8** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py tools/tests/fixtures/bis/
  git commit -m "$(cat <<'EOF'
  feat(3.2): add _load_bis_path() for versioned BiS directory support

  --bis now accepts either a flat .json file (backward-compatible) or a
  directory that is traversed recursively and merged by character, with
  cross-file deduplication of item IDs. Six new pytest cases cover all
  branches including recursive nesting, non-JSON file skipping, and
  missing-path error handling.
  EOF
  )"
  ```

---

### Task 3 — Ship `bis/tww-s3/` and `bis/README.md` (3.2)

**Files:**
- Create: `bis/tww-s3/warrior-arms.json`
- Create: `bis/tww-s3/paladin-protection.json`
- Create: `bis/README.md`

This task ships the real-world BiS directory alongside the test fixtures. The files are illustrative starting points; the raid leader updates them per-patch following the README.

- [ ] **3.1** Create `bis/tww-s3/warrior-arms.json` as a minimal but valid example:

  ```json
  {
    "_comment": "TWW Season 3 — Arms Warrior BiS. Update after each patch. Format: Name-Realm -> [itemIDs].",
    "ExampleWarrior-Stormrage": [212401, 212405, 212408]
  }
  ```

- [ ] **3.2** Create `bis/tww-s3/paladin-protection.json`:

  ```json
  {
    "_comment": "TWW Season 3 — Protection Paladin BiS. Update after each patch.",
    "ExamplePaladin-Stormrage": [212410, 212415, 212420]
  }
  ```

- [ ] **3.3** Create `bis/README.md`:

  ```markdown
  # BobleLoot BiS Directory

  This directory holds per-tier, per-spec Best-in-Slot item lists consumed by
  `tools/wowaudit.py` when `--bis bis/` (or `--bis bis/tww-s3/`) is passed.

  ## Layout

  ```
  bis/
    <tier>/
      <class>-<spec>.json    one file per class/spec combination
    README.md                this file
  ```

  Current tiers: `tww-s3/` (The War Within, Season 3).

  ## File format

  Each file is a JSON object mapping `"Name-Realm"` to a list of item IDs:

  ```json
  {
    "Boble-Stormrage": [212401, 212405],
    "Kotoma-TwistingNether": [212401]
  }
  ```

  - **Name** is the character name as it appears in WoWAudit (case-sensitive).
  - **Realm** has spaces stripped (e.g. `TwistingNether`, not `Twisting Nether`).
  - Item IDs can be found on Wowhead, WoWAudit, or Raidbots.
  - A character may appear in multiple files; IDs are union-merged automatically.

  ## How to update (each patch / tier)

  1. Find the current BiS lists for each active spec (Wowhead, Icy Veins, or
     Raidbots "best gear" report).
  2. Edit (or create) the relevant `<class>-<spec>.json` file.
  3. Run `py tools/wowaudit.py --bis bis/tww-s3/` to regenerate the Lua file.
  4. Open a PR — the diff will be scoped to just the changed per-spec file,
     making review straightforward.

  ## Switching tiers

  Point `--bis` at the new tier directory:

  ```sh
  py tools/wowaudit.py --bis bis/tww-s4/
  ```

  Or use a Batch 2.3 tier preset that sets `bisPath` automatically:

  ```sh
  py tools/wowaudit.py --tier tww-s4
  ```

  ## Backward compatibility

  `--bis` still accepts a single flat JSON file for teams that have not
  migrated to the directory layout. Both modes produce identical output.

  ## Automated derivation (item 3.3)

  Pass `--bis-from-wishlist` to derive BiS membership from WoWAudit
  wishlist scores instead of maintaining this directory manually.
  Any item whose best-spec score exceeds `--bis-threshold` (default `2.0`)
  is treated as BiS for that character. See `py tools/wowaudit.py --help`.
  ```

- [ ] **3.4** Verify `_load_bis_path` handles the `_comment` key gracefully. The `_comment` key is a string value, not a list — add a defensive guard in `_load_bis_path`:

  In the directory-merge loop, add a type check so non-list values are skipped silently:

  ```python
  for char_name, item_ids in raw.items():
      if not isinstance(item_ids, list):
          continue  # skip _comment and other metadata keys
      int_ids = [int(x) for x in item_ids]
      ...
  ```

  Also apply the same guard in the single-file branch:

  ```python
  return {
      k: [int(x) for x in v]
      for k, v in raw.items()
      if isinstance(v, list)
  }
  ```

- [ ] **3.5** Add one test covering `_comment` key skipping:

  ```python
  def test_load_bis_path_skips_non_list_values(tmp_path):
      """Keys with non-list values (e.g. _comment) are silently skipped."""
      (tmp_path / "warrior-arms.json").write_text(
          '{"_comment": "update weekly", "Boble-Stormrage": [212401]}',
          encoding="utf-8",
      )
      result = wa._load_bis_path(tmp_path)
      assert "_comment" not in result
      assert result["Boble-Stormrage"] == [212401]
  ```

  Run: `pytest tools/tests/test_wowaudit.py -k "non_list_values" -v` — should pass immediately.

- [ ] **3.6** Commit:

  ```
  git add bis/ tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "$(cat <<'EOF'
  feat(3.2): ship bis/tww-s3/ directory with README and _comment guard

  Adds the top-level versioned BiS directory with two example per-spec
  files and a README documenting the update process and tier-switching
  workflow. _load_bis_path now skips non-list values so _comment metadata
  keys in JSON files are silently ignored.
  EOF
  )"
  ```

---

### Task 4 — Add `--bis-from-wishlist` flag (3.3, TDD first)

**Files:**
- Test: `tools/tests/test_wowaudit.py` (new class)
- Modify: `tools/wowaudit.py` — add `_derive_bis_from_wishlists()`, update `fetch_rows()` signature, update `main()`

- [ ] **4.1** Add tests **before** implementing. Insert after the `_load_bis_path` test class:

  ```python
  # ---------------------------------------------------------------------------
  # Task 3A-4 — --bis-from-wishlist / _derive_bis_from_wishlists (item 3.3)
  # ---------------------------------------------------------------------------

  def test_derive_bis_from_wishlists_basic():
      """Items above threshold are marked BiS; items below are not."""
      # sims_by_id: {char_id: {item_id: score}}
      sims_by_id = {
          1: {212401: 3.5, 212405: 0.5, 212408: 2.0},
          2: {212401: 1.9, 212410: 2.1},
      }
      roster = [
          {"id": 1, "name": "Boble", "realm": "Stormrage"},
          {"id": 2, "name": "Kotoma", "realm": "TwistingNether"},
      ]
      result = wa._derive_bis_from_wishlists(
          sims_by_id=sims_by_id,
          roster=roster,
          threshold=2.0,
      )
      # Boble: 212401 (3.5 >= 2.0) and 212408 (2.0 >= 2.0) are BiS; 212405 (0.5) is not
      assert sorted(result["Boble-Stormrage"]) == [212401, 212408]
      # Kotoma: 212410 (2.1 >= 2.0) is BiS; 212401 (1.9) is not
      assert result["Kotoma-TwistingNether"] == [212410]


  def test_derive_bis_from_wishlists_default_threshold():
      """Default threshold of 2.0 is applied when not specified."""
      sims_by_id = {1: {212401: 1.99, 212405: 2.0}}
      roster = [{"id": 1, "name": "Boble", "realm": "Stormrage"}]
      result = wa._derive_bis_from_wishlists(sims_by_id, roster, threshold=2.0)
      # 1.99 is below 2.0; 2.0 is exactly at threshold (inclusive).
      assert 212401 not in result.get("Boble-Stormrage", [])
      assert 212405 in result.get("Boble-Stormrage", [])


  def test_derive_bis_from_wishlists_no_items_above_threshold():
      """Character with all items below threshold gets an empty BiS list."""
      sims_by_id = {1: {212401: 0.1}}
      roster = [{"id": 1, "name": "Boble", "realm": "Stormrage"}]
      result = wa._derive_bis_from_wishlists(sims_by_id, roster, threshold=2.0)
      assert result.get("Boble-Stormrage", []) == []


  def test_derive_bis_from_wishlists_character_not_in_sims():
      """Roster members with no wishlist data at all get an empty BiS list."""
      sims_by_id: dict = {}
      roster = [{"id": 1, "name": "Boble", "realm": "Stormrage"}]
      result = wa._derive_bis_from_wishlists(sims_by_id, roster, threshold=2.0)
      assert result.get("Boble-Stormrage", []) == []


  def test_derive_bis_from_wishlists_bad_roster_entry_skipped():
      """Roster entries without id or name are skipped without error."""
      sims_by_id = {1: {212401: 3.5}}
      roster = [
          {"id": 1, "name": "Boble", "realm": "Stormrage"},
          {"id": None, "name": "Ghost", "realm": "Realm"},  # bad id
          {"name": "NoId", "realm": "Realm"},               # missing id key
      ]
      result = wa._derive_bis_from_wishlists(sims_by_id, roster, threshold=2.0)
      assert "Boble-Stormrage" in result
      assert "Ghost-Realm" not in result
      assert "NoId-Realm" not in result


  def test_fetch_rows_bis_from_wishlist_mode(monkeypatch):
      """fetch_rows with bis_from_wishlist=True returns derived BiS in sims rows."""

      def fake_http(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return _fixture("wishlists.json")
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      rows, _weeks, warnings, derived_bis = wa.fetch_rows(
          "fake-key", None, use_cache=False,
          bis_from_wishlist=True, bis_threshold=2.0,
      )

      # wishlists.json: Boble (id=1) has item 212401 at 3.5% (above 2.0)
      assert isinstance(derived_bis, dict)
      assert 212401 in derived_bis.get("Boble-Stormrage", [])
  ```

- [ ] **4.2** Run tests to confirm they fail:

  ```
  pytest tools/tests/test_wowaudit.py -k "derive_bis or bis_from_wishlist_mode" -v
  ```

  Expected: `7 failed`.

- [ ] **4.3** Add `_derive_bis_from_wishlists()` to `tools/wowaudit.py`. Insert after `_load_bis_path()`:

  ```python
  # --------------------------------------------------------------------------
  # Wishlist-derived BiS (item 3.3)
  # --------------------------------------------------------------------------

  def _derive_bis_from_wishlists(
      sims_by_id: dict[int, dict[int, float]],
      roster: list[dict],
      threshold: float = 2.0,
  ) -> dict[str, list[int]]:
      """Derive a BiS mapping from wishlist sim scores.

      Any item whose score meets or exceeds ``threshold`` (percent upgrade,
      same unit as ``_best_wishlist_score`` returns) is marked BiS for
      that character. This removes the need to maintain per-spec JSON files
      manually.

      Args:
          sims_by_id: Mapping of ``{character_id: {item_id: best_score}}``,
              as produced inside ``fetch_rows``.
          roster: The raw ``/characters`` list so character names are resolved.
          threshold: Minimum score (inclusive) for an item to be BiS.
              Default ``2.0`` (2% upgrade).

      Returns:
          ``{ "Name-Realm": [itemIDs] }`` dict, same shape as a flat bis.json.
          Characters with no items above threshold are present with ``[]``.
      """
      bis: dict[str, list[int]] = {}
      for c in roster:
          if not isinstance(c, dict):
              continue
          cid  = c.get("id")
          full = _full_name(c.get("name"), c.get("realm"))
          if not full or not isinstance(cid, int):
              continue
          char_sims = sims_by_id.get(cid, {})
          bis_ids = [
              iid
              for iid, score in char_sims.items()
              if score >= threshold
          ]
          bis[full] = bis_ids
      return bis
  ```

- [ ] **4.4** Extend `fetch_rows()` signature to accept two new keyword arguments and return the derived BiS when requested. Update the function signature:

  ```python
  def fetch_rows(
      api_key: str,
      dump_dir: Path | None,
      use_cache: bool = False,
      bis_from_wishlist: bool = False,
      bis_threshold: float = 2.0,
  ) -> tuple[list[dict], int, list[str]] | tuple[list[dict], int, list[str], dict[str, list[int]]]:
  ```

  Update the docstring `Returns:` section:

  ```
  Returns:
      ``(rows, weeks_in_season, fetch_warnings)`` normally, or
      ``(rows, weeks_in_season, fetch_warnings, derived_bis)`` when
      ``bis_from_wishlist=True``.
  ```

  At the end of `fetch_rows()`, replace `return rows, weeks_in_season, fetch_warnings` with:

  ```python
  if bis_from_wishlist:
      derived_bis = _derive_bis_from_wishlists(sims_by_id, roster, bis_threshold)
      return rows, weeks_in_season, fetch_warnings, derived_bis
  return rows, weeks_in_season, fetch_warnings
  ```

- [ ] **4.5** Update `main()` in `tools/wowaudit.py` to add the new CLI flags and wire them through:

  After the `--use-cache` argument definition, add:

  ```python
  ap.add_argument(
      "--bis-from-wishlist",
      action="store_true",
      default=False,
      help=(
          "Derive BiS membership from WoWAudit wishlist scores instead of "
          "loading a --bis file. Any item with a best-spec score >= "
          "--bis-threshold is marked BiS for that character."
      ),
  )
  ap.add_argument(
      "--bis-threshold",
      type=float,
      default=2.0,
      metavar="PCT",
      help=(
          "Minimum wishlist score (percent upgrade, same units as WoWAudit "
          "percentages) for --bis-from-wishlist. Default: 2.0."
      ),
  )
  ```

  In the API-fetch branch of `main()`, replace the `fetch_rows(...)` call with:

  ```python
  fetch_result = fetch_rows(
      args.api_key,
      args.dump_raw,
      use_cache=args.use_cache,
      bis_from_wishlist=args.bis_from_wishlist,
      bis_threshold=args.bis_threshold,
  )
  if args.bis_from_wishlist:
      rows, weeks_in_season, fetch_warnings, derived_bis = fetch_result
      if args.bis is not None:
          # --bis-from-wishlist wins; --bis is ignored with a warning.
          fetch_warnings.append(
              "--bis-from-wishlist is active; --bis path is ignored."
          )
      bis = derived_bis
  else:
      rows, weeks_in_season, fetch_warnings = fetch_result
      if args.bis is not None:
          bis = _load_bis_path(args.bis)
      else:
          bis = {}
  ```

  Guard `--bis-from-wishlist` to API mode only (convert mode always requires explicit BiS). Add after `args = ap.parse_args()`:

  ```python
  if args.bis_from_wishlist and args.wowaudit is not None:
      sys.exit("--bis-from-wishlist is only valid in API mode (no --wowaudit).")
  ```

- [ ] **4.6** Re-run all new tests:

  ```
  pytest tools/tests/test_wowaudit.py -k "derive_bis or bis_from_wishlist" -v
  ```

  Expected: `7 passed`.

- [ ] **4.7** Run the full suite:

  ```
  pytest tools/ -v --tb=short 2>&1 | tail -20
  ```

  Expected: all prior tests pass; total count increases by 7.

- [ ] **4.8** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "$(cat <<'EOF'
  feat(3.3): add --bis-from-wishlist flag with configurable threshold

  Any wishlist item whose best-spec score meets or exceeds --bis-threshold
  (default 2.0%) is marked BiS for that character, removing the need to
  maintain per-spec JSON files manually. --bis-from-wishlist is API-mode
  only; using it alongside --bis logs a fetch_warning and ignores the file.
  Seven new pytest cases cover threshold boundary, empty roster, missing
  sim data, and the full fetch_rows integration path.
  EOF
  )"
  ```

---

### Task 5 — Overlap note and fetch_rows type annotation cleanup

**Files:**
- Modify: `tools/wowaudit.py` — clean up the overloaded return type annotation

The `fetch_rows` overloaded return type introduced in Task 4 is technically correct but awkward for type checkers. Simplify to a named tuple or a `FetchResult` dataclass so downstream callers (including the Actions script) have a stable signature.

- [ ] **5.1** At the top of `tools/wowaudit.py`, after the imports, define a simple dataclass:

  ```python
  from dataclasses import dataclass, field


  @dataclass
  class FetchResult:
      """Return value of :func:`fetch_rows`.

      Attributes:
          rows: Per-character row dicts (one per roster member).
          weeks_in_season: Number of M+ season weeks elapsed (for auto cap).
          warnings: Human-readable warning strings accumulated during fetch.
          derived_bis: BiS mapping derived from wishlist scores when
              ``bis_from_wishlist=True`` was passed; ``None`` otherwise.
      """

      rows: list[dict]
      weeks_in_season: int
      warnings: list[str]
      derived_bis: dict[str, list[int]] | None = field(default=None)
  ```

- [ ] **5.2** Update `fetch_rows()` to return a `FetchResult`:

  Change the return type annotation to `-> FetchResult` and replace the two return statements at the end of the function:

  ```python
  if bis_from_wishlist:
      derived_bis = _derive_bis_from_wishlists(sims_by_id, roster, bis_threshold)
      return FetchResult(rows, weeks_in_season, fetch_warnings, derived_bis)
  return FetchResult(rows, weeks_in_season, fetch_warnings)
  ```

- [ ] **5.3** Update all callers in `main()`. Replace tuple-unpacking calls with attribute access:

  ```python
  result = fetch_rows(
      args.api_key,
      args.dump_raw,
      use_cache=args.use_cache,
      bis_from_wishlist=args.bis_from_wishlist,
      bis_threshold=args.bis_threshold,
  )
  rows            = result.rows
  weeks_in_season = result.weeks_in_season
  fetch_warnings  = result.warnings

  if args.bis_from_wishlist:
      if args.bis is not None:
          fetch_warnings.append(
              "--bis-from-wishlist is active; --bis path is ignored."
          )
      bis = result.derived_bis or {}
  else:
      bis = _load_bis_path(args.bis) if args.bis is not None else {}
  ```

- [ ] **5.4** Update the monkeypatched tests in Task 4 that unpack the tuple. In `test_fetch_rows_bis_from_wishlist_mode`, replace:

  ```python
  rows, _weeks, warnings, derived_bis = wa.fetch_rows(...)
  ```

  with:

  ```python
  result = wa.fetch_rows(...)
  rows         = result.rows
  warnings     = result.warnings
  derived_bis  = result.derived_bis
  ```

  Apply the same pattern to all other `fetch_rows` tests that unpack the three-tuple — change them to use `.rows`, `.weeks_in_season`, `.warnings`.

- [ ] **5.5** Run the full suite:

  ```
  pytest tools/ -v --tb=short 2>&1 | tail -20
  ```

  Expected: all tests pass.

- [ ] **5.6** Commit:

  ```
  git add tools/wowaudit.py tools/tests/test_wowaudit.py
  git commit -m "$(cat <<'EOF'
  refactor: introduce FetchResult dataclass for fetch_rows return value

  Replaces the overloaded tuple return type with a named FetchResult
  dataclass, giving callers stable attribute access and making mypy
  annotations unambiguous. All tests updated to use attribute access.
  EOF
  )"
  ```

---

### Task 6 — Document the Batch 2A overlap in code comments

**Files:**
- Modify: `tools/wowaudit.py` — add a cross-reference comment in `_derive_bis_from_wishlists` and `_best_wishlist_score`

This is a non-code coordination step that takes 5 minutes and prevents double-work confusion when Batch 2A lands.

- [ ] **6.1** Add a comment block at the top of `_derive_bis_from_wishlists()`:

  ```python
  # Batch 2A overlap note:
  # Batch 2A (item 2.1) adds _mainspec_sim_score() and a --spec-aware flag
  # that makes _best_wishlist_score use only the character's main-spec score.
  # When Batch 2A lands, consider passing the spec-aware score into sims_by_id
  # so --bis-from-wishlist thresholding uses mainspec scores rather than the
  # cross-spec max. Until then, sims_by_id holds the max-across-specs value
  # produced by _best_wishlist_score — a conservative (higher) estimate,
  # so BiS derivation will be slightly broader than spec-aware mode would give.
  # This is a known acceptable trade-off for the Batch 3A release window.
  ```

- [ ] **6.2** Commit:

  ```
  git add tools/wowaudit.py
  git commit -m "$(cat <<'EOF'
  docs: add Batch 2A/3A overlap note in _derive_bis_from_wishlists

  Explains that --bis-from-wishlist uses the cross-spec max score until
  Batch 2A's spec-aware sim selection lands, and that this is intentional
  and conservative (broader BiS set, not narrower).
  EOF
  )"
  ```

---

### Task 7 — Add `.luacheckrc` (3.4 prerequisite)

**Files:**
- Create: `.luacheckrc`

luacheck is a Lua static analyser. This config teaches it about WoW's global API surface so the lint job does not drown in false positives.

- [ ] **7.1** Create `.luacheckrc` at the repo root:

  ```lua
  -- .luacheckrc — luacheck configuration for BobleLoot
  -- Run: luacheck *.lua
  -- CI: see .github/workflows/refresh.yml (lint job)

  -- Treat all *.lua files at the repo root.
  files["*.lua"] = {}

  -- WoW addon globals (Lua 5.1 / WoW 10.x environment).
  -- Only list globals actually read or written by this addon.
  globals = {
    -- LibStub / Ace3 bootstrap
    "LibStub",
    "AceLibrary",

    -- AceDB / AceComm / AceTimer (loaded via embeds.xml)
    "AceDB",
    "AceComm",
    "AceTimer",

    -- WoW client globals used by BobleLoot
    "BobleLoot_Data",
    "BobleLootDB",
    "BobleLootSyncDB",
    "RCLootCouncilLootDB",

    -- WoW API functions used across the addon
    "GetServerTime",
    "UnitIsGroupLeader",
    "UnitName",
    "UnitClass",
    "GetNumGroupMembers",
    "GetRaidRosterInfo",
    "C_Timer",
    "C_WeeklyRewards",
    "GameTooltip",
    "UIParent",
    "CreateFrame",
    "InterfaceOptionsFrame_OpenToCategory",

    -- LibDeflate (embedded)
    "LibDeflate",
  }

  -- Read-only WoW globals (we read these but never write them).
  read_globals = {
    "print",
    "pairs",
    "ipairs",
    "next",
    "select",
    "type",
    "tostring",
    "tonumber",
    "math",
    "table",
    "string",
    "unpack",
    "error",
    "assert",
    "pcall",
    "xpcall",
    "setmetatable",
    "getmetatable",
    "rawget",
    "rawset",
    "bit",
    "floor",
    "ceil",
    "max",
    "min",
    "abs",
    -- WoW string.format alias
    "format",
  }

  -- Ignore the Data/ directory (auto-generated Lua, not hand-maintained).
  exclude_files = {
    "Data/*.lua",
    ".claude/",
  }

  -- Max line length: 120 chars (matches the project's black config for Python).
  max_line_length = 120

  -- Suppress noisy unused-variable warnings for loop vars named _ or _N.
  unused_args = false
  ```

- [ ] **7.2** Install luacheck locally if not present and do a smoke-run:

  ```
  luacheck *.lua --config .luacheckrc 2>&1 | head -30
  ```

  The CI job installs it via `sudo apt-get install luarocks && sudo luarocks install luacheck` — local install is optional. If luacheck is not installed, skip the local run and note it in the commit message.

- [ ] **7.3** Commit:

  ```
  git add .luacheckrc
  git commit -m "$(cat <<'EOF'
  chore(3.4): add .luacheckrc with WoW global allowlist

  Configures luacheck for the BobleLoot Lua files: WoW 10.x API globals,
  Ace3 bootstrap globals, the three SavedVariable tables, and LibDeflate.
  Data/ is excluded (auto-generated). Max line length 120.
  EOF
  )"
  ```

---

### Task 8 — Add GitHub Actions `refresh.yml` (3.4)

**Files:**
- Create: `.github/workflows/refresh.yml`

Two jobs: `lint` (runs on every push and PR) and `refresh` (weekly cron, runs `wowaudit.py`, opens PR with data diff).

- [ ] **8.1** Create the `.github/workflows/` directory:

  ```
  mkdir -p .github/workflows
  ```

- [ ] **8.2** Create `.github/workflows/refresh.yml`:

  ```yaml
  # .github/workflows/refresh.yml
  # Batch 3A (item 3.4) — lint every push; refresh data weekly.
  #
  # Jobs:
  #   lint    — pytest tools/ + luacheck *.lua  (push + PR)
  #   refresh — weekly wowaudit.py run + PR open (cron only)
  #
  # Secrets required (Settings → Secrets → Actions):
  #   WOWAUDIT_API_KEY  — WoWAudit team API key
  #   GH_PAT            — Personal Access Token with repo+workflow scopes
  #                        (needed so the refresh job can open a PR)

  name: BobleLoot CI

  on:
    push:
      branches: ["main", "release/**", "plans/**"]
    pull_request:
      branches: ["main"]
    schedule:
      # Weekly on Monday 04:00 UTC — after EU maintenance windows.
      - cron: "0 4 * * 1"
    workflow_dispatch:
      # Allow manual trigger for testing the refresh job.

  jobs:
    # --------------------------------------------------------------------------
    # lint — runs on every push and pull_request
    # --------------------------------------------------------------------------
    lint:
      name: Lint (pytest + luacheck)
      runs-on: ubuntu-latest
      if: github.event_name != 'schedule'

      steps:
        - name: Checkout
          uses: actions/checkout@v4

        - name: Set up Python
          uses: actions/setup-python@v5
          with:
            python-version: "3.11"

        - name: Install Python dependencies
          run: |
            python -m pip install --upgrade pip
            pip install pytest jsonschema

        - name: Run pytest
          run: pytest tools/ -v --tb=short

        - name: Install luacheck
          run: |
            sudo apt-get update -qq
            sudo apt-get install -y luarocks
            sudo luarocks install luacheck

        - name: Run luacheck
          run: luacheck *.lua --config .luacheckrc

    # --------------------------------------------------------------------------
    # refresh — weekly data refresh, opens a PR if anything changed
    # --------------------------------------------------------------------------
    refresh:
      name: Weekly data refresh
      runs-on: ubuntu-latest
      # Only run on the weekly schedule or a manual workflow_dispatch.
      if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'

      permissions:
        contents: write
        pull-requests: write

      steps:
        - name: Checkout
          uses: actions/checkout@v4
          with:
            # Full history so the diff PR is meaningful.
            fetch-depth: 0
            # Use PAT so the PR-creation step can push a new branch.
            token: ${{ secrets.GH_PAT }}

        - name: Set up Python
          uses: actions/setup-python@v5
          with:
            python-version: "3.11"

        - name: Install Python dependencies
          run: |
            python -m pip install --upgrade pip
            pip install pytest jsonschema

        - name: Run wowaudit.py
          env:
            WOWAUDIT_API_KEY: ${{ secrets.WOWAUDIT_API_KEY }}
          run: |
            python tools/wowaudit.py \
              --bis-from-wishlist \
              --bis-threshold 2.0 \
              --out Data/BobleLoot_Data.lua
          # If the API key is absent the script exits non-zero and the job fails
          # with a clear error — secrets.WOWAUDIT_API_KEY is required.

        - name: Check for changes
          id: diff
          run: |
            git diff --quiet Data/BobleLoot_Data.lua \
              && echo "changed=false" >> "$GITHUB_OUTPUT" \
              || echo "changed=true"  >> "$GITHUB_OUTPUT"

        - name: Create refresh branch and commit
          if: steps.diff.outputs.changed == 'true'
          run: |
            DATE=$(date -u +%Y-%m-%d)
            BRANCH="chore/weekly-refresh-${DATE}"
            git config user.name  "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git checkout -b "${BRANCH}"
            git add Data/BobleLoot_Data.lua
            git commit -m "chore: weekly data refresh (${DATE})"
            git push origin "${BRANCH}"
            echo "BRANCH=${BRANCH}" >> "$GITHUB_ENV"
            echo "DATE=${DATE}"     >> "$GITHUB_ENV"

        - name: Open pull request
          if: steps.diff.outputs.changed == 'true'
          env:
            GH_TOKEN: ${{ secrets.GH_PAT }}
          run: |
            gh pr create \
              --title "chore: weekly data refresh (${{ env.DATE }})" \
              --body "$(cat <<'PREOF'
            ## Weekly data refresh

            Auto-generated by the `refresh` job in `.github/workflows/refresh.yml`.

            ### What changed
            `Data/BobleLoot_Data.lua` was regenerated from the current WoWAudit
            team data using `--bis-from-wishlist` (threshold 2.0%).

            ### Review checklist
            - [ ] Diff looks reasonable (no unexpected character removals)
            - [ ] Warnings section (if any) is understood and acceptable
            - [ ] Merge and `/reload` in-game to pick up new scores
            PREOF
            )" \
              --base main \
              --head "${{ env.BRANCH }}"

        - name: No changes detected
          if: steps.diff.outputs.changed == 'false'
          run: echo "BobleLoot_Data.lua is already up to date — no PR needed."
  ```

- [ ] **8.3** Verify the YAML is syntactically valid locally (requires `python-yaml`):

  ```
  python3 -c "import yaml; yaml.safe_load(open('.github/workflows/refresh.yml'))" && echo "YAML OK"
  ```

  Expected: `YAML OK`.

- [ ] **8.4** Commit:

  ```
  git add .github/workflows/refresh.yml
  git commit -m "$(cat <<'EOF'
  feat(3.4): add GitHub Actions refresh.yml with lint + weekly refresh jobs

  lint job runs pytest tools/ and luacheck *.lua on every push and PR.
  refresh job runs on the weekly Monday 04:00 UTC cron: fetches data via
  wowaudit.py --bis-from-wishlist and opens a PR titled
  "chore: weekly data refresh (<date>)" if BobleLoot_Data.lua changed.
  Requires WOWAUDIT_API_KEY and GH_PAT secrets in repository settings.
  EOF
  )"
  ```

---

### Task 9 — Integration smoke test and fixture coverage gap fill

**Files:**
- Modify: `tools/tests/test_wowaudit.py` — add two integration-level tests that exercise the full `main()`-level path for `--bis-from-wishlist` and `--bis` directory mode via argument simulation

These tests do not call `main()` (which calls `sys.exit`) but invoke `fetch_rows` + `build_lua` back-to-back to verify the end-to-end Lua output shape for the new code paths.

- [ ] **9.1** Add the following tests at the bottom of `tools/tests/test_wowaudit.py`:

  ```python
  # ---------------------------------------------------------------------------
  # Task 3A-9 — end-to-end Lua output for new 3A code paths
  # ---------------------------------------------------------------------------

  def test_build_lua_with_derived_bis_marks_bis_entries(monkeypatch):
      """Wishlist-derived BiS IDs appear in the Lua bis table for the character."""

      def fake_http(path, api_key):
          if path == "/period":
              return _fixture("period.json")
          if "/characters" in path:
              return _fixture("characters.json")
          if "/attendance" in path:
              return _fixture("attendance.json")
          if "/historical_data" in path:
              return {"characters": []}
          if "/wishlists" in path:
              return _fixture("wishlists.json")
          return {}

      monkeypatch.setattr(wa, "http_get_json", fake_http)
      monkeypatch.setattr(wa, "_read_cache", lambda _: None)
      monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

      result = wa.fetch_rows(
          "fake-key", None, use_cache=False,
          bis_from_wishlist=True, bis_threshold=2.0,
      )
      bis = result.derived_bis or {}
      lua = wa.build_lua(
          result.rows, bis,
          sim_cap=5.0, mplus_cap=100, history_cap=5,
      )

      # wishlists.json item 212401 at 3.5% (above 2.0%) → BiS for Boble-Stormrage
      assert "[212401] = true" in lua
      assert 'bis  = {' in lua


  def test_build_lua_bis_directory_merges_correctly(tmp_path):
      """Using _load_bis_path on a directory produces merged bis in Lua output."""

      tier_dir = tmp_path / "tww-s3"
      tier_dir.mkdir()
      (tier_dir / "warrior-arms.json").write_text(
          '{"Boble-Stormrage": [212401, 212405]}', encoding="utf-8"
      )
      (tier_dir / "paladin-prot.json").write_text(
          '{"Boble-Stormrage": [212410]}', encoding="utf-8"
      )

      bis = wa._load_bis_path(tier_dir)
      rows = [
          {"character": "Boble-Stormrage", "mplus_dungeons": 10, "attendance": 80.0}
      ]
      lua = wa.build_lua(rows, bis, sim_cap=5.0, mplus_cap=100, history_cap=5)

      # All three IDs from both files should appear
      assert "[212401] = true" in lua
      assert "[212405] = true" in lua
      assert "[212410] = true" in lua
  ```

- [ ] **9.2** Run the new integration tests:

  ```
  pytest tools/tests/test_wowaudit.py -k "build_lua_with_derived_bis or build_lua_bis_directory" -v
  ```

  Expected: `2 passed`.

- [ ] **9.3** Run the full suite one final time:

  ```
  pytest tools/ -v 2>&1 | tail -5
  ```

  Expected: all tests pass. Record the total test count (target: ≥ 78, i.e. 54 existing + ~24 new).

- [ ] **9.4** Commit:

  ```
  git add tools/tests/test_wowaudit.py
  git commit -m "$(cat <<'EOF'
  test(3a): add end-to-end Lua output tests for derived BiS and directory merge

  Verify that wishlist-derived BiS IDs appear correctly in the bis table
  of the Lua output, and that _load_bis_path on a directory produces the
  expected merged set in the Lua file.
  EOF
  )"
  ```

---

### Task 10 — Final check: run all tests, verify file completeness

**Files:** No changes — verification only.

- [ ] **10.1** Run the full pytest suite from the repo root:

  ```
  pytest tools/ -v --tb=short
  ```

  Expected: all tests pass with zero errors.

- [ ] **10.2** Verify all expected files exist:

  ```
  python3 -c "
  from pathlib import Path
  expected = [
      'tools/wowaudit.py',
      'tools/tests/test_wowaudit.py',
      'tools/tests/fixtures/wishlists_partial.json',
      'tools/tests/fixtures/bis/tww-s3/warrior-arms.json',
      'tools/tests/fixtures/bis/tww-s3/paladin-protection.json',
      'bis/tww-s3/warrior-arms.json',
      'bis/tww-s3/paladin-protection.json',
      'bis/README.md',
      '.github/workflows/refresh.yml',
      '.luacheckrc',
  ]
  root = Path('.')
  missing = [p for p in expected if not (root / p).exists()]
  print('Missing:', missing or 'none — all present')
  "
  ```

  Expected: `Missing: none — all present`.

- [ ] **10.3** Confirm `dataWarnings` is present in the Lua output from a convert-mode run with the new per-character warnings path (requires the sample CSV):

  ```
  python3 tools/wowaudit.py \
    --wowaudit tools/sample_input/wowaudit_valid.csv \
    --bis bis/tww-s3/ \
    --out /tmp/test_output.lua \
    --sim-cap 5.0 --mplus-cap 100 --history-cap 5
  grep -c "BobleLoot_Data" /tmp/test_output.lua
  ```

  Expected: `1` (the Lua table definition).

---

## Manual Verification

After all tasks are committed to a branch and pushed to GitHub:

1. **Per-character warnings (3.1):** Run `py tools/wowaudit.py --api-key <key>` against a real team. Open `Data/BobleLoot_Data.lua`. Confirm:
   - If any roster member had no wishlist items, a `-- WARNING: <Name-Realm>: no wishlist data` comment appears at the top of the file.
   - The `dataWarnings` Lua array is populated with the same strings.
   - Characters with complete data have no such warning.

2. **Versioned BiS directory (3.2):** Run `py tools/wowaudit.py --api-key <key> --bis bis/tww-s3/`. Confirm the `bis` table in the generated Lua matches the union of all item IDs from `warrior-arms.json` and `paladin-protection.json` for characters that appear in both files. Run again with `--bis bis/tww-s3/warrior-arms.json` (single file) and confirm backward-compatible flat-file mode works identically.

3. **`--bis-from-wishlist` (3.3):** Run `py tools/wowaudit.py --api-key <key> --bis-from-wishlist --bis-threshold 2.0`. Confirm:
   - Characters whose best wishlist score for an item is >= 2.0% have that item in their `bis` table.
   - Characters with all items below 2.0% have `bis = {}`.
   - The run report does not error.
   - Passing `--bis` alongside `--bis-from-wishlist` logs a fetch_warning that `--bis path is ignored`.

4. **GitHub Actions (3.4):** After the workflow file is merged to `main`:
   - Trigger `workflow_dispatch` on the `refresh` job from the GitHub Actions UI.
   - Confirm the job fetches data, detects whether `BobleLoot_Data.lua` changed, and opens a PR (or prints "no PR needed").
   - Confirm the `lint` job runs on the next push and that `pytest tools/` and `luacheck *.lua` both pass.

---

## Rollback Notes

- **3.1 (per-character warnings):** The change is additive to `fetch_warnings`. If a bug in the warning detection fires false positives, the simplest rollback is to comment out the new warning block in `fetch_rows()` and re-emit without it. The Batch 1A `dataWarnings` array remains intact.
- **3.2 (BiS directory):** `_load_bis_path` with a file path is identical in behaviour to the pre-3A code path. If directory mode has a bug, pass `--bis <flat_file.json>` to revert to the prior behaviour — no code change needed.
- **3.3 (`--bis-from-wishlist`):** The flag defaults to `False`; omitting it restores prior behaviour. No rollback needed unless the flag is in a cron invocation — edit `refresh.yml` to remove `--bis-from-wishlist` and add `--bis bis/tww-s3/` instead.
- **3.4 (GitHub Actions):** Disable the workflow in the GitHub UI (Actions → `BobleLoot CI` → disable) or delete `refresh.yml`. The cron will not run. The `lint` job is entirely additive and safe to revert at any time.

---

## Coordination Notes — Batch 2A and Batch 3A in the same release

Batch 2A (items 2.1–2.4) introduces `_mainspec_sim_score()`, a `--spec-aware` flag, a `mainspec` field in the emitted Lua, and a `role` field. Batch 3A's `--bis-from-wishlist` uses the same `sims_by_id` dict built during wishlist ingestion.

**Key interaction:** Until Batch 2A lands, `sims_by_id[cid][iid]` holds the **cross-spec max score** (from `_best_wishlist_score`). After Batch 2A lands, it *could* hold the mainspec-only score when `--spec-aware` is active. The comment added in Task 6 documents this gap.

**If both batches ship in the same release cycle (v1.3):**

1. Batch 2A should land first (it modifies the wishlist ingestion loop to optionally call `_mainspec_sim_score` instead of `_best_wishlist_score`).
2. After Batch 2A merges, update `fetch_rows` so that when `bis_from_wishlist=True` and `spec_aware=True` are both active, `sims_by_id` holds the mainspec-filtered scores before `_derive_bis_from_wishlists` is called. This is a small targeted change (~5 lines in the wishlist loop).
3. The `FetchResult` dataclass introduced in Task 5 makes this wiring easy — `derived_bis` can be computed after the spec-aware pass without changing the function signature.

**If batches ship separately:** No action required. The cross-spec max gives a slightly broader BiS set (more items marked BiS than spec-aware would give) which is the conservative direction — it does not exclude items a character actually needs.

**Do not absorb Batch 2A scope into Batch 3A:** `mainspec`, `role`, `--tier`, and vault-loot categorization remain 2A work. Batch 3A touches only `wowaudit.py`'s fetch-and-emit pipeline, the BiS loading path, and CI.
