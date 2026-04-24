"""pytest entry point for scoring regression tests (item 4.6).

Imports ScoreEngine and LuaDataParser from tools/test_scoring.py.
All assertions mirror the documented invariants in Scoring.lua.
"""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Import test_scoring as a module.
# ---------------------------------------------------------------------------
TOOLS_DIR = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location(
    "test_scoring_module", TOOLS_DIR / "test_scoring.py"
)
ts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ts)

FIXTURE_PATH = TOOLS_DIR / "tests" / "fixtures" / "BobleLoot_Data_sample.lua"


@pytest.fixture(scope="module")
def data():
    return ts.load_fixture()


@pytest.fixture(scope="module")
def engine(data):
    return ts.ScoreEngine(data)


# ---------------------------------------------------------------------------
# Lua parser tests
# ---------------------------------------------------------------------------

def test_parser_loads_fixture(data):
    """Fixture parses without error and contains expected top-level keys."""
    assert "characters" in data
    assert "mplusCap" in data
    assert "historyCap" in data


def test_parser_character_names(data):
    """All expected characters are present in the parsed data."""
    chars = data["characters"]
    expected = {
        "Fullchar-Stormrage", "Nosim-Stormrage", "Zerosim-Stormrage",
        "Allnil-Stormrage", "Trialchar-Stormrage", "Noloot-Stormrage",
    }
    assert expected.issubset(set(chars.keys())), (
        f"Missing characters: {expected - set(chars.keys())}"
    )


def test_parser_score_overrides_parsed(data):
    """scoreOverrides table is parsed correctly."""
    overrides = data.get("scoreOverrides") or {}
    assert 999001 in overrides
    assert overrides[999001] == 95.0


def test_parser_bis_table_parsed(data):
    """bis table for Fullchar-Stormrage is parsed as a dict."""
    char = data["characters"]["Fullchar-Stormrage"]
    assert isinstance(char["bis"], dict)
    assert char["bis"].get(212401) is True


def test_parser_sims_known_parsed(data):
    """simsKnown table is parsed correctly."""
    char = data["characters"]["Fullchar-Stormrage"]
    assert char["simsKnown"][212401] is True


# ---------------------------------------------------------------------------
# Nil-sim gate (Batch 1B invariant)
# ---------------------------------------------------------------------------

def test_nil_sim_excludes_candidate_when_sim_weight_active(engine):
    """Nosim-Stormrage has no sim data; with sim weight > 0, score is None."""
    score, bd = engine.compute(212401, "Nosim-Stormrage")
    assert score is None, (
        f"Expected nil score for no-sim candidate, got {score}"
    )


def test_zero_sim_scores_rather_than_excluded(engine):
    """Zerosim-Stormrage has simsKnown=true and sims[212401] absent (= 0.0).

    The 1B nil-vs-zero fix: this must NOT be treated as nil-sim.
    The candidate must receive a score (possibly low, but not nil).
    """
    score, bd = engine.compute(212401, "Zerosim-Stormrage")
    assert score is not None, (
        "Expected a numeric score for zero-sim candidate (1B regression)"
    )
    assert isinstance(score, float)


# ---------------------------------------------------------------------------
# All-nil-component path
# ---------------------------------------------------------------------------

def test_all_nil_components_returns_nil(engine):
    """Allnil-Stormrage has no computable components; score must be None."""
    score, bd = engine.compute(212401, "Allnil-Stormrage")
    assert score is None


# ---------------------------------------------------------------------------
# scoreOverrides short-circuit (Batch 4A item 4.7)
# ---------------------------------------------------------------------------

def test_score_override_returns_fixed_score(engine):
    """When scoreOverrides contains an itemID, the override score is returned."""
    # Fixture: scoreOverrides[999001] = 95.0
    score, bd = engine.compute(999001, "Fullchar-Stormrage")
    assert score == 95.0
    assert bd == {"_override": True}


def test_score_override_does_not_affect_other_items(engine):
    """Items not in scoreOverrides are computed normally."""
    # 212401 is not in scoreOverrides; Fullchar has all data components.
    score, bd = engine.compute(212401, "Fullchar-Stormrage")
    assert score is not None
    assert "_override" not in (bd or {})


# ---------------------------------------------------------------------------
# Per-role history multiplier (Batch 2A)
# ---------------------------------------------------------------------------

def test_trial_role_reduces_history_component():
    """Trialchar (trial role) has lower history influence than an equivalent raider."""
    data = ts.load_fixture()

    # Profile with default trial weight = 0.5
    profile_trial_05 = {
        "weights": {"sim": 0, "bis": 0, "history": 50, "attendance": 25, "mplus": 25},
        "partialBiSValue": 0.25,
        "roleHistoryWeights": {"raider": 1.0, "trial": 0.5, "bench": 0.5},
        "overrideCaps": False,
    }
    # Give Trialchar and a synthetic raider the same data.
    data["characters"]["SyntheticRaider-Stormrage"] = {
        "attendance": 60.0,
        "mplusDungeons": 20,
        "role": "raider",
        "itemsReceived": 0,
    }

    engine_trial = ts.ScoreEngine(data, profile_trial_05)
    score_trial,  _ = engine_trial.compute(212401, "Trialchar-Stormrage")
    score_raider, _ = engine_trial.compute(212401, "SyntheticRaider-Stormrage")

    assert score_trial is not None
    assert score_raider is not None
    # A trial with 0 items received (hist=1.0) pulled toward midpoint:
    # hist_val = 0.5 + (1.0 - 0.5) * 0.5 = 0.75
    # A raider with 0 items received stays at hist_val = 1.0
    # So raider score > trial score when history weight > 0.
    assert score_raider > score_trial, (
        f"Expected raider ({score_raider:.2f}) > trial ({score_trial:.2f})"
    )


def test_trial_weight_zero_pulls_to_midpoint():
    """With trial weight = 0, history contribution = 0.5 (midpoint)."""
    data = ts.load_fixture()
    profile_trial_0 = {
        "weights": {"sim": 0, "bis": 0, "history": 100, "attendance": 0, "mplus": 0},
        "partialBiSValue": 0.25,
        "roleHistoryWeights": {"raider": 1.0, "trial": 0.0, "bench": 0.5},
        "overrideCaps": False,
    }
    engine_t0 = ts.ScoreEngine(data, profile_trial_0)
    # Trialchar: itemsReceived=0 -> hist_raw=1.0 -> after mult=0: 0.5+0.5*0=0.5
    score, bd = engine_t0.compute(212401, "Trialchar-Stormrage")
    assert score is not None
    assert abs(score - 50.0) < 0.1, (
        f"Expected ~50.0 for trial weight=0, got {score:.2f}"
    )


# ---------------------------------------------------------------------------
# Zero history cap
# ---------------------------------------------------------------------------

def test_zero_items_received_with_soft_floor():
    """With itemsReceived=0 and softFloor=6, history component should be 1.0."""
    data = ts.load_fixture()
    engine = ts.ScoreEngine(data)
    char = data["characters"]["Noloot-Stormrage"]
    assert char["itemsReceived"] == 0
    hist_val, _ = ts._history_component(char, soft_floor=6, history_reference=None)
    # 1 - (0 / 6) = 1.0
    assert hist_val == 1.0


def test_history_reference_overrides_soft_floor():
    """historyReference > softFloor is used as denominator."""
    char = {"itemsReceived": 3}
    hist_val, _ = ts._history_component(char, soft_floor=4, history_reference=10.0)
    # denom = max(4, 10) = 10; val = 1 - 3/10 = 0.7
    assert abs(hist_val - 0.7) < 1e-9


# ---------------------------------------------------------------------------
# Spec-aware sim path (Batch 2A)
# ---------------------------------------------------------------------------

def test_fullchar_has_correct_sim_value(data):
    """Fullchar-Stormrage's sim for 212401 is 3.5 (from fixture)."""
    char = data["characters"]["Fullchar-Stormrage"]
    assert char["sims"][212401] == 3.5
    assert char["simsKnown"][212401] is True


# ---------------------------------------------------------------------------
# Full integration: Fullchar scores above zero on item 212401
# ---------------------------------------------------------------------------

def test_fullchar_receives_positive_score(engine):
    """Fullchar-Stormrage with all components present receives a positive score."""
    score, bd = engine.compute(212401, "Fullchar-Stormrage")
    assert score is not None
    assert score > 0


def test_score_is_bounded_0_to_100(engine):
    """All computable scores are in the range [0, 100]."""
    data = ts.load_fixture()
    engine_all = ts.ScoreEngine(data)
    chars = data.get("characters") or {}
    for name in chars:
        score, _ = engine_all.compute(212401, name)
        if score is not None:
            assert 0 <= score <= 100, (
                f"Score out of range for {name}: {score}"
            )
