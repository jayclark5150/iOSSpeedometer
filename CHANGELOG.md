# Changelog

## [5.0.0] - 2026-11-11
- Trips now finish reliably when auto-stop fires on any tab (end-of-trip handling moved out of the Speed view into `TripManager`)
- Auto-ended walks and bike rides are now saved to Apple Health automatically
- Max speed is clamped to a per-activity plausible bound so a spurious GPS fix can't set a bogus record
- GPS "teleport" fixes are now detected by implied speed (per activity) and re-anchored instead of dropped

## [4.0.0] - 2026-11-11
- Trip history with saved routes, browsable on a new History tab
- Auto start/stop based on movement, with per-activity thresholds

## [3.0.0] - 2026-07-20
- Activity types: drive, walk, and bike modes
- HealthKit workout saving with GPS routes
- Updated README with HealthKit integration details

## [1.0.0] - 2026-07-01
- Initial release: GPS speedometer trip computer for iPhone
