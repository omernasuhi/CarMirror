import Combine
import CoreLocation
import Foundation

// MARK: - Modeller

struct RouteStep {
    var instructions: String
    /// Manevradan sonra bu adım boyunca gidilecek mesafe (metre).
    var distance: CLLocationDistance
    var coordinates: [CLLocationCoordinate2D]

    var endCoordinate: CLLocationCoordinate2D { coordinates.last ?? CLLocationCoordinate2D() }
}

struct RoutePlan: Identifiable {
    let id = UUID()
    var destinationName: String
    var destinationCoordinate: CLLocationCoordinate2D
    var coordinates: [CLLocationCoordinate2D]
    var steps: [RouteStep]
    var distance: CLLocationDistance
    var expectedTravelTime: TimeInterval

    var summary: String {
        "\(NavigationFormat.distance(distance)) · \(NavigationFormat.duration(expectedTravelTime))"
    }
}

struct NavigationProgress: Equatable {
    /// Üzerinde ilerlenen adım.
    var stepIndex: Int
    /// Bir sonraki manevraya (adımın sonuna) kalan mesafe.
    var distanceToManeuver: CLLocationDistance
    var remainingDistance: CLLocationDistance
    var remainingTime: TimeInterval
    var eta: Date
}

struct PlaceResult: Equatable {
    var name: String
    var address: String
    var coordinate: CLLocationCoordinate2D
    var distance: CLLocationDistance?

    static func == (lhs: PlaceResult, rhs: PlaceResult) -> Bool {
        lhs.name == rhs.name && lhs.address == rhs.address
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

enum NavigationError: LocalizedError {
    case noLocation
    case notFound(String)
    case routeFailed

    var errorDescription: String? {
        switch self {
        case .noLocation: return "Konum alınamadı; konum iznini kontrol edin."
        case let .notFound(query): return "\"\(query)\" için yer bulunamadı."
        case .routeFailed: return "Rota hesaplanamadı."
        }
    }
}

/// Konum kaynağı (gerçekte Core Location; testlerde sahte).
protocol LocationSource: AnyObject {
    var onUpdate: ((CLLocation) -> Void)? { get set }
    var latest: CLLocation? { get }
    func requestAuthorization() async -> Bool
    func start()
    func stop()
}

/// Yer arama ve rota hesaplama (gerçekte MapKit; testlerde sahte).
protocol RouteProvider {
    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [PlaceResult]
    func route(from origin: CLLocationCoordinate2D, to place: PlaceResult) async throws -> RoutePlan
}

/// Rota ve manevraları gösteren taraf (CarPlay sahnesi).
protocol NavigationPresenter: AnyObject {
    func navigationDidStart(_ plan: RoutePlan, from origin: CLLocationCoordinate2D)
    func navigationDidUpdate(_ progress: NavigationProgress, plan: RoutePlan)
    func navigationDidEnd(arrived: Bool)
}

// MARK: - Motor

/// Araç içi navigasyon: hedefi bulur, rotayı hesaplar, konumla ilerlemeyi
/// izler, manevraları önceden duyurur ve CarPlay'e manevra kartlarını iletir.
/// Ana iş parçacığından kullanılır.
final class NavigationEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case routing
        case navigating
        case arrived
    }

    static let shared = NavigationEngine(location: CoreLocationSource(), router: MapKitRouteProvider())

    @Published private(set) var state: State = .idle
    @Published private(set) var plan: RoutePlan?
    @Published private(set) var progress: NavigationProgress?
    @Published private(set) var lastSearchResults: [PlaceResult] = []
    @Published private(set) var isLocationAuthorized: Bool?

    /// Sesli duyurular ("300 metre sonra sağa dönün"); ana kuyrukta çağrılır.
    var onAnnouncement: ((String) -> Void)?
    var now: () -> Date = { Date() }
    /// İlk konum için beklenecek süre.
    var locationTimeout: TimeInterval = 6

    weak var presenter: NavigationPresenter? {
        didSet {
            if let plan, let origin, state == .navigating {
                presenter?.navigationDidStart(plan, from: origin)
                if let progress {
                    presenter?.navigationDidUpdate(progress, plan: plan)
                }
            }
        }
    }

    private let location: LocationSource
    private let router: RouteProvider
    private var destination: PlaceResult?
    private var origin: CLLocationCoordinate2D?
    private var stepIndex = 0
    private var announcedThresholds: Set<String> = []
    private var offRouteCount = 0
    private var isRerouting = false

    init(location: LocationSource, router: RouteProvider) {
        self.location = location
        self.router = router
        location.onUpdate = { [weak self] fix in self?.handle(location: fix) }
    }

    var currentLocation: CLLocation? { location.latest }
    var isActive: Bool { state == .navigating || state == .routing }

    // MARK: Komutlar

    /// Hedefi bulup rotayı başlatır.
    @discardableResult
    func start(to query: String, announceSummary: Bool) async throws -> RoutePlan {
        let fix = try await ensureLocation()
        let results = try await router.search(query, near: fix.coordinate)
        guard let place = results.first else { throw NavigationError.notFound(query) }
        return try await route(to: place, from: fix, announceSummary: announceSummary)
    }

    @discardableResult
    func start(to place: PlaceResult, announceSummary: Bool) async throws -> RoutePlan {
        let fix = try await ensureLocation()
        return try await route(to: place, from: fix, announceSummary: announceSummary)
    }

    private func route(to place: PlaceResult, from fix: CLLocation, announceSummary: Bool) async throws -> RoutePlan {
        state = .routing
        do {
            let newPlan = try await router.route(from: fix.coordinate, to: place)
            if announceSummary {
                announce("Rota hazır \(NavigationFormat.honorific). \(newPlan.destinationName): \(NavigationFormat.distance(newPlan.distance)), yaklaşık \(NavigationFormat.duration(newPlan.expectedTravelTime)). Yola çıkıyoruz.")
            }
            begin(newPlan, destination: place, origin: fix.coordinate)
            return newPlan
        } catch {
            state = plan == nil ? .idle : .navigating
            throw error
        }
    }

    func stop() {
        let wasActive = plan != nil
        plan = nil
        progress = nil
        destination = nil
        origin = nil
        state = .idle
        location.stop()
        if wasActive {
            presenter?.navigationDidEnd(arrived: false)
        }
    }

    func searchPlaces(_ query: String, limit: Int = 3) async throws -> [PlaceResult] {
        let near = location.latest?.coordinate
        var results = try await router.search(query, near: near)
        results.sort { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
        let limited = Array(results.prefix(limit))
        lastSearchResults = limited
        return limited
    }

    /// "Ne zaman varırız" için özet.
    func statusDescription() -> String {
        guard let plan else { return "Aktif navigasyon yok." }
        guard let progress else {
            return "\(plan.destinationName) rotası hazırlanıyor: \(plan.summary)."
        }
        let eta = NavigationFormat.clock(progress.eta)
        let next = upcomingInstruction(for: progress.stepIndex) ?? "hedef"
        return "Hedef \(plan.destinationName). Kalan \(NavigationFormat.distance(progress.remainingDistance)), yaklaşık \(NavigationFormat.duration(progress.remainingTime)), varış \(eta). Sıradaki manevra \(NavigationFormat.distance(progress.distanceToManeuver)) sonra: \(next)."
    }

    // MARK: İlerleme

    func handle(location fix: CLLocation) {
        guard let plan, state == .navigating else { return }

        // Hedefe varış
        let destinationDistance = fix.distance(from: CLLocation(latitude: plan.destinationCoordinate.latitude, longitude: plan.destinationCoordinate.longitude))
        if destinationDistance < 40 {
            progress = NavigationProgress(stepIndex: stepIndex, distanceToManeuver: 0, remainingDistance: 0, remainingTime: 0, eta: now())
            state = .arrived
            announce("Hedefinize vardınız \(NavigationFormat.honorific). \(plan.destinationName). İyi günler dilerim.")
            presenter?.navigationDidEnd(arrived: true)
            location.stop()
            return
        }

        // Adımın sonuna (manevra noktasına) yaklaşınca sonraki adıma geç.
        var distanceToManeuver = fix.distance(from: location(of: plan.steps[stepIndex].endCoordinate))
        while stepIndex < plan.steps.count - 1, distanceToManeuver < 25 {
            stepIndex += 1
            announcedThresholds.removeAll()
            distanceToManeuver = fix.distance(from: location(of: plan.steps[stepIndex].endCoordinate))
            if let instruction = upcomingInstruction(for: stepIndex - 1) {
                announce("Şimdi: \(instruction)")
            }
        }

        // Yaklaşan manevra duyuruları
        if let instruction = upcomingInstruction(for: stepIndex) {
            for threshold in [1000.0, 350.0, 70.0] where distanceToManeuver <= threshold {
                let key = "\(stepIndex)-\(Int(threshold))"
                guard !announcedThresholds.contains(key) else { continue }
                announcedThresholds.insert(key)
                if threshold == 70 {
                    announce("Şimdi: \(instruction)")
                } else if threshold == 350 || plan.steps[stepIndex].distance > 1200 {
                    announce("\(NavigationFormat.spokenDistance(distanceToManeuver)) sonra: \(instruction)")
                }
            }
        } else if stepIndex == plan.steps.count - 1 {
            let key = "arrival-350"
            if destinationDistance <= 350, !announcedThresholds.contains(key) {
                announcedThresholds.insert(key)
                announce("Hedefiniz \(NavigationFormat.spokenDistance(destinationDistance)) ileride.")
            }
        }

        // Kalan mesafe ve süre
        let remainingSteps = plan.steps.dropFirst(stepIndex + 1).reduce(0) { $0 + $1.distance }
        let remainingDistance = max(destinationDistance, distanceToManeuver + remainingSteps)
        let ratio = plan.distance > 0 ? min(1, remainingDistance / plan.distance) : 0
        let remainingTime = plan.expectedTravelTime * ratio
        let update = NavigationProgress(
            stepIndex: stepIndex,
            distanceToManeuver: distanceToManeuver,
            remainingDistance: remainingDistance,
            remainingTime: remainingTime,
            eta: now().addingTimeInterval(remainingTime)
        )
        progress = update
        presenter?.navigationDidUpdate(update, plan: plan)

        // Rotadan sapma
        if distanceFromRoute(fix.coordinate, plan: plan) > 80 {
            offRouteCount += 1
            if offRouteCount >= 3 {
                offRouteCount = 0
                reroute(from: fix.coordinate)
            }
        } else {
            offRouteCount = 0
        }
    }

    // MARK: Yardımcılar

    private func begin(_ newPlan: RoutePlan, destination place: PlaceResult, origin start: CLLocationCoordinate2D) {
        plan = newPlan
        destination = place
        origin = start
        stepIndex = 0
        announcedThresholds.removeAll()
        offRouteCount = 0
        progress = nil
        state = .navigating
        location.start()
        presenter?.navigationDidStart(newPlan, from: start)
        if let fix = location.latest {
            handle(location: fix)
        }
    }

    private func reroute(from coordinate: CLLocationCoordinate2D) {
        guard !isRerouting, let destination else { return }
        isRerouting = true
        announce("Rota yeniden hesaplanıyor \(NavigationFormat.honorific).")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRerouting = false }
            do {
                let newPlan = try await self.router.route(from: coordinate, to: destination)
                guard self.state == .navigating else { return }
                self.presenter?.navigationDidEnd(arrived: false)
                self.begin(newPlan, destination: destination, origin: coordinate)
            } catch {
                NSLog("CarMirror: yeniden rota hesaplanamadı: \(error.localizedDescription)")
            }
        }
    }

    private func ensureLocation() async throws -> CLLocation {
        let authorized = await location.requestAuthorization()
        isLocationAuthorized = authorized
        guard authorized else { throw NavigationError.noLocation }
        location.start()
        let deadline = now().addingTimeInterval(locationTimeout)
        while location.latest == nil, now() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let fix = location.latest else { throw NavigationError.noLocation }
        return fix
    }

    /// `index` adımı üzerinde gidilirken sıradaki manevra (bir sonraki adımın talimatı).
    private func upcomingInstruction(for index: Int) -> String? {
        guard let plan, index + 1 < plan.steps.count else { return nil }
        let text = plan.steps[index + 1].instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func announce(_ text: String) {
        onAnnouncement?(text)
    }

    private func location(of coordinate: CLLocationCoordinate2D) -> CLLocation {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Konumun rota çizgisine uzaklığı (metre); yalnızca yakın adımlara bakar.
    func distanceFromRoute(_ coordinate: CLLocationCoordinate2D, plan: RoutePlan) -> CLLocationDistance {
        let lower = max(0, stepIndex - 1)
        let upper = min(plan.steps.count - 1, stepIndex + 1)
        guard lower <= upper else { return 0 }
        var best = CLLocationDistance.greatestFiniteMagnitude
        for index in lower...upper {
            let points = plan.steps[index].coordinates
            if points.count == 1 {
                best = min(best, NavigationGeometry.distance(from: coordinate, to: points[0]))
            }
            for pair in 0..<max(0, points.count - 1) {
                best = min(best, NavigationGeometry.distance(from: coordinate, toSegment: points[pair], points[pair + 1]))
            }
        }
        return best == .greatestFiniteMagnitude ? 0 : best
    }
}

// MARK: - Geometri ve biçimlendirme

enum NavigationGeometry {
    /// Küçük alanlarda yeterli olan düzlem yaklaşımı (metre).
    static func localOffset(of point: CLLocationCoordinate2D, from reference: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let latitudeScale = 110_540.0
        let longitudeScale = 111_320.0 * cos(reference.latitude * .pi / 180)
        return ((point.longitude - reference.longitude) * longitudeScale, (point.latitude - reference.latitude) * latitudeScale)
    }

    static func distance(from point: CLLocationCoordinate2D, to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let offset = localOffset(of: other, from: point)
        return sqrt(offset.x * offset.x + offset.y * offset.y)
    }

    static func distance(from point: CLLocationCoordinate2D, toSegment a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let pa = localOffset(of: a, from: point)
        let pb = localOffset(of: b, from: point)
        let dx = pb.x - pa.x
        let dy = pb.y - pa.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return sqrt(pa.x * pa.x + pa.y * pa.y) }
        // Noktadan doğruya izdüşüm; parça dışına taşarsa uçlara kırp.
        let t = max(0, min(1, (-pa.x * dx - pa.y * dy) / lengthSquared))
        let closestX = pa.x + t * dx
        let closestY = pa.y + t * dy
        return sqrt(closestX * closestX + closestY * closestY)
    }
}

enum NavigationFormat {
    static var honorific: String { AssistantSettings.shared.effectiveHonorific }

    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            let rounded = Int((meters / 10).rounded() * 10)
            return "\(max(rounded, 10)) metre"
        }
        let kilometers = meters / 1000
        let text = kilometers >= 10 ? String(format: "%.0f", kilometers) : String(format: "%.1f", kilometers).replacingOccurrences(of: ".", with: ",")
        return "\(text) kilometre"
    }

    /// Sesli duyuru için kaba yuvarlama ("yaklaşık 300 metre").
    static func spokenDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            let rounded = Int((meters / 50).rounded() * 50)
            return "\(max(rounded, 50)) metre"
        }
        let kilometers = (meters / 100).rounded() / 10
        let text = kilometers == kilometers.rounded() ? String(format: "%.0f", kilometers) : String(format: "%.1f", kilometers).replacingOccurrences(of: ".", with: ",")
        return "\(text) kilometre"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "bir dakikadan az" }
        if minutes < 60 { return "\(minutes) dakika" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) saat" : "\(hours) saat \(rest) dakika"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
