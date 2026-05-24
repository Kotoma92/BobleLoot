# Changelog

All notable changes are listed here. Each release is also published with
notes on GitHub: https://github.com/Kotoma92/BobleLoot/releases

## [1.2.4] - 2026-05-24

### Fixed
- TOC now declares `X-Curse-Project-ID: 1521965` so the BigWigs
  packager can upload to CurseForge from the tag workflow. Previous
  tagged releases (1.2.0 - 1.2.3) packaged successfully but skipped
  the CF upload silently because the project ID was missing.

## [1.2.3] - 2026-05-24

### Changed
- TOC now declares interface compatibility for `120001`, `120005`, and
  `120007` so the addon does not show as out of date on the latest
  retail builds.
- Added `## X-Website` metadata pointing at the GitHub repo.

### Added
- `.editorconfig` for consistent indentation / line endings across editors.
- This `CHANGELOG.md`.

## [1.2.2] - 2026-05-24

Lower-priority raid performance cleanups:
- `VotingFrame`: `OnEnter` / `OnLeave` / `OnMouseDown` hoisted to
  module-level static handlers; cell state is stashed on the frame, so
  re-renders no longer allocate fresh closures.
- Shift-click compare reuses the cached `_sessionStats.nameToScore` map
  instead of doing its own O(N) Compute pass.
- Column sort reuses the cached `simRef` / `histRef` when the
  (session, itemID) cache is warm. Saves ~9000 wasted iterations per
  30-candidate sort click.
- `Sync:SendScores`: cheap count + score-sum pre-check skips the
  sort+concat signature build when nothing changed.

## [1.2.1] - 2026-05-24

Raid-scale performance fixes for the 30-candidate / 30-instance
scenario:
- `VotingFrame`: cached `simRef` / `histRef` / `names` in
  `_sessionStats` and hoisted `computeSessionStats` to the start of
  `doCellUpdate`. Eliminated ~870 redundant `Compute` calls per render.
- `Sync`: `SendHello` is now scheduled through `ScheduleHello` with a
  10-second dedupe window and 0-3 second jitter. Prevents `HELLO`
  broadcast storms on `GROUP_ROSTER_UPDATE` blips (ready checks,
  vehicle entries, etc.).

## [1.2.0] - 2026-05-24

- BigWigs packager GitHub Action wired up (`.github/workflows/release.yml`).
- `.pkgmeta` ignores tooling, BiS source, and the generated data file.
- TOC author placeholder fixed; version bumped after the long pause.
- `/bl config` and `/bl options` documented as the standard entrypoint
  for the settings panel.

## [1.0.x] - prior

Initial public releases. See git history for details.
