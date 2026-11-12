//
//  SpeedometerApp.swift  (v4 — History)
//  GPS speedometer / trip computer that saves history and Apple Health workouts.
//
//  Xcode setup required:
//  1. Target > Signing & Capabilities > + Capability > HealthKit
//  2. Target > Info > add:
//     "Privacy - Health Update Usage Description"
//        = "Saves your walks and bike rides as workouts."
//     "Privacy - Health Share Usage Description"
//        = "Used to confirm workouts were saved."
//

import SwiftUI
import SwiftData
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
        case .drive: .other
        }
    }

    var hkDistanceType: HKQuantityType {
        switch self {
        case .bike: HKQuantityType(.distanceCycling)
        default:    HKQuantityType(.distanceWalkingRunning)
        }
    }
}

// MARK: - Trip History Model

@Model
final class TripRecord {
    var id: UUID
    var date: Date
    var activityRawValue: String
    var distanceMeters: Double
    var durationSeconds: Double
    var maxSpeedMPS: Double
    var encodedRoute: Data

    init(date: Date, activity: ActivityType, distanceMeters: Double,
         durationSeconds: Double, maxSpeedMPS: Double, locations: [CLLocation]) {
        self.id = UUID()
        self.date = date
        self.activityRawValue = activity.rawValue
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.maxSpeedMPS = maxSpeedMPS
        let pairs = locations.map { [$0.coordinate.latitude, $0.coordinate.longitude] }
        self.encodedRoute = (try? JSONEncoder().encode(pairs)) ?? Data()
    }

    var activity: ActivityType { ActivityType(rawValue: activityRawValue) ?? .drive }

    var routeCoordinates: [CLLocationCoordinate2D] {
        guard let pairs = try? JSONDecoder().decode([[Double]].self, from: encodedRoute) else { return [] }
        return pairs.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
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
    @Published var tripStart: Date? = nil
    @Published var accumulatedTime: TimeInterval = 0
    @Published var routeLocations: [CLLocation] = []
    @Published var activity: ActivityType = .drive

    // Session bookkeeping for HealthKit
    @Published var sessionStart: Date? = nil
    @Published var sessionEnd: Date? = nil
    @Published var segments: [(start: Date, end: Date)] = []

    // Auto start — resets to off each launch
    @Published var autoStart: Bool = false
    @Published var autoEndRequested: Bool = false
    var isArmed: Bool { autoStart && !isTracking }

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation? = nil
    private var stopTimer: Timer? = nil

    // Thresholds vary by activity (m/s)
    private var autoStartThreshold: Double {
        switch activity {
        case .drive: return 2.2   // ~5 mph
        case .bike:  return 3.6   // ~8 mph
        case .walk:  return 0.7   // ~1.5 mph
        }
    }
    private var autoStopThreshold: Double {
        switch activity {
        case .drive: return 1.0   // ~2.2 mph
        case .bike:  return 2.2   // ~5 mph
        case .walk:  return 0.4   // ~0.9 mph
        }
    }
    private var autoStopDelay: TimeInterval {
        activity == .drive ? 30 : 15
    }

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
        cancelAutoStop()
        if let start = tripStart {
            let now = Date()
            accumulatedTime += now.timeIntervalSince(start)
            segments.append((start: start, end: now))
        }
        tripStart = nil
        sessionEnd = Date()
        isTracking = false
    }

    func resetTrip() {
        cancelAutoStop()
        autoEndRequested = false
        pauseTrip()
        tripDistanceMeters = 0
        maxSpeedMetersPerSecond = 0
        accumulatedTime = 0
        routeLocations.removeAll()
        lastLocation = nil
        sessionStart = nil
        sessionEnd = nil
        segments.removeAll()
    }

    var elapsed: TimeInterval {
        accumulatedTime + (tripStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var hasSavableTrip: Bool {
        !isTracking
        && activity.savableToHealth
        && tripDistanceMeters > 10
        && sessionStart != nil
        && sessionEnd != nil
        && routeLocations.count > 1
    }

    var hasHistoryToSave: Bool {
        tripDistanceMeters > 10
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    private func scheduleAutoStop() {
        guard stopTimer == nil else { return }
        stopTimer = Timer.scheduledTimer(withTimeInterval: autoStopDelay, repeats: false) { [weak self] _ in
            // Signal the view to save to history, then reset
            self?.autoEndRequested = true
        }
    }

    private func cancelAutoStop() {
        stopTimer?.invalidate()
        stopTimer = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        accuracy = location.horizontalAccuracy
        let speed = location.speed
        speedMetersPerSecond = speed >= 0 ? speed : 0

        // Auto start / auto pause logic
        if autoStart {
            if !isTracking, speedMetersPerSecond >= autoStartThreshold,
               location.horizontalAccuracy >= 0, location.horizontalAccuracy < 50 {
                startTrip()
            } else if isTracking {
                if speedMetersPerSecond < autoStopThreshold {
                    scheduleAutoStop()
                } else {
                    cancelAutoStop()
                }
            }
        }

        guard isTracking,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy < 50 else { return }

        if speedMetersPerSecond > maxSpeedMetersPerSecond {
            maxSpeedMetersPerSecond = speedMetersPerSecond
        }

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
        let segments = trip.segments

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

                let config = HKWorkoutConfiguration()
                config.activityType = activity.hkActivityType
                config.locationType = .outdoor

                let builder = HKWorkoutBuilder(healthStore: store,
                                               configuration: config,
                                               device: .local())

                try await builder.beginCollection(at: start)

                if segments.count > 1 {
                    var events: [HKWorkoutEvent] = []
                    for i in 0..<(segments.count - 1) {
                        events.append(HKWorkoutEvent(type: .pause,
                                                      dateInterval: DateInterval(start: segments[i].end, duration: 0),
                                                      metadata: nil))
                        events.append(HKWorkoutEvent(type: .resume,
                                                      dateInterval: DateInterval(start: segments[i + 1].start, duration: 0),
                                                      metadata: nil))
                    }
                    try await builder.addWorkoutEvents(events)
                }

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
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 14) {

            Picker("Activity", selection: $trip.activity) {
                ForEach(ActivityType.allCases) { a in
                    Label(a.rawValue, systemImage: a.symbol).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .disabled(trip.isTracking)
            .onChange(of: trip.activity) { trip.applyActivityTuning() }

            Toggle(isOn: $trip.autoStart) {
                Label("Auto Start", systemImage: "bolt.fill")
                    .font(.subheadline)
            }
            .disabled(trip.isTracking)

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
        .onChange(of: trip.autoEndRequested) { _, requested in
            guard requested else { return }
            saveToHistory()
            trip.resetTrip()
        }
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
            if trip.isArmed {
                Label("Waiting for movement…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    trip.isTracking ? trip.pauseTrip() : trip.startTrip()
                } label: {
                    Label(trip.isTracking ? "Pause" : "Start",
                          systemImage: trip.isTracking ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(trip.isTracking ? .orange : .green)
            }

            Button(role: .destructive) {
                saveToHistory()
                trip.resetTrip()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private func saveToHistory() {
        guard trip.hasHistoryToSave else { return }
        let record = TripRecord(
            date: trip.sessionStart ?? Date(),
            activity: trip.activity,
            distanceMeters: trip.tripDistanceMeters,
            durationSeconds: trip.elapsed,
            maxSpeedMPS: trip.maxSpeedMetersPerSecond,
            locations: trip.routeLocations
        )
        modelContext.insert(record)
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

// MARK: - History List Row

struct TripRowView: View {
    let record: TripRecord
    let useMPH: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.activity.symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                HStack(spacing: 12) {
                    Label(Units.distanceString(record.distanceMeters, mph: useMPH),
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    Label(Units.durationString(record.durationSeconds),
                          systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Trip Detail View

struct TripDetailView: View {
    let record: TripRecord
    let useMPH: Bool

    private var routeRegion: MKCoordinateRegion {
        let coords = record.routeCoordinates
        guard !coords.isEmpty else { return MKCoordinateRegion() }
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.5 + 0.005,
                                    longitudeDelta: (maxLon - minLon) * 1.5 + 0.005)
        return MKCoordinateRegion(center: center, span: span)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if record.routeCoordinates.count > 1 {
                    Map(initialPosition: .region(routeRegion)) {
                        MapPolyline(coordinates: record.routeCoordinates)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        if let first = record.routeCoordinates.first {
                            Marker("Start", systemImage: "flag.fill", coordinate: first)
                                .tint(.green)
                        }
                        if let last = record.routeCoordinates.last {
                            Marker("End", systemImage: "flag.checkered", coordinate: last)
                                .tint(.red)
                        }
                    }
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statCard("Distance",
                             Units.distanceString(record.distanceMeters, mph: useMPH),
                             "point.topleft.down.to.point.bottomright.curvepath")
                    statCard("Duration",
                             Units.durationString(record.durationSeconds),
                             "clock")
                    statCard("Max Speed",
                             String(format: "%.0f %@",
                                    Units.speed(record.maxSpeedMPS, mph: useMPH),
                                    useMPH ? "mph" : "km/h"),
                             "speedometer")
                    statCard("Activity",
                             record.activity.rawValue,
                             record.activity.symbol)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(record.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statCard(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .multilineTextAlignment(.center)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - History Tab

struct HistoryView: View {
    @Query(sort: \TripRecord.date, order: .reverse) private var records: [TripRecord]
    @Environment(\.modelContext) private var modelContext
    let useMPH: Bool

    var body: some View {
        NavigationStack {
            List {
                ForEach(records) { record in
                    NavigationLink(destination: TripDetailView(record: record, useMPH: useMPH)) {
                        TripRowView(record: record, useMPH: useMPH)
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { modelContext.delete(records[i]) }
                }
            }
            .navigationTitle("History")
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No Trips Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Completed trips will appear here after you reset.")
                    )
                }
            }
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

            HistoryView(useMPH: useMPH)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
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
        .modelContainer(for: TripRecord.self)
    }
}
