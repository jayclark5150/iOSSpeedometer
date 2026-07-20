# iOS Speedometer

A GPS speedometer and trip computer for iPhone, built with SwiftUI, CoreLocation, and MapKit. Mount your phone on the dash and get a big, glanceable speed readout plus live trip stats and a route map.

<!-- Add a screenshot: drag an image into this repo (e.g. docs/screenshot.png) and update the path below -->
<!-- ![Speedometer screenshot](docs/screenshot.png) -->

## Features

- **Live speed** — large rounded-font readout driven directly by GPS (`CLLocation.speed`), with smooth numeric transitions
- **Trip distance** — accumulated between GPS fixes with accuracy filtering (ignores jitter under 2 m, GPS "teleports" over 200 m, and fixes worse than ±50 m)
- **Trip duration** — running clock that correctly accumulates across pause/resume
- **Max speed** — high-water mark for the current trip
- **Interactive route map** — MapKit view that draws your route as a live polyline, with a start flag, user-location dot, compass, and scale bar
- **mph / km/h toggle** — preference persists between launches
- **GPS accuracy indicator** — green when the fix is solid, orange while settling
- **Screen stays awake** while the app is open, for dash-mounted use

## Requirements

- Xcode 26 or later
- iOS 17.0+ (uses the SwiftUI MapKit APIs: `Map`, `MapPolyline`, `UserAnnotation`)
- A physical iPhone for real GPS testing (the Simulator can fake movement via **Features > Location > Freeway Drive**)

## Building

1. Clone the repo and open `Speedometer.xcodeproj` in Xcode
2. Select the Speedometer target > **Signing & Capabilities** and choose your own team
3. Build and run on your device (Cmd+R)

The location permission string (`NSLocationWhenInUseUsageDescription`) is already configured in the project. On first launch, tap **Allow While Using App** when prompted.

## How it works

All logic lives in a single file, `Speedometer/SpeedometerApp.swift`:

- `TripManager` — an `ObservableObject` wrapping `CLLocationManager`. Publishes live speed and accuracy, and while tracking, accumulates distance between consecutive fixes, records the route coordinates, and tracks max speed. Negative (invalid) GPS speed values are clamped to zero.
- `SpeedView` — the main gauge tab: speed readout, stats card (distance / duration / max), start–pause–reset controls, and unit picker.
- `TripMapView` — the map tab: route polyline, start marker, and a floating stats capsule, updated live.

Tracking uses when-in-use location only, so recording pauses if the app is backgrounded or the screen locks — by design for dash-mounted use.

## Roadmap

- Background tracking (Always permission + location background mode)
- Trip history with saved routes
- HUD mode (mirrored display for windshield reflection)
- Average speed and moving time vs. stopped time

## License

See [LICENSE](LICENSE).
