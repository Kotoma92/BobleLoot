# Batch 3A — Python Resilience & CI (items 3.1–3.4)

**Date:** 2026-04-23
**Branch:** release/v1.1.0
**Status:** Implementation plan

## Scope

Roadmap items from Batch 3 that are purely data-side and unblock CI automation:

- **3.1** Per-character partial-success ingestion (`fetch_warnings` tracks
  missing characters from `/wishlists`; Lua output annotates missing chars)
- **3.2** Versioned BiS directory (`bis/<tier>/<class>-<spec>.json`;
  `--bis` accepts file or directory)
- **3.3** `--bis-from-wishlist` flag (derive BiS from sim threshold)
- **3.4** GitHub Actions weekly refresh workflow + luacheck lint job

## Files in scope

- `tools/wowaudit.py`
- `tools/tests/test_wowaudit.py`
- `tools/tests/fixtures/`
- `bis/` (new top-level directory)
- `bis/README.md`
- `.github/workflows/refresh.yml`
- `.luacheckrc`

## DO NOT touch

- `Scoring.lua`, `LootHistory.lua` (plan 3B targets)
- UI files, `Core.lua`, `Sync.lua`
- Anything outside `tools/`, `bis/`, `.github/`, `.luacheckrc`

---

## Task 3.1 — Per-character partial-success ingestion

### Behaviour

`/wishlists` returns data for N of M roster characters.  The missing ones
currently emit empty sims silently.

After this task:
1. `fetch_rows` cross-references the roster against `wl_chars` and appends
   a warning for every roster character absent from the wishlists payload.
2. `build_lua` emits the warning block (already implemented) and also emits
   a `missingWishlists = { "Name-Realm", ... }` array so Lua can surface it.

### Tests (TDD — write first)

```
test_fetch_rows_warns_on_missing_wishlist_character
test_build_lua_emits_missing_wishlists_array
test_build_lua_no_missing_wishlists_omits_key
```

### Commit message

```
feat(3.1): warn on per-character missing wishlist data
```

---

## Task 3.2 — Versioned BiS directory

### Behaviour

`--bis` currently accepts only a JSON file. After this task it also accepts
a directory. When a directory is given, every `.json` file inside (any
depth) is merged into a single `{ "Name-Realm": [itemIDs] }` mapping.

The new canonical location is `bis/<tier>/<class>-<spec>.json`.
Ship three example files:
- `bis/tww-s3/paladin-holy.json`
- `bis/tww-s3/warrior-protection.json`
- `bis/tww-s3/README.md`  (or top-level `bis/README.md`)

Backward-compat: passing a single file continues to work as before.

### Tests (TDD — write first)

```
test_load_bis_from_file_unchanged
test_load_bis_from_directory_merges_files
test_load_bis_directory_deduplicates_item_ids
test_load_bis_empty_directory_returns_empty
test_load_bis_nested_directory_walks_recursively
```

### Commit message

```
feat(3.2): versioned BiS directory support
```

---

## Task 3.3 — `--bis-from-wishlist` flag

### Behaviour

New CLI flag `--bis-from-wishlist` (default threshold: `2.0`).
Optional companion `--bis-threshold FLOAT`.

When active:
- For each character and each item, if the best-spec sim score
  (`_best_wishlist_score`) exceeds the threshold, the item is added to
  that character's BiS list.
- The derived BiS **replaces** any `--bis` file/directory for the run.
  If both are given, `--bis-from-wishlist` wins and a warning is emitted.
- Works in API mode only (rows must carry `sim_*` columns).

New helper function: `_derive_bis_from_rows(rows, threshold) -> dict[str, list[int]]`

### Tests (TDD — write first)

```
test_derive_bis_from_rows_basic
test_derive_bis_from_rows_threshold_respected
test_derive_bis_from_rows_empty_rows
test_derive_bis_from_rows_no_sim_cols_returns_empty
test_derive_bis_from_rows_negative_scores_excluded
```

### Commit message

```
feat(3.3): --bis-from-wishlist derives BiS from sim threshold
```

---

## Task 3.4 — GitHub Actions refresh workflow + luacheck

### Behaviour

**`.luacheckrc`** — configure for WoW globals (WoW API, RC globals, BobleLoot
namespace) so luacheck can run on all Lua files without false positives.

**`.github/workflows/refresh.yml`** — two jobs:

1. `lint` job (runs on every push/PR):
   - `pytest tools/` (Python tests)
   - `luacheck` on all `*.lua` files using `.luacheckrc`

2. `refresh` job (scheduled weekly — Sunday 03:00 UTC):
   - Runs `python tools/wowaudit.py --api-key $WOWAUDIT_API_KEY --tier TWW-S3`
   - Opens a PR titled `chore: weekly data refresh (<date>)`
   - Only creates PR when `Data/BobleLoot_Data.lua` changed
   - Uses `peter-evans/create-pull-request` action
   - API key stored in GitHub secret `WOWAUDIT_API_KEY`

### Commit message

```
feat(3.4): GitHub Actions lint + weekly data refresh workflow
```

---

## Test count targets

| After task | Expected passing |
|---|---|
| Baseline | 77 |
| 3.1 | ~83 |
| 3.2 | ~89 |
| 3.3 | ~95 |
| 3.4 | 95 (no new Python tests) |
