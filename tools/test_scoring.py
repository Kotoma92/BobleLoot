#!/usr/bin/env python3
"""tools/test_scoring.py — Python port of Scoring.lua for CI regression.

This module:
1. Provides a regex-based parser for BobleLoot_Data.lua that extracts
   the data structures used by Scoring:Compute.
2. Provides a Python reimplementation of Scoring:Compute that mirrors
   the Lua formula exactly, including all Batch 1B, 2A, and 4.5 / 4.7
   additions.
3. Is imported by tools/tests/test_scoring.py (the pytest entry point).

Scope: this is a REGRESSION tool, not a Lua interpreter. It mirrors the
formula. When Scoring.lua changes, update this file to match.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Lua regex parser
# ---------------------------------------------------------------------------

_NUM_RE = re.compile(r"-?\d+(?:\.\d+)?")
_STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
_BOOL_RE = re.compile(r"\b(true|false)\b")


def _parse_number(s: str) -> float | int:
    """Parse a Lua number literal."""
    try:
        if "." in s:
            return float(s)
        return int(s)
    except ValueError:
        return float(s)


class LuaDataParser:
    """Minimal regex-based parser for the BobleLoot_Data.lua fixture format.

    Only the subset of Lua table syntax used in the fixture is supported:
      - String keys: ["Name-Realm"] = { ... }
      - Integer bracket keys: [212401] = true / value
      - Simple assignments: key = value
      - Nested tables with balanced braces

    Args:
        source: The full text of the Lua file to parse.
    """

    def __init__(self, source: str) -> None:
        self._source = source

    def parse(self) -> dict:
        """Return the ``BobleLoot_Data`` table as a Python dict.

        Returns:
            Parsed dict. Missing keys are absent (not ``None``).

        Raises:
            ValueError: If the source does not contain ``BobleLoot_Data = {``.
        """
        match = re.search(
            r"BobleLoot_Data\s*=\s*\{", self._source
        )
        if not match:
            raise ValueError(
                "Source does not contain 'BobleLoot_Data = {'"
            )
        start = match.end()
        body, _ = self._extract_table(self._source, start)
        return body

    def _extract_table(self, text: str, pos: int) -> tuple[dict, int]:
        """Extract a balanced ``{ ... }`` table starting at ``pos``.

        Returns:
            (parsed_dict, end_position_after_closing_brace)
        """
        result: dict = {}
        depth = 1
        i = pos

        while i < len(text) and depth > 0:
            # Skip whitespace and Lua line comments before each token.
            i = _skip_ws(text, i)
            if i >= len(text) or depth <= 0:
                break
            c = text[i]

            # String key: ["something"] = value
            if text[i:i+2] == '["':
                end = text.index('"]', i + 2)
                key = text[i + 2 : end]
                i = end + 2
                # Skip whitespace and '='
                i = _skip_ws_eq(text, i)
                val, i = self._parse_value(text, i)
                result[key] = val

            # Integer bracket key: [12345] = value
            elif c == "[" and i + 1 < len(text) and text[i + 1].isdigit():
                end = text.index("]", i + 1)
                key = int(text[i + 1 : end])
                i = end + 1
                i = _skip_ws_eq(text, i)
                val, i = self._parse_value(text, i)
                result[key] = val

            # Identifier key: somekey = value
            elif c.isalpha() or c == "_":
                m = re.match(r"[A-Za-z_]\w*", text[i:])
                if m:
                    key = m.group()
                    i += m.end()
                    i = _skip_ws_eq(text, i)
                    val, i = self._parse_value(text, i)
                    result[key] = val
                else:
                    i += 1

            elif c == "}":
                depth -= 1
                i += 1

            elif c == "{":
                depth += 1
                i += 1

            else:
                i += 1

        return result, i

    def _parse_value(self, text: str, pos: int) -> tuple[Any, int]:
        """Parse a Lua value starting at pos.

        Handles: numbers, strings, booleans, nested tables (``{ }``).
        """
        i = _skip_ws(text, pos)
        c = text[i] if i < len(text) else ""

        if c == "{":
            sub, end = self._extract_table(text, i + 1)
            return sub, end

        if c == '"':
            m = _STR_RE.match(text, i)
            if m:
                return m.group(1), m.end()

        m = _NUM_RE.match(text, i)
        if m:
            return _parse_number(m.group()), m.end()

        m = _BOOL_RE.match(text, i)
        if m:
            return m.group() == "true", m.end()

        # Skip to next comma, newline, or closing brace.
        end = i
        while end < len(text) and text[end] not in (",", "\n", "}"):
            end += 1
        return text[i:end].strip(), end


def _skip_ws(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    # Skip Lua comments.
    if i < len(text) and text[i:i+2] == "--":
        end = text.find("\n", i)
        return _skip_ws(text, end + 1 if end != -1 else len(text))
    return i


def _skip_ws_eq(text: str, i: int) -> int:
    i = _skip_ws(text, i)
    if i < len(text) and text[i] == "=":
        i += 1
    return _skip_ws(text, i)


def load_lua_data(path: Path) -> dict:
    """Parse a ``BobleLoot_Data.lua`` file and return the data dict.

    Args:
        path: Absolute path to the Lua file.

    Returns:
        Parsed BobleLoot_Data dict.

    Raises:
        FileNotFoundError: If ``path`` does not exist.
        ValueError: If the file cannot be parsed.
    """
    source = path.read_text(encoding="utf-8")
    return LuaDataParser(source).parse()


# ---------------------------------------------------------------------------
# Python port of Scoring:Compute (mirrors Scoring.lua as of Batch 2A + 4A)
# ---------------------------------------------------------------------------

def _clamp01(x: float) -> float:
    return max(0.0, min(1.0, x))


def _sim_component(
    char: dict, item_id: int, sim_reference: float | None
) -> tuple[float | None, float | None]:
    """Port of simComponent(char, itemID, simReference).

    Batch 1B invariant: simsKnown present + truthy = result known, even
    if sims[itemID] is absent (treat as 0.0).
    """
    sims = char.get("sims")
    if sims is None:
        return None, None
    sims_known = char.get("simsKnown") or {}
    known = bool(sims_known.get(item_id))
    pct = sims.get(item_id)
    if pct is None and not known:
        return None, None
    pct = pct if pct is not None else 0.0
    if sim_reference and sim_reference > 0:
        return _clamp01(pct / sim_reference), pct
    return pct / 100.0, pct


def _bis_component(
    char: dict, item_id: int, partial: float
) -> tuple[float, bool | None]:
    """Port of bisComponent(char, itemID, partial)."""
    bis = char.get("bis")
    if not bis:
        return partial, None
    if bis.get(item_id):
        return 1.0, True
    return partial, False


def _history_component(
    char: dict, soft_floor: int, history_reference: float | None
) -> tuple[float | None, int | None]:
    """Port of historyComponent(char, softFloor, historyReference).

    Batch 3A hybrid model: denominator = max(softFloor, historyReference).
    """
    items_received = char.get("itemsReceived")
    if items_received is None:
        return None, None
    denom = soft_floor or 0
    if history_reference and history_reference > denom:
        denom = history_reference
    if denom <= 0:
        return 1.0, items_received
    return _clamp01(1.0 - (items_received / denom)), items_received


def _attendance_component(
    char: dict,
) -> tuple[float | None, float | None]:
    """Port of attendanceComponent(char)."""
    att = char.get("attendance")
    if att is None:
        return None, None
    return _clamp01(att / 100.0), att


def _mplus_component(
    char: dict, mplus_cap: int
) -> tuple[float | None, int | None]:
    """Port of mplusComponent(char, mplusCap)."""
    v = char.get("mplusDungeons") or char.get("mplusScore")
    if v is None:
        return None, None
    if mplus_cap <= 0:
        return 0.0, v
    return _clamp01(v / mplus_cap), v


class ScoreEngine:
    """Python port of Scoring:Compute with configurable profile and data.

    Args:
        data: Parsed BobleLoot_Data dict (from ``load_lua_data``).
        profile: AceDB profile dict. Defaults reproduce the in-game
            defaults from Core.lua Batch 2A.
    """

    _DEFAULT_WEIGHTS = {
        "sim": 30,
        "bis": 20,
        "history": 20,
        "attendance": 15,
        "mplus": 15,
    }
    _DEFAULT_ROLE_HISTORY_WEIGHTS = {
        "raider": 1.0,
        "trial":  0.5,
        "bench":  0.5,
    }

    def __init__(
        self,
        data: dict,
        profile: dict | None = None,
    ) -> None:
        self._data = data
        self._profile = profile or {
            "weights": self._DEFAULT_WEIGHTS.copy(),
            "partialBiSValue": 0.25,
            "roleHistoryWeights": self._DEFAULT_ROLE_HISTORY_WEIGHTS.copy(),
            "overrideCaps": False,
        }

    def compute(
        self,
        item_id: int,
        candidate_name: str,
        opts: dict | None = None,
    ) -> tuple[float | None, dict | None]:
        """Compute the score for (item_id, candidate_name).

        Returns:
            ``(score, breakdown)`` or ``(None, None)`` when no data.
            Mirrors the Lua return contract.
        """
        data = self._data
        profile = self._profile
        chars = data.get("characters") or {}
        char = chars.get(candidate_name)
        if not char:
            return None, None

        # item 4.7: scoreOverrides short-circuit.
        overrides = data.get("scoreOverrides") or {}
        if item_id in overrides:
            override_score = overrides[item_id]
            if isinstance(override_score, (int, float)):
                return float(override_score), {"_override": True}

        opts = opts or {}
        sim_reference     = opts.get("simReference")
        history_reference = opts.get("historyReference")

        mplus_cap   = data.get("mplusCap") or 40
        history_cap = data.get("historyCap") or 5

        if profile.get("overrideCaps"):
            mplus_cap   = profile.get("mplusCap") or mplus_cap
            history_cap = profile.get("historyCap") or history_cap

        sim_val,  sim_raw  = _sim_component(char, item_id, sim_reference)
        bis_val,  bis_raw  = _bis_component(
            char, item_id, profile.get("partialBiSValue", 0.25)
        )
        hist_val, hist_raw = _history_component(
            char, history_cap, history_reference
        )
        att_val,  att_raw  = _attendance_component(char)
        mp_val,   mp_raw   = _mplus_component(char, mplus_cap)

        weights: dict = profile.get("weights") or {}

        # Sim-weight gate (Batch 1B): if sim weight is active and no sim
        # data, exclude this candidate entirely.
        if (weights.get("sim") or 0) > 0 and sim_val is None:
            return None, None

        # Per-role history multiplier (Batch 2A).
        if hist_val is not None:
            role_weights: dict = profile.get("roleHistoryWeights") or {}
            char_role = char.get("role") or "raider"
            role_mult = role_weights.get(char_role)
            if isinstance(role_mult, (int, float)):
                role_mult = max(0.0, min(2.0, float(role_mult)))
                hist_val = 0.5 + (hist_val - 0.5) * role_mult
                hist_val = _clamp01(hist_val)

        components = {
            "sim":        (sim_val,  sim_raw,  weights.get("sim", 0)),
            "bis":        (bis_val,  bis_raw,  weights.get("bis", 0)),
            "history":    (hist_val, hist_raw, weights.get("history", 0)),
            "attendance": (att_val,  att_raw,  weights.get("attendance", 0)),
            "mplus":      (mp_val,   mp_raw,   weights.get("mplus", 0)),
        }

        total_weight = 0.0
        weighted = 0.0
        breakdown: dict = {}

        for name, (val, raw, w) in components.items():
            if val is not None and w > 0:
                total_weight += w
                weighted     += w * val
                breakdown[name] = {"value": val, "raw": raw, "weight": w}

        if total_weight <= 0:
            return None, None

        score = (weighted / total_weight) * 100.0

        for entry in breakdown.values():
            entry["effectiveWeight"]  = entry["weight"] / total_weight
            entry["contribution"]     = entry["effectiveWeight"] * entry["value"] * 100.0

        return score, breakdown


# ---------------------------------------------------------------------------
# Convenience loader for tests
# ---------------------------------------------------------------------------

FIXTURE_PATH = (
    Path(__file__).resolve().parent / "tests" / "fixtures" / "BobleLoot_Data_sample.lua"
)


def load_fixture() -> dict:
    """Load the standard test fixture."""
    return load_lua_data(FIXTURE_PATH)


if __name__ == "__main__":
    data = load_fixture()
    engine = ScoreEngine(data)
    print("Loaded characters:", list((data.get("characters") or {}).keys()))
    # Quick sanity check:
    score, bd = engine.compute(212401, "Fullchar-Stormrage")
    print(f"Fullchar-Stormrage / 212401 => score={score:.2f}")
    score2, bd2 = engine.compute(999001, "Fullchar-Stormrage")
    print(f"Fullchar-Stormrage / 999001 (override) => score={score2:.2f}")
