import MapKit
import SwiftUI

/// Rota ve araç konumunu gösteren harita; kamera aracı takip eder.
@MainActor
struct NavigationMapView: View {
    @ObservedObject var navigation: NavigationEngine
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)

    var body: some View {
        Map(position: $camera, interactionModes: []) {
            if let plan = navigation.plan {
                MapPolyline(coordinates: plan.coordinates)
                    .stroke(Color(red: 0.2, green: 0.6, blue: 1.0), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                Marker(plan.destinationName, systemImage: "flag.checkered", coordinate: plan.destinationCoordinate)
                    .tint(.orange)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: true))
        .mapControlVisibility(.hidden)
        .onChange(of: navigation.plan?.id) { _, _ in
            camera = .userLocation(followsHeading: true, fallback: fallbackRegion)
        }
        .onAppear {
            camera = .userLocation(followsHeading: true, fallback: fallbackRegion)
        }
    }

    private var fallbackRegion: MapCameraPosition {
        guard let plan = navigation.plan else { return .automatic }
        let latitudes = plan.coordinates.map(\.latitude)
        let longitudes = plan.coordinates.map(\.longitude)
        guard let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
              let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLatitude - minLatitude) * 1.4),
            longitudeDelta: max(0.01, (maxLongitude - minLongitude) * 1.4)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

/// Kalan mesafe, süre ve varış saati.
struct NavigationStatusLine: View {
    @ObservedObject var navigation: NavigationEngine
    var unit: CGFloat

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 11 * unit, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10 * unit)
                .padding(.vertical, 5 * unit)
                .background(Color.black.opacity(0.55), in: Capsule())
        }
    }

    private var text: String? {
        guard let plan = navigation.plan else { return nil }
        if let progress = navigation.progress {
            return "\(NavigationFormat.distance(progress.remainingDistance)) · \(NavigationFormat.duration(progress.remainingTime)) · \(NavigationFormat.clock(progress.eta))"
        }
        return plan.summary
    }
}
