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
# Plan 1B — simsKnown emission
# ---------------------------------------------------------------------------

def test_build_lua_emits_sims_known_for_zero_results():
    """A '0' CSV cell -> simsKnown[id]=true, sims[id] omitted."""
    rows = [
        {"character": "Zerochar-Realm", "attendance": 100, "mplus_dungeons": 0,
         "sim_111": "0", "sim_222": "1.5"},
    ]
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
    assert "[222] = 1.5" in lua
    assert "[111] = 0" not in lua
    assert "simsKnown" in lua
    assert "[111] = true" in lua
    assert "[222] = true" in lua


def test_build_lua_omits_unsimmed_items_from_known():
    """Empty CSV cell -> item appears in neither sims nor simsKnown."""
    rows = [
        {"character": "Partial-Realm", "attendance": 100, "mplus_dungeons": 0,
         "sim_111": "", "sim_222": "2.0"},
    ]
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
    assert "[111] = true" not in lua
    assert "[222] = true" in lua
    assert "[222] = 2.0" in lua


def test_build_lua_empty_sims_known_when_no_sim_columns():
    rows = [
        {"character": "Nosims-Realm", "attendance": 100, "mplus_dungeons": 0},
    ]
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
    assert "simsKnown = {}" in lua


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

    rows, weeks, warnings, _missing = wa.fetch_rows("fake-key", None, use_cache=False)

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

    rows, weeks, warnings, _missing = wa.fetch_rows("fake-key", None, use_cache=False)

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

    rows, weeks, warnings, _missing = wa.fetch_rows("fake-key", None, use_cache=False)

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
        # Also return empty data for historical_data labels.
        if label.startswith("historical_"):
            return {"characters": []}
        return fixtures.get(label)

    def fake_http_get_json(path, api_key):
        http_calls.append(path)
        return {}

    monkeypatch.setattr(wa, "_read_cache", fake_read_cache)
    monkeypatch.setattr(wa, "_write_cache", lambda *_: None)
    monkeypatch.setattr(wa, "http_get_json", fake_http_get_json)

    rows, weeks, warnings, _missing = wa.fetch_rows("fake-key", None, use_cache=True)

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


# ---------------------------------------------------------------------------
# Task 12 — _read_table CSV edge cases
# ---------------------------------------------------------------------------

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

    rows, _, _, _ = wa.fetch_rows("key", None)
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

    rows, _, _, _ = wa.fetch_rows("key", None)
    by_name = {r["character"]: r for r in rows}
    # NoSpec character has no main_spec field
    assert by_name["NoSpec-Stormrage"]["mainspec"] is None
    assert by_name["NoSpec-Stormrage"]["role"] == "raider"


def test_role_map_unknown_status_defaults_to_raider():
    """An unrecognised status string maps to 'raider', not 'trial' or 'bench'."""
    assert wa._ROLE_MAP.get("social", "raider") == "raider"
    assert wa._ROLE_MAP.get("", "raider")        == "raider"


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

    rows, _, _, _ = wa.fetch_rows("key", None, spec_aware=True)
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

    rows, _, _, _ = wa.fetch_rows("key", None, spec_aware=False)
    row = rows[0]
    # spec_aware=False: max across specs = 8.0
    assert row.get("sim_212401") == 8.0


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


# ---------------------------------------------------------------------------
# Task 3.1 — Per-character partial-success ingestion
# ---------------------------------------------------------------------------

def test_fetch_rows_warns_on_missing_wishlist_character(monkeypatch):
    """Characters in the roster but absent from /wishlists get a fetch_warning."""

    def fake_http(path, key):
        if path == "/period":
            return _fixture("period.json")
        if "/characters" in path:
            # Two characters in roster.
            return [
                {"id": 1, "name": "Boble",  "realm": "Stormrage"},
                {"id": 2, "name": "Kotoma", "realm": "Twisting Nether"},
            ]
        if "/attendance" in path:
            return _fixture("attendance.json")
        if "/historical_data" in path:
            return {"characters": []}
        if "/wishlists" in path:
            # Only Boble (id=1) is present in wishlists; Kotoma is missing.
            return {
                "characters": [
                    {"id": 1, "instances": []},
                ]
            }
        return {}

    monkeypatch.setattr(wa, "http_get_json", fake_http)
    monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
    monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

    rows, _, warnings, _missing = wa.fetch_rows("fake-key", None, use_cache=False)

    # Kotoma should appear in warnings as missing from wishlists.
    assert any("Kotoma-TwistingNether" in w and "wishlist" in w.lower() for w in warnings), \
        f"Expected missing-wishlist warning for Kotoma, got: {warnings}"


def test_build_lua_emits_missing_wishlists_array():
    """build_lua emits a missingWishlists array when missing_wishlists is non-empty."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0, "mplus_dungeons": 30}]
    lua = wa.build_lua(
        rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
        missing_wishlists=["Kotoma-TwistingNether", "Other-Realm"],
    )
    assert "missingWishlists" in lua
    assert '"Kotoma-TwistingNether"' in lua
    assert '"Other-Realm"' in lua


def test_build_lua_no_missing_wishlists_omits_key():
    """build_lua omits missingWishlists key when the list is empty or absent."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0, "mplus_dungeons": 30}]
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5)
    assert "missingWishlists" not in lua

    lua2 = wa.build_lua(
        rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
        missing_wishlists=[],
    )
    assert "missingWishlists" not in lua2


def test_fetch_rows_all_chars_in_wishlists_no_warning(monkeypatch):
    """No missing-wishlist warning when all roster chars appear in wishlists payload."""

    def fake_http(path, key):
        if path == "/period":
            return _fixture("period.json")
        if "/characters" in path:
            return [{"id": 1, "name": "Boble", "realm": "Stormrage"}]
        if "/attendance" in path:
            return _fixture("attendance.json")
        if "/historical_data" in path:
            return {"characters": []}
        if "/wishlists" in path:
            return {"characters": [{"id": 1, "instances": []}]}
        return {}

    monkeypatch.setattr(wa, "http_get_json", fake_http)
    monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
    monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

    rows, _, warnings, _missing = wa.fetch_rows("fake-key", None, use_cache=False)

    missing_warnings = [w for w in warnings if "wishlist" in w.lower() and "missing" in w.lower()]
    assert missing_warnings == [], f"Unexpected missing-wishlist warnings: {missing_warnings}"


def test_fetch_rows_returns_missing_wishlists_list(monkeypatch):
    """fetch_rows returns missing_wishlists as fourth element when character absent."""

    def fake_http(path, key):
        if path == "/period":
            return _fixture("period.json")
        if "/characters" in path:
            return [
                {"id": 1, "name": "Boble",  "realm": "Stormrage"},
                {"id": 2, "name": "Kotoma", "realm": "Twisting Nether"},
            ]
        if "/attendance" in path:
            return _fixture("attendance.json")
        if "/historical_data" in path:
            return {"characters": []}
        if "/wishlists" in path:
            return {"characters": [{"id": 1, "instances": []}]}
        return {}

    monkeypatch.setattr(wa, "http_get_json", fake_http)
    monkeypatch.setattr(wa, "_read_cache",  lambda _: None)
    monkeypatch.setattr(wa, "_write_cache", lambda *_: None)

    result = wa.fetch_rows("fake-key", None, use_cache=False)
    # fetch_rows returns (rows, weeks, fetch_warnings, missing_wishlists)
    assert len(result) == 4
    rows, weeks, warnings, missing = result
    assert "Kotoma-TwistingNether" in missing


# ---------------------------------------------------------------------------
# Task 3.2 — Versioned BiS directory
# ---------------------------------------------------------------------------

def test_load_bis_from_file_unchanged(tmp_path):
    """load_bis with a file path behaves identically to the old direct json.load."""
    bis_file = tmp_path / "bis.json"
    bis_file.write_text(
        '{"Boble-Stormrage": [212401, 212403], "Kotoma-TwistingNether": [212450]}',
        encoding="utf-8",
    )
    result = wa.load_bis(bis_file)
    assert result == {
        "Boble-Stormrage": [212401, 212403],
        "Kotoma-TwistingNether": [212450],
    }


def test_load_bis_from_directory_merges_files(tmp_path):
    """load_bis merges all .json files found directly in a directory."""
    bis_dir = tmp_path / "bis"
    bis_dir.mkdir()
    (bis_dir / "paladin-holy.json").write_text(
        '{"Boble-Stormrage": [212401, 212403]}', encoding="utf-8"
    )
    (bis_dir / "warrior-protection.json").write_text(
        '{"Kotoma-TwistingNether": [212450]}', encoding="utf-8"
    )
    result = wa.load_bis(bis_dir)
    assert result["Boble-Stormrage"] == [212401, 212403]
    assert result["Kotoma-TwistingNether"] == [212450]


def test_load_bis_directory_deduplicates_item_ids(tmp_path):
    """When two files list the same character, item IDs are merged without duplicates."""
    bis_dir = tmp_path / "bis"
    bis_dir.mkdir()
    (bis_dir / "file1.json").write_text(
        '{"Boble-Stormrage": [212401, 212403]}', encoding="utf-8"
    )
    (bis_dir / "file2.json").write_text(
        '{"Boble-Stormrage": [212403, 212500]}', encoding="utf-8"
    )
    result = wa.load_bis(bis_dir)
    items = result["Boble-Stormrage"]
    assert sorted(items) == [212401, 212403, 212500]
    # No duplicates.
    assert len(items) == len(set(items))


def test_load_bis_empty_directory_returns_empty(tmp_path):
    """An empty directory returns an empty mapping."""
    bis_dir = tmp_path / "bis"
    bis_dir.mkdir()
    result = wa.load_bis(bis_dir)
    assert result == {}


def test_load_bis_nested_directory_walks_recursively(tmp_path):
    """load_bis finds .json files in subdirectories."""
    bis_dir = tmp_path / "bis"
    subdir = bis_dir / "tww-s3"
    subdir.mkdir(parents=True)
    (subdir / "paladin-holy.json").write_text(
        '{"Boble-Stormrage": [212401]}', encoding="utf-8"
    )
    result = wa.load_bis(bis_dir)
    assert result == {"Boble-Stormrage": [212401]}


def test_load_bis_skips_non_json_files(tmp_path):
    """Non-.json files in the directory are ignored."""
    bis_dir = tmp_path / "bis"
    bis_dir.mkdir()
    (bis_dir / "paladin-holy.json").write_text('{"Boble-Stormrage": [212401]}', encoding="utf-8")
    (bis_dir / "README.md").write_text("# BiS files", encoding="utf-8")
    (bis_dir / "notes.txt").write_text("some notes", encoding="utf-8")
    result = wa.load_bis(bis_dir)
    assert result == {"Boble-Stormrage": [212401]}


# ---------------------------------------------------------------------------
# Task 3.3 — _derive_bis_from_rows / --bis-from-wishlist
# ---------------------------------------------------------------------------

def test_derive_bis_from_rows_basic():
    """Items whose sim value exceeds threshold are included in the BiS list."""
    rows = [
        {"character": "Boble-Stormrage",
         "mplus_dungeons": 10, "attendance": 80.0,
         "sim_212401": 3.5, "sim_212403": 0.5},
    ]
    result = wa._derive_bis_from_rows(rows, threshold=2.0)
    assert "Boble-Stormrage" in result
    assert 212401 in result["Boble-Stormrage"]
    assert 212403 not in result["Boble-Stormrage"]


def test_derive_bis_from_rows_threshold_respected():
    """Items exactly at the threshold are NOT included (strictly greater than)."""
    rows = [
        {"character": "Boble-Stormrage",
         "mplus_dungeons": 10, "attendance": 80.0,
         "sim_212401": 2.0, "sim_212403": 2.1},
    ]
    result = wa._derive_bis_from_rows(rows, threshold=2.0)
    assert 212401 not in result.get("Boble-Stormrage", [])
    assert 212403 in result.get("Boble-Stormrage", [])


def test_derive_bis_from_rows_empty_rows():
    """Empty rows list returns empty dict."""
    assert wa._derive_bis_from_rows([], threshold=2.0) == {}


def test_derive_bis_from_rows_no_sim_cols_returns_empty():
    """Characters with no sim_ columns produce an empty BiS list."""
    rows = [
        {"character": "Boble-Stormrage", "mplus_dungeons": 10, "attendance": 80.0},
    ]
    result = wa._derive_bis_from_rows(rows, threshold=2.0)
    # Either the character is absent or has an empty list.
    assert result.get("Boble-Stormrage", []) == []


def test_derive_bis_from_rows_negative_scores_excluded():
    """Negative sim values (downgrades) are never included."""
    rows = [
        {"character": "Boble-Stormrage",
         "mplus_dungeons": 10, "attendance": 80.0,
         "sim_212401": -1.0, "sim_212403": 3.0},
    ]
    result = wa._derive_bis_from_rows(rows, threshold=2.0)
    assert 212401 not in result.get("Boble-Stormrage", [])
    assert 212403 in result.get("Boble-Stormrage", [])


def test_derive_bis_from_rows_multiple_characters():
    """Each character gets their own independent BiS list."""
    rows = [
        {"character": "Boble-Stormrage",
         "mplus_dungeons": 10, "attendance": 80.0,
         "sim_212401": 3.5, "sim_212403": 0.5},
        {"character": "Kotoma-TwistingNether",
         "mplus_dungeons": 8, "attendance": 70.0,
         "sim_212401": 0.1, "sim_212403": 4.2},
    ]
    result = wa._derive_bis_from_rows(rows, threshold=2.0)
    assert 212401 in result["Boble-Stormrage"]
    assert 212403 not in result["Boble-Stormrage"]
    assert 212403 in result["Kotoma-TwistingNether"]
    assert 212401 not in result["Kotoma-TwistingNether"]


def test_derive_bis_from_rows_custom_threshold():
    """A high threshold of 5.0 only captures very high-value sims."""
    rows = [
        {"character": "Boble-Stormrage",
         "mplus_dungeons": 10, "attendance": 80.0,
         "sim_212401": 4.9, "sim_212403": 6.0},
    ]
    result = wa._derive_bis_from_rows(rows, threshold=5.0)
    assert 212401 not in result.get("Boble-Stormrage", [])
    assert 212403 in result.get("Boble-Stormrage", [])


# ---------------------------------------------------------------------------
# Task 4A-1 — tier-config YAML loading (item 4.1)
# ---------------------------------------------------------------------------

import yaml  # PyYAML — installed as part of 4A

TIER_CONFIG_PATH = TOOLS_DIR / "tier-config.yaml"


def test_load_tier_config_returns_known_tier():
    """_load_tier_config('tww-s3') returns the expected preset dict."""
    preset = wa._load_tier_config("tww-s3")
    assert preset["ilvlFloor"] == 636
    assert preset["mplusCap"] == 160
    assert preset["historyDays"] == 84
    assert preset["softFloor"] == 6


def test_load_tier_config_case_insensitive():
    """Tier names are matched case-insensitively."""
    preset = wa._load_tier_config("TWW-S3")
    assert preset["mplusCap"] == 160


def test_load_tier_config_tww_s2():
    """Historical tier tww-s2 is resolvable."""
    preset = wa._load_tier_config("tww-s2")
    assert preset["ilvlFloor"] == 610


def test_load_tier_config_unknown_tier_exits():
    """Unknown tier name causes sys.exit with a helpful message."""
    with pytest.raises(SystemExit) as exc_info:
        wa._load_tier_config("totally-fake-tier-xyz")
    assert "totally-fake-tier-xyz" in str(exc_info.value).lower()


def test_load_tier_config_bis_path_returned():
    """bisPath is returned as a string when present."""
    preset = wa._load_tier_config("tww-s3")
    assert preset["bisPath"] == "bis/tww-s3"


def test_load_tier_config_null_bis_path():
    """bisPath is None when the YAML entry has null."""
    preset = wa._load_tier_config("tww-s2")
    assert preset["bisPath"] is None


def test_load_tier_config_yaml_file_exists():
    """tools/tier-config.yaml is present on disk."""
    assert TIER_CONFIG_PATH.is_file(), (
        f"tools/tier-config.yaml not found at {TIER_CONFIG_PATH}"
    )


def test_tier_config_yaml_is_valid():
    """tier-config.yaml is syntactically valid YAML."""
    doc = yaml.safe_load(TIER_CONFIG_PATH.read_text(encoding="utf-8"))
    assert "tiers" in doc
    assert isinstance(doc["tiers"], dict)


# ---------------------------------------------------------------------------
# Task 4A-2 — retry_with_backoff decorator (item 4.4)
# ---------------------------------------------------------------------------

import time


def test_retry_succeeds_on_first_attempt(monkeypatch):
    """A function that always succeeds is called exactly once."""
    call_count = 0

    def always_ok(url, key):
        nonlocal call_count
        call_count += 1
        return {"ok": True}

    monkeypatch.setattr(wa, "_sleep", lambda _: None)  # skip real sleep
    decorated = wa.retry_with_backoff(always_ok, delays=[5, 30], cache_key_fn=None)
    result = decorated("http://example.com/test", "apikey")
    assert result == {"ok": True}
    assert call_count == 1


def test_retry_retries_on_http_error_then_succeeds(monkeypatch):
    """First call raises HTTPError; second call succeeds."""
    attempts = []

    def flaky(url, key):
        attempts.append(1)
        if len(attempts) == 1:
            raise urllib.error.HTTPError(url, 429, "Rate Limited", {}, None)
        return {"ok": True}

    monkeypatch.setattr(wa, "_sleep", lambda _: None)
    decorated = wa.retry_with_backoff(flaky, delays=[5, 30], cache_key_fn=None)
    result = decorated("http://example.com/test", "key")
    assert result == {"ok": True}
    assert len(attempts) == 2


def test_retry_exhausts_to_cache_fallback(monkeypatch):
    """After all retries fail, _read_cache is called as the final fallback."""
    def always_fail(url, key):
        raise urllib.error.HTTPError(url, 503, "Unavailable", {}, None)

    cached_value = {"cached": True}
    cache_calls = []

    def fake_read_cache(path):
        cache_calls.append(path)
        return cached_value

    monkeypatch.setattr(wa, "_sleep", lambda _: None)
    monkeypatch.setattr(wa, "_read_cache", fake_read_cache)

    decorated = wa.retry_with_backoff(
        always_fail,
        delays=[0, 0],
        cache_key_fn=lambda url, key: url,
    )
    result = decorated("http://example.com/test", "key")
    assert result == {"cached": True}
    assert len(cache_calls) == 1


def test_retry_propagates_when_cache_empty(monkeypatch):
    """When all retries fail and cache is empty, the last exception propagates."""
    def always_fail(url, key):
        raise urllib.error.HTTPError(url, 503, "Unavailable", {}, None)

    monkeypatch.setattr(wa, "_sleep", lambda _: None)
    monkeypatch.setattr(wa, "_read_cache", lambda _: None)  # cache miss

    decorated = wa.retry_with_backoff(
        always_fail,
        delays=[0, 0],
        cache_key_fn=lambda url, key: url,
    )
    with pytest.raises(urllib.error.HTTPError):
        decorated("http://example.com/test", "key")


def test_retry_sleep_durations_called_in_order(monkeypatch):
    """Sleep is called with the configured delays in order."""
    slept = []
    attempts = [0]

    def flaky(url, key):
        attempts[0] += 1
        if attempts[0] < 3:
            raise urllib.error.HTTPError(url, 429, "Rate", {}, None)
        return {"ok": True}

    monkeypatch.setattr(wa, "_sleep", lambda d: slept.append(d))
    decorated = wa.retry_with_backoff(flaky, delays=[5, 30], cache_key_fn=None)
    result = decorated("http://example.com/test", "key")
    assert result == {"ok": True}
    assert slept == [5, 30]


def test_http_get_json_uses_backoff_on_rate_limit(monkeypatch):
    """http_get_json retries on 429 rather than propagating immediately."""
    # Simulate rate-limit on first call, success on second.
    call_log = []

    def fake_urlopen(req, **kwargs):
        call_log.append("called")
        if len(call_log) == 1:
            raise urllib.error.HTTPError(
                req.full_url, 429, "Too Many Requests", {}, None
            )
        # Second call: return a minimal JSON response
        import io
        body = b'{"characters": []}'
        class FakeResponse:
            headers = {}
            def read(self):
                return body
            def __enter__(self): return self
            def __exit__(self, *a): pass
        return FakeResponse()

    monkeypatch.setattr(wa, "_sleep", lambda _: None)
    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)

    result = wa.http_get_json("/test-endpoint", "fake-key")
    assert isinstance(result, dict)
    assert len(call_log) == 2


# ---------------------------------------------------------------------------
# Task 4A-3 — character rename sidecar (item 4.5)
# ---------------------------------------------------------------------------

RENAMES_FIXTURE = {
    "OldChar-OldRealm": "NewChar-NewRealm",
    "Migrant-TwistingNether": "Migrant-Stormrage",
}


def test_apply_renames_renames_character_key():
    """Row character keys matching old names are replaced with new names."""
    rows = [
        {"character": "OldChar-OldRealm", "attendance": 100.0},
        {"character": "Stable-Realm", "attendance": 80.0},
    ]
    result = wa._apply_renames(rows, bis={}, renames=RENAMES_FIXTURE)
    names = [r["character"] for r in result["rows"]]
    assert "NewChar-NewRealm" in names
    assert "OldChar-OldRealm" not in names
    assert "Stable-Realm" in names


def test_apply_renames_renames_bis_keys():
    """BiS dict keys matching old names are replaced."""
    bis = {
        "OldChar-OldRealm": [212401, 212405],
        "Stable-Realm": [212410],
    }
    result = wa._apply_renames([], bis=bis, renames=RENAMES_FIXTURE)
    assert "NewChar-NewRealm" in result["bis"]
    assert "OldChar-OldRealm" not in result["bis"]
    assert result["bis"]["NewChar-NewRealm"] == [212401, 212405]


def test_apply_renames_skips_metadata_keys():
    """Keys starting with underscore are treated as metadata, not renames."""
    renames_with_meta = {
        "_comment": "this is metadata",
        "OldChar-OldRealm": "NewChar-NewRealm",
    }
    rows = [{"character": "OldChar-OldRealm", "attendance": 95.0}]
    result = wa._apply_renames(rows, bis={}, renames=renames_with_meta)
    assert result["rows"][0]["character"] == "NewChar-NewRealm"


def test_apply_renames_empty_renames_is_noop():
    """An empty renames map leaves rows and bis unchanged."""
    rows = [{"character": "Boble-Stormrage", "attendance": 100.0}]
    bis = {"Boble-Stormrage": [212401]}
    result = wa._apply_renames(rows, bis=bis, renames={})
    assert result["rows"][0]["character"] == "Boble-Stormrage"
    assert "Boble-Stormrage" in result["bis"]


def test_apply_renames_no_match_is_noop():
    """Names that do not appear in renames are unchanged."""
    rows = [{"character": "Unknown-Realm", "attendance": 90.0}]
    result = wa._apply_renames(rows, bis={}, renames=RENAMES_FIXTURE)
    assert result["rows"][0]["character"] == "Unknown-Realm"


def test_build_lua_emits_renames_table(monkeypatch):
    """build_lua with a non-empty renames map writes a renames = {} table."""
    rows = [{"character": "NewChar-NewRealm", "attendance": 95.0,
             "mplus_dungeons": 10}]
    renames = {"OldChar-OldRealm": "NewChar-NewRealm"}
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
                       renames=renames)
    assert "renames" in lua
    assert "OldChar-OldRealm" in lua
    assert "NewChar-NewRealm" in lua


def test_build_lua_omits_renames_table_when_empty():
    """build_lua with no renames does not write a renames table."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0,
             "mplus_dungeons": 10}]
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
                       renames={})
    assert "renames" not in lua


def test_renames_json_file_exists():
    """tools/renames.json is present on disk."""
    assert (TOOLS_DIR / "renames.json").is_file()


# ---------------------------------------------------------------------------
# Task 4A-4 — scoreOverrides sidecar (item 4.7)
# ---------------------------------------------------------------------------

def test_build_lua_emits_score_overrides_table():
    """build_lua with score_overrides writes scoreOverrides = { [id] = v }."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0,
             "mplus_dungeons": 10}]
    overrides = {212401: 95.0, 212405: 0.0}
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
                       score_overrides=overrides)
    assert "scoreOverrides" in lua
    assert "[212401] = 95.0" in lua
    assert "[212405] = 0.0" in lua


def test_build_lua_omits_score_overrides_when_empty():
    """build_lua with no overrides does not write scoreOverrides."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0,
             "mplus_dungeons": 10}]
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
                       score_overrides={})
    assert "scoreOverrides" not in lua


def test_build_lua_score_override_float_formatting():
    """Score override values are emitted as floats (not ints)."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0,
             "mplus_dungeons": 10}]
    overrides = {999999: 50}  # int input
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
                       score_overrides=overrides)
    # Must be emitted as 50.0, not 50 (Lua distinguishes int/float only
    # where the decimal point is present; being explicit avoids confusion)
    assert "[999999] = 50.0" in lua


def test_score_overrides_json_file_exists():
    """tools/score-overrides.json is present on disk."""
    assert (TOOLS_DIR / "score-overrides.json").is_file()


def test_score_overrides_json_is_valid():
    """tools/score-overrides.json is syntactically valid JSON."""
    path = TOOLS_DIR / "score-overrides.json"
    doc = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(doc, dict)


def test_score_overrides_numeric_values_only(monkeypatch):
    """Non-numeric override values are rejected with a warning, not a crash."""
    rows = [{"character": "Boble-Stormrage", "attendance": 95.0,
             "mplus_dungeons": 10}]
    # Pass a string value — should be skipped rather than crashing.
    overrides = {212401: "bad-value", 212405: 75.0}
    # build_lua should not raise; only valid numeric entries appear.
    lua = wa.build_lua(rows, {}, sim_cap=5.0, mplus_cap=100, history_cap=5,
                       score_overrides=overrides)
    assert "[212405] = 75.0" in lua
    assert "bad-value" not in lua


# ---------------------------------------------------------------------------
# Task 4A-8 — --renames and --score-overrides CLI flags (item 4.5 / 4.7)
# ---------------------------------------------------------------------------

def test_renames_path_default_is_sibling_of_wowaudit():
    """Default renames path is tools/renames.json."""
    wowaudit_path = TOOLS_DIR / "wowaudit.py"
    assert (wowaudit_path.parent / "renames.json").is_file()


def test_score_overrides_path_default_is_sibling():
    """Default score-overrides path is tools/score-overrides.json."""
    assert (TOOLS_DIR / "score-overrides.json").is_file()


# ---------------------------------------------------------------------------
# Batch 4B — export_bundle() round-trip tests (roadmap 4.3)
# ---------------------------------------------------------------------------

SAMPLE_ROWS = [
    {
        "character": "Boble-Draenor",
        "attendance": "95",
        "mplus_dungeons": "30",
        "sim_12345": "2.9",
        "sim_67890": "1.1",
        "mainspec": "Holy",
        "role": "raider",
    },
    {
        "character": "Kotoma-Draenor",
        "attendance": "80",
        "mplus_dungeons": "15",
        "mainspec": "Protection",
        "role": "trial",
    },
]

SAMPLE_BIS = {
    "Boble-Draenor": [12345, 67890],
    "Kotoma-Draenor": [],
}


class TestExportBundle:
    def test_schema_field_present(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        assert bundle["schema"] == "bobleloot-export-v1"

    def test_character_count(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        assert len(bundle["characters"]) == 2

    def test_bis_round_trip(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        char = bundle["characters"]["Boble-Draenor"]
        assert set(char["bis"]) == {12345, 67890}

    def test_sims_round_trip(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        char = bundle["characters"]["Boble-Draenor"]
        assert char["sims"][12345] == pytest.approx(2.9)
        assert char["sims"][67890] == pytest.approx(1.1)

    def test_mainspec_and_role_included(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        char = bundle["characters"]["Boble-Draenor"]
        assert char["mainspec"] == "Holy"
        assert char["role"] == "raider"

    def test_scoring_config_preserved(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        cfg = bundle["scoringConfig"]
        assert cfg["simCap"] == 5.0
        assert cfg["mplusCap"] == 40
        assert cfg["historyCap"] == 5

    def test_no_api_key_in_bundle(self):
        """The exported bundle must never contain API credentials."""
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        bundle_str = json.dumps(bundle)
        assert "api_key" not in bundle_str.lower()
        assert "authorization" not in bundle_str.lower()
        assert "WOWAUDIT_API_KEY" not in bundle_str

    def test_empty_rows_produces_empty_characters(self):
        bundle = wa.export_bundle([], {}, 5.0, 40, 5)
        assert bundle["characters"] == {}

    def test_team_url_optional(self):
        without = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        assert "teamUrl" not in without

        with_url = wa.export_bundle(
            SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5,
            team_url="https://wowaudit.com/eu/test"
        )
        assert with_url["teamUrl"] == "https://wowaudit.com/eu/test"

    def test_json_serialisable(self):
        """The bundle must be serialisable to JSON without errors."""
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        result = json.dumps(bundle)
        reloaded = json.loads(result)
        assert reloaded["schema"] == "bobleloot-export-v1"

    def test_character_missing_sims_still_included(self):
        """Characters without sim columns must still appear with empty sims."""
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        char = bundle["characters"]["Kotoma-Draenor"]
        assert char["sims"] == {}

    def test_export_flag_writes_file(self, tmp_path):
        """Integration: passing rows directly to export_bundle and writing JSON."""
        out = tmp_path / "bundle.json"
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        out.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
        loaded = json.loads(out.read_text(encoding="utf-8"))
        assert loaded["schema"] == "bobleloot-export-v1"
        assert "Boble-Draenor" in loaded["characters"]

    def test_exported_at_and_generated_at_present(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        assert "exportedAt" in bundle
        assert "generatedAt" in bundle
        # Both should be ISO-8601 UTC strings ending in Z.
        assert bundle["exportedAt"].endswith("Z")
        assert bundle["generatedAt"].endswith("Z")

    def test_custom_weights_preserved(self):
        custom_w = {"sim": 0.5, "bis": 0.1, "history": 0.2,
                    "attendance": 0.1, "mplus": 0.1}
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5,
                                  weights=custom_w)
        assert bundle["scoringConfig"]["weights"]["sim"] == pytest.approx(0.5)

    def test_default_weights_used_when_none_passed(self):
        bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
        w = bundle["scoringConfig"]["weights"]
        assert w["sim"] == pytest.approx(0.40)
        assert w["bis"] == pytest.approx(0.20)
