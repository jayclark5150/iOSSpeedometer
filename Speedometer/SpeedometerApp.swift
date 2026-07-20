//
//  SpeedometerApp.swift  (v3 — HealthKit)
//  GPS speedometer / trip computer that can save walks and bike rides
//  to Apple Health as workouts with route maps.
//
//  New Xcode setup required for v3:
//  1. Target > Signing & Capabilities > + Capability > HealthKit
//  2. Target > Info > add:
//     "Privacy - Health Update Usage Description"
//        = "Saves your walks and bike rides as workouts."
//     "Privacy - Health Share Usage Description"
//        = "Used to confirm workouts were saved."
//

import SwiftUI
import CoreLocation
import Combine
import MapKit
import HealthKit

// MARK: - Activity Type

enum ActivityType: String, CaseIterable, Identifiable {
    case drive = "Drive"
    case walk  = "Walk"
    case bike  = "Bike"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .drive: "car.fill"
        case .walk:  "figure.walk"
        case .bike:  "bicycle"
        }
    }

    var savableToHealth: Bool { self != .drive }

    var hkActivityType: HKWorkoutActivityType {
        switch self {
        case .walk: .walking
        case .bike: .cycling
        case .drive: .other   // never saved; placeholder
        }
    }

    var hkDistanceType: HKQuantityType {
        switch self {
        case .bike: HKQuantityType(.distanceCycling)
        default:    HKQuantityType(.distanceWalkingRunning)
        }
    }
}

// MARK: - Trip / Location Manager

final class TripManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    // Live values
    @Published var speedMetersPerSecond: Double = 0
    @Published var accuracy: Double = -1
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    // Trip values
    @Published var isTracking = false
    @Published var tripDistanceMeters: Double = 0
    @Published var maxSpeedMetersPerSecond: Double = 0
    @Published var tripStart: Date? = nil               // start of current running segment
    @Published var accumulatedTime: TimeInterval = 0
    @Published var routeLocations: [CLLocation] = []    // full fixes, needed for HealthKit routes
    @Published var activity: ActivityType = .drive

    // Session bookkeeping for HealthKit
    @Published var sessionStart: Date? = nil            // first Start after a reset
    @Published var sessionEnd: Date? = nil              // most recent Pause

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation? = nil

    var routeCoordinates: [CLLocationCoordinate2D] {
        routeLocations.map(\.coordinate)
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        applyActivityTuning()
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    /// Tune CoreLocation for the kind of movement expected.
    func applyActivityTuning() {
        manager.activityType = (activity == .drive) ? .automotiveNavigation : .fitness
    }

    // MARK: Trip controls

    func startTrip() {
        if sessionStart == nil { sessionStart = Date() }
        tripStart = Date()
        sessionEnd = nil
        isTracking = true
        lastLocation = nil
    }

    func pauseTrip() {
        if let start = tripStart {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        tripStart = nil
        sessionEnd = Date()
        isTracking = false
    }

    func resetTrip() {
        pauseTrip()
        tripDistanceMeters = 0
        maxSpeedMetersPerSecond = 0
        accumulatedTime = 0
        routeLocations.removeAll()
        lastLocation = nil
        sessionStart = nil
        sessionEnd = nil
    }

    var elapsed: TimeInterval {
        accumulatedTime + (tripStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// True when there is a completed (paused) trip worth saving.
    var hasSavableTrip: Bool {
        !isTracking
        && activity.savableToHealth
        && tripDistanceMeters > 10
        && sessionStart != nil
        && sessionEnd != nil
        && routeLocations.count > 1
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        accuracy = location.horizontalAccuracy
        let speed = location.speed
        speedMetersPerSecond = speed >= 0 ? speed : 0

        guard isTracking,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < 50 else { return }

        if speedMetersPerSecond > maxSpeedMetersPerSecond {
            maxSpeedMetersPerSecond = speedMetersPerSecond
        }

        // Walks move slowly, so use a smaller jitter floor than driving.
        let minDelta: Double = (activity == .drive) ? 2 : 1

        if let last = lastLocation {
            let delta = location.distance(from: last)
            let dt = location.timestamp.timeIntervalSince(last.timestamp)
            if delta >= minDelta, delta < 200, dt > 0 {
                tripDistanceMeters += delta
                routeLocations.append(location)
                lastLocation = location
            }
        } else {
            routeLocations.append(location)
            lastLocation = location
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
}

// MARK: - HealthKit Manager

final class HealthManager: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @Published var saveState: SaveState = .idle

    private let store = HKHealthStore()

    func saveWorkout(from trip: TripManager) {
        guard HKHealthStore.isHealthDataAvailable() else {
            saveState = .failed("Health data isn't available on this device.")
            return
        }
        guard let start = trip.sessionStart, let end = trip.sessionEnd else {
            saveState = .failed("No completed trip to save.")
            return
        }

        let activity = trip.activity
        let distance = trip.tripDistanceMeters
        let locations = trip.routeLocations

        saveState = .saving

        Task { @MainActor in
            do {
                let workoutType = HKObjectType.workoutType()
                let routeType = HKSeriesType.workoutRoute()
                let distanceType = activity.hkDistanceType

                try await store.requestAuthorization(
                    toShare: [workoutType, routeType, distanceType],
                    read: []
                )

                // Build the workout.
                let config = HKWorkoutConfiguration()
                config.activityType = activity.hkActivityType
                config.locationType = .outdoor

                let builder = HKWorkoutBuilder(healthStore: store,
                                               configuration: config,
                                               device: .local())

                try await builder.beginCollection(at: start)

                let distanceSample = HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                    start: start,
                    end: end
                )
                try await builder.addSamples([distanceSample])
                try await builder.endCollection(at: end)

                guard let workout = try await builder.finishWorkout() else {
                    saveState = .failed("Workout could not be created.")
                    return
                }

                // Attach the GPS route.
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
                try await routeBuilder.insertRouteData(locations)
                try await routeBuilder.finishRoute(with: workout, metadata: nil)

                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Formatting helpers

enum Units {
    static func speed(_ mps: Double, mph: Bool) -> Double {
        mph ? mps * 2.23694 : mps * 3.6
    }
    static func distanceString(_ meters: Double, mph: Bool) -> String {
        if mph {
            String(format: "%.2f mi", meters / 1609.344)
        } else {
            String(format: "%.2f km", meters / 1000)
        }
    }
    static func durationString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Speed Tab

struct SpeedView: View {
    @ObservedObject var trip: TripManager
    @ObservedObject var health: HealthManager
    @Binding var useMPH: Bool

    var body: some View {
        VStack(spacing: 14) {

            // Activity picker — locked while tracking
            Picker("Activity", selection: $trip.activity) {
                ForEach(ActivityType.allCases) { a in
                    Label(a.rawValue, systemImage: a.symbol).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .disabled(trip.isTracking)
            .onChange(of: trip.activity) { trip.applyActivityTuning() }

            Spacer()

            Text(String(format: "%.0f", Units.speed(trip.speedMetersPerSecond, mph: useMPH)))
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: trip.speedMetersPerSecond)

            Text(useMPH ? "mph" : "km/h")
                .font(.title2)
                .foregroundStyle(.secondary)

            Spacer()

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 0) {
                    stat("Distance", Units.distanceString(trip.tripDistanceMeters, mph: useMPH))
                    Divider().frame(height: 40)
                    stat("Duration", Units.durationString(trip.elapsed))
                    Divider().frame(height: 40)
                    stat("Max", String(format: "%.0f %@",
                                       Units.speed(trip.maxSpeedMetersPerSecond, mph: useMPH),
                                       useMPH ? "mph" : "km/h"))
                }
            }
            .padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

            if trip.accuracy >= 0 {
                Label(String(format: "GPS: ±%.0f m", trip.accuracy),
                      systemImage: trip.accuracy < 20 ? "location.fill" : "location.slash")
                    .font(.footnote)
                    .foregroundStyle(trip.accuracy < 20 ? .green : .orange)
            }

            controls

            // Save to Health — appears only after a paused walk/bike trip
            if trip.hasSavableTrip {
                saveToHealthButton
            }

            Picker("Units", selection: $useMPH) {
                Text("mph").tag(true)
                Text("km/h").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .padding(.bottom, 4)

            if trip.authorizationStatus == .denied {
                Text("Location access is denied. Enable it in Settings > Privacy > Location Services.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .alert("Saved to Apple Health",
               isPresented: .constant(health.saveState == .saved)) {
            Button("OK") { health.saveState = .idle }
        } message: {
            Text("Your \(trip.activity.rawValue.lowercased()) was saved as a workout with its route.")
        }
        .alert("Couldn't Save",
               isPresented: .constant({
                   if case .failed = health.saveState { return true }
                   return false
               }())) {
            Button("OK") { health.saveState = .idle }
        } message: {
            if case .failed(let msg) = health.saveState { Text(msg) }
        }
    }

    private var saveToHealthButton: some View {
        Button {
            health.saveWorkout(from: trip)
        } label: {
            Label(health.saveState == .saving ? "Saving..." : "Save to Apple Health",
                  systemImage: "heart.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pink)
        .controlSize(.large)
        .disabled(health.saveState == .saving)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                trip.isTracking ? trip.pauseTrip() : trip.startTrip()
            } label: {
                Label(trip.isTracking ? "Pause" : "Start",
                      systemImage: trip.isTracking ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(trip.isTracking ? .orange : .green)

            Button(role: .destructive) {
                trip.resetTrip()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Map Tab

struct TripMapView: View {
    @ObservedObject var trip: TripManager
    @Binding var useMPH: Bool

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()

            if trip.routeLocations.count > 1 {
                MapPolyline(coordinates: trip.routeCoordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }

            if let start = trip.routeLocations.first {
                Marker("Start", systemImage: "flag.fill", coordinate: start.coordinate)
                    .tint(.green)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .overlay(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 16) {
                    Label(Units.distanceString(trip.tripDistanceMeters, mph: useMPH),
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(Units.durationString(trip.elapsed), systemImage: "clock")
                    Label(String(format: "%.0f %@",
                                 Units.speed(trip.speedMetersPerSecond, mph: useMPH),
                                 useMPH ? "mph" : "km/h"),
                          systemImage: "speedometer")
                }
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Root View

struct RootView: View {
    @StateObject private var trip = TripManager()
    @StateObject private var health = HealthManager()
    @AppStorage("useMPH") private var useMPH = true

    var body: some View {
        TabView {
            SpeedView(trip: trip, health: health, useMPH: $useMPH)
                .tabItem { Label("Speed", systemImage: "speedometer") }

            TripMapView(trip: trip, useMPH: $useMPH)
                .tabItem { Label("Map", systemImage: "map") }
        }
        .onAppear {
            trip.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - App Entry Point

@main
struct SpeedometerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
