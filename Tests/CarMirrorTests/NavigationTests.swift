import CoreLocation
import XCTest
@testable import CarMirror

// MARK: - Sahteler

final class FakeLocationSource: LocationSource {
    var onUpdate: ((CLLocation) -> Void)?
    var latest: CLLocation?
    var authorized: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(authorized: Bool, latest: CLLocationCoordinate2D? = nil) {
        self.authorized = authorized
        if let latest {
            self.latest = CLLocation(latitude: latest.latitude, longitude: latest.longitude)
        }
    }

    func requestAuthorization() async -> Bool { authorized }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }

    func move(to coordinate: CLLocationCoordinate2D) {
        let fix = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        latest = fix
        onUpdate?(fix)
    }
}

final class FakeRouter: RouteProvider {
    var places: [PlaceResult] = []
    var plan: RoutePlan?
    private(set) var searchQueries: [String] = []
    private(set) var routeCalls = 0

    func search(_ query: String, near: CLLocationCoordinate2D?) async throws -> [PlaceResult] {
        searchQueries.append(query)
        return places
    }

    func route(from origin: CLLocationCoordinate2D, to place: PlaceResult) async throws -> RoutePlan {
        routeCalls += 1
        guard let plan else { throw NavigationError.routeFailed }
        return plan
    }
}

final class FakePresenter: NavigationPresenter {
    private(set) var startCount = 0
    private(set) var updates: [NavigationProgress] = []
    private(set) var endings: [Bool] = []

    func navigationDidStart(_ plan: RoutePlan, from origin: CLLocationCoordinate2D) { startCount += 1 }
    func navigationDidUpdate(_ progress: NavigationProgress, plan: RoutePlan) { updates.append(progress) }
    func navigationDidEnd(arrived: Bool) { endings.append(arrived) }
}

/// Kuzeye düz bir deneme rotası: başlangıçta sağa dön, 500 m sonra sola dön, 300 m sonra hedef.
enum TestRoute {
    static let origin = CLLocationCoordinate2D(latitude: 41.0, longitude: 29.0)

    static func point(metersNorth: Double, metersEast: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: 41.0 + metersNorth / 110_540,
            longitude: 29.0 + metersEast / (111_320 * cos(41.0 * .pi / 180))
        )
    }

    static let destination = point(metersNorth: 800)
    static let place = PlaceResult(name: "Test Hedefi", address: "Test Mahallesi", coordinate: destination, distance: 800)

    static func plan() -> RoutePlan {
        let turnLeft = point(metersNorth: 500)
        return RoutePlan(
            destinationName: "Test Hedefi",
            destinationCoordinate: destination,
            coordinates: [origin, turnLeft, destination],
            steps: [
                RouteStep(instructions: "Proceed to the route", distance: 0, coordinates: [origin]),
                RouteStep(instructions: "Turn right onto Test Street", distance: 500, coordinates: [origin, turnLeft]),
                RouteStep(instructions: "Turn left onto Finish Avenue", distance: 300, coordinates: [turnLeft, destination]),
            ],
            distance: 800,
            expectedTravelTime: 160
        )
    }
}

// MARK: - Testler

final class NavigationEngineTests: XCTestCase {
    private var location: FakeLocationSource!
    private var router: FakeRouter!
    private var presenter: FakePresenter!
    private var engine: NavigationEngine!
    private var announcements: [String] = []

    override func setUp() {
        super.setUp()
        location = FakeLocationSource(authorized: true, latest: TestRoute.origin)
        router = FakeRouter()
        router.places = [TestRoute.place]
        router.plan = TestRoute.plan()
        presenter = FakePresenter()
        announcements = []
        engine = NavigationEngine(location: location, router: router)
        engine.presenter = presenter
        engine.onAnnouncement = { [weak self] text in self?.announcements.append(text) }
    }

    func testStartFindsPlaceRoutesAndAnnouncesFirstManeuver() async throws {
        let plan = try await engine.start(to: "test hedefi", announceSummary: true)
        XCTAssertEqual(plan.destinationName, "Test Hedefi")
        XCTAssertEqual(router.searchQueries, ["test hedefi"])
        XCTAssertEqual(engine.state, .navigating)
        XCTAssertEqual(presenter.startCount, 1)
        XCTAssertEqual(location.startCount, 2, "izin alınınca ve rota başlayınca konum güncellemeleri açılır")
        XCTAssertEqual(announcements.count, 2)
        XCTAssertTrue(announcements[0].contains("Rota hazır"), announcements[0])
        XCTAssertTrue(announcements[0].contains("800 metre"), announcements[0])
        XCTAssertEqual(announcements[1], "Şimdi: Turn right onto Test Street")
    }

    func testAnnouncesApproachingManeuversAndArrival() async throws {
        try await engine.start(to: "test hedefi", announceSummary: false)
        announcements.removeAll()

        location.move(to: TestRoute.point(metersNorth: 250))
        XCTAssertEqual(announcements, ["250 metre sonra: Turn left onto Finish Avenue"])
        let progress = try XCTUnwrap(engine.progress)
        XCTAssertEqual(progress.stepIndex, 1)
        XCTAssertEqual(progress.distanceToManeuver, 250, accuracy: 5)
        XCTAssertEqual(progress.remainingDistance, 550, accuracy: 5)
        XCTAssertEqual(progress.remainingTime, 110, accuracy: 2)

        location.move(to: TestRoute.point(metersNorth: 490))
        XCTAssertEqual(announcements.count, 3, "\(announcements)")
        XCTAssertEqual(announcements[1], "Şimdi: Turn left onto Finish Avenue")
        XCTAssertEqual(announcements[2], "Hedefiniz 300 metre ileride.")
        XCTAssertEqual(engine.progress?.stepIndex, 2)

        location.move(to: TestRoute.destination)
        XCTAssertEqual(engine.state, .arrived)
        XCTAssertTrue(announcements.last?.contains("vardınız") == true, "\(announcements)")
        XCTAssertEqual(presenter.endings, [true])
        XCTAssertGreaterThan(presenter.updates.count, 1)
        XCTAssertTrue(engine.statusDescription().contains("Test Hedefi"))
    }

    func testOffRouteTriggersReroute() async throws {
        try await engine.start(to: "test hedefi", announceSummary: false)
        announcements.removeAll()

        for _ in 0..<3 {
            location.move(to: TestRoute.point(metersNorth: 100, metersEast: 200))
        }
        XCTAssertTrue(announcements.contains { $0.contains("yeniden hesaplanıyor") }, "\(announcements)")
        waitUntil(timeout: 3, message: "yeniden rota istenmedi") { self.router.routeCalls == 2 }
        waitUntil(timeout: 3, message: "yeni rota sunulmadı") { self.presenter.startCount == 2 }
        XCTAssertEqual(presenter.endings, [false])
        XCTAssertEqual(engine.state, .navigating)
    }

    func testStopEndsSession() async throws {
        try await engine.start(to: "test hedefi", announceSummary: false)
        engine.stop()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.plan)
        XCTAssertEqual(presenter.endings, [false])
        XCTAssertEqual(engine.statusDescription(), "Aktif navigasyon yok.")
    }

    func testMissingLocationPermission() async {
        location.authorized = false
        do {
            try await engine.start(to: "test hedefi", announceSummary: false)
            XCTFail("konum hatası bekleniyordu")
        } catch let error as NavigationError {
            guard case .noLocation = error else { return XCTFail("beklenmeyen hata: \(error)") }
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
        XCTAssertEqual(engine.isLocationAuthorized, false)
        XCTAssertEqual(engine.state, .idle)
    }

    func testUnknownPlace() async {
        router.places = []
        do {
            try await engine.start(to: "yok böyle bir yer", announceSummary: false)
            XCTFail("bulunamadı hatası bekleniyordu")
        } catch let error as NavigationError {
            guard case .notFound = error else { return XCTFail("beklenmeyen hata: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("yok böyle bir yer"))
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }

    func testSearchPlacesSortsByDistanceAndLimits() async throws {
        router.places = [
            PlaceResult(name: "Uzak", address: "", coordinate: TestRoute.origin, distance: 3000),
            PlaceResult(name: "Yakın", address: "", coordinate: TestRoute.origin, distance: 200),
            PlaceResult(name: "Orta", address: "", coordinate: TestRoute.origin, distance: 900),
            PlaceResult(name: "En uzak", address: "", coordinate: TestRoute.origin, distance: 9000),
        ]
        let results = try await engine.searchPlaces("kahveci")
        XCTAssertEqual(results.map(\.name), ["Yakın", "Orta", "Uzak"])
        XCTAssertEqual(engine.lastSearchResults.count, 3)
    }

    func testFormatting() {
        XCTAssertEqual(NavigationFormat.distance(840), "840 metre")
        XCTAssertEqual(NavigationFormat.distance(12_400), "12 kilometre")
        XCTAssertEqual(NavigationFormat.distance(2_350), "2,4 kilometre")
        XCTAssertEqual(NavigationFormat.spokenDistance(270), "250 metre")
        XCTAssertEqual(NavigationFormat.spokenDistance(1_500), "1,5 kilometre")
        XCTAssertEqual(NavigationFormat.duration(25 * 60), "25 dakika")
        XCTAssertEqual(NavigationFormat.duration(70 * 60), "1 saat 10 dakika")
        XCTAssertEqual(NavigationFormat.duration(20), "bir dakikadan az")
    }

    func testGeometry() {
        let a = TestRoute.origin
        let b = TestRoute.point(metersNorth: 1000)
        let beside = TestRoute.point(metersNorth: 500, metersEast: 80)
        XCTAssertEqual(NavigationGeometry.distance(from: beside, toSegment: a, b), 80, accuracy: 2)
        let beyond = TestRoute.point(metersNorth: 1300)
        XCTAssertEqual(NavigationGeometry.distance(from: beyond, toSegment: a, b), 300, accuracy: 3)
    }
}
