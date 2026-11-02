import CarPlay
import CoreLocation
import MapKit
import UIKit

/// CarPlay sahnesi. Özel bir pencereye (CPWindow) çizim yapabilmek için
/// uygulamanın navigasyon uygulaması olarak (`com.apple.developer.carplay-maps`)
/// tanımlanması gerekir; kök şablon bir `CPMapTemplate`'tir. Pencerede
/// asistan, navigasyon haritası ya da yansıtılan telefon ekranı gösterilir;
/// manevra kartları ve varış paneli CarPlay'in kendi arayüzüyle çizilir.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapTemplate: CPMapTemplate?
    private var mirrorViewController: CarPlayMirrorViewController?

    private var navigationSession: CPNavigationSession?
    private var trip: CPTrip?
    private var maneuvers: [CPManeuver] = []
    private var currentManeuverIndex = -1

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        carWindow = window

        let viewController = CarPlayMirrorViewController()
        window.rootViewController = viewController
        mirrorViewController = viewController

        let mapTemplate = CPMapTemplate()
        mapTemplate.automaticallyHidesNavigationBar = true
        mapTemplate.hidesButtonsWithNavigationBar = true
        mapTemplate.trailingNavigationBarButtons = [makeFillButton(for: viewController)]
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)
        self.mapTemplate = mapTemplate

        NSLog("CarMirror: CarPlay bağlandı")
        MirrorReceiver.shared.restartListener()
        MirrorReceiver.shared.setSink(viewController.sink)
        MirrorState.shared.update(carPlayConnected: true)
        NavigationEngine.shared.presenter = self

        #if targetEnvironment(simulator)
        // Simülatörde iOS ekran yayını çalışmadığından CarPlay ekranı açılınca
        // uygulamanın kendi ekranı yansıtılmaya başlar (asistan sekmesi hariç).
        InAppMirror.shared.autoStartWhenPossible = true
        InAppMirror.shared.startOnPhoneWindow(automatic: true)
        #endif
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        NSLog("CarMirror: CarPlay ayrıldı")
        MirrorReceiver.shared.setSink(nil)
        MirrorState.shared.update(carPlayConnected: false)
        if NavigationEngine.shared.presenter === self {
            NavigationEngine.shared.presenter = nil
        }
        navigationSession = nil
        trip = nil
        maneuvers = []
        mirrorViewController = nil
        mapTemplate = nil
        carWindow = nil
        self.interfaceController = nil

        #if targetEnvironment(simulator)
        InAppMirror.shared.autoStartWhenPossible = false
        InAppMirror.shared.stop()
        #endif
    }

    private func makeFillButton(for viewController: CarPlayMirrorViewController) -> CPBarButton {
        CPBarButton(title: Self.fillButtonTitle(fillsScreen: viewController.fillsScreen)) { [weak viewController] button in
            guard let viewController else { return }
            viewController.fillsScreen.toggle()
            button.title = Self.fillButtonTitle(fillsScreen: viewController.fillsScreen)
        }
    }

    private static func fillButtonTitle(fillsScreen: Bool) -> String {
        fillsScreen ? "Sığdır" : "Doldur"
    }
}

// MARK: - Navigasyon (CarPlay manevra kartları ve varış paneli)

extension CarPlaySceneDelegate: NavigationPresenter {
    func navigationDidStart(_ plan: RoutePlan, from origin: CLLocationCoordinate2D) {
        guard let mapTemplate else { return }
        NSLog("CarMirror: CarPlay navigasyon oturumu başlıyor: \(plan.destinationName), \(plan.steps.count) adım")
        endSession(arrived: false)

        let originItem = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        originItem.name = "Konumunuz"
        let destinationItem = MKMapItem(placemark: MKPlacemark(coordinate: plan.destinationCoordinate))
        destinationItem.name = plan.destinationName
        let choice = CPRouteChoice(
            summaryVariants: [plan.summary],
            additionalInformationVariants: ["En hızlı rota"],
            selectionSummaryVariants: [plan.destinationName]
        )
        let trip = CPTrip(origin: originItem, destination: destinationItem, routeChoices: [choice])
        self.trip = trip

        maneuvers = plan.steps.map { step in
            let maneuver = CPManeuver()
            maneuver.instructionVariants = [step.instructions.isEmpty ? plan.destinationName : step.instructions]
            maneuver.symbolImage = Self.symbol(for: step.instructions)
            maneuver.initialTravelEstimates = CPTravelEstimates(
                distanceRemaining: Measurement(value: step.distance, unit: UnitLength.meters),
                timeRemaining: plan.distance > 0 ? plan.expectedTravelTime * step.distance / plan.distance : 0
            )
            return maneuver
        }
        currentManeuverIndex = -1

        navigationSession = mapTemplate.startNavigationSession(for: trip)
        mapTemplate.update(
            CPTravelEstimates(distanceRemaining: Measurement(value: plan.distance, unit: UnitLength.meters), timeRemaining: plan.expectedTravelTime),
            for: trip,
            with: .default
        )
        showManeuver(after: 0, distance: plan.steps.first?.distance ?? 0, time: 0, plan: plan)
    }

    func navigationDidUpdate(_ progress: NavigationProgress, plan: RoutePlan) {
        guard let mapTemplate, let trip, navigationSession != nil else { return }
        mapTemplate.update(
            CPTravelEstimates(distanceRemaining: Measurement(value: progress.remainingDistance, unit: UnitLength.meters), timeRemaining: progress.remainingTime),
            for: trip,
            with: .default
        )
        let ratio = plan.distance > 0 ? progress.distanceToManeuver / plan.distance : 0
        showManeuver(after: progress.stepIndex, distance: progress.distanceToManeuver, time: plan.expectedTravelTime * ratio, plan: plan)
    }

    func navigationDidEnd(arrived: Bool) {
        endSession(arrived: arrived)
    }

    /// `stepIndex` adımı üzerinde gidilirken gösterilecek kart: bir sonraki adımın manevrası.
    private func showManeuver(after stepIndex: Int, distance: CLLocationDistance, time: TimeInterval, plan: RoutePlan) {
        guard let navigationSession else { return }
        let nextIndex = stepIndex + 1
        let estimates = CPTravelEstimates(distanceRemaining: Measurement(value: max(0, distance), unit: UnitLength.meters), timeRemaining: max(0, time))
        if nextIndex < maneuvers.count {
            if nextIndex != currentManeuverIndex {
                currentManeuverIndex = nextIndex
                navigationSession.upcomingManeuvers = [maneuvers[nextIndex]]
            }
            navigationSession.updateEstimates(estimates, for: maneuvers[nextIndex])
        } else {
            // Son adım: hedefe varış kartı.
            if currentManeuverIndex != maneuvers.count {
                currentManeuverIndex = maneuvers.count
                let arrival = CPManeuver()
                arrival.instructionVariants = ["Hedef: \(plan.destinationName)"]
                arrival.symbolImage = UIImage(systemName: "flag.checkered")
                navigationSession.upcomingManeuvers = [arrival]
            }
            if let maneuver = navigationSession.upcomingManeuvers.first {
                navigationSession.updateEstimates(estimates, for: maneuver)
            }
        }
    }

    private func endSession(arrived: Bool) {
        guard let navigationSession else { return }
        if arrived {
            navigationSession.finishTrip()
        } else {
            navigationSession.cancelTrip()
        }
        self.navigationSession = nil
        trip = nil
        maneuvers = []
        currentManeuverIndex = -1
    }

    private static func symbol(for instructions: String) -> UIImage? {
        let text = instructions.lowercased()
        let name: String
        if text.contains("u-turn") || text.contains("u dönüşü") {
            name = "arrow.uturn.left"
        } else if text.contains("right") || text.contains("sağ") {
            name = text.contains("slight") || text.contains("hafif") ? "arrow.up.right" : "arrow.turn.up.right"
        } else if text.contains("left") || text.contains("sol") {
            name = text.contains("slight") || text.contains("hafif") ? "arrow.up.left" : "arrow.turn.up.left"
        } else if text.contains("roundabout") || text.contains("kavşak") || text.contains("döner") {
            name = "arrow.triangle.turn.up.right.circle"
        } else if text.contains("exit") || text.contains("çıkış") {
            name = "arrow.up.right"
        } else if text.contains("arrive") || text.contains("destination") || text.contains("varış") || text.contains("hedef") {
            name = "flag.checkered"
        } else {
            name = "arrow.up"
        }
        return UIImage(systemName: name)
    }
}
