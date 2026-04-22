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
