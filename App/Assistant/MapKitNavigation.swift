import CoreLocation
import Foundation
import MapKit

/// Core Location ile gerçek konum.
final class CoreLocationSource: NSObject, LocationSource, CLLocationManagerDelegate {
    var onUpdate: ((CLLocation) -> Void)?
    private(set) var latest: CLLocation?

    private let manager = CLLocationManager()
    private var authorizationContinuations: [CheckedContinuation<Bool, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 5
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func requestAuthorization() async -> Bool {
        if isAuthorized { return true }
        guard manager.authorizationStatus == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            authorizationContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let authorized = isAuthorized
        let pending = authorizationContinuations
        authorizationContinuations.removeAll()
        pending.forEach { $0.resume(returning: authorized) }
        if authorized {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        latest = fix
        onUpdate?(fix)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("CarMirror: konum hatası: \(error.localizedDescription)")
    }
}

/// MapKit ile yer arama ve araç rotası.
struct MapKitRouteProvider: RouteProvider {
    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [PlaceResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        let origin = near.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        return response.mapItems.prefix(8).map { item in
            let coordinate = item.placemark.coordinate
            let distance = origin?.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            return PlaceResult(name: item.name ?? query, address: Self.address(of: item), coordinate: coordinate, distance: distance)
        }
    }

    func route(from origin: CLLocationCoordinate2D, to place: PlaceResult) async throws -> RoutePlan {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        destination.name = place.name
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw NavigationError.routeFailed }
        return RoutePlan(route: route, destination: place)
    }

    private static func address(of item: MKMapItem) -> String {
        let placemark = item.placemark
        let parts = [placemark.thoroughfare, placemark.subLocality, placemark.locality]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

extension RoutePlan {
    init(route: MKRoute, destination: PlaceResult) {
        let steps = route.steps.map { step in
            RouteStep(instructions: step.instructions, distance: step.distance, coordinates: step.polyline.coordinateList)
        }
        self.init(
            destinationName: destination.name,
            destinationCoordinate: destination.coordinate,
            coordinates: route.polyline.coordinateList,
            steps: steps.isEmpty ? [RouteStep(instructions: "", distance: route.distance, coordinates: route.polyline.coordinateList)] : steps,
            distance: route.distance,
            expectedTravelTime: route.expectedTravelTime
        )
    }
}

extension MKMultiPoint {
    var coordinateList: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
