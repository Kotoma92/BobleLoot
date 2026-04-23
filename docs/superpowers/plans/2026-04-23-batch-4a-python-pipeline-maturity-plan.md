# Batch 4A — Python Pipeline Maturity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the Python data pipeline for year-two longevity by introducing a YAML tier-config that supersedes the Batch 2A JSON presets, adding exponential backoff against WoWAudit rate limits, shipping a character-rename sidecar for realm transfer migration, building a pytest-based scoring regression suite, and emitting a `scoreOverrides` table for per-item score exceptions.

**Architecture:** A new top-level `tools/tier-config.yaml` maps tier names to all five tuning knobs _plus_ a `bisPath` reference into the Batch 3A versioned BiS directory; `wowaudit.py`'s `_load_tier_preset()` is replaced by `_load_tier_config()` that reads this YAML and returns the same dict shape — all existing callers remain unaffected. A reusable `@retry_with_backoff` decorator wraps `http_get_json` with 5 s / 30 s / cached-fallback stages and tracks `X-RateLimit-Remaining` when present. A `tools/renames.json` sidecar maps `"Old-Realm"` to `"New-Realm"`; the Python build step applies renames to all three key spaces (roster rows, BiS keys, loot-history keys) before emitting the Lua file, and also writes a `renames` table into the Lua file so `LootHistory:Apply` can resolve stale RC keys at runtime. `tools/test_scoring.py` contains a regex-based `BobleLoot_Data.lua` parser and a Python port of `Scoring:Compute` that the pytest harness exercises against a fixture data file. A `tools/score-overrides.json` hand-curated sidecar is read by `wowaudit.py` and emitted verbatim as `scoreOverrides = { [itemID] = float }` in the Lua file; `Scoring:Compute` checks this table at the top of the function and returns early when a match is found.

**Tech Stack:** Python 3.11+, PyYAML (new dependency), pytest (existing), jsonschema (existing), Lua (WoW 10.x) for two small additive consumption changes

**Roadmap items covered:**

> **4.1 `[Data]` Multi-tier BiS management**
> `--tier-config` YAML mapping tier names to ilvl floors, mplus caps,
> history windows, and BiS file paths. Tier-1 BiS kept read-only in
> Settings so historical score displays remain accurate even after
> Tier-2 is live.

> **4.4 `[Data]` Rate limiting + exponential backoff**
> `http_get_json` currently has no retry. The weekly CI run will hit
> WoWAudit's rate limits over a long season (the historical-data loop
> fetches one request per raid week). Add exponential backoff:
> 5s / 30s / cached-fallback. Track `X-RateLimit-Remaining` if present.

> **4.5 `[Data]` Character rename / realm transfer migration**
> After a year, some characters transfer realms. Both `BobleLootSyncDB`
> and `RCLootCouncilLootDB` will have stale `Name-OldRealm` keys. Ship
> a `renames.json` sidecar (`bis/` neighbour) mapping
> `"Old-Realm": "New-Realm"`. The build step applies renames before
> emitting; `LootHistory:Apply` checks `BobleLootDB.profile.renames`
> before the name lookup.

> **4.6 `[Data]` Automated scoring regression tests in CI**
> Add `tools/test_scoring.py`: reads a sample `BobleLoot_Data.lua` via a
> regex-based parser, runs the scoring formula in Python, asserts
> expected outputs. Exercises nil-sim, zero-history-cap, all-nil-component,
> and the 1.2 nil-vs-zero fix. Runs in CI before every release.

> **4.7 `[Data]` `scoreOverrides` table in `BobleLoot_Data.lua`**
> For edge-case items (cosmetic mounts, legendary memories, high-variance
> trinkets), the Python tool writes a `scoreOverrides = { [itemID] = float }`
> table. `Scoring:Compute` checks this before computing. No in-game
> editor; maintenance is in the same workflow as the BiS files.

**Dependencies:** Batches 1, 2A, 3A all merged. Specifically:
- Batch 1A: `http_get_json`, `_read_cache`, `_write_cache`, `FetchResult` dataclass, `fetch_warnings` list, `build_lua` accepting `fetch_warnings`, 54 pytest cases in `tools/tests/test_wowaudit.py`.
- Batch 2A: `_load_tier_preset()`, `TIERS_DIR`, `tools/tiers/tww-s3.json`, `mainspec` / `role` fields in rows and Lua emission, `_ROLE_MAP`, spec-aware sim path.
- Batch 3A: `_load_bis_path()` directory merge, `_derive_bis_from_wishlists()`, versioned `bis/<tier>/` directory, `.github/workflows/refresh.yml` lint job running `pytest tools/`.

---

## Batch 4B / 4C / 4D / 4E coordination note

- **4B (catalyst + export/import):** `wowaudit.py --export` writes a JSON dataset bundle. The `scoreOverrides` table (4.7) should be included in that bundle. The 4A plan does not touch `--export` — leave a `# TODO(4B): include scoreOverrides in export bundle` comment in the `scoreOverrides` emission block so the 4B worker sees it.
- **4C (RC version-compat):** Lua-only; no overlap with 4A.
- **4D (UI polish):** Lua-only; no overlap with 4A.
- **4E (empty/error states):** Lua-only; no overlap with 4A.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tools/tier-config.yaml` | **Create** | Top-level YAML replacing per-file JSON presets; one document with all tier entries |
| `tools/wowaudit.py` | **Modify** | `_load_tier_config()` (replaces `_load_tier_preset()`); `@retry_with_backoff` decorator on `http_get_json`; rename-map application; `scoreOverrides` emission |
| `tools/renames.json` | **Create** | `{"Old-Realm": "New-Realm"}` sidecar; hand-curated; initially empty `{}` |
| `tools/score-overrides.json` | **Create** | `{"212401": 95.0}` sidecar; hand-curated; initially empty `{}` |
| `tools/test_scoring.py` | **Create** | Lua parser + Python port of `Scoring:Compute`; fixture-driven regression assertions |
| `tools/tests/test_wowaudit.py` | **Modify** | New test classes for backoff, renames, scoreOverrides emission, tier-config YAML |
| `tools/tests/test_scoring.py` | **Create** | pytest entry point that imports `tools/test_scoring.py` and runs assertions |
| `tools/tests/fixtures/BobleLoot_Data_sample.lua` | **Create** | Minimal Lua data file exercising all scoring paths (nil-sim, zero-sim, nil-history, zero-history-cap, all-nil) |
| `.github/workflows/refresh.yml` | **Modify** | Add `pytest tools/tests/test_scoring.py` step to lint job |
| `Scoring.lua` | **Modify** | Add `scoreOverrides` short-circuit at the top of `Scoring:Compute` |
| `LootHistory.lua` | **Modify** | Apply `BobleLootDB.profile.renames[name]` before history lookup in `LH:Apply` |

### BiS retention policy (4.1)

All `bis/<tier>/` directories are **retained indefinitely**. When a new tier launches, the raid leader adds a new `bis/<tier>/` subdirectory and updates `tier-config.yaml` to add the new tier entry pointing at it. The old tier's `bisPath` in `tier-config.yaml` still resolves correctly because the directory was never deleted. This lets the Python tool regenerate a historically-accurate Lua file for any past tier by passing `--tier <old-tier>`.

**Never run `rm -rf bis/<tier>/` between tiers.** This is documented in `bis/README.md` (Batch 3A) and reinforced here.

---

## Tasks

### Task 1 — Install PyYAML and establish `tools/tier-config.yaml` (4.1, TDD first)

**Files:**
- Create: `tools/tier-config.yaml`
- Modify: `tools/tests/test_wowaudit.py` (new class)
- Modify: `tools/wowaudit.py` — add `_load_tier_config()`, deprecate `_load_tier_preset()`

PyYAML must be available in the CI environment. The `refresh.yml` `pip install` line is extended in Task 10.

#### Sub-task 1.1 — Write `tools/tier-config.yaml`

Create `tools/tier-config.yaml` with the following content. The file is a single YAML mapping; each top-level key is a tier name (normalised lower-case, hyphens OK). All tier keys are optional in each entry; absent keys fall through to CLI defaults exactly as the Batch 2A JSON presets did.

```yaml
# tools/tier-config.yaml
# Multi-tier BobleLoot configuration.
# Used by: py tools/wowaudit.py --tier <name>
#
# Keys per entry (all optional):
#   ilvlFloor   — minimum item level for loot history (int)
#   mplusCap    — season M+ dungeon cap (int)
#   historyDays — rolling loot-history window in days (int)
#   softFloor   — history denominator soft floor (int)
#   bisPath     — path to BiS directory or file, relative to repo root (str | null)
#
# BiS retention: NEVER delete old tier directories. Each tier's bisPath
# must remain readable so that --tier <old-tier> can reproduce a
# historically-accurate Lua file. Add new tiers; never remove old ones.

tiers:
  tww-s2:
    ilvlFloor:   610
    mplusCap:    130
    historyDays: 84
    softFloor:   5
    bisPath:     null

  tww-s3:
    ilvlFloor:   636
    mplusCap:    160
    historyDays: 84
    softFloor:   6
    bisPath:     "bis/tww-s3"
```

- [ ] **1.1** Create `tools/tier-config.yaml` with the content above.

#### Sub-task 1.2 — Write failing tests

- [ ] **1.2** Add a new test class to `tools/tests/test_wowaudit.py` after the existing tier-preset tests:

```python
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
    import yaml
    doc = yaml.safe_load(TIER_CONFIG_PATH.read_text(encoding="utf-8"))
    assert "tiers" in doc
    assert isinstance(doc["tiers"], dict)
```

- [ ] **1.3** Run to confirm failure (expected — `_load_tier_config` does not exist yet):

```
pytest tools/tests/test_wowaudit.py -k "tier_config" -v
```

Expected: `8 failed` (AttributeError or ImportError).

#### Sub-task 1.4 — Implement `_load_tier_config()`

- [ ] **1.4** In `tools/wowaudit.py`, add `import yaml` to the imports block. Then add `_load_tier_config()` immediately after the existing `_load_tier_preset()` function. `_load_tier_config()` reads `tools/tier-config.yaml`; `_load_tier_preset()` is preserved but marked deprecated via a comment so old callers do not break if any test still references it.

```python
# --------------------------------------------------------------------------
# Tier configuration — YAML (item 4.1, supersedes JSON presets from 2A)
# --------------------------------------------------------------------------

TIER_CONFIG_PATH = Path(__file__).resolve().parent / "tier-config.yaml"


def _load_tier_config(tier_name: str) -> dict:
    """Load a tier entry from ``tools/tier-config.yaml``.

    Args:
        tier_name: Case-insensitive tier key, e.g. ``"TWW-S3"`` or
            ``"tww-s3"``. Hyphens and underscores are both accepted.

    Returns:
        Dict with any subset of keys: ``ilvlFloor``, ``mplusCap``,
        ``historyDays``, ``softFloor``, ``bisPath``.  Missing keys
        in the YAML entry are absent from the returned dict (not ``None``),
        so callers can distinguish "not configured" from "explicitly null".

    Raises:
        SystemExit: If ``tier-config.yaml`` is missing, malformed, or
            the requested tier name does not appear under ``tiers:``.
    """
    try:
        import yaml
    except ImportError:
        sys.exit(
            "PyYAML is required for --tier. Install with: pip install pyyaml"
        )

    if not TIER_CONFIG_PATH.is_file():
        sys.exit(
            f"tools/tier-config.yaml not found at {TIER_CONFIG_PATH}. "
            "Create it or use the per-tier JSON presets in tools/tiers/."
        )

    try:
        doc = yaml.safe_load(TIER_CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception as exc:  # yaml.YAMLError or OSError
        sys.exit(f"Failed to parse tools/tier-config.yaml: {exc}")

    tiers: dict = doc.get("tiers") or {}
    normalised = tier_name.strip().lower()
    if normalised not in tiers:
        available = sorted(tiers.keys())
        sys.exit(
            f"Tier '{tier_name}' not found in tools/tier-config.yaml. "
            f"Available tiers: {', '.join(available) or '(none)'}."
        )

    entry: dict = tiers[normalised] or {}
    return {k: v for k, v in entry.items() if v is not None or k == "bisPath"}
```

- [ ] **1.5** Update `main()` in `tools/wowaudit.py`: in the `--tier` preset-application block (originally using `_load_tier_preset`), replace the call with `_load_tier_config`. Also wire the `bisPath` key: if `tier_preset.get("bisPath")` is a non-null string and `args.bis` was not explicitly provided, set `args.bis = Path(REPO_ROOT / tier_preset["bisPath"])` before the `_load_bis_path` call.

  Add `REPO_ROOT = Path(__file__).resolve().parent.parent` as a module-level constant near the top of `wowaudit.py` (after `DEFAULT_OUT`).

  The `bisPath` wiring inside `main()`:

  ```python
  # After loading tier_preset (now via _load_tier_config):
  preset_bis = tier_preset.get("bisPath")
  if preset_bis and args.bis is None:
      args.bis = REPO_ROOT / preset_bis
  ```

- [ ] **1.6** Re-run tests:

```
pytest tools/tests/test_wowaudit.py -k "tier_config" -v
```

Expected: `8 passed`.

- [ ] **1.7** Run the full suite to confirm no regressions:

```
pytest tools/ -v --tb=short 2>&1 | tail -20
```

- [ ] **1.8** Commit:

```
git add tools/tier-config.yaml tools/wowaudit.py tools/tests/test_wowaudit.py
git commit -m "$(cat <<'EOF'
feat(4.1): add tools/tier-config.yaml and _load_tier_config()

Replaces per-file JSON presets (tools/tiers/) with a single YAML that
maps tier names to all five tuning knobs plus a bisPath reference. The
--tier flag now reads tier-config.yaml via _load_tier_config(); old
_load_tier_preset() is preserved as a deprecated fallback. bisPath in
the YAML automatically sets --bis when not explicitly provided.
Eight new pytest cases cover lookup, case-insensitivity, null bisPath,
unknown-tier exit, and YAML validity.
EOF
)"
```

---

### Task 2 — Exponential backoff retry decorator (4.4, TDD first)

**Files:**
- Modify: `tools/wowaudit.py` — add `retry_with_backoff` decorator and apply to `http_get_json`
- Modify: `tools/tests/test_wowaudit.py` — new test class

The backoff strategy is: attempt 1 → attempt 2 after 5 s → attempt 3 after 30 s → cached fallback (call `_read_cache` for the endpoint path; if present return it; otherwise propagate the last exception). `X-RateLimit-Remaining` is logged as a warning when present and below a threshold (default 5). The decorator is defined once and reused; it is not hardwired to `http_get_json` so unit tests can apply it to a mock.

#### Sub-task 2.1 — Write failing tests

- [ ] **2.1** Add to `tools/tests/test_wowaudit.py`:

```python
# ---------------------------------------------------------------------------
# Task 4A-2 — retry_with_backoff decorator (item 4.4)
# ---------------------------------------------------------------------------

import time
import urllib.error


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

    real_urlopen = wa._urlopen if hasattr(wa, "_urlopen") else None

    def fake_urlopen(req):
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
```

- [ ] **2.2** Run to confirm failure:

```
pytest tools/tests/test_wowaudit.py -k "retry" -v
```

Expected: `6 failed`.

#### Sub-task 2.3 — Implement `retry_with_backoff` and `_sleep`

- [ ] **2.3** In `tools/wowaudit.py`, add the following near the top of the file (below imports, above the `.env` loader section):

```python
import time as _time_module


def _sleep(seconds: float) -> None:
    """Thin wrapper around time.sleep for test-monkeypatching."""
    _time_module.sleep(seconds)


def retry_with_backoff(
    fn,
    delays: list[float],
    cache_key_fn,
    rate_limit_warn_threshold: int = 5,
):
    """Wrap ``fn`` with exponential backoff and a cached-fallback final stage.

    Args:
        fn: The callable to retry. Must accept ``(url_or_path, api_key)``
            and raise ``urllib.error.URLError`` / ``urllib.error.HTTPError``
            on failure.
        delays: Ordered list of sleep durations (seconds) between attempts.
            ``len(delays) + 1`` total attempts are made before the cache
            fallback is tried.
        cache_key_fn: Callable ``(url, api_key) -> str`` that returns the
            cache key to pass to ``_read_cache``. Pass ``None`` to skip
            the cache fallback (exception is propagated instead).
        rate_limit_warn_threshold: Log a warning when
            ``X-RateLimit-Remaining`` (if present in the response headers)
            is at or below this value. Default 5.

    Returns:
        A wrapped callable with the same signature as ``fn``.
    """
    import functools

    @functools.wraps(fn)
    def wrapper(url_or_path, api_key):
        last_exc = None
        for attempt, delay in enumerate(
            [None] + delays  # attempt 0 = no prior delay
        ):
            if delay is not None:
                _sleep(delay)
            try:
                result = fn(url_or_path, api_key)
                return result
            except (urllib.error.URLError, urllib.error.HTTPError) as exc:
                last_exc = exc
                # Log rate-limit warnings immediately.
                remaining = None
                if hasattr(exc, "headers") and exc.headers:
                    remaining = exc.headers.get("X-RateLimit-Remaining")
                if remaining is not None:
                    try:
                        rem_int = int(remaining)
                        if rem_int <= rate_limit_warn_threshold:
                            print(
                                f"[WARN] X-RateLimit-Remaining={rem_int} — "
                                f"approaching WoWAudit rate limit.",
                                file=sys.stderr,
                            )
                    except (ValueError, TypeError):
                        pass
                # Continue to next retry.
        # All retries exhausted — try cache fallback.
        if cache_key_fn is not None:
            cached = _read_cache(cache_key_fn(url_or_path, api_key))
            if cached is not None:
                print(
                    f"[WARN] All retries failed for {url_or_path!r}; "
                    f"using cached response.",
                    file=sys.stderr,
                )
                return cached
        raise last_exc

    return wrapper
```

- [ ] **2.4** Apply `retry_with_backoff` to `http_get_json`. Locate the function definition and wrap it at module level after the function body. The cache key for `http_get_json` is the URL path (first argument):

```python
# After the http_get_json function definition:
http_get_json = retry_with_backoff(
    http_get_json,
    delays=[5, 30],
    cache_key_fn=lambda path, _key: path,
)
```

  The `_read_cache` and `_write_cache` functions are already defined in `wowaudit.py` (Batch 1A). The backoff wrapper calls `_read_cache` with the path string, which matches the cache key that `_write_cache` used when the endpoint last succeeded.

- [ ] **2.5** Re-run backoff tests:

```
pytest tools/tests/test_wowaudit.py -k "retry" -v
```

Expected: `6 passed`.

- [ ] **2.6** Run the full suite:

```
pytest tools/ -v --tb=short 2>&1 | tail -20
```

- [ ] **2.7** Commit:

```
git add tools/wowaudit.py tools/tests/test_wowaudit.py
git commit -m "$(cat <<'EOF'
feat(4.4): add retry_with_backoff decorator with cached-fallback stage

http_get_json now retries up to 3 times (0 s / 5 s / 30 s) before
falling back to _read_cache. X-RateLimit-Remaining headers are logged
as warnings when <= 5. _sleep is a thin wrapper for test monkeypatching.
Six new pytest cases cover first-success, retry-then-succeed, cache
fallback, empty-cache propagation, sleep ordering, and the full
http_get_json integration path.
EOF
)"
```

---

### Task 3 — Character rename / realm transfer sidecar (4.5, TDD first)

**Files:**
- Create: `tools/renames.json`
- Modify: `tools/wowaudit.py` — `_apply_renames()` helper, call in `build_lua` pre-emit
- Modify: `tools/tests/test_wowaudit.py` — new class
- Modify: `LootHistory.lua` — apply renames in `LH:Apply` before history lookup (Lua-side, manual verification)

The renames sidecar has format `{"Old Name-OldRealm": "New Name-NewRealm"}`. It is applied in three places during the Python build step:

1. **Roster rows:** `row["character"]` key.
2. **BiS map keys:** The `bis` dict passed to `build_lua`.
3. **Lua `renames` table:** Written verbatim so `LootHistory:Apply` can resolve stale RC `RCLootCouncilLootDB` keys at runtime.

The renames map is **not** the same as `BobleLootDB.profile.renames`. `BobleLootDB.profile` is an AceDB profile key owned by the Batch 2B migrations framework. `BobleLoot_Data.lua` (a generated data file, not a SavedVar) carries `renames` as a plain data table that the Lua runtime can read. `LootHistory:Apply` reads `data.renames` (from `BobleLoot_Data`) rather than `profile.renames` — this avoids adding a migration and keeps the rename table in the same versioned-data workflow as BiS lists.

#### Sub-task 3.1 — Create `tools/renames.json`

- [ ] **3.1** Create `tools/renames.json`. Initially it is an empty object — future transfers are added by hand:

```json
{
  "_comment": "Character rename / realm transfer map. Format: 'Old Name-OldRealm': 'New Name-NewRealm'. Applied by wowaudit.py before emitting BobleLoot_Data.lua and consumed by LootHistory:Apply at runtime via data.renames.",
  "_example": "Oldchar-OldRealm: Newchar-NewRealm"
}
```

Note: the `_comment` and `_example` keys are metadata strings (not rename entries). `_apply_renames()` ignores values whose keys start with `_`.

#### Sub-task 3.2 — Write failing tests

- [ ] **3.2** Add to `tools/tests/test_wowaudit.py`:

```python
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
```

- [ ] **3.3** Run to confirm failure:

```
pytest tools/tests/test_wowaudit.py -k "renames" -v
```

Expected: `8 failed`.

#### Sub-task 3.4 — Implement `_apply_renames()`

- [ ] **3.4** Add `_apply_renames()` to `tools/wowaudit.py` after the `_load_tier_config()` function:

```python
# --------------------------------------------------------------------------
# Character rename / realm transfer (item 4.5)
# --------------------------------------------------------------------------

def _apply_renames(
    rows: list[dict],
    bis: dict[str, list[int]],
    renames: dict[str, str],
) -> dict:
    """Apply a character-rename map to rows and BiS keys.

    Args:
        rows: Per-character row dicts. ``row["character"]`` is updated
            in-place for any matching old name.
        bis: BiS mapping ``{ "Name-Realm": [itemIDs] }``. Any key that
            appears as an old name in ``renames`` is replaced.
        renames: Mapping ``{ "Old-Realm": "New-Realm" }``. Keys starting
            with ``_`` are treated as metadata and ignored.

    Returns:
        Dict with keys ``"rows"`` (list[dict]) and ``"bis"`` (dict),
        both with renames applied.
    """
    # Filter out metadata keys (e.g. _comment, _example).
    effective: dict[str, str] = {
        old: new
        for old, new in renames.items()
        if not old.startswith("_") and isinstance(new, str)
    }

    if not effective:
        return {"rows": rows, "bis": bis}

    # Rename row character keys.
    for row in rows:
        old_name = row.get("character", "")
        if old_name in effective:
            row["character"] = effective[old_name]

    # Rename BiS keys.
    new_bis: dict[str, list[int]] = {}
    for key, item_ids in bis.items():
        new_key = effective.get(key, key)
        new_bis[new_key] = item_ids

    return {"rows": rows, "bis": new_bis}
```

- [ ] **3.5** Update `build_lua()` to accept an optional `renames: dict[str, str] | None = None` parameter and emit the `renames` table when non-empty. In the header block of `build_lua`, add after the `scoreOverrides` emission (Task 5 adds that; keep a placeholder comment if Task 5 is not yet done):

```python
# Emit renames table for LootHistory:Apply (item 4.5).
effective_renames = {
    k: v for k, v in (renames or {}).items()
    if not k.startswith("_") and isinstance(v, str)
}
if effective_renames:
    out.append("    renames = {")
    for old_name, new_name in sorted(effective_renames.items()):
        out.append(
            f'        ["{_lua_escape(old_name)}"] = '
            f'"{_lua_escape(new_name)}",'
        )
    out.append("    },")
```

- [ ] **3.6** Update `main()` to load `tools/renames.json`, call `_apply_renames()` before `build_lua`, and pass `renames` through to `build_lua`. Insert after `bis = _load_bis_path(...)` (or `bis = result.derived_bis or {}`) and before the `build_lua` call:

```python
# Load rename sidecar (item 4.5).
renames_path = Path(__file__).resolve().parent / "renames.json"
renames: dict[str, str] = {}
if renames_path.is_file():
    try:
        raw_renames = json.loads(renames_path.read_text(encoding="utf-8"))
        renames = {
            k: v for k, v in raw_renames.items()
            if isinstance(k, str) and isinstance(v, str)
            and not k.startswith("_")
        }
    except (json.JSONDecodeError, OSError) as exc:
        print(f"[WARN] Failed to load tools/renames.json: {exc}", file=sys.stderr)

renamed = _apply_renames(rows, bis, renames)
rows = renamed["rows"]
bis  = renamed["bis"]
```

Pass `renames=renames` to `build_lua`.

- [ ] **3.7** Re-run rename tests:

```
pytest tools/tests/test_wowaudit.py -k "renames" -v
```

Expected: `8 passed`.

- [ ] **3.8** Run the full suite:

```
pytest tools/ -v --tb=short 2>&1 | tail -20
```

#### Sub-task 3.9 — Lua-side consumption in `LootHistory:Apply`

This is a small additive change to `LootHistory.lua`. It is manually verified (no automated Lua test runner).

- [ ] **3.9** In `LootHistory.lua`, locate the `LH:Apply` function. At the point where a character name from RC history is looked up in the session candidate list or in `data.characters`, add the rename check. The insertion point is immediately before the line that reads `data.characters[fullName]` (or the equivalent name-resolution call):

```lua
-- item 4.5: apply character renames before lookup so realm-transferred
-- characters are matched by their new name.
local function resolveRename(name, data)
    if data and data.renames then
        return data.renames[name] or name
    end
    return name
end
```

Add this helper at the top of `LootHistory.lua` (module-level, before `LH:Apply`).

Then inside `LH:Apply`, wherever `fullName` is used to index `data.characters`, wrap it:

```lua
local resolvedName = resolveRename(fullName, data)
local charData = data.characters[resolvedName]
```

**Do not commit the Lua change in this task's commit.** Lua changes are committed after in-game manual verification (see Manual Verification section).

- [ ] **3.10** Commit the Python side:

```
git add tools/renames.json tools/wowaudit.py tools/tests/test_wowaudit.py
git commit -m "$(cat <<'EOF'
feat(4.5): add renames.json sidecar and _apply_renames() for realm transfers

tools/renames.json maps Old-Realm to New-Realm. _apply_renames() updates
row character keys and BiS dict keys before Lua emission. build_lua emits
a renames = {} table when non-empty so LootHistory:Apply can resolve
stale RCLootCouncilLootDB keys at runtime via data.renames (not
profile.renames -- the data file is the source of truth, not AceDB).
Eight new pytest cases cover key replacement, BiS rename, metadata-key
skipping, empty-map no-op, and Lua table emission.
EOF
)"
```

---

### Task 4 — `scoreOverrides` sidecar and emission (4.7, TDD first)

**Files:**
- Create: `tools/score-overrides.json`
- Modify: `tools/wowaudit.py` — load sidecar, emit `scoreOverrides` in Lua
- Modify: `tools/tests/test_wowaudit.py` — new class
- Modify: `Scoring.lua` — early return when `data.scoreOverrides[itemID]` is set (Lua-side, manual verification)

#### Sub-task 4.1 — Create `tools/score-overrides.json`

- [ ] **4.1** Create `tools/score-overrides.json`. Initially contains the format comment only; real overrides are added by hand as edge cases emerge:

```json
{
  "_comment": "Per-item score overrides. Format: itemID (as string) -> float score 0.0-100.0. Scoring:Compute returns this value directly, skipping formula computation. Use for cosmetic mounts, legendary memories, high-variance trinkets. Maintained in the same workflow as BiS files.",
  "_example": "212401: 95.0"
}
```

#### Sub-task 4.2 — Write failing tests

- [ ] **4.2** Add to `tools/tests/test_wowaudit.py`:

```python
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
```

- [ ] **4.3** Run to confirm failure:

```
pytest tools/tests/test_wowaudit.py -k "score_overrides or score_override" -v
```

Expected: `6 failed`.

#### Sub-task 4.4 — Implement emission in `build_lua`

- [ ] **4.4** Update `build_lua()` to accept `score_overrides: dict[int, float] | None = None` and emit the table in the Lua header block (before the `characters` table):

```python
# Emit scoreOverrides table (item 4.7).
# TODO(4B): include scoreOverrides in export bundle.
effective_overrides: dict[int, float] = {}
for raw_id, raw_val in (score_overrides or {}).items():
    try:
        iid = int(raw_id)
        fval = float(raw_val)
        effective_overrides[iid] = fval
    except (ValueError, TypeError):
        pass  # skip non-numeric entries silently

if effective_overrides:
    out.append("    scoreOverrides = {")
    for item_id, score_val in sorted(effective_overrides.items()):
        out.append(f"        [{item_id}] = {score_val:.1f},")
    out.append("    },")
```

- [ ] **4.5** Update `main()` to load `tools/score-overrides.json` and pass `score_overrides` to `build_lua`:

```python
# Load score-overrides sidecar (item 4.7).
overrides_path = Path(__file__).resolve().parent / "score-overrides.json"
score_overrides: dict[int, float] = {}
if overrides_path.is_file():
    try:
        raw_overrides = json.loads(overrides_path.read_text(encoding="utf-8"))
        for k, v in raw_overrides.items():
            if k.startswith("_"):
                continue
            try:
                score_overrides[int(k)] = float(v)
            except (ValueError, TypeError):
                print(
                    f"[WARN] score-overrides.json: skipping invalid entry "
                    f"{k!r}={v!r}",
                    file=sys.stderr,
                )
    except (json.JSONDecodeError, OSError) as exc:
        print(f"[WARN] Failed to load tools/score-overrides.json: {exc}",
              file=sys.stderr)
```

- [ ] **4.6** Re-run override tests:

```
pytest tools/tests/test_wowaudit.py -k "score_overrides or score_override" -v
```

Expected: `6 passed`.

#### Sub-task 4.7 — Lua-side consumption in `Scoring:Compute`

This is a small additive change to `Scoring.lua`. It is manually verified.

- [ ] **4.7** In `Scoring.lua`, at the very top of `Scoring:Compute`, add the early-return check immediately after the `char` guard:

```lua
function Scoring:Compute(itemID, candidateName, profile, data, opts)
    if not data or not data.characters then return nil end
    local char = data.characters[candidateName]
    if not char then return nil end

    -- item 4.7: scoreOverrides short-circuit.
    -- If the data file carries a fixed score for this item, return it
    -- directly without running the formula. No in-game editor; the
    -- override table is maintained in tools/score-overrides.json.
    if data.scoreOverrides then
        local overrideScore = data.scoreOverrides[itemID]
        if type(overrideScore) == "number" then
            -- Return score + minimal breakdown so callers that unpack
            -- two values (score, breakdown) do not error.
            return overrideScore, { _override = true }
        end
    end

    -- ... existing Compute body continues unchanged ...
```

**Do not commit the Lua change in this task's commit.**

- [ ] **4.8** Commit the Python side:

```
git add tools/score-overrides.json tools/wowaudit.py tools/tests/test_wowaudit.py
git commit -m "$(cat <<'EOF'
feat(4.7): add score-overrides.json sidecar and scoreOverrides emission

tools/score-overrides.json maps itemID strings to float scores. build_lua
emits scoreOverrides = { [itemID] = float } in the Lua data file header
when the map is non-empty. Non-numeric values are skipped with a warning.
Six new pytest cases cover table emission, omission when empty, float
formatting, file existence, JSON validity, and bad-value skipping.
EOF
)"
```

---

### Task 5 — Scoring regression test suite (4.6, TDD first)

**Files:**
- Create: `tools/tests/fixtures/BobleLoot_Data_sample.lua`
- Create: `tools/test_scoring.py` — Lua parser + Python port of `Scoring:Compute`
- Create: `tools/tests/test_scoring.py` — pytest entry point

This task creates a self-contained Python port of the scoring formula for CI regression testing. The port is deliberately NOT a general Lua interpreter — it is a Python reimplementation of the exact formula from `Scoring.lua` (as of Batch 2A, including `mainspec`, `role`, per-role history multiplier). If `Scoring.lua` changes in a way that breaks the invariants asserted here, the CI fails and the developer must update both the Lua and the port.

#### Sub-task 5.1 — Create the Lua fixture

- [ ] **5.1** Create `tools/tests/fixtures/BobleLoot_Data_sample.lua`. This file is a minimal but realistic `BobleLoot_Data.lua` that exercises every scoring path. It does **not** need to be a runnable Lua script — the Python regex parser handles it.

```lua
-- BobleLoot_Data_sample.lua
-- Fixture for tools/tests/test_scoring.py
-- Generated by hand to exercise all scoring code paths.
-- DO NOT edit without updating the corresponding Python assertions.

BobleLoot_Data = {
    generatedAt = 1745000000,
    simCap      = 5.0,
    mplusCap    = 160,
    historyCap  = 6,

    scoreOverrides = {
        [999001] = 95.0,
    },

    characters = {
        -- Full data: all components present.
        ["Fullchar-Stormrage"] = {
            attendance    = 90.0,
            mplusDungeons = 80,
            mainspec      = "Holy",
            role          = "raider",
            bis      = { [212401] = true },
            sims     = { [212401] = 3.5 },
            simsKnown = { [212401] = true },
            itemsReceived = 2,
        },
        -- Nil-sim path: simsKnown is absent for this item (never simmed).
        ["Nosim-Stormrage"] = {
            attendance    = 75.0,
            mplusDungeons = 40,
            role          = "raider",
            itemsReceived = 1,
        },
        -- Zero-sim path (Batch 1B fix): simsKnown present, sims value 0.0.
        -- Must NOT be treated as nil-sim.
        ["Zerosim-Stormrage"] = {
            attendance    = 80.0,
            mplusDungeons = 60,
            role          = "raider",
            bis      = { [212401] = true },
            sims     = {},
            simsKnown = { [212401] = true },
            itemsReceived = 0,
        },
        -- All-nil-component path: missing attendance AND mplus AND history.
        -- Score:Compute should return nil (no computable score).
        ["Allnil-Stormrage"] = {
            role = "raider",
        },
        -- Trial role: history component should be multiplied by 0.5.
        ["Trialchar-Stormrage"] = {
            attendance    = 60.0,
            mplusDungeons = 20,
            role          = "trial",
            itemsReceived = 0,
        },
        -- Zero history cap: denominator is softFloor (6); itemsReceived=0 -> 1.0.
        ["Noloot-Stormrage"] = {
            attendance    = 100.0,
            mplusDungeons = 160,
            role          = "raider",
            itemsReceived = 0,
        },
    },
}
```

#### Sub-task 5.2 — Create `tools/test_scoring.py`

- [ ] **5.2** Create `tools/test_scoring.py`. This module is importable and also runnable as a script. It contains the Lua parser, the Python-port formulas, and the `ScoreEngine` class.

```python
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
        """Extract a balanced `{ ... }` table starting at `pos`.

        Returns:
            (parsed_dict, end_position_after_closing_brace)
        """
        result: dict = {}
        depth = 1
        i = pos

        while i < len(text) and depth > 0:
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
    if text[i:i+2] == "--":
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
```

#### Sub-task 5.3 — Create `tools/tests/test_scoring.py`

- [ ] **5.3** Create `tools/tests/test_scoring.py`:

```python
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
    data["characters"]["SyntheticRadier-Stormrage"] = {
        "attendance": 60.0,
        "mplusDungeons": 20,
        "role": "raider",
        "itemsReceived": 0,
    }

    engine_trial = ts.ScoreEngine(data, profile_trial_05)
    score_trial,  _ = engine_trial.compute(212401, "Trialchar-Stormrage")
    score_raider, _ = engine_trial.compute(212401, "SyntheticRadier-Stormrage")

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
```

- [ ] **5.4** Run the new test module to confirm it passes once the fixture and module are in place:

```
pytest tools/tests/test_scoring.py -v --tb=short
```

Expected: all tests pass. If parser tests fail, debug `LuaDataParser` against the fixture.

- [ ] **5.5** Also confirm the full suite still passes:

```
pytest tools/ -v --tb=short 2>&1 | tail -20
```

- [ ] **5.6** Commit:

```
git add tools/test_scoring.py tools/tests/test_scoring.py tools/tests/fixtures/BobleLoot_Data_sample.lua
git commit -m "$(cat <<'EOF'
feat(4.6): add scoring regression test suite with Python port of Scoring:Compute

tools/test_scoring.py: regex Lua parser + ScoreEngine (Python port of
Scoring:Compute including 1B nil-vs-zero, 2A spec-aware and per-role
history multiplier, 4.7 scoreOverrides short-circuit). Exercises nil-sim
exclusion, zero-sim scoring, all-nil-component nil return, override
short-circuit, trial role history reduction, zero-items-received with
softFloor, history-reference denominator selection, and 0-100 bounds.
tools/tests/test_scoring.py: pytest entry point (17 assertions).
tools/tests/fixtures/BobleLoot_Data_sample.lua: hand-crafted fixture.
EOF
)"
```

---

### Task 6 — Extend CI workflow to run scoring regression suite (4.6)

**Files:**
- Modify: `.github/workflows/refresh.yml` — add `pytest tools/tests/test_scoring.py` and `pyyaml` to pip install

- [ ] **6.1** In `.github/workflows/refresh.yml`, in the `lint` job's "Install Python dependencies" step, add `pyyaml` to the pip install line:

```yaml
- name: Install Python dependencies
  run: |
    python -m pip install --upgrade pip
    pip install pytest jsonschema pyyaml
```

- [ ] **6.2** In the same `lint` job, add a new step after "Run pytest" that runs the scoring regression suite explicitly. This makes the CI output unambiguous about which suite failed:

```yaml
- name: Run scoring regression tests
  run: pytest tools/tests/test_scoring.py -v --tb=short
```

- [ ] **6.3** Verify the YAML is syntactically valid:

```
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/refresh.yml'))" && echo "YAML OK"
```

- [ ] **6.4** Commit:

```
git add .github/workflows/refresh.yml
git commit -m "$(cat <<'EOF'
ci(4.6): add scoring regression suite to lint job; add pyyaml to pip install

pytest tools/tests/test_scoring.py runs explicitly in the lint job so CI
failures are unambiguous (separate from the wowaudit.py harness). pyyaml
added to the pip install line to support --tier YAML loading (4.1).
EOF
)"
```

---

### Task 7 — Commit Lua-side changes after in-game verification

**Files:**
- Modify: `Scoring.lua` — `scoreOverrides` short-circuit (4.7)
- Modify: `LootHistory.lua` — `resolveRename` helper + usage in `LH:Apply` (4.5)

These changes are committed only after passing the Manual Verification checklist items for 4.5 and 4.7. The Lua diffs are small and additive.

#### `Scoring.lua` change (4.7 scoreOverrides)

- [ ] **7.1** In `Scoring.lua`, add the override check at the top of `Scoring:Compute` immediately after the `char` guard (see Sub-task 4.7 for the exact Lua code). Confirm in-game that:
  - Passing `--score-override 212401:95.0` (or editing `score-overrides.json`) and regenerating the Lua file causes item 212401 to display `95` for all candidates in the voting frame.
  - Removing the override and regenerating returns to formula-computed scores.
  - The `{ _override = true }` breakdown does not crash the tooltip code (the tooltip should handle unknown component keys gracefully).

- [ ] **7.2** Commit `Scoring.lua`:

```
git add Scoring.lua
git commit -m "$(cat <<'EOF'
feat(4.7/lua): scoreOverrides early return in Scoring:Compute

When data.scoreOverrides[itemID] is a number, Scoring:Compute returns
it directly with breakdown = { _override = true }. This short-circuits
the formula for edge-case items maintained in tools/score-overrides.json.
EOF
)"
```

#### `LootHistory.lua` change (4.5 renames)

- [ ] **7.3** In `LootHistory.lua`, add the `resolveRename` helper and apply it in `LH:Apply` before the `data.characters[fullName]` lookup (see Sub-task 3.9 for the exact Lua code). Confirm in-game that:
  - A character entry in `renames.json` (e.g. `"OldChar-OldRealm": "NewChar-NewRealm"`) causes the old name's RC loot history to be credited to the new name's score after a data regeneration and `/reload`.
  - Characters not in the renames map are unaffected.
  - The `_bl lootdb` output shows history credited under the new name.

- [ ] **7.4** Commit `LootHistory.lua`:

```
git add LootHistory.lua
git commit -m "$(cat <<'EOF'
feat(4.5/lua): apply data.renames before history lookup in LH:Apply

resolveRename(name, data) checks data.renames (emitted by wowaudit.py
from tools/renames.json) and returns the new name when a mapping exists.
This means realm-transferred characters have their old RC loot history
credited to their new name without any manual data migration.
EOF
)"
```

---

### Task 8 — Wire `--renames` and `--score-overrides` CLI flags (optional polish)

**Files:**
- Modify: `tools/wowaudit.py` — add `--renames` and `--score-overrides` flags to override the default sidecar paths

These are optional power-user flags. The defaults (files next to `wowaudit.py`) cover 95% of usage. The flags exist for CI environments where sidecars live elsewhere.

- [ ] **8.1** In `main()`, add to argparse:

```python
ap.add_argument(
    "--renames",
    type=Path,
    default=None,
    metavar="FILE",
    help=(
        "Path to a renames.json sidecar. "
        "Default: tools/renames.json (sibling of wowaudit.py). "
        "Format: {'Old-Realm': 'New-Realm'}."
    ),
)
ap.add_argument(
    "--score-overrides",
    type=Path,
    default=None,
    metavar="FILE",
    help=(
        "Path to a score-overrides.json sidecar. "
        "Default: tools/score-overrides.json. "
        "Format: {'itemID': float}."
    ),
)
```

- [ ] **8.2** Update the sidecar-loading logic in `main()` to use `args.renames` and `args.score_overrides` when provided, falling back to the default sibling paths.

- [ ] **8.3** Add two tests:

```python
def test_renames_path_default_is_sibling_of_wowaudit():
    """Default renames path is tools/renames.json."""
    # Verify the constant is correct relative to wowaudit.py.
    import importlib.util
    wowaudit_path = TOOLS_DIR / "wowaudit.py"
    assert (wowaudit_path.parent / "renames.json").is_file()


def test_score_overrides_path_default_is_sibling():
    """Default score-overrides path is tools/score-overrides.json."""
    assert (TOOLS_DIR / "score-overrides.json").is_file()
```

- [ ] **8.4** Run:

```
pytest tools/tests/test_wowaudit.py -k "renames_path or overrides_path" -v
```

- [ ] **8.5** Commit:

```
git add tools/wowaudit.py tools/tests/test_wowaudit.py
git commit -m "$(cat <<'EOF'
feat: add --renames and --score-overrides CLI flags for non-default paths

Both flags override the default sibling-file locations for the renames
and score-overrides sidecars, allowing CI runs with custom paths.
EOF
)"
```

---

### Task 9 — `bis/README.md` retention policy addendum (4.1 documentation)

**Files:**
- Modify: `bis/README.md` — add tier retention section

- [ ] **9.1** In `bis/README.md` (created in Batch 3A), add a section documenting the retention policy introduced in 4.1:

```markdown
## Tier retention policy (Batch 4.1)

**Never delete a tier directory.** When a new tier launches:

1. Create `bis/<new-tier>/` and populate it.
2. Add the new tier to `tools/tier-config.yaml` with the correct `bisPath`.
3. Leave all old tier directories in place.

This means `py tools/wowaudit.py --tier tww-s2` will always regenerate a
historically-accurate Lua file for Season 2 scores, because `bis/tww-s2/`
is still on disk. Old BiS lists are the source of truth for historical
comparisons — the `tierPreset` field in `BobleLoot_Data.lua` identifies
which tier a given data file was generated for.
```

- [ ] **9.2** Commit:

```
git add bis/README.md
git commit -m "$(cat <<'EOF'
docs(4.1): add tier retention policy to bis/README.md

Documents that old bis/<tier>/ directories must never be deleted so that
--tier <old-tier> always regenerates a historically-accurate data file.
EOF
)"
```

---

### Task 10 — Final verification pass

**Files:** No changes — verification only.

- [ ] **10.1** Install `pyyaml` in the development environment if not already present:

```
pip install pyyaml
```

- [ ] **10.2** Run the complete pytest suite:

```
pytest tools/ -v --tb=short
```

Expected: all tests pass. Record total count (target ≥ baseline + 40 new tests across Tasks 1–8).

- [ ] **10.3** Verify all expected files exist:

```python
python3 -c "
from pathlib import Path
expected = [
    'tools/tier-config.yaml',
    'tools/renames.json',
    'tools/score-overrides.json',
    'tools/test_scoring.py',
    'tools/tests/test_scoring.py',
    'tools/tests/fixtures/BobleLoot_Data_sample.lua',
    '.github/workflows/refresh.yml',
]
root = Path('.')
missing = [p for p in expected if not (root / p).exists()]
print('Missing:', missing or 'none -- all present')
"
```

Expected: `Missing: none -- all present`.

- [ ] **10.4** Smoke-test the tier-config YAML path end-to-end in dry-run mode (no API key required; uses `--use-cache` or `--wowaudit` convert mode):

```
python3 tools/wowaudit.py \
  --wowaudit tools/sample_input/wowaudit_valid.csv \
  --tier tww-s3 \
  --out /tmp/batch4a_smoke.lua
grep "tierPreset" /tmp/batch4a_smoke.lua
```

Expected: `tierPreset  = "tww-s3"` appears in the output.

- [ ] **10.5** Smoke-test the scoring regression module directly:

```
python3 tools/test_scoring.py
```

Expected output includes:
```
Loaded characters: [...]
Fullchar-Stormrage / 212401 => score=<positive float>
Fullchar-Stormrage / 999001 (override) => score=95.00
```

---

## Manual Verification Checklist

### 4.1 — Tier-config YAML reads

1. Run `py tools/wowaudit.py --tier tww-s3 --api-key <key>`. Confirm:
   - `Data/BobleLoot_Data.lua` contains `tierPreset = "tww-s3"`, `lootMinIlvl = 636`, and (if `bis/tww-s3/` exists) a populated `bis` table.
   - Running with `--tier tww-s2` produces `tierPreset = "tww-s2"` and `lootMinIlvl = 610`.
2. Confirm `--bis bis/tww-s3/` applied automatically when `bisPath: "bis/tww-s3"` is set in `tier-config.yaml` and `--bis` is not explicitly passed.
3. Confirm that passing an unknown tier name (`--tier totally-fake`) exits with a message listing available tiers.
4. Open `bis/README.md` and confirm the retention policy section is present.

### 4.4 — Backoff behaviour against a mocked rate-limited endpoint

1. In a Python REPL, import `wowaudit` and monkeypatch `http_get_json` to raise `HTTPError(429)` twice then succeed. Confirm the retry decorator sleeps and eventually returns the result (automated by pytest Task 2 tests).
2. In a real API run: if `X-RateLimit-Remaining` appears in the WoWAudit response headers, confirm a warning is printed to stderr when the value is ≤ 5.
3. Simulate a full failure (all retries exhaust) by passing an invalid API key with the cache populated. Confirm `_read_cache` result is returned rather than a crash.

### 4.5 — Rename sidecar end-to-end

1. Add an entry to `tools/renames.json`: `"Kotoma-TwistingNether": "Kotoma-Stormrage"`.
2. Run `py tools/wowaudit.py --api-key <key>`.
3. Open `Data/BobleLoot_Data.lua`. Confirm:
   - The `characters` table has `"Kotoma-Stormrage"` (not `"Kotoma-TwistingNether"`).
   - The `renames = { ["Kotoma-TwistingNether"] = "Kotoma-Stormrage" }` table is present.
4. In-game after `/reload`:
   - Open a loot vote. Confirm that if `RCLootCouncilLootDB` has loot history under `"Kotoma-TwistingNether"`, it is credited to the renamed character's score.
   - `/bl lootdb` shows history attributed to the new name.
5. Revert `renames.json` to `{}` and confirm no `renames` table appears in the next Lua generation.

### 4.6 — Scoring regression suite in CI

1. Push the `plans/batch-4` branch. Observe the `lint` job in GitHub Actions.
2. Confirm both `pytest tools/ -v` and `pytest tools/tests/test_scoring.py -v` steps appear and pass.
3. Deliberately break `ScoreEngine.compute` (e.g. comment out the `histVal` role-multiplier block) in a local branch. Run `pytest tools/tests/test_scoring.py`. Confirm `test_trial_role_reduces_history_component` fails. Revert.
4. Deliberately break the Lua fixture (remove `simsKnown` from `Zerosim-Stormrage`). Confirm `test_zero_sim_scores_rather_than_excluded` fails (1B regression). Revert.

### 4.7 — `scoreOverrides` display in a test session

1. Add an entry to `tools/score-overrides.json`: `"212401": 95.0`.
2. Run `py tools/wowaudit.py --api-key <key>`.
3. In `Data/BobleLoot_Data.lua` confirm: `scoreOverrides = { [212401] = 95.0 }` is present.
4. In-game after `/reload`:
   - Open a vote for item 212401. Confirm all candidates show a score of 95 (the override bypasses the formula).
   - Open a vote for a different item. Confirm scores are formula-computed as normal.
5. Revert `score-overrides.json` to `{}`. Regenerate. Confirm `scoreOverrides` is absent from the Lua file. In-game: formula scores restored for item 212401.
6. Confirm that a character for whom `Scoring:Compute` would normally return `nil` (no sim data, sim weight > 0) still shows 95 when the override is present — the override bypasses the nil-sim gate.

---

## Rollback Notes

- **4.1 (tier-config YAML):** `_load_tier_preset()` is preserved in `wowaudit.py` as a deprecated fallback. To revert to JSON presets: update `main()` to call `_load_tier_preset(args.tier)` instead of `_load_tier_config(args.tier)`. No data loss; `tools/tiers/*.json` files are untouched by 4A.
- **4.4 (backoff):** The `retry_with_backoff` wrapping of `http_get_json` is applied at module level. To disable: remove the `http_get_json = retry_with_backoff(...)` line. The original function is still in scope. Cache fallback behaviour is already present in Batch 1A's `_read_cache`; the backoff layer only adds the sleep/retry before the cache fallback fires.
- **4.5 (renames):** `_apply_renames()` is a no-op when `renames.json` is empty or absent. Revert: empty `tools/renames.json` (`{}`). The Lua `renames` table will be absent on the next generation; `LootHistory:Apply`'s `resolveRename` safely returns the original name when `data.renames` is nil.
- **4.6 (regression tests):** Removing `tools/tests/test_scoring.py` from the pytest run is a one-line change in `refresh.yml`. The `tools/test_scoring.py` module is standalone and does not affect the existing `test_wowaudit.py` tests.
- **4.7 (scoreOverrides):** Emit is conditional on the map being non-empty. Revert: empty `tools/score-overrides.json` (`{}`). The Lua `scoreOverrides` table will be absent; `Scoring:Compute` guards `if data.scoreOverrides then` so an absent table is safe.

---

## Coordination Notes

### Overlap with Batch 2A (`--tier`)

Batch 2A introduced `_load_tier_preset()` reading from `tools/tiers/<name>.json`. Batch 4A's `_load_tier_config()` reads from `tools/tier-config.yaml` and returns an identical dict shape. The migration path:

1. `_load_tier_preset()` is kept in `wowaudit.py` with a deprecation comment so any test that still imports it does not break.
2. `main()` switches from `_load_tier_preset` to `_load_tier_config` as part of Task 1.
3. The `tools/tiers/` directory and its JSON files remain on disk for reference; they are not deleted.
4. The `bisPath` key in `tier-config.yaml` is new (JSON presets had `bisPath: null` always) — it supersedes the manual `--bis bis/<tier>/` that users previously had to specify alongside `--tier`.

### Overlap with Batch 3A (CI workflow + BiS directory)

Batch 3A added `.github/workflows/refresh.yml` with a `lint` job running `pytest tools/` and a `refresh` job. Batch 4A:

- Adds `pyyaml` to the `pip install` line in the lint job (required for `_load_tier_config`).
- Adds an explicit `pytest tools/tests/test_scoring.py` step to the lint job so the regression suite is visibly separate in CI output.
- Does **not** modify the `refresh` job. The refresh job's `wowaudit.py` invocation already uses `--bis-from-wishlist`; users who switch to `--tier tww-s3` (which sets `bisPath` automatically) can update the refresh job in a separate commit.

The `bis/<tier>/` directory retention policy is documented in `bis/README.md` and enforced by the tier-config YAML design (old tiers remain in the file permanently).

### Overlap with Batch 4B (export/import bundle)

Batch 4B will add `wowaudit.py --export <path.json>` that writes a portable JSON bundle. The `scoreOverrides` table (4.7) should be included in that bundle. A `# TODO(4B): include scoreOverrides in export bundle` comment is placed in the `scoreOverrides` emission block in `build_lua` so the 4B worker picks it up without needing to read this plan.

The `renames` table (4.5) should also be included in the export bundle so a new leader's import operation can resolve stale RC keys on their own machine. Add the same `# TODO(4B):` comment near the renames emission block.

Batch 4B's `--export` path touches `wowaudit.py` only for the `--export` subcommand. There is no overlap with 4A's `--tier-config`, `--renames`, or `--score-overrides` flags.

### Test count baseline

After all tasks are committed, `pytest tools/ -v` should report approximately:
- Batch 1A baseline: 54 tests
- Batch 2A additions: ~24 tests
- Batch 3A additions: ~24 tests
- Batch 4A additions: ~40 new tests (Tasks 1–8)
- **Total target: ≥ 142 tests**

The scoring regression suite (`tools/tests/test_scoring.py`) contributes 17 tests and is counted within this target.
