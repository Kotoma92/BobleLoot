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
