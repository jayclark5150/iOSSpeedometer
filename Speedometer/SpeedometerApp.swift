//
//  SpeedometerApp.swift
//  A minimal GPS speedometer for iPhone.
//
//  Setup:
//  1. Xcode -> New Project -> iOS App -> SwiftUI, name it "Speedometer"
//  2. Replace the contents of the generated App file with this file
//     (or delete ContentView.swift and paste all of this into the App file).
//  3. Target -> Info tab -> add key:
//     "Privacy - Location When In Use Usage Description"
//     value: "Used to display your current speed."
//  4. Run on a real iPhone (the Simulator can fake location via
//     Features -> Location -> Freeway Drive).
//

import SwiftUI
import CoreLocation
import Combine

// MARK: - Location / Speed Manager

final class SpeedManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var speedMetersPerSecond: Double = 0        // raw from GPS
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var accuracy: Double = -1                   // horizontal accuracy in meters

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
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

        // speed is m/s; negative means invalid (no fix yet, or standing still with poor signal)
        let speed = location.speed
        speedMetersPerSecond = speed >= 0 ? speed : 0
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Common on first launch before the user grants permission; safe to ignore here.
        print("Location error: \(error.localizedDescription)")
    }
}

// MARK: - Main View

struct SpeedometerView: View {

    @StateObject private var speedManager = SpeedManager()
    @State private var useMPH = true

    private var displaySpeed: Double {
        useMPH
            ? speedManager.speedMetersPerSecond * 2.23694   // m/s -> mph
            : speedManager.speedMetersPerSecond * 3.6       // m/s -> km/h
    }

    var body: some View {
        VStack(spacing: 24) {

            Spacer()

            // Big speed readout
            Text(String(format: "%.0f", displaySpeed))
                .font(.system(size: 140, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: displaySpeed)

            Text(useMPH ? "mph" : "km/h")
                .font(.title2)
                .foregroundStyle(.secondary)

            Spacer()

            // GPS accuracy indicator
            if speedManager.accuracy >= 0 {
                Label(
                    String(format: "GPS accuracy: ±%.0f m", speedManager.accuracy),
                    systemImage: speedManager.accuracy < 20 ? "location.fill" : "location.slash"
                )
                .font(.footnote)
                .foregroundStyle(speedManager.accuracy < 20 ? .green : .orange)
            }

            // Unit toggle
            Picker("Units", selection: $useMPH) {
                Text("mph").tag(true)
                Text("km/h").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            .padding(.bottom, 32)

            // Permission prompt if denied
            if speedManager.authorizationStatus == .denied {
                Text("Location access is denied. Enable it in Settings > Privacy > Location Services.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
        .onAppear {
            speedManager.start()
            UIApplication.shared.isIdleTimerDisabled = true   // keep screen awake while driving
        }
        .onDisappear {
            speedManager.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - App Entry Point

@main
struct SpeedometerApp: App {
    var body: some Scene {
        WindowGroup {
            SpeedometerView()
        }
    }
}
