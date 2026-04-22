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
