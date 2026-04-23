#!/usr/bin/env python3
"""wowaudit.py — produce the Lua data file consumed by the Boble Loot addon.

Two modes, auto-selected:

  API fetch (default):
      py tools/wowaudit.py [--api-key ...]

      Pulls the team roster live from https://wowaudit.com. The API key
      can come from --api-key, the WOWAUDIT_API_KEY env var, or a `.env`
      file at the repo root (see .env.example).

  Manual convert:
      py tools/wowaudit.py --wowaudit path/to/export.csv --bis bis.json

      Reads a CSV / XLSX export from wowaudit's "Character data" sheet
      (required columns: character, mplus_dungeons, attendance,
      items_received, plus per-item sim_<itemID> columns) plus a JSON
      file mapping "Name-Realm" -> [BiS itemIDs].

In both modes the output is written to ``../Data/BobleLoot_Data.lua``
relative to this script (i.e. the addon's own Data folder), unless
``--out`` is given.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

# --------------------------------------------------------------------------
# .env loader (zero-dependency)
# --------------------------------------------------------------------------

def _load_dotenv() -> None:
    """Load KEY=VALUE pairs from the nearest ``.env`` into os.environ
    without overwriting existing variables."""
    for d in (Path(__file__).resolve().parent, *Path(__file__).resolve().parents):
        candidate = d / ".env"
        if not candidate.is_file():
            continue
        try:
            text = candidate.read_text(encoding="utf-8")
        except OSError:
            return
        for raw in text.splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value
        return


_load_dotenv()

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------

DEFAULT_OUT = Path(__file__).resolve().parent.parent / "Data" / "BobleLoot_Data.lua"
REQUIRED_COLS = {"character", "mplus_dungeons", "attendance"}

API_BASE = "https://wowaudit.com/v1"

# --------------------------------------------------------------------------
# CSV / XLSX reading
# --------------------------------------------------------------------------

def _read_table(path: Path) -> list[dict]:
    """Read a CSV or XLSX file into a list of dicts.

    For XLSX files, requires openpyxl (sys.exit with install hint if absent —
    this is an unrecoverable user-input error, not a network partial failure,
    so sys.exit is acceptable here per Batch 1A design decision).
    """
    suffix = path.suffix.lower()
    if suffix in {".xlsx", ".xls"}:
        try:
            from openpyxl import load_workbook  # type: ignore
        except ImportError:
            sys.exit("openpyxl is required to read XLSX inputs (pip install openpyxl)")
        wb = load_workbook(path, data_only=True, read_only=True)
        ws = wb.active
        rows = list(ws.iter_rows(values_only=True))
        if not rows:
            return []
        header = [str(h).strip() if h is not None else "" for h in rows[0]]
        return [
            {header[i]: row[i] for i in range(len(header)) if header[i]}
            for row in rows[1:]
            if any(c is not None for c in row)
        ]
    with path.open(newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def _to_float(v, default=0.0) -> float:
    if v is None or v == "":
        return default
    try:
        return float(str(v).replace("%", "").replace(",", ""))
    except ValueError:
        return default


def _to_int(v, default=0) -> int:
    return int(round(_to_float(v, default)))


def _lua_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')

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

# --------------------------------------------------------------------------
# Lua emitter
# --------------------------------------------------------------------------

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
        sim_known_ids: list[int] = []
        for col in sim_cols:
            raw = row.get(col)
            if raw is None or raw == "":
                continue
            val = _to_float(raw, default=None)
            if val is None:
                continue
            item_id = int(col[4:])
            # simsKnown records every item the sim engine produced a result
            # for, even a 0% result. sims only carries the numeric value when
            # non-zero (file-size optimisation); Scoring.lua reads simsKnown
            # to tell "no data" from "data, value is 0".
            sim_known_ids.append(item_id)
            if val != 0.0:
                sim_pairs.append(f"[{item_id}] = {val}")
        if sim_pairs:
            out.append(f"            sims = {{ {', '.join(sim_pairs)} }},")
        else:
            out.append("            sims = {},")
        if sim_known_ids:
            known_pairs = ", ".join(f"[{i}] = true" for i in sim_known_ids)
            out.append(f"            simsKnown = {{ {known_pairs} }},")
        else:
            out.append("            simsKnown = {},")

        out.append("        },")

    out.append("    },")
    out.append("}")
    out.append("")
    return "\n".join(out)

# --------------------------------------------------------------------------
# API fetch
# --------------------------------------------------------------------------

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


def _full_name(name: str | None, realm: str | None) -> str | None:
    if not name:
        return None
    if realm:
        # Strip spaces from realm to match WoW's "Name-Realm" format.
        realm_clean = "".join(realm.split())
        return f"{name}-{realm_clean}"
    return name


def _best_wishlist_score(item: dict) -> float:
    """Pick the highest sim percentage across all specs/wishes for an item.

    wowaudit's API returns `score_by_spec[spec].percentage` and
    `wishes[*].percentage` as percent values already (e.g. 2.9 means a
    2.9% upgrade, 0.0744 means a 0.0744% sidegrade). We pass them
    through unchanged.
    """
    best = 0.0
    sbs = item.get("score_by_spec")
    if isinstance(sbs, dict):
        for spec_data in sbs.values():
            if isinstance(spec_data, dict):
                p = spec_data.get("percentage")
                if isinstance(p, (int, float)) and p > best:
                    best = p
    for w in item.get("wishes") or []:
        if isinstance(w, dict):
            p = w.get("percentage")
            if isinstance(p, (int, float)) and p > best:
                best = p
    return float(best)


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
                        # First sighting wins; later sightings only overwrite
                        # when strictly greater. This ensures a 0.0 result is
                        # recorded (so simsKnown picks it up downstream)
                        # instead of being silently dropped by `score > prev`
                        # when prev defaulted to 0.0.
                        if iid not in sims_by_id[cid] or score > sims_by_id[cid][iid]:
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


def fetch_team_url(api_key: str) -> str | None:
    try:
        team = http_get_json("/team", api_key)
        if isinstance(team, dict):
            return team.get("url")
    except Exception:
        pass
    return None


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

    Uses a two-step approach to handle nested braces correctly: first find
    all character name positions, then find all bis = {...} blocks, and
    associate each bis block with the nearest preceding character name.
    """
    import re
    result: dict[str, set[int]] = {}
    char_positions = [
        (m.start(), m.group(1))
        for m in re.finditer(r'\["([^"]+)"\]\s*=\s*\{', lua_text)
    ]
    bis_blocks = [
        (m.start(), m.group(1))
        for m in re.finditer(r'bis\s*=\s*\{([^}]*)\}', lua_text)
    ]
    for bis_pos, bis_content in bis_blocks:
        preceding = [(pos, name) for pos, name in char_positions if pos < bis_pos]
        if preceding:
            _, name = max(preceding, key=lambda x: x[0])
            ids = set(int(x) for x in re.findall(r'\[(\d+)\]\s*=\s*true', bis_content))
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

# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    # Mode selection (auto): if --wowaudit is given, convert mode; else API.
    ap.add_argument("--wowaudit", type=Path, default=None,
                    help="CSV/XLSX export. Switches to convert mode (no API call).")
    ap.add_argument("--bis",      type=Path, default=None,
                    help="JSON file: { \"Name-Realm\": [itemID, ...] }. "
                         "Required in convert mode; optional in API mode.")
    # API mode
    ap.add_argument("--api-key", default=os.environ.get("WOWAUDIT_API_KEY"),
                    help="WoWAudit team API key (or WOWAUDIT_API_KEY env var, or .env file).")
    ap.add_argument("--dump-raw", type=Path, default=None,
                    help="Directory to also write raw API responses into (debugging).")
    ap.add_argument("--use-cache", action="store_true",
                    help="Replay the last successful API responses from "
                         "tools/.cache/ instead of hitting the network.")
    # Output
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT,
                    help=f"Output .lua path (default: {DEFAULT_OUT}).")
    ap.add_argument("--sim-cap",     type=float, default=5.0)
    ap.add_argument("--mplus-cap",   type=int,   default=None,
                    help="Override M+ dungeons cap. Default: 10 per week of "
                         "the current season (so it grows over the season).")
    ap.add_argument("--mplus-cap-per-week", type=int, default=10,
                    help="Per-week increment for the auto M+ cap (default 10).")
    ap.add_argument("--history-cap", type=int,   default=5)
    args = ap.parse_args()

    weeks_in_season = 1
    team_url = None
    fetch_warnings: list[str] = []
    if args.wowaudit is not None:
        # Convert mode.
        if args.bis is None:
            sys.exit("--bis is required when using --wowaudit.")
        rows = _read_table(args.wowaudit)
        with args.bis.open(encoding="utf-8") as f:
            bis_raw = json.load(f)
        bis = {k: [int(x) for x in v] for k, v in bis_raw.items()}
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
            # wowaudit's API doesn't expose a BiS flag; supply --bis to populate.
            bis = {}

    if args.mplus_cap is not None:
        mplus_cap = args.mplus_cap
    else:
        mplus_cap = max(args.mplus_cap_per_week,
                        args.mplus_cap_per_week * max(weeks_in_season, 1))

    try:
        lua = build_lua(
            rows, bis, args.sim_cap, mplus_cap, args.history_cap,
            team_url, fetch_warnings if not args.wowaudit else None,
        )
    except ValueError as exc:
        sys.exit(str(exc))
    report = _build_run_report(
        rows, bis, mplus_cap, fetch_warnings if not args.wowaudit else [],
        args.out if args.out.is_file() else None,
    )
    print(report)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(lua, encoding="utf-8")
    print(f"Wrote {args.out}: {len(rows)} characters, "
          f"{sum(len(v) for v in bis.values())} BiS entries. "
          f"M+ cap = {mplus_cap} ({weeks_in_season} week(s) into season).")


if __name__ == "__main__":
    main()
